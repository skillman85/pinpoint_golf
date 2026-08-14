import fs from "node:fs/promises";
import { cert, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const inputPath = process.argv[2];
const serviceAccountPath = process.argv[3];
const shouldWrite = process.argv.includes("--write");

if (!inputPath || !serviceAccountPath) {
  throw new Error("Usage: node scripts/import-scorecard-directory.mjs <scorecards.json> <service-account.json> [--write]");
}

function slug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/&/g, "and")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function cleanName(value) {
  return String(value || "").replace(/\s+\./g, "").trim();
}

function isGenericCourseName(value) {
  return /^(18[- ]?hole course|18[- ]?hole|course)$/i.test(cleanName(value));
}

function numberValue(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function teeParAndStrokeColumns(course, teeLabel) {
  const defaults = course.scorecard?.gender_defaults || {};
  const label = teeLabel.toLowerCase();
  if (label.includes("red") || label.includes("ladies") || label.includes("women")) {
    return {
      par: defaults.ladies?.par_column || defaults.men?.par_column || "men_par",
      strokeIndex: defaults.ladies?.stroke_index_column || defaults.men?.stroke_index_column || "men_si"
    };
  }
  return {
    par: defaults.men?.par_column || defaults.ladies?.par_column || "men_par",
    strokeIndex: defaults.men?.stroke_index_column || defaults.ladies?.stroke_index_column || "men_si"
  };
}

function teeFromColumn(course, column) {
  const label = cleanName(column.label);
  const { par: parColumn, strokeIndex: strokeIndexColumn } = teeParAndStrokeColumns(course, label);
  const holes = [];

  for (const row of course.scorecard?.holes || []) {
    const values = row.values || {};
    const yards = numberValue(values[column.key]);
    const par = numberValue(values[parColumn]);
    if (!yards || !par) continue;

    holes.push({
      number: numberValue(values.hole) || numberValue(row.hole) || holes.length + 1,
      par,
      yards,
      strokeIndex: numberValue(values[strokeIndexColumn]) || holes.length + 1
    });
  }

  if (holes.length === 0) return null;

  return {
    name: label,
    yards: holes.reduce((total, hole) => total + hole.yards, 0),
    par: holes.reduce((total, hole) => total + hole.par, 0),
    slope: 113,
    rating: holes.reduce((total, hole) => total + hole.par, 0),
    holes: holes.sort((first, second) => first.number - second.number)
  };
}

function normalizeCourse(course) {
  const clubName = cleanName(course.club_name);
  const courseName = cleanName(course.course_name);
  const displayName = !courseName || isGenericCourseName(courseName) || courseName.localeCompare(clubName, undefined, { sensitivity: "accent" }) === 0
    ? clubName
    : `${clubName} - ${courseName}`;

  const distanceColumns = (course.scorecard?.columns || []).filter((column) => column.role === "distance");
  const tees = distanceColumns
    .map((column) => teeFromColumn(course, column))
    .filter(Boolean)
    .filter((tee, index, allTees) => (
      allTees.findIndex((candidate) => (
        candidate.name.toLowerCase() === tee.name.toLowerCase()
        && candidate.yards === tee.yards
        && candidate.par === tee.par
      )) === index
    ));

  if (!displayName || tees.length === 0) return null;

  const externalId = `mscorecard:${course.course_variant_id || course.course_id || slug(displayName)}`;
  return {
    externalId,
    favoriteKey: `${externalId}|${displayName.toLowerCase()}`,
    name: displayName,
    location: course.address?.formatted || [
      course.address?.locality,
      course.address?.county_or_region,
      course.address?.country
    ].filter(Boolean).join(", ") || "Imported scorecard",
    distance: course.address?.locality || course.address?.county_or_region || "Imported scorecard",
    source: "mscorecard",
    sourceUrl: course.source_url,
    tees,
    hasVerifiedScorecard: tees.some((tee) => tee.holes.length >= 9)
  };
}

function searchTokensFor(course) {
  const ignored = new Set(["and", "club", "course", "golf", "the", "united", "kingdom"]);
  const tokens = new Set();
  [course.name, course.location, course.distance, course.externalId].forEach((value) => {
    String(value || "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, " ")
      .split(/\s+/)
      .filter((token) => token.length > 1 && !ignored.has(token))
      .forEach((token) => tokens.add(token));
  });
  return Array.from(tokens).slice(0, 100);
}

function duplicateKey(course) {
  return slug(`${course.name}|${course.location}`);
}

const input = JSON.parse(await fs.readFile(inputPath, "utf8"));
const serviceAccount = JSON.parse(await fs.readFile(serviceAccountPath, "utf8"));
const courses = (input.courses || []).map(normalizeCourse).filter(Boolean);

initializeApp({ credential: cert(serviceAccount) });
const firestore = getFirestore();
const existingSnapshot = await firestore.collection("courseDirectory").get();
const existingExternalIds = new Set(existingSnapshot.docs.map((doc) => doc.id));
const existingCourseKeys = new Set(existingSnapshot.docs.map((doc) => duplicateKey(doc.data().payload || {})));

const uniqueCourses = [];
const skipped = [];
for (const course of courses) {
  const documentId = encodeURIComponent(course.externalId);
  const key = duplicateKey(course);
  if (existingExternalIds.has(documentId) || existingCourseKeys.has(key)) {
    skipped.push(course);
    continue;
  }
  uniqueCourses.push(course);
  existingExternalIds.add(documentId);
  existingCourseKeys.add(key);
}

if (shouldWrite && uniqueCourses.length > 0) {
  const now = new Date();
  for (let index = 0; index < uniqueCourses.length; index += 400) {
    const batch = firestore.batch();
    for (const course of uniqueCourses.slice(index, index + 400)) {
      const reference = firestore.collection("courseDirectory").doc(encodeURIComponent(course.externalId));
      batch.set(reference, {
        externalId: course.externalId,
        favoriteKey: course.favoriteKey,
        source: course.source,
        name: course.name,
        clubName: "",
        location: course.location,
        latitude: null,
        longitude: null,
        hasCoordinates: false,
        searchTokens: searchTokensFor(course),
        payload: course,
        firstSeenAt: now,
        lastSeenAt: now,
        updatedAt: now
      }, { merge: false });
    }
    await batch.commit();
  }
}

const teeCount = uniqueCourses.reduce((total, course) => total + course.tees.length, 0);
console.log(JSON.stringify({
  mode: shouldWrite ? "write" : "dry-run",
  inputCourses: input.courses?.length || 0,
  normalizedCourses: courses.length,
  addedCourses: uniqueCourses.length,
  skippedDuplicates: skipped.length,
  addedTees: teeCount,
  addedNames: uniqueCourses.map((course) => course.name)
}, null, 2));

