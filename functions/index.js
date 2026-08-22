const admin = require("firebase-admin");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { logger } = require("firebase-functions");

admin.initializeApp();

const database = admin.firestore();
const invalidTokenCodes = new Set([
  "messaging/invalid-registration-token",
  "messaging/registration-token-not-registered"
]);

async function loadTokenRecords(uid) {
  const userReference = database.collection("users").doc(uid);
  const [devicesSnapshot, userSnapshot] = await Promise.all([
    userReference.collection("pushDevices").get(),
    userReference.get()
  ]);
  const records = devicesSnapshot.docs
    .map((document) => ({ token: document.get("token"), reference: document.ref, userReference }))
    .filter((record) => typeof record.token === "string" && record.token.length > 0);
  const knownTokens = new Set(records.map((record) => record.token));

  for (const token of userSnapshot.get("pushTokens") || []) {
    if (typeof token === "string" && token.length > 0 && !knownTokens.has(token)) {
      records.push({ token, reference: null, userReference });
    }
  }
  return records;
}

function eventVersion(snapshot, payload) {
  return String(
    payload.updatedAt?.toMillis?.()
      || payload.createdAt?.toMillis?.()
      || snapshot.createTime?.toMillis?.()
      || "1"
  );
}

async function claimDispatch(dispatchId, version) {
  const reference = database.collection("pushDispatches").doc(dispatchId);
  return database.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(reference);
    const existing = snapshot.data();
    const createdAt = existing?.createdAt?.toDate?.();
    const isRecent = createdAt && Date.now() - createdAt.getTime() < 2 * 60 * 1000;
    const isSameEvent = existing?.eventVersion === version;

    if ((existing?.status === "complete" && isSameEvent) || (existing?.status === "processing" && isRecent)) {
      return null;
    }

    transaction.set(reference, {
      status: "processing",
      eventVersion: version,
      createdAt: admin.firestore.Timestamp.now(),
      updatedAt: admin.firestore.Timestamp.now()
    }, { merge: true });
    return reference;
  });
}

async function removeInvalidTokens(records, response) {
  const operations = [];
  response.responses.forEach((result, index) => {
    if (result.success || !invalidTokenCodes.has(result.error?.code)) return;
    const record = records[index];
    if (record.reference) operations.push(record.reference.delete());
    operations.push(record.userReference.set({
      pushTokens: admin.firestore.FieldValue.arrayRemove(record.token)
    }, { merge: true }));
  });
  await Promise.allSettled(operations);
}

function summarizeDeliveryFailures(response) {
  return response.responses
    .filter((result) => !result.success && result.error?.code)
    .reduce((summary, result) => {
      const code = result.error.code;
      summary[code] = (summary[code] || 0) + 1;
      return summary;
    }, {});
}

async function deliverNotification({ type, resourceId, version, recipientIds, notification, data, category }) {
  const dispatchReference = await claimDispatch(`${type}_${resourceId}`, version);
  if (!dispatchReference) {
    logger.info("Notification already dispatched", { type, resourceId });
    return;
  }

  try {
    if (recipientIds.length === 0) {
      await dispatchReference.set({
        status: "complete",
        sent: 0,
        reason: "no_recipients",
        updatedAt: admin.firestore.Timestamp.now()
      }, { merge: true });
      return;
    }

    const tokenGroups = await Promise.all(recipientIds.map(loadTokenRecords));
    const records = tokenGroups.flat();
    if (records.length === 0) {
      await dispatchReference.set({
        status: "complete",
        sent: 0,
        reason: "no_tokens",
        updatedAt: admin.firestore.Timestamp.now()
      }, { merge: true });
      logger.info("Notification recipients have no device tokens", { type, resourceId });
      return;
    }

    const aps = { sound: "default" };
    if (category) aps.category = category;
    const response = await admin.messaging().sendEachForMulticast({
      tokens: records.map((record) => record.token),
      notification,
      data,
      apns: { payload: { aps } }
    });
    await removeInvalidTokens(records, response);

    const failureCodes = summarizeDeliveryFailures(response);
    await dispatchReference.set({
      status: "complete",
      sent: response.successCount,
      failed: response.failureCount,
      failureCodes,
      updatedAt: admin.firestore.Timestamp.now()
    }, { merge: true });
    logger.info("Push notification dispatched", {
      type,
      resourceId,
      successCount: response.successCount,
      failureCount: response.failureCount,
      failureCodes
    });
  } catch (error) {
    await dispatchReference.delete().catch(() => {});
    logger.error("Push notification failed", { type, resourceId, error });
    throw error;
  }
}

async function friendIdsFor(uid) {
  const friendships = await database
    .collection("friendships")
    .where("memberIds", "array-contains", uid)
    .get();
  const recipientIds = new Set();
  friendships.forEach((document) => {
    const memberIds = document.get("memberIds") || [];
    memberIds
      .filter((memberId) => memberId && memberId !== uid)
      .forEach((memberId) => recipientIds.add(memberId));
  });
  return Array.from(recipientIds);
}

exports.sendRoundPushNotification = onDocumentCreated("sharedRounds/{roundId}", async (event) => {
  const snapshot = event.data;
  const round = snapshot?.data();
  if (!round?.ownerId) {
    logger.warn("Shared round missing ownerId", { roundId: event.params.roundId });
    return;
  }

  const stablefordText = Number.isInteger(round.stableford) ? `, ${round.stableford} pts` : "";
  await deliverNotification({
    type: "sharedRound",
    resourceId: event.params.roundId,
    version: eventVersion(snapshot, round),
    recipientIds: await friendIdsFor(round.ownerId),
    notification: {
      title: `${round.ownerName || "A friend"} completed a round`,
      body: `${round.courseName || "Golf round"}: Gross ${round.gross || "-"}${stablefordText}`
    },
    data: {
      type: "sharedRound",
      sharedRoundId: event.params.roundId,
      ownerId: String(round.ownerId),
      courseName: String(round.courseName || "")
    },
    category: null
  });
});

exports.sendFriendRequestPushNotification = onDocumentCreated("friendRequests/{requestId}", async (event) => {
  const snapshot = event.data;
  const request = snapshot?.data();
  if (!request || request.status !== "pending" || !request.fromUserId || !request.toUserId) {
    logger.info("Friend request push skipped", { requestId: event.params.requestId });
    return;
  }

  const sender = await database.collection("users").doc(request.fromUserId).get();
  const fromName = sender.get("displayName") || "A golfer";
  await deliverNotification({
    type: "friendRequest",
    resourceId: event.params.requestId,
    version: eventVersion(snapshot, request),
    recipientIds: [request.toUserId],
    notification: {
      title: "New friend request",
      body: `${fromName} wants to connect on Precision Golf`
    },
    data: {
      type: "friendRequest",
      friendRequestId: event.params.requestId,
      fromUserId: String(request.fromUserId),
      toUserId: String(request.toUserId),
      fromName: String(fromName)
    },
    category: "FRIEND_REQUEST"
  });
});

exports.sendGroupInvitePushNotification = onDocumentCreated("groupInvites/{inviteId}", async (event) => {
  const snapshot = event.data;
  const invite = snapshot?.data();
  if (!invite || invite.status !== "pending" || !invite.fromUserId || !invite.toUserId || !invite.groupId) {
    logger.info("Group invite push skipped", { inviteId: event.params.inviteId });
    return;
  }

  const sender = await database.collection("users").doc(invite.fromUserId).get();
  const fromName = sender.get("displayName") || "A golfer";
  await deliverNotification({
    type: "groupInvite",
    resourceId: event.params.inviteId,
    version: eventVersion(snapshot, invite),
    recipientIds: [invite.toUserId],
    notification: {
      title: "New golf group invite",
      body: `${fromName} invited you to ${invite.groupName || "a golf group"}`
    },
    data: {
      type: "groupInvite",
      groupInviteId: event.params.inviteId,
      groupId: String(invite.groupId),
      groupName: String(invite.groupName || ""),
      fromUserId: String(invite.fromUserId),
      toUserId: String(invite.toUserId)
    },
    category: "GROUP_INVITE"
  });
});
