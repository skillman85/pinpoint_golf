import { cached, normalizeCacheKey } from "../lib/cache.js";
import { numberParam, requireMethod, sendError, sendJson, splitList } from "../lib/http.js";
import { RapidAPIError, searchNearbyCoursesByCoordinate } from "../lib/rapidapi.js";

const NEAR_TTL_SECONDS = 14 * 24 * 60 * 60;

export default async function handler(req, res) {
  if (!requireMethod(req, res)) return;

  const lat = numberParam(req.query.lat);
  const lng = numberParam(req.query.lng);
  const queries = splitList(req.query.queries).slice(0, 10);

  if (queries.length === 0) {
    sendError(res, 400, "Missing queries parameter. Send nearby course names from the app.", "missing_queries");
    return;
  }
  if (lat === null || lng === null) {
    sendError(res, 400, "Missing lat/lng parameters for nearby course search.", "missing_location");
    return;
  }

  const radiusMeters = Math.min(Math.max(Number(req.query.radiusMeters ?? 45_000), 5_000), 80_000);
  const areaKey = `${lat.toFixed(2)},${lng.toFixed(2)}`;
  const limit = Math.min(Math.max(Number(req.query.limit ?? 4), 1), 8);
  const cacheKey = normalizeCacheKey(["near", areaKey, radiusMeters, queries.join("|"), limit]);

  try {
    const { payload, cache, cacheWrite } = await cached(cacheKey, NEAR_TTL_SECONDS, async () => ({
      areaKey,
      radiusMeters,
      queries,
      courses: await searchNearbyCoursesByCoordinate(lat, lng, queries, {
        radiusMeters,
        limit,
        maxClubSearches: 10,
        maxCoursesPerClub: 1,
        budget: { remaining: 5 }
      })
    }));

    sendJson(res, 200, { ...payload, cache, ...(cacheWrite ? { cacheWrite } : {}) }, 60);
  } catch (error) {
    handleError(res, error);
  }
}

function handleError(res, error) {
  if (error instanceof RapidAPIError) {
    sendError(res, error.status, error.message, error.code);
    return;
  }
  sendError(res, 500, error?.message || "Nearby course search failed.", "near_search_failed");
}
