export function sendJson(res, status, payload, cacheSeconds = 0) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  if (cacheSeconds > 0) {
    res.setHeader("Cache-Control", `s-maxage=${cacheSeconds}, stale-while-revalidate=86400`);
  } else {
    res.setHeader("Cache-Control", "no-store");
  }
  res.end(JSON.stringify(payload));
}

export function sendError(res, status, message, code = "error") {
  sendJson(res, status, { error: { code, message } });
}

export function requireMethod(req, res, method = "GET") {
  if (req.method === method) {
    return true;
  }
  res.setHeader("Allow", method);
  sendError(res, 405, `Use ${method}.`, "method_not_allowed");
  return false;
}

export function stringParam(value) {
  if (Array.isArray(value)) return value[0] ?? "";
  return typeof value === "string" ? value : "";
}

export function numberParam(value) {
  const parsed = Number(stringParam(value));
  return Number.isFinite(parsed) ? parsed : null;
}

export function splitList(value) {
  return stringParam(value)
    .split(/[|,]/)
    .map((item) => item.trim())
    .filter(Boolean);
}
