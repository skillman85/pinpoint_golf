import { firebaseAdmin } from "./lib/firebaseAdmin.js";

export default async function handler(req, res) {
  const firebase = await firebaseStatus();
  res.status(200).json({
    ok: true,
    service: "precision-course-api",
    firebase
  });
}

async function firebaseStatus() {
  const env = {
    projectId: Boolean(process.env.FIREBASE_PROJECT_ID),
    clientEmail: Boolean(process.env.FIREBASE_CLIENT_EMAIL),
    privateKey: Boolean(process.env.FIREBASE_PRIVATE_KEY),
    privateKeyHasBeginMarker: /BEGIN PRIVATE KEY/.test(process.env.FIREBASE_PRIVATE_KEY || ""),
    privateKeyHasEscapedNewlines: /\\n/.test(process.env.FIREBASE_PRIVATE_KEY || "")
  };

  try {
    const { firestore } = firebaseAdmin();
    await firestore.collection("courseApiCache").doc("healthcheck").set({
      ok: true,
      checkedAt: new Date()
    }, { merge: true });
    return {
      ok: true,
      env
    };
  } catch (error) {
    return {
      ok: false,
      env,
      code: error?.code || error?.errorInfo?.code || "firebase_error",
      message: error?.message || "Firebase check failed."
    };
  }
}
