import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { firebaseAdmin } from "../lib/firebaseAdmin.js";
import { requireMethod, sendError, sendJson } from "../lib/http.js";

const supportedTypes = new Set(["sharedRound", "friendRequest", "groupInvite"]);
const invalidTokenCodes = new Set([
  "messaging/invalid-registration-token",
  "messaging/registration-token-not-registered"
]);

function bearerToken(req) {
  const header = typeof req.headers.authorization === "string" ? req.headers.authorization : "";
  return header.startsWith("Bearer ") ? header.slice(7).trim() : "";
}

async function loadTokenRecords(firestore, uid) {
  const userReference = firestore.collection("users").doc(uid);
  const [devicesSnapshot, userSnapshot] = await Promise.all([
    userReference.collection("pushDevices").get(),
    userReference.get()
  ]);
  const records = devicesSnapshot.docs
    .map((document) => ({ token: document.get("token"), reference: document.ref }))
    .filter((record) => typeof record.token === "string" && record.token.length > 0);
  const knownTokens = new Set(records.map((record) => record.token));
  for (const token of userSnapshot.get("pushTokens") || []) {
    if (typeof token === "string" && token.length > 0 && !knownTokens.has(token)) {
      records.push({ token, reference: null, userReference });
    }
  }
  return records;
}

async function notificationContext(firestore, type, resourceId, callerUid) {
  if (type === "sharedRound") {
    const snapshot = await firestore.collection("sharedRounds").doc(resourceId).get();
    const round = snapshot.data();
    if (!snapshot.exists || !round || round.ownerId !== callerUid) return null;

    const friendships = await firestore.collection("friendships")
      .where("memberIds", "array-contains", callerUid)
      .get();
    const recipientIds = new Set();
    friendships.forEach((document) => {
      const memberIds = document.get("memberIds") || [];
      memberIds.filter((uid) => uid && uid !== callerUid).forEach((uid) => recipientIds.add(uid));
    });
    const points = Number.isInteger(round.stableford) ? `, ${round.stableford} pts` : "";
    return {
      eventVersion: String(round.updatedAt?.toMillis?.() || round.createdAt?.toMillis?.() || snapshot.createTime?.toMillis?.() || "1"),
      recipientIds: Array.from(recipientIds),
      notification: {
        title: `${round.ownerName || "A friend"} completed a round`,
        body: `${round.courseName || "Golf round"}: Gross ${round.gross || "-"}${points}`
      },
      data: {
        type,
        sharedRoundId: resourceId,
        ownerId: String(round.ownerId),
        courseName: String(round.courseName || "")
      },
      category: null
    };
  }

  if (type === "friendRequest") {
    const snapshot = await firestore.collection("friendRequests").doc(resourceId).get();
    const request = snapshot.data();
    if (!snapshot.exists || !request || request.fromUserId !== callerUid || request.status !== "pending") return null;
    const sender = await firestore.collection("users").doc(callerUid).get();
    const fromName = sender.get("displayName") || "A golfer";
    return {
      eventVersion: String(request.updatedAt?.toMillis?.() || request.createdAt?.toMillis?.() || snapshot.createTime?.toMillis?.() || "1"),
      recipientIds: [request.toUserId],
      notification: { title: "New friend request", body: `${fromName} wants to connect on Precision Golf` },
      data: {
        type,
        friendRequestId: resourceId,
        fromUserId: String(request.fromUserId),
        toUserId: String(request.toUserId),
        fromName: String(fromName)
      },
      category: "FRIEND_REQUEST"
    };
  }

  const snapshot = await firestore.collection("groupInvites").doc(resourceId).get();
  const invite = snapshot.data();
  if (!snapshot.exists || !invite || invite.fromUserId !== callerUid || invite.status !== "pending") return null;
  const sender = await firestore.collection("users").doc(callerUid).get();
  const fromName = sender.get("displayName") || "A golfer";
  return {
    eventVersion: String(invite.updatedAt?.toMillis?.() || invite.createdAt?.toMillis?.() || snapshot.createTime?.toMillis?.() || "1"),
    recipientIds: [invite.toUserId],
    notification: {
      title: "New golf group invite",
      body: `${fromName} invited you to ${invite.groupName || "a golf group"}`
    },
    data: {
      type,
      groupInviteId: resourceId,
      groupId: String(invite.groupId),
      groupName: String(invite.groupName || ""),
      fromUserId: String(invite.fromUserId),
      toUserId: String(invite.toUserId)
    },
    category: "GROUP_INVITE"
  };
}

async function claimDispatch(firestore, dispatchId, eventVersion) {
  const reference = firestore.collection("pushDispatches").doc(dispatchId);
  return firestore.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(reference);
    const existing = snapshot.data();
    const createdAt = existing?.createdAt?.toDate?.();
    const isRecent = createdAt && Date.now() - createdAt.getTime() < 2 * 60 * 1000;
    const isSameEvent = existing?.eventVersion === eventVersion;
    if ((existing?.status === "complete" && isSameEvent) || (existing?.status === "processing" && isRecent)) return null;
    transaction.set(reference, {
      status: "processing",
      eventVersion,
      createdAt: Timestamp.now(),
      updatedAt: Timestamp.now()
    }, { merge: true });
    return reference;
  });
}

async function removeInvalidTokens(records, response) {
  const operations = [];
  response.responses.forEach((result, index) => {
    if (result.success || !invalidTokenCodes.has(result.error?.code)) return;
    const record = records[index];
    if (record.reference) {
      operations.push(record.reference.delete());
    } else if (record.userReference) {
      operations.push(record.userReference.set({ pushTokens: FieldValue.arrayRemove(record.token) }, { merge: true }));
    }
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

export default async function handler(req, res) {
  if (!requireMethod(req, res, "POST")) return;
  const token = bearerToken(req);
  if (!token) return sendError(res, 401, "Sign in is required.", "unauthorized");

  const type = typeof req.body?.type === "string" ? req.body.type : "";
  const resourceId = typeof req.body?.resourceId === "string" ? req.body.resourceId.trim() : "";
  if (!supportedTypes.has(type) || !resourceId || resourceId.length > 160) {
    return sendError(res, 400, "A supported notification type and resource ID are required.", "invalid_request");
  }

  const { auth, firestore, messaging } = firebaseAdmin();
  let decodedToken;
  try {
    decodedToken = await auth.verifyIdToken(token, true);
  } catch {
    return sendError(res, 401, "The Firebase session is invalid or expired.", "invalid_session");
  }

  const context = await notificationContext(firestore, type, resourceId, decodedToken.uid);
  if (!context) {
    return sendError(res, 403, "This notification event is unavailable or does not belong to you.", "forbidden");
  }

  const dispatchReference = await claimDispatch(firestore, `${type}_${resourceId}`, context.eventVersion);
  if (!dispatchReference) return sendJson(res, 200, { ok: true, duplicate: true, sent: 0 });

  try {
    const tokenGroups = await Promise.all(context.recipientIds.map((uid) => loadTokenRecords(firestore, uid)));
    const records = tokenGroups.flat();
    if (records.length === 0) {
      await dispatchReference.set({ status: "complete", sent: 0, reason: "no_tokens", updatedAt: Timestamp.now() }, { merge: true });
      return sendJson(res, 200, { ok: true, sent: 0, reason: "no_tokens" });
    }

    const aps = { sound: "default" };
    if (context.category) aps.category = context.category;
    const response = await messaging.sendEachForMulticast({
      tokens: records.map((record) => record.token),
      notification: context.notification,
      data: context.data,
      apns: { payload: { aps } }
    });
    await removeInvalidTokens(records, response);
    const failureCodes = summarizeDeliveryFailures(response);
    await dispatchReference.set({
      status: "complete",
      sent: response.successCount,
      failed: response.failureCount,
      failureCodes,
      updatedAt: Timestamp.now()
    }, { merge: true });
    return sendJson(res, 200, { ok: true, sent: response.successCount, failed: response.failureCount, failureCodes });
  } catch (error) {
    await dispatchReference.delete().catch(() => {});
    console.error("Push dispatch failed", { type, resourceId, error });
    return sendError(res, 500, "The push notification could not be sent.", "send_failed");
  }
}
