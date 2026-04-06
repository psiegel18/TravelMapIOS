# TravelMapping

Monorepo for TravelMapping project. The iOS app lives in `TravelMappingApp/`.

## iOS App (TravelMappingApp/)

### Build

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

### Key Conventions

- Use `.buttonStyle(.plain)` on any Button with a custom `.background()` — prevents purple glow on physical devices
- Use `.formatted()` on integers in UI text for comma separators
- Rail lines rendered with double-stroke technique (not StrokeStyle dashes — MapKit bug)
- Polylines capped at 15 coordinates to work around MapKit dash rendering issues
- `TMStatsService` CSV parser skips "TOTAL" summary rows
- Backward-compatible Codable: use `decodeIfPresent` with defaults for new fields

### Project Structure

```
TravelMappingApp/
  TravelMappingApp/
    ContentView.swift          # Tab bar (5 tabs)
    Views/                     # All SwiftUI views
    Services/                  # API, sync, recording, caching
    Models/                    # RoadTrip, UserProfile, etc.
    Parsers/                   # .list file parsing
    Intents/                   # Siri/Shortcuts
  TravelMappingWatch/          # watchOS companion
  TravelMappingWidget/         # Home screen widgets
```
