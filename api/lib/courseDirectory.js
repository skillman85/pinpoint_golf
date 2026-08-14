import { firebaseAdmin } from "./firebaseAdmin.js";

function firestore() {
  try {
    return firebaseAdmin().firestore;
  } catch {
    return null;
  }
}

function courseDocId(externalId) {
  return encodeURIComponent(`${externalId}`.trim());
}

function tokensFor(...values) {
  const ignored = new Set(["and", "club", "course", "golf", "the", "united", "kingdom"]);
  const tokens = new Set();
  for (const value of values) {
    `${value || ""}`
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, " ")
      .split(/\s+/)
      .filter((token) => token.length > 1 && !ignored.has(token))
      .forEach((token) => tokens.add(token));
  }
  return Array.from(tokens).slice(0, 100);
}

function isCourseMatch(course, query) {
  const normalizedQuery = `${query}`.toLowerCase().trim();
  if (!normalizedQuery) return true;
  const haystack = [
    course.name,
    course.clubName,
    course.location,
    course.distance,
    course.externalId
  ].join(" ").toLowerCase();
  return normalizedQuery
    .split(/\s+/)
    .filter(Boolean)
    .every((term) => haystack.includes(term));
}

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function distanceMiles(firstLat, firstLng, secondLat, secondLng) {
  const earthRadiusMiles = 3958.8;
  const lat1 = firstLat * Math.PI / 180;
  const lat2 = secondLat * Math.PI / 180;
  const deltaLat = (secondLat - firstLat) * Math.PI / 180;
  const deltaLng = (secondLng - firstLng) * Math.PI / 180;
  const a = Math.sin(deltaLat / 2) ** 2
    + Math.cos(lat1) * Math.cos(lat2) * Math.sin(deltaLng / 2) ** 2;
  return earthRadiusMiles * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

export async function searchDirectory(query, limit = 8) {
  const database = firestore();
  const terms = tokensFor(query).slice(0, 10);
  if (!database || terms.length === 0) return [];

  try {
    const snapshot = await database
      .collection("courseDirectory")
      .where("searchTokens", "array-contains-any", terms)
      .limit(40)
      .get();

    return snapshot.docs
      .map((doc) => doc.data())
      .filter((row) => row.payload && isCourseMatch(row.payload, query))
      .sort((first, second) => {
        const firstSeen = first.lastSeenAt?.toMillis?.() ?? 0;
        const secondSeen = second.lastSeenAt?.toMillis?.() ?? 0;
        return secondSeen - firstSeen;
      })
      .map((row) => row.payload)
      .slice(0, Math.min(Math.max(limit, 1), 12));
  } catch {
    return [];
  }
}

export async function searchNearbyDirectory(lat, lng, radiusMiles = 5, limit = 3) {
  const database = firestore();
  const latitude = finiteNumber(lat);
  const longitude = finiteNumber(lng);
  if (!database || latitude === null || longitude === null) return [];

  try {
    const snapshot = await database
      .collection("courseDirectory")
      .where("hasCoordinates", "==", true)
      .limit(200)
      .get();

    return snapshot.docs
      .map((doc) => doc.data())
      .filter((row) => row.payload)
      .map((row) => ({
        course: row.payload,
        miles: distanceMiles(latitude, longitude, Number(row.latitude), Number(row.longitude))
      }))
      .filter((row) => row.miles <= radiusMiles)
      .sort((first, second) => first.miles - second.miles)
      .map((row) => ({
        ...row.course,
        distance: `${row.miles.toFixed(row.miles < 10 ? 1 : 0)} mi`
      }))
      .slice(0, Math.min(Math.max(limit, 1), 3));
  } catch {
    return [];
  }
}

export async function findDirectoryCourseByExternalId(externalId) {
  const database = firestore();
  const id = `${externalId}`.trim();
  if (!database || !id) return null;

  try {
    const snapshot = await database.collection("courseDirectory").doc(courseDocId(id)).get();
    return snapshot.data()?.payload || null;
  } catch {
    return null;
  }
}

export async function saveDirectoryCourses(courses) {
  const database = firestore();
  const validCourses = courses.filter((course) => (
    course?.favoriteKey
    && course?.externalId
    && Array.isArray(course.tees)
    && course.tees.length > 0
  ));
  if (!database || validCourses.length === 0) return "skipped";

  try {
    const batch = database.batch();
    const now = new Date();
    for (const course of validCourses) {
      const latitude = finiteNumber(course.latitude);
      const longitude = finiteNumber(course.longitude);
      const reference = database.collection("courseDirectory").doc(courseDocId(course.externalId));
      batch.set(reference, {
        externalId: course.externalId,
        favoriteKey: course.favoriteKey,
        source: course.source || "golfcourseapi",
        name: course.name,
        clubName: course.clubName || "",
        location: course.location || "",
        latitude,
        longitude,
        hasCoordinates: latitude !== null && longitude !== null,
        searchTokens: tokensFor(course.name, course.clubName, course.location, course.distance, course.externalId),
        payload: course,
        lastSeenAt: now,
        updatedAt: now
      }, { merge: true });
    }
    await batch.commit();
    return "firestore";
  } catch {
    return "failed";
  }
}
