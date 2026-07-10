const admin = require("firebase-admin");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { logger } = require("firebase-functions");

admin.initializeApp();

async function loadUserPushTokens(uid) {
  const snapshot = await admin.firestore().collection("users").doc(uid).get();
  const pushTokens = snapshot.get("pushTokens") || [];
  return pushTokens.filter((token) => typeof token === "string" && token.length > 0);
}

exports.sendRoundPushNotification = onDocumentCreated("sharedRounds/{roundId}", async (event) => {
  const round = event.data && event.data.data();
  if (!round || !round.ownerId) {
    logger.warn("Shared round missing ownerId", { roundId: event.params.roundId });
    return;
  }

  const friendships = await admin
    .firestore()
    .collection("friendships")
    .where("memberIds", "array-contains", round.ownerId)
    .get();

  const recipientIds = new Set();
  friendships.forEach((document) => {
    const memberIds = document.get("memberIds") || [];
    memberIds
      .filter((memberId) => memberId && memberId !== round.ownerId)
      .forEach((memberId) => recipientIds.add(memberId));
  });

  if (recipientIds.size === 0) {
    logger.info("No friends to notify", { roundId: event.params.roundId });
    return;
  }

  const tokenReads = Array.from(recipientIds).map(loadUserPushTokens);
  const tokens = (await Promise.all(tokenReads)).flat();

  if (tokens.length === 0) {
    logger.info("Friends have no push tokens yet", { roundId: event.params.roundId });
    return;
  }

  const stablefordText = Number.isInteger(round.stableford) ? `, ${round.stableford} pts` : "";
  const message = {
    tokens,
    notification: {
      title: `${round.ownerName || "A friend"} completed a round`,
      body: `${round.courseName || "Golf round"}: Gross ${round.gross || "-"}${stablefordText}`
    },
    data: {
      type: "sharedRound",
      sharedRoundId: event.params.roundId,
      ownerId: round.ownerId,
      courseName: String(round.courseName || "")
    },
    apns: {
      payload: {
        aps: {
          sound: "default"
        }
      }
    }
  };

  const response = await admin.messaging().sendEachForMulticast(message);
  logger.info("Round push notification sent", {
    roundId: event.params.roundId,
    successCount: response.successCount,
    failureCount: response.failureCount
  });
});

exports.sendFriendRequestPushNotification = onDocumentCreated("friendRequests/{requestId}", async (event) => {
  const request = event.data && event.data.data();
  if (!request || request.status !== "pending" || !request.fromUserId || !request.toUserId) {
    logger.info("Friend request push skipped", { requestId: event.params.requestId });
    return;
  }

  const [fromUserSnapshot, tokens] = await Promise.all([
    admin.firestore().collection("users").doc(request.fromUserId).get(),
    loadUserPushTokens(request.toUserId)
  ]);

  if (tokens.length === 0) {
    logger.info("Friend request recipient has no push tokens yet", {
      requestId: event.params.requestId,
      toUserId: request.toUserId
    });
    return;
  }

  const fromName = fromUserSnapshot.get("displayName") || "A golfer";
  const fromHomeClub = fromUserSnapshot.get("homeClub") || "Precision Golf";
  const response = await admin.messaging().sendEachForMulticast({
    tokens,
    notification: {
      title: "New friend request",
      body: `${fromName} wants to connect on Precision Golf`
    },
    data: {
      type: "friendRequest",
      friendRequestId: event.params.requestId,
      fromUserId: request.fromUserId,
      toUserId: request.toUserId,
      fromName: String(fromName),
      fromHomeClub: String(fromHomeClub)
    },
    apns: {
      payload: {
        aps: {
          category: "FRIEND_REQUEST",
          sound: "default"
        }
      }
    }
  });

  logger.info("Friend request push notification sent", {
    requestId: event.params.requestId,
    successCount: response.successCount,
    failureCount: response.failureCount
  });
});

exports.sendGroupInvitePushNotification = onDocumentCreated("groupInvites/{inviteId}", async (event) => {
  const invite = event.data && event.data.data();
  if (!invite || invite.status !== "pending" || !invite.fromUserId || !invite.toUserId || !invite.groupId) {
    logger.info("Group invite push skipped", { inviteId: event.params.inviteId });
    return;
  }

  const [fromUserSnapshot, tokens] = await Promise.all([
    admin.firestore().collection("users").doc(invite.fromUserId).get(),
    loadUserPushTokens(invite.toUserId)
  ]);

  if (tokens.length === 0) {
    logger.info("Group invite recipient has no push tokens yet", {
      inviteId: event.params.inviteId,
      toUserId: invite.toUserId
    });
    return;
  }

  const fromName = fromUserSnapshot.get("displayName") || "A golfer";
  const response = await admin.messaging().sendEachForMulticast({
    tokens,
    notification: {
      title: "New golf group invite",
      body: `${fromName} invited you to ${invite.groupName || "a golf group"}`
    },
    data: {
      type: "groupInvite",
      groupInviteId: event.params.inviteId,
      groupId: invite.groupId,
      groupName: String(invite.groupName || ""),
      fromUserId: invite.fromUserId,
      toUserId: invite.toUserId
    },
    apns: {
      payload: {
        aps: {
          category: "GROUP_INVITE",
          sound: "default"
        }
      }
    }
  });

  logger.info("Group invite push notification sent", {
    inviteId: event.params.inviteId,
    successCount: response.successCount,
    failureCount: response.failureCount
  });
});
