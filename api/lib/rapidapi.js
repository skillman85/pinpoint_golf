const RAPIDAPI_HOST = "uk-golf-course-data-api.p.rapidapi.com";
const BASE_URL = `https://${RAPIDAPI_HOST}`;

export class RapidAPIError extends Error {
  constructor(message, status = 500, code = "rapidapi_error") {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function rapidKey() {
  return process.env.UK_GOLF_API_KEY || process.env.RAPIDAPI_KEY || "";
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

function unwrapArray(payload, keys) {
  if (Array.isArray(payload)) return payload;
  for (const key of keys) {
    if (Array.isArray(payload?.[key])) return payload[key];
  }
  return [];
}

async function request(path, query = {}) {
  const key = rapidKey().trim();
  if (!key) {
    throw new RapidAPIError("RapidAPI key is missing.", 500, "missing_api_key");
  }

  const url = new URL(path, BASE_URL);
  for (const [name, value] of Object.entries(query)) {
    if (value !== undefined && value !== null && `${value}` !== "") {
      url.searchParams.set(name, `${value}`);
    }
  }

  const response = await fetch(url, {
    headers: {
      "X-RapidAPI-Key": key,
      "X-RapidAPI-Host": RAPIDAPI_HOST
    }
  });

  if (response.status === 401 || response.status === 403) {
    throw new RapidAPIError("RapidAPI rejected the key.", response.status, "unauthorized");
  }
  if (response.status === 429) {
    throw new RapidAPIError("RapidAPI rate limit reached.", response.status, "rate_limited");
  }
  if (!response.ok) {
    throw new RapidAPIError("RapidAPI returned an unexpected response.", response.status, "invalid_response");
  }

  return response.json();
}

export async function searchClubs(query) {
  const payload = await request("/clubs", { search: query });
  return unwrapArray(payload, ["data", "clubs", "results"]).map(normalizeClub);
}

export async function fetchClubCourses(clubId) {
  const payload = await request(`/clubs/${encodeURIComponent(clubId)}/courses`);
  return unwrapArray(payload, ["data", "courses", "results"]).map(normalizeCourseSummary);
}

export async function fetchScorecard(courseId) {
  const payload = await request(`/courses/${encodeURIComponent(courseId)}`);
  const scorecard = Array.isArray(payload)
    ? payload[0]
    : firstPresent(payload, ["data", "course", "scorecard"], payload);
  return normalizeScorecard(scorecard, courseId);
}

export async function searchCourses(query, options = {}) {
  const {
    maxClubs = 6,
    maxCoursesPerClub = 2,
    limit = 8
  } = options;

  const clubs = await searchClubs(query);
  const results = [];
  const seen = new Set();

  for (const club of clubs.slice(0, maxClubs)) {
    const courses = await fetchClubCourses(club.id);
    for (const course of courses.slice(0, maxCoursesPerClub)) {
      try {
        const scorecard = await fetchScorecard(course.id);
        const normalized = toGolfCourse(club, course, scorecard);
        if (!seen.has(normalized.favoriteKey)) {
          results.push(normalized);
          seen.add(normalized.favoriteKey);
        }
        if (results.length >= limit) {
          return results;
        }
      } catch {
        // Skip individual scorecard failures so one bad RapidAPI record does not fail the whole search.
      }
    }
  }

  return results;
}

export async function searchMultipleQueries(queries, options = {}) {
  const results = [];
  const seen = new Set();
  const limit = options.limit ?? 8;

  for (const query of queries) {
    const matches = await searchCourses(query, options);
    for (const course of matches) {
      if (!seen.has(course.favoriteKey)) {
        results.push(course);
        seen.add(course.favoriteKey);
      }
      if (results.length >= limit) {
        return results;
      }
    }
  }

  return results;
}

function normalizeClub(raw) {
  return {
    id: `${firstPresent(raw, ["id", "club_id", "clubId"], "")}`,
    name: `${firstPresent(raw, ["name", "club", "club_name"], "Unknown Club")}`,
    county: firstPresent(raw, ["county", "region"], null),
    postcode: firstPresent(raw, ["postcode", "post_code"], null),
    latitude: Number(firstPresent(raw, ["latitude", "lat"], NaN)),
    longitude: Number(firstPresent(raw, ["longitude", "lng"], NaN))
  };
}

function normalizeCourseSummary(raw) {
  return {
    id: `${firstPresent(raw, ["id", "course_id", "courseId"], "")}`,
    name: `${firstPresent(raw, ["name", "course", "course_name"], "Course")}`
  };
}

function normalizeScorecard(raw, fallbackId) {
  const tees = unwrapArray(raw, ["teeSets", "tee_sets", "tees"]);
  return {
    id: `${firstPresent(raw, ["id", "course_id", "courseId"], fallbackId)}`,
    name: `${firstPresent(raw, ["name", "course", "course_name"], "Course")}`,
    tees: tees.map(normalizeTee).filter((tee) => tee.holes.length > 0)
  };
}

function normalizeTee(raw) {
  const holes = unwrapArray(raw, ["holes"]).map(normalizeHole).filter((hole) => hole.number > 0);
  const yards = Number(firstPresent(raw, ["yards", "yardage"], holes.reduce((total, hole) => total + hole.yards, 0)));
  const par = Number(firstPresent(raw, ["par"], holes.reduce((total, hole) => total + hole.par, 0)));
  return {
    name: `${firstPresent(raw, ["name", "tee", "tee_name", "colour", "color"], "Tee")}`,
    yards,
    par,
    slope: Number(firstPresent(raw, ["slopeRating", "slope_rating", "slope"], 113)),
    rating: Number(firstPresent(raw, ["courseRating", "course_rating", "rating"], par)),
    holes
  };
}

function normalizeHole(raw, index) {
  return {
    number: Number(firstPresent(raw, ["holeNumber", "hole_number", "number"], index + 1)),
    par: Number(firstPresent(raw, ["par"], 4)),
    yards: Number(firstPresent(raw, ["yardage", "yards"], 0)),
    strokeIndex: Number(firstPresent(raw, ["strokeIndex", "stroke_index", "handicap", "si"], index + 1))
  };
}

function toGolfCourse(club, course, scorecard) {
  const courseName = scorecard.name && scorecard.name !== "Course" ? scorecard.name : course.name;
  const location = [club.county, club.postcode].filter(Boolean).join(", ") || "Verified UK scorecard";
  return {
    externalId: scorecard.id || course.id,
    favoriteKey: `${courseName.toLowerCase()}|${location.toLowerCase()}`,
    name: courseName,
    clubName: club.name,
    location,
    distance: club.postcode || club.county || "UK",
    source: "rapidapi",
    tees: scorecard.tees
  };
}
