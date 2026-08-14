import { cached, normalizeCacheKey } from "../lib/cache.js";
import { findDirectoryCourseByExternalId, saveDirectoryCourses } from "../lib/courseDirectory.js";
import { requireMethod, sendError, sendJson, stringParam } from "../lib/http.js";
import { fetchScorecard, GolfCourseAPIError } from "../lib/golfcourseapi.js";

const SCORECARD_TTL_SECONDS = 365 * 24 * 60 * 60;

export default async function handler(req, res) {
  if (!requireMethod(req, res)) return;

  const id = stringParam(req.query.id).trim();
  if (!id) {
    sendError(res, 400, "Missing id parameter.", "missing_course_id");
    return;
  }

  const cacheKey = normalizeCacheKey(["scorecard", id]);

  try {
    const directoryScorecard = await findDirectoryCourseByExternalId(id);
    if (directoryScorecard) {
      sendJson(res, 200, {
        id,
        scorecard: directoryScorecard,
        cache: "directory"
      }, 60 * 60);
      return;
    }

    const { payload, cache, cacheWrite } = await cached(cacheKey, SCORECARD_TTL_SECONDS, async () => ({
      id,
      scorecard: await fetchScorecard(id)
    }));

    const directoryWrite = await saveDirectoryCourses([payload.scorecard]);
    sendJson(res, 200, { ...payload, cache, ...(cacheWrite ? { cacheWrite } : {}), directoryWrite }, 60 * 60);
  } catch (error) {
    const directoryScorecard = await findDirectoryCourseByExternalId(id);
    if (directoryScorecard && error instanceof GolfCourseAPIError && error.code === "rate_limited") {
      sendJson(res, 200, {
        id,
        scorecard: directoryScorecard,
        cache: "directory",
        providerWarning: error.code
      }, 60 * 60);
      return;
    }
    handleError(res, error);
  }
}

function handleError(res, error) {
  if (error instanceof GolfCourseAPIError) {
    sendError(res, error.status, error.message, error.code);
    return;
  }
  sendError(res, 500, error?.message || "Scorecard lookup failed.", "scorecard_lookup_failed");
}
