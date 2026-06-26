import { cached, normalizeCacheKey } from "../lib/cache.js";
import { requireMethod, sendError, sendJson, stringParam } from "../lib/http.js";
import { fetchScorecard, RapidAPIError } from "../lib/rapidapi.js";

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
    const { payload, cache } = await cached(cacheKey, SCORECARD_TTL_SECONDS, async () => ({
      id,
      scorecard: await fetchScorecard(id)
    }));

    sendJson(res, 200, { ...payload, cache }, 60 * 60);
  } catch (error) {
    handleError(res, error);
  }
}

function handleError(res, error) {
  if (error instanceof RapidAPIError) {
    sendError(res, error.status, error.message, error.code);
    return;
  }
  sendError(res, 500, "Scorecard lookup failed.", "scorecard_lookup_failed");
}
