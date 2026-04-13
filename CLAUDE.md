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
- Sentry crash reporting (all errors via `SentrySDK.capture(error:)`, no `print()`); SDK 9.9.0; environment `development`/`testflight`/`appstore` via `sandboxReceipt`; continuous profiling, unmasked session replay, structured logs, error-attached screenshots, user feedback widget with native form, size analysis via CI
- Sentry contexts: `trip_state` (refreshed every 10s during recording), `preferences`, `profile` — visible on every captured event
- `TripStorageService` is an `actor` — callers must `await` (or pre-compute in `.task`)
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
- Use `ShareLink(item: url)` for file/URL share sheets, not a `UIActivityViewController` wrapper (both the wrapped and nested-wrapper variants fail in subtle ways on iPhone; native ShareLink handles presentation correctly)
- New types must be embedded in existing files (pbxproj edits don't work reliably)
- Chained `.alert(...)` modifiers on a `Section` inside a `Form` silently fail to present — attach alerts to the `Form` itself (outside all sections)
- Sentry `customButton` for user feedback must be embedded in the SwiftUI view hierarchy (0x0 invisible `UIViewRepresentable` host works) — an orphan UIButton won't find a presenting view controller and the form won't appear
- `RouteDetailView` merges consecutive same-clinched segments into single `MapPolyline` objects before rendering — thousands → dozens. Without this, MapKit Metal teardown blocks main thread for 5-7s on iPad
- Prefer the App Store write-review URL (`https://apps.apple.com/app/id{APP_ID}?action=write-review`) over `SKStoreReviewController.requestReview()` — the system prompt is silently throttled (3/year cap, can no-op in TestFlight)

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
PrivacyInfo.xcprivacy          # Apple privacy manifest (in TravelMappingApp/, added to all 3 targets)
ci_scripts/ci_post_xcodebuild.sh  # Xcode Cloud: uploads dSYMs, creates release, uploads archive for Size Analysis
```

### Xcode Cloud

- `SENTRY_AUTH_TOKEN` stored as a Shared Environment Variable (Secret)
- `ci_post_xcodebuild.sh` installs `sentry-cli` into `$CI_WORKSPACE/.sentry-cli-bin`, uploads dSYMs with `--include-sources`, creates/finalizes a Sentry release matching `com.psiegel18.TravelMapping@<version>+<build>`, associates commits via GitHub integration, and uploads the xcarchive for Size Analysis
- All steps non-fatal so a transient failure in one doesn't skip the rest
