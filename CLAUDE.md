# TravelMapping

iOS/watchOS/widget app for the TravelMapping community project. GitHub: `psiegel18/TravelMapIOS`.

## Build

```bash
xcodebuild -project TravelMappingApp.xcodeproj -scheme TravelMappingApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### Architecture

- **SwiftUI** app targeting iOS 17+
- 5 main tabs: Travelers, Road Trips, Route Planner, Leaderboard, Settings
- Two TravelMapping APIs: `.shared` (roads) and `.rail` (rail/transit)
- iCloud sync via `NSUbiquitousKeyValueStore` in `SyncedSettingsService`
- GPS trip recording with real-time segment matching in `TripRecordingService`
- Sentry crash reporting (all errors via `SentrySDK.capture(error:)`, no `print()`)
- Stats prefetch on launch for primary user + up to 3 favorites
- In-memory `StatsCache` (1hr TTL) for instant re-navigation
- Widget data populated from main app via app group (`group.com.psiegel18.TravelMapping`)

### Key Conventions

- Use `.buttonStyle(.plain)` on any Button with a custom `.background()` — prevents purple glow on physical devices
- Use `.formatted()` on integers in UI text for comma separators
- Rail lines rendered with double-stroke technique (not StrokeStyle dashes — MapKit bug)
- Polylines capped at 15 coordinates to work around MapKit dash rendering issues
- `TMStatsService` CSV parser skips "TOTAL" summary rows
- Backward-compatible Codable: use `decodeIfPresent` with defaults for new fields
- Expensive map work (polyline rebuild, segment distance) runs off main thread
- Multi-region routes aggregate by root base name (e.g. `il.i090` → `i090`)
- Use `ShareLink` for sharing text, not `UIActivityViewController` wrappers
- New types must be embedded in existing files (pbxproj edits don't work reliably)

### Project Structure

```
TravelMappingApp.xcodeproj/    # Xcode project (repo root)
TravelMappingApp/              # iOS app target sources
  ContentView.swift            # Tab bar (5 tabs), prefetch, widget cache
  Views/
    GetStartedView.swift       # Native onboarding (region picker, segment picker map, email composer)
    SettingsView.swift         # Settings, TipJar, PrivacyPolicyView
    StatisticsView.swift       # Stats with StatsCache, cross-region route aggregation
    TravelMapView.swift        # Map with background polyline rebuild, bounding box tap filter
    RouteDetailView.swift      # Cross-region route detail with per-region breakdown
    UserDetailView.swift       # User profile with List/Map/Stats tabs
    ...
  Services/                    # API, sync, recording, caching
  Models/                      # RoadTrip, UserProfile, etc.
  Parsers/                     # .list file parsing
  Intents/                     # Siri/Shortcuts
Shared/                        # Code shared across targets
TravelMappingWatch/            # watchOS companion target
TravelMappingWidget/           # Home screen widgets target (reads from app group)
docs/PRIVACY.html              # Web privacy policy (GitHub Pages)
```
