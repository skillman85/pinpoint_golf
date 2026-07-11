# Precision Golf PWA

This is the web/PWA foundation for players who are not using the iOS app.

## Intent

The PWA should become functionally equivalent to the iOS app over time:

- Firebase Auth sign in and profile sync
- Individual round scoring
- Saved rounds and digital scorecards
- Season stats and goals
- Friends, friend profiles and shared rounds
- Groups and live Stableford leaderboards

## First pass

This branch starts the installable app shell, visual system, tab navigation, demo individual scoring flow, friends/groups screens and Firebase-ready config.

The Firebase web app ID still needs to be added from the Firebase console:

```sh
VITE_FIREBASE_WEB_APP_ID=your_web_app_id
```

## Run

```sh
npm install
npm run dev
```

## Build

```sh
npm run build
```
