import { cert, getApps, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";

function requireEnvironment(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}.`);
  return value;
}

export function firebaseAdmin() {
  const app = getApps()[0] ?? initializeApp({
    credential: cert({
      projectId: requireEnvironment("FIREBASE_PROJECT_ID"),
      clientEmail: requireEnvironment("FIREBASE_CLIENT_EMAIL"),
      privateKey: requireEnvironment("FIREBASE_PRIVATE_KEY").replace(/\\n/g, "\n")
    })
  });

  return {
    auth: getAuth(app),
    firestore: getFirestore(app),
    messaging: getMessaging(app)
  };
}

