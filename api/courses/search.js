import { cached, getCached, normalizeCacheKey } from "../lib/cache.js";
import { saveDirectoryCourses, searchDirectory } from "../lib/courseDirectory.js";
import { requireMethod, sendError, sendJson, stringParam } from "../lib/http.js";
import { GolfCourseAPIError, searchMultipleQueries } from "../lib/golfcourseapi.js";
import { searchKnownCourses } from "../lib/knownCourses.js";

const SEARCH_TTL_SECONDS = 30 * 24 * 60 * 60;
const SEARCH_CACHE_VERSION = "golfcourseapi-v4";

export default async function handler(req, res) {
  if (!requireMethod(req, res)) return;

  const query = stringParam(req.query.q).trim();
  if (!query) {
    sendError(res, 400, "Missing q search parameter.", "missing_query");
    return;
  }

  const limit = Math.min(Math.max(Number(req.query.limit ?? 8), 1), 12);
  const providerQueries = providerSearchQueries(query);
  const cacheKey = normalizeCacheKey(["search", SEARCH_CACHE_VERSION, providerQueries, limit]);

  try {
    const directoryCourses = await searchDirectory(query, limit);
    if (directoryCourses.length >= limit) {
      sendJson(res, 200, {
        query,
        courses: directoryCourses.slice(0, limit),
        cache: "directory"
      }, 60 * 60);
      return;
    }

    const seededKnownCourses = searchKnownCourses(query, limit);
    const knownCourses = mergeCourses(directoryCourses, seededKnownCourses).slice(0, limit);
    if (seededKnownCourses.length > 0) {
      const directoryWrite = await saveDirectoryCourses(knownCourses);
      sendJson(res, 200, {
        query,
        courses: knownCourses,
        cache: directoryCourses.length > 0 ? "directory" : "known",
        directoryWrite
      }, 60 * 60);
      return;
    }

    const { payload, cache, cacheWrite } = await cached(cacheKey, SEARCH_TTL_SECONDS, async () => ({
      query,
      providerQueries,
      courses: await searchMultipleQueries(providerQueries, {
        limit: providerSearchLimit(query, limit),
        maxDetails: providerSearchLimit(query, limit)
      })
    }));

    const courses = mergeCourses(directoryCourses, payload.courses || []).slice(0, limit);
    const directoryWrite = await saveDirectoryCourses(courses);

    sendJson(res, 200, {
      ...payload,
      courses,
      cache,
      ...(cacheWrite ? { cacheWrite } : {}),
      directoryWrite
    }, 60);
  } catch (error) {
    const directoryCourses = await searchDirectory(query, limit);
    if (directoryCourses.length > 0 && error instanceof GolfCourseAPIError && error.code === "rate_limited") {
      sendJson(res, 200, {
        query,
        courses: directoryCourses,
        cache: "directory",
        providerWarning: error.code
      }, 60 * 60);
      return;
    }
    const knownCourses = searchKnownCourses(query, limit);
    if (knownCourses.length > 0 && error instanceof GolfCourseAPIError && error.code === "rate_limited") {
      await saveDirectoryCourses(knownCourses);
      sendJson(res, 200, {
        query,
        courses: knownCourses,
        cache: "known",
        providerWarning: error.code
      }, 60 * 60);
      return;
    }
    const legacyCourses = error instanceof GolfCourseAPIError && error.code === "rate_limited"
      ? await legacyCachedSearchCourses(query, limit)
      : [];
    if (legacyCourses.length > 0) {
      const courses = mergeCourses(directoryCourses, legacyCourses).slice(0, limit);
      await saveDirectoryCourses(courses);
      sendJson(res, 200, {
        query,
        courses,
        cache: "legacy",
        providerWarning: error.code
      }, 60 * 60);
      return;
    }
    handleError(res, error);
  }
}

function providerSearchQueries(query) {
  const normalized = `${query}`.toLowerCase().trim();
  if (isBarePlaceQuery(normalized)) {
    return uniqueStrings([
      `${query} golf`,
      `${query} golf club`,
      `${query} golf course`,
      query
    ]).slice(0, 4);
  }
  return uniqueStrings([query]).slice(0, 1);
}

function providerSearchLimit(query, limit) {
  return Math.min(limit, isBarePlaceQuery(query) ? 5 : 3);
}

function isBarePlaceQuery(query) {
  const normalized = `${query}`.toLowerCase().trim();
  return normalized.length > 0 && !/\b(golf|course|club)\b/.test(normalized);
}

function uniqueStrings(values) {
  const seen = new Set();
  return values
    .map((value) => `${value}`.trim())
    .filter(Boolean)
    .filter((value) => {
      const key = value.toLowerCase();
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

async function legacyCachedSearchCourses(query, limit) {
  const cacheKeys = [
    normalizeCacheKey(["search", query, limit]),
    normalizeCacheKey(["search", query, 8]),
    normalizeCacheKey(["search", query, 5]),
    normalizeCacheKey(["search", "golfcourseapi-v1", query, limit])
  ];
  for (const cacheKey of cacheKeys) {
    const payload = await getCached(cacheKey);
    const courses = payload?.courses || [];
    if (courses.length > 0) return courses;
  }
  return [];
}

function mergeCourses(...courseGroups) {
  const seen = new Set();
  const courses = [];
  for (const course of courseGroups.flat()) {
    const key = course?.favoriteKey || `${course?.name}|${course?.location}`.toLowerCase();
    if (!course || seen.has(key)) continue;
    courses.push(course);
    seen.add(key);
  }
  return courses;
}

function handleError(res, error) {
  if (error instanceof GolfCourseAPIError) {
    sendError(res, error.status, error.message, error.code);
    return;
  }
  sendError(res, 500, error?.message || "Course search failed.", "course_search_failed");
}
