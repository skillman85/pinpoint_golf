import { cached, normalizeCacheKey } from "../lib/cache.js";
import { saveDirectoryCourses, searchDirectory, searchNearbyDirectory } from "../lib/courseDirectory.js";
import { numberParam, requireMethod, sendError, sendJson, splitList } from "../lib/http.js";
import { GolfCourseAPIError, golfCourseAPIKeySource, searchMultipleQueries } from "../lib/golfcourseapi.js";

const NEAR_TTL_SECONDS = 14 * 24 * 60 * 60;
const NEAR_CACHE_VERSION = "directory-5mi-v1";
const DEFAULT_RADIUS_METERS = 8047;
const DEFAULT_LIMIT = 3;

export default async function handler(req, res) {
  if (!requireMethod(req, res)) return;

  const lat = numberParam(req.query.lat);
  const lng = numberParam(req.query.lng);
  const queries = splitList(req.query.queries).slice(0, 2);

  if (lat === null || lng === null) {
    sendError(res, 400, "Missing lat/lng parameters for nearby course search.", "missing_location");
    return;
  }

  const radiusMeters = Math.min(Math.max(Number(req.query.radiusMeters ?? DEFAULT_RADIUS_METERS), 1_000), DEFAULT_RADIUS_METERS);
  const radiusMiles = radiusMeters / 1609.344;
  const areaKey = `${lat.toFixed(2)},${lng.toFixed(2)}`;
  const limit = Math.min(Math.max(Number(req.query.limit ?? DEFAULT_LIMIT), 1), DEFAULT_LIMIT);
  const cacheKey = normalizeCacheKey(["near", NEAR_CACHE_VERSION, areaKey, radiusMeters, limit]);
  const debug = req.query.debug === "1";

  try {
    const nearbyDirectory = await searchNearbyDirectory(lat, lng, radiusMiles, limit);
    if (nearbyDirectory.length > 0) {
      sendJson(res, 200, {
        areaKey,
        radiusMeters,
        queries,
        courses: nearbyDirectory,
        cache: "directory"
      }, 60 * 60);
      return;
    }

    if (debug) {
      const result = await mergedNearbySearch(lat, lng, queries, {
        limit,
        radiusMiles,
        debug: true
      });
      sendJson(res, 200, {
        areaKey,
        radiusMeters,
        queries,
        courses: result.courses,
        providers: result.providers
      }, 0);
      return;
    }

    const { payload, cache, cacheWrite } = await cached(cacheKey, NEAR_TTL_SECONDS, async () => ({
      areaKey,
      radiusMeters,
      queries,
      courses: await mergedNearbySearch(lat, lng, queries, {
        limit,
        radiusMiles
      })
    }));

    const directoryWrite = await saveDirectoryCourses(payload.courses || []);
    sendJson(res, 200, { ...payload, cache, ...(cacheWrite ? { cacheWrite } : {}), directoryWrite }, 60);
  } catch (error) {
    if (error instanceof GolfCourseAPIError && error.code === "rate_limited") {
      const directoryCourses = await directoryMatchesForQueries(queries, limit);
      if (directoryCourses.length > 0) {
        sendJson(res, 200, {
          areaKey,
          radiusMeters,
          queries,
          courses: directoryCourses,
          cache: "directory",
          providerWarning: error.code
        }, 60 * 60);
        return;
      }
    }
    handleError(res, error);
  }
}

async function mergedNearbySearch(lat, lng, queries, options) {
  const courses = queries.length > 0
    ? await searchMultipleQueries(queries, { limit: Math.min(options.limit, 3), maxDetails: 1 })
    : [];

  if (options.debug) {
    return {
      courses,
      providers: {
        golfCourseAPI: {
          count: courses.length,
          keySource: golfCourseAPIKeySource(),
          error: null
        }
      }
    };
  }
  return courses;
}

async function directoryMatchesForQueries(queries, limit) {
  const results = [];
  const seen = new Set();
  for (const query of queries) {
    const matches = await searchDirectory(query, Math.max(1, limit - results.length));
    for (const course of matches) {
      if (!seen.has(course.favoriteKey)) {
        results.push(course);
        seen.add(course.favoriteKey);
      }
      if (results.length >= limit) return results;
    }
  }
  return results;
}

function handleError(res, error) {
  if (error instanceof GolfCourseAPIError) {
    sendError(res, error.status, error.message, error.code);
    return;
  }
  sendError(res, 500, error?.message || "Nearby course search failed.", "near_search_failed");
}
