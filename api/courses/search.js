import { cached, normalizeCacheKey } from "../lib/cache.js";
import { requireMethod, sendError, sendJson, stringParam } from "../lib/http.js";
import { RapidAPIError, searchCourses } from "../lib/rapidapi.js";

const SEARCH_TTL_SECONDS = 30 * 24 * 60 * 60;

export default async function handler(req, res) {
  if (!requireMethod(req, res)) return;

  const query = stringParam(req.query.q).trim();
  if (!query) {
    sendError(res, 400, "Missing q search parameter.", "missing_query");
    return;
  }

  const limit = Math.min(Math.max(Number(req.query.limit ?? 8), 1), 12);
  const cacheKey = normalizeCacheKey(["search", query, limit]);

  try {
    const { payload, cache } = await cached(cacheKey, SEARCH_TTL_SECONDS, async () => ({
      query,
      courses: await searchCourses(query, {
        limit,
        maxClubs: 2,
        maxCoursesPerClub: 1,
        budget: { remaining: 5 }
      })
    }));

    sendJson(res, 200, { ...payload, cache }, 60);
  } catch (error) {
    handleError(res, error);
  }
}

function handleError(res, error) {
  if (error instanceof RapidAPIError) {
    sendError(res, error.status, error.message, error.code);
    return;
  }
  sendError(res, 500, error?.message || "Course search failed.", "course_search_failed");
}
