export const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY || "AIzaSyCy7f2LVPu-CMtMPZslRl3Q74ZTsf97SUg",
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN || "precision-golf-fc3bd.firebaseapp.com",
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID || "precision-golf-fc3bd",
  storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET || "precision-golf-fc3bd.firebasestorage.app",
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID || "352805011225",
  appId: import.meta.env.VITE_FIREBASE_WEB_APP_ID || ""
};

export const hasFirebaseWebAppId = Boolean(firebaseConfig.appId);
