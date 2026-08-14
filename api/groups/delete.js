import { firebaseAdmin } from "../lib/firebaseAdmin.js";
import { requireMethod, sendError, sendJson } from "../lib/http.js";

function bearerToken(req) {
  const header = typeof req.headers.authorization === "string" ? req.headers.authorization : "";
  return header.startsWith("Bearer ") ? header.slice(7).trim() : "";
}

export default async function handler(req, res) {
  if (!requireMethod(req, res, "POST")) return;

  const token = bearerToken(req);
  if (!token) return sendError(res, 401, "Sign in is required.", "unauthorized");

  const groupId = typeof req.body?.groupId === "string" ? req.body.groupId.trim() : "";
  if (!groupId || groupId.length > 160) {
    return sendError(res, 400, "A valid group ID is required.", "invalid_request");
  }

  const { auth, firestore } = firebaseAdmin();
  let caller;
  try {
    caller = await auth.verifyIdToken(token, true);
  } catch {
    return sendError(res, 401, "The Firebase session is invalid or expired.", "invalid_session");
  }

  const groupReference = firestore.collection("golfGroups").doc(groupId);
  const groupSnapshot = await groupReference.get();
  if (!groupSnapshot.exists) {
    return sendJson(res, 200, { ok: true, alreadyDeleted: true });
  }
  if (groupSnapshot.get("ownerId") !== caller.uid) {
    return sendError(res, 403, "Only the group owner can delete this group.", "forbidden");
  }

  try {
    const [gamesSnapshot, invitesSnapshot] = await Promise.all([
      firestore.collection("liveGroupGames").where("groupId", "==", groupId).get(),
      firestore.collection("groupInvites").where("groupId", "==", groupId).get()
    ]);
    const gameChildren = await Promise.all(gamesSnapshot.docs.map(async (gameDocument) => {
      const [players, events] = await Promise.all([
        gameDocument.ref.collection("players").get(),
        gameDocument.ref.collection("events").get()
      ]);
      return [...players.docs, ...events.docs];
    }));

    const writer = firestore.bulkWriter();
    gameChildren.flat().forEach((document) => writer.delete(document.ref));
    gamesSnapshot.docs.forEach((document) => writer.delete(document.ref));
    invitesSnapshot.docs.forEach((document) => writer.delete(document.ref));
    await writer.close();
    await groupReference.delete();

    return sendJson(res, 200, {
      ok: true,
      deletedGames: gamesSnapshot.size,
      deletedInvites: invitesSnapshot.size
    });
  } catch (error) {
    console.error("Group deletion failed", { groupId, callerUid: caller.uid, error });
    return sendError(res, 500, "The group could not be deleted. Please try again.", "delete_failed");
  }
}
