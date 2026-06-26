# Pinpoint Golf Course API

Backend proxy for UK golf course search.

The iOS app calls this API instead of calling RapidAPI directly. The backend keeps the RapidAPI key private and caches results in Supabase so repeated searches do not burn quota.

## Environment

Create these variables in Vercel:

```text
UK_GOLF_API_KEY
SUPABASE_URL
SUPABASE_SERVICE_ROLE_KEY
```

`SUPABASE_SERVICE_ROLE_KEY` must only live on the backend. Do not put it in the iOS app.

## iOS App Configuration

Set this Xcode build setting to your deployed backend URL:

```text
PINPOINT_COURSE_API_BASE_URL=https://your-vercel-app.vercel.app
```

The value is exposed to the app as `PinpointCourseAPIBaseURL` in `Info.plist`. It is not a secret.

If this value is empty, the app falls back to bundled/local courses rather than calling RapidAPI from the phone.

## Supabase

Run:

```sql
supabase/course-cache.sql
```

This creates `course_api_cache`.

If Supabase env vars are missing, the API still works with in-memory cache only, but Vercel functions may lose that cache between cold starts.

## Endpoints

```text
GET /api/courses/search?q=wentworth&limit=8
GET /api/courses/near?lat=51.60&lng=-0.40&queries=Sandy%20Lodge|Moor%20Park&limit=4
GET /api/courses/scorecard?id=12345
```

## Cache TTLs

- Course name search: 30 days
- Nearby search: 14 days
- Scorecard lookup: 365 days

## Local

```bash
npm install
npm run check
npm run dev
```

Then call:

```text
http://localhost:3000/api/courses/search?q=wentworth
```
