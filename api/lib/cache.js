import { firebaseAdmin } from "./firebaseAdmin.js";

const memoryCache = new Map();

export function normalizeCacheKey(parts) {
  return parts
    .filter((part) => part !== undefined && part !== null && `${part}`.trim() !== "")
    .map((part) => `${part}`.trim().toLowerCase().replace(/\s+/g, " "))
    .join(":");
}

function firestore() {
  try {
    return firebaseAdmin().firestore;
  } catch {
    return null;
  }
}

function cacheDocId(cacheKey) {
  return Buffer.from(cacheKey).toString("base64url");
}

export async function getCached(cacheKey) {
  const now = Date.now();
  const memoryHit = memoryCache.get(cacheKey);
  if (memoryHit && memoryHit.expiresAt > now) {
    return memoryHit.payload;
  }

  const database = firestore();
  if (!database) return null;

  try {
    const snapshot = await database.collection("courseApiCache").doc(cacheDocId(cacheKey)).get();
    const row = snapshot.data();
    const expiresAt = row?.expiresAt?.toMillis?.() ?? 0;
    if (!row || expiresAt <= now) {
      return null;
    }

    memoryCache.set(cacheKey, {
      payload: row.payload,
      expiresAt
    });
    return row.payload;
  } catch {
    return null;
  }
}

export async function setCached(cacheKey, payload, ttlSeconds) {
  const expiresAt = new Date(Date.now() + ttlSeconds * 1000);
  memoryCache.set(cacheKey, {
    payload,
    expiresAt: expiresAt.getTime()
  });

  const database = firestore();
  if (!database) return;

  try {
    await database.collection("courseApiCache").doc(cacheDocId(cacheKey)).set({
      cacheKey,
      payload,
      expiresAt,
      updatedAt: new Date()
    }, { merge: true });
  } catch (error) {
    throw new Error(`Firestore cache write failed: ${error?.message || "unknown error"}`);
  }
}

export async function cached(cacheKey, ttlSeconds, loader) {
  let hit = null;
  try {
    hit = await getCached(cacheKey);
  } catch {
    hit = null;
  }

  if (hit) {
    return { payload: hit, cache: "hit" };
  }

  const payload = await loader();
  let cacheWrite = "skipped";
  try {
    await setCached(cacheKey, payload, ttlSeconds);
    cacheWrite = firestore() ? "firestore" : "memory";
  } catch {
    cacheWrite = "failed";
    // Cache writes are best-effort. The API should still return live results.
  }
  return { payload, cache: "miss", cacheWrite };
}
