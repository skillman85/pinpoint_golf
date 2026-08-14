import { cached, getCached, normalizeCacheKey, setCached } from "./cache.js";

const BASE_URL = "https://api.golfcourseapi.com";
const API_TTL_SECONDS = 30 * 24 * 60 * 60;
const MIN_REQUEST_GAP_MS = 1200;
const RATE_LIMIT_COOLDOWN_SECONDS = 24 * 60 * 60;
const RATE_LIMIT_CACHE_KEY = normalizeCacheKey(["golfcourseapi", "rate_limited"]);

let nextProviderRequestAt = 0;

export class GolfCourseAPIError extends Error {
  constructor(message, status = 500, code = "golfcourseapi_error") {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function apiKey() {
  return process.env.GOLFCOURSE_API_KEY || "";
}

export function golfCourseAPIKeySource() {
  if (process.env.GOLFCOURSE_API_KEY) return "GOLFCOURSE_API_KEY";
  return null;
}

function firstPresent(source, keys, fallback = undefined) {
  for (const key of keys) {
    if (source && source[key] !== undefined && source[key] !== null) {
      return source[key];
    }
  }
  return fallback;
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

async function request(path, query = {}) {
  const key = apiKey().trim();
  if (!key) {
    throw new GolfCourseAPIError("GolfCourseAPI key is missing.", 500, "missing_api_key");
  }

  const url = new URL(path, BASE_URL);
  for (const [name, value] of Object.entries(query)) {
    if (value !== undefined && value !== null && `${value}` !== "") {
      url.searchParams.set(name, `${value}`);
    }
  }

  const cacheKey = normalizeCacheKey(["golfcourseapi", path, url.searchParams.toString()]);
  const { payload } = await cached(cacheKey, API_TTL_SECONDS, async () => {
    const rateLimit = await getCached(RATE_LIMIT_CACHE_KEY);
    if (rateLimit) {
      throw new GolfCourseAPIError("GolfCourseAPI rate limit reached.", 429, "rate_limited");
    }
    return fetchWithRetry(url, key);
  });

  return payload;
}

async function fetchWithRetry(url, key) {
  await waitForProviderSlot();
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${key}`
    }
  });

  if (response.status === 429) {
    await setCached(RATE_LIMIT_CACHE_KEY, {
      limitedAt: new Date().toISOString(),
      url: url.pathname
    }, RATE_LIMIT_COOLDOWN_SECONDS).catch(() => {});
  }

  return parseResponse(response);
}

async function waitForProviderSlot() {
  const now = Date.now();
  const waitMs = Math.max(0, nextProviderRequestAt - now);
  nextProviderRequestAt = Math.max(now, nextProviderRequestAt) + MIN_REQUEST_GAP_MS;
  if (waitMs > 0) {
    await delay(waitMs);
  }
}

async function parseResponse(response) {
  if (response.status === 401 || response.status === 403) {
    throw new GolfCourseAPIError("GolfCourseAPI rejected the key.", response.status, "unauthorized");
  }
  if (response.status === 429) {
    throw new GolfCourseAPIError("GolfCourseAPI rate limit reached.", response.status, "rate_limited");
  }
  if (!response.ok) {
    throw new GolfCourseAPIError("GolfCourseAPI returned an unexpected response.", response.status, "invalid_response");
  }

  return response.json();
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function searchCourses(query, options = {}) {
  const {
    limit = 8,
    maxDetails = 8
  } = options;

  const payload = await request("/v1/search", { search_query: query });
  const candidates = rankSearchResults(asArray(payload.courses), query).slice(0, Math.max(1, maxDetails));
  const courses = [];
  const seen = new Set();

  for (const candidate of candidates) {
    if (courses.length >= limit) break;
    try {
      const detail = await fetchCourse(candidate.id);
      const normalized = toGolfCourse(detail);
      if (!normalized.tees.length || seen.has(normalized.favoriteKey)) continue;
      courses.push(normalized);
      seen.add(normalized.favoriteKey);
    } catch (error) {
      if (error instanceof GolfCourseAPIError && ["unauthorized", "rate_limited"].includes(error.code)) {
        throw error;
      }
    }
  }

  return courses;
}

export async function searchMultipleQueries(queries, options = {}) {
  const results = [];
  const seen = new Set();
  const limit = options.limit ?? 8;

  for (const query of queries) {
    const matches = await searchCourses(query, {
      ...options,
      limit: Math.max(1, limit - results.length)
    });
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

export async function fetchCourse(id) {
  const payload = await request(`/v1/courses/${encodeURIComponent(id)}`);
  return payload.course || payload;
}

export async function fetchScorecard(id) {
  return toGolfCourse(await fetchCourse(id));
}

function rankSearchResults(courses, query) {
  const ukPreferred = preferUnitedKingdom(courses);
  const exactMatches = ukPreferred.filter((course) => isExactQueryMatch(course, query));
  return exactMatches.length > 0 ? exactMatches : ukPreferred;
}

function preferUnitedKingdom(courses) {
  const ukCourses = courses.filter(isUnitedKingdomCourse);
  return ukCourses.length > 0 ? ukCourses : courses;
}

function isUnitedKingdomCourse(course) {
  const country = course?.location?.country || "";
  const address = course?.location?.address || "";
  return /united kingdom|uk\b/i.test(country) || /,\s*uk$/i.test(address);
}

function isExactQueryMatch(course, query) {
  const normalizedQuery = normalizeSearchText(query);
  if (!normalizedQuery) return true;
  const haystack = normalizeSearchText(`${course.club_name || ""} ${course.course_name || ""}`);
  return new RegExp(`\\b${escapeRegExp(normalizedQuery)}\\b`, "i").test(haystack);
}

function normalizeSearchText(value) {
  return `${value}`.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function toGolfCourse(course) {
  const clubName = `${firstPresent(course, ["club_name", "clubName"], "")}`.trim();
  const courseName = `${firstPresent(course, ["course_name", "courseName"], clubName || "Golf Course")}`.trim();
  const location = normalizeLocation(course.location);
  const tees = normalizeTees(course.tees);
  const displayName = clubName && clubName.localeCompare(courseName, undefined, { sensitivity: "accent" }) !== 0
    ? `${clubName} - ${courseName}`
    : courseName;

  return {
    externalId: `${course.id}`,
    favoriteKey: `${course.id}|${displayName.toLowerCase()}`,
    name: displayName,
    clubName,
    location,
    latitude: Number(firstPresent(course.location, ["latitude", "lat"], null)),
    longitude: Number(firstPresent(course.location, ["longitude", "lng", "lon"], null)),
    distance: course.location?.city || course.location?.state || course.location?.country || "GolfCourseAPI",
    source: "golfcourseapi",
    tees
  };
}

function normalizeLocation(location = {}) {
  const parts = [
    location.city,
    location.state,
    location.country
  ].filter(Boolean);
  return parts.length > 0 ? parts.join(", ") : location.address || "GolfCourseAPI";
}

function normalizeTees(tees) {
  const rawTees = [
    ...asArray(tees?.male),
    ...asArray(tees?.female),
    ...asArray(tees)
  ];
  const seen = new Set();
  return rawTees
    .map(normalizeTee)
    .filter((tee) => tee.holes.length > 0)
    .filter((tee) => {
      const key = `${tee.name}|${tee.yards}|${tee.par}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

function normalizeTee(raw) {
  const holes = asArray(raw.holes).map(normalizeHole).filter((hole) => hole.number > 0);
  const par = Number(firstPresent(raw, ["par_total", "parTotal", "par"], holes.reduce((total, hole) => total + hole.par, 0)));
  return {
    name: `${firstPresent(raw, ["tee_name", "teeName", "name"], "Tee")}`,
    yards: Number(firstPresent(raw, ["total_yards", "totalYards", "yards"], holes.reduce((total, hole) => total + hole.yards, 0))),
    par,
    slope: Number(firstPresent(raw, ["slope_rating", "slopeRating", "slope"], 113)),
    rating: Number(firstPresent(raw, ["course_rating", "courseRating", "rating"], par)),
    holes
  };
}

function normalizeHole(raw, index) {
  return {
    number: Number(firstPresent(raw, ["hole_number", "holeNumber", "number", "hole"], index + 1)),
    par: Number(firstPresent(raw, ["par"], 4)),
    yards: Number(firstPresent(raw, ["yardage", "yards"], 0)),
    strokeIndex: Number(firstPresent(raw, ["stroke_index", "strokeIndex", "handicap_index", "handicap", "si"], index + 1))
  };
}
