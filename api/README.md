# Precision Golf Course API

Backend proxy for golf course search.

The iOS app calls this API instead of calling GolfCourseAPI directly. The backend keeps the API key private, stores normalized found courses in Firebase Firestore, and caches provider responses so repeated searches do not burn quota.

## Environment

Create these variables in Vercel:

```text
GOLFCOURSE_API_KEY
FIREBASE_PROJECT_ID
FIREBASE_CLIENT_EMAIL
FIREBASE_PRIVATE_KEY
```

The Firebase values come from a Firebase service account and must only live on the backend. Do not put the private key in the iOS app.

`GOLFCOURSE_API_KEY` should be the key from GolfCourseAPI. The backend does not call any other golf course search provider.

## iOS App Configuration

Set this Xcode build setting to your deployed backend URL:

```text
PINPOINT_COURSE_API_BASE_URL=https://your-vercel-app.vercel.app
```

The value is exposed to the app as `PrecisionCourseAPIBaseURL` in `Info.plist`. It is not a secret.

If this value is empty, live course search will be unavailable. The app does not call GolfCourseAPI directly from the phone.

## Firebase

The backend uses these Firestore collections:

- `courseApiCache` for provider response caching.
- `courseDirectory` for normalized course records that the app can reuse before calling GolfCourseAPI again.

If Firebase Admin env vars are missing, the API still works with in-memory cache only, but Vercel functions may lose that cache between cold starts and cannot build the shared course directory.

## Endpoints

```text
GET /api/health
GET /api/courses/search?q=wentworth&limit=8
GET /api/courses/near?lat=51.60&lng=-0.40&limit=3&radiusMeters=8047
GET /api/courses/scorecard?id=12345
```

## Cache TTLs

- Course name search: 30 days
- Nearby search: 14 days
- Scorecard lookup: 365 days

Successful API searches are also upserted into Firestore `courseDirectory` by GolfCourseAPI `externalId`. Future matching searches check that directory first, then call GolfCourseAPI only when more data is needed.

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
