# Precision Golf

Precision Golf is a SwiftUI prototype for a live golf performance tracker.

## What is included

- Ultra-modern dark SwiftUI interface
- Home performance dashboard
- Location-style nearby course selection using mock course data
- Tee box and scorecard preview with par, yardage, slope, rating, and stroke index
- Live hole-by-hole round tracker
- Score, putts, fairway miss, GIR miss, penalties, and quick notes
- Insights screen with live patterns and practice recommendation
- Journal screen for confidence, swing thoughts, and round reflection

## Open in Xcode

Open:

```text
PinpointGolf.xcodeproj
```

Then run the `PinpointGolf` scheme on an iPhone simulator.

## Verification

The project was built successfully with:

```sh
xcodebuild -project PinpointGolf.xcodeproj -scheme PinpointGolf -configuration Debug -sdk iphonesimulator -destination generic/platform=iOS\ Simulator -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```
