# SmartRide

SmartRide is a native iOS app, built entirely in SwiftUI, that answers one question well: **when should I actually leave?** It combines live MapKit traffic data with a user's own driving history to recommend the best departure time for a trip — either "leave as early as possible while still arriving by a target time" or "find the best moment to leave starting now."

There is no backend, no server, and no third-party SDKs. Everything — routing, traffic estimation, history, notifications, and background refresh — runs on-device using Apple's own frameworks.

---

## Table of Contents

- [What it does](#what-it-does)
- [Frameworks & technologies](#frameworks--technologies)
- [App structure (tab by tab)](#app-structure-tab-by-tab)
- [The traffic recommendation engine](#the-traffic-recommendation-engine)
- [Notifications & background refresh](#notifications--background-refresh)
- [Data model](#data-model)
- [Known limitations](#known-limitations)
- [Project layout](#project-layout)

---

## What it does

Pick an origin, a destination, and optional stops in between. SmartRide then does one of two things:

1. **Depart At** — "If I leave around now, when's actually the best time in the next couple hours, and how much would I save vs. leaving right this second?"
2. **Arrive By** — "I need to be there by 6:15. What's the latest I can leave and still land exactly at 6:15 — not 10 minutes early, not 2 minutes late?"

Both answers are backed by real MapKit directions requests fired at multiple future departure times, blended with the user's own historical driving samples for that route, day of week, and time of day. The app also tracks saved commutes, recurring reminders (e.g. "remind me to leave for work every weekday"), a history of past trips, and a live traffic-aware map.

---

## Frameworks & technologies

All first-party Apple frameworks — confirmed by auditing every `import` statement across all Swift files in the project. No CocoaPods, no SPM third-party packages, no backend.

| Framework | What it's used for |
|---|---|
| **SwiftUI** | Every screen, all 5 tabs, all cards/sheets/popovers |
| **SwiftData** | Persistence — `@Model` classes, `@Query`, `ModelContext` for saved commutes, reminders, history, settings |
| **MapKit** | `MKDirections` for real routing/ETA requests, `MKRoute`/`MKPolyline` for route geometry, SwiftUI `Map` with `.mapStyle(.standard(showsTraffic: true))` for the live traffic overlay |
| **CoreLocation** | `CLLocationManager` for current location, `CLGeocoder` for address search/reverse geocoding, `CLLocation.distance(from:)` for straight-line distance math |
| **Charts** | The native Apple `Charts` framework powers the "View All Times" line graph |
| **UserNotifications** | Local notifications for Start At alarms (`UNCalendarNotificationTrigger`, repeating weekly) and Reach By / traffic-worsening alerts (`UNTimeIntervalNotificationTrigger`, one-shot, recomputed each time) |
| **BackgroundTasks** | `BGTaskScheduler` / `BGAppRefreshTask` — best-effort background refresh of upcoming reminders even if the app isn't opened |
| **Combine** | `@Published` / `ObservableObject` reactivity feeding SwiftUI views |
| **UniformTypeIdentifiers** | Drag-and-drop reordering of trip stops |
| **Swift Concurrency** | `async`/`await`, `withTaskGroup` for firing multiple MapKit requests concurrently, `.task(id:)` for debounced recomputation, `Task.isCancelled` staleness guards |

---

## App structure (tab by tab)

### Home
The main screen. Lets you set origin/destination/stops, pick Depart At or Arrive By, and see:
- The recommended time (big number), with a clear **"LEAVE AT"** label so it's unambiguous what the number means.
- Expected drive duration and a confidence percentage.
- Time saved vs. leaving right now.
- Three quick-pick "depart at" cards (Leave Now / Leave in 15 / Leave in 30) each showing the actual time cost of that choice.
- A live traffic map (MapKit's native traffic overlay) with the route drawn as a polyline.
- A "View All Times" button opening a 90-minute, 10-minute-interval chart + list of upcoming departure options (see below).
- **Smart Commute Alert**: for any saved commute with alerts enabled, SmartRide opportunistically rechecks the live traffic prediction whenever Home appears and fires a local notification if the predicted drive time has worsened by 12+ minutes since the last check (`SmartAlertChecker.swift`).

### Routes / Saved Commutes
Save frequently-used origin/destination/stop combinations as named commutes (e.g. "Home → Work"), with per-commute alert toggles and target arrival times. Commutes can be quickly loaded back into Home.

### Planner
A calendar-oriented view for setting up recurring reminders — "every weekday, remind me to leave for work" (Start At) or "remind me what time to leave to arrive by 9 AM" (Reach By). Internally recomputes recommendations the same way Home does, just driven by a calendar date instead of "right now."

### History
A log of past trips (`LoggedTrip`), each trip also silently contributing a `HistoricalSample` (duration, day of week, time bucket) used to personalize future recommendations for that route.

### Profile / Settings
Notification toggles, favorite locations, and app-level preferences (`AppSettings`).

### All Departure Times (detail sheet, not a tab)
Reached from Home's Leave At card. Shows a line chart and list of the next 90 minutes of departure options at 10-minute intervals — deliberately narrower than the engine's full 2.5-hour / 5-minute-granularity internal search window, since almost nobody actually chooses between leaving now and leaving two hours from now. Marks the best option in this near-term window, a dashed "leaving now" reference line, and (when it falls in range) a "Traffic Cliff" marker — the point beyond which drive time jumps sharply.

---

## The traffic recommendation engine

All of this lives in `RecommendationEngine.swift`. The goal throughout was to replace arbitrary constants with real formulas and real data wherever possible.

### 1. Live checkpoints, not a single guess
For a given trip, the engine fires **10 concurrent `MKDirections` requests** (via `withTaskGroup`) at future departure offsets of 15, 30, 45 … up to 150 minutes from now, each with its own real `departureDate`. This produces 10 genuine MapKit ETAs spread across the near future, rather than extrapolating from one snapshot.

### 2. Interpolating between checkpoints
To estimate drive time at an arbitrary minute in between two checkpoints, the engine linearly interpolates between the two nearest real checkpoints bracketing that time, and holds flat past either end of the sampled range.

### 3. Blending live data with personal history
Each estimate is a weighted blend of:
- **Checkpoint estimate** — from the live MapKit checkpoints above.
- **Historical estimate** — the user's own past drives on this exact route, bucketed by day-of-week (weekdays pooled together, weekends separate) and time-of-day.

The blend weight (`personalTrust`) scales with **distinct calendar days sampled**, not raw sample count — capped at 0.7. This matters because one real trip now logs ~10 checkpoints at once; counting raw samples would let a single trip look like ten days of history. Counting distinct days prevents that.

Historical weight also applies **recency-weighted exponential decay** — older samples count less, via `pow(0.5, ageDays / halfLife)` — so a route's predicted time adapts as driving patterns change rather than being anchored to data from months ago.

A single lone historical sample doesn't get flat-carried across its entire search radius either — its influence fades toward a live-data fallback the further away from that one sample's own time bucket you look, avoiding a "flat for an hour, then a fake jump" artifact.

### 4. Route-based traffic sensitivity (not arbitrary constants)
How much a route's time should swing with time-of-day traffic is computed from **the real fraction of the route's distance spent on numbered highways** (`highwayDistanceFraction`), using the formula:

```
sensitivity = 0.5 + 0.8 × highwayDistanceFraction
```

This replaced an earlier version that used arbitrary hardcoded multipliers (1.3 / 0.9 / 0.6) based on crude distance-ratio buckets. The highway-fraction approach is grounded in real traffic-flow theory (the "fundamental diagram" — highway segments see much sharper peak/off-peak swings than surface streets).

### 5. Traffic-insensitive modes
Walking and transit don't have a "rush hour" the way driving does, so `TravelMode.isTrafficSensitive` gates the time-of-day blending factor — it returns a flat `1.0` for walking/transit instead of applying a driving-shaped traffic curve to modes that don't have one.

### 6. Biking duration — distance ÷ speed
Biking time is computed directly from the route's real distance divided by an average speed (12 mph), replacing an earlier arbitrary 2.2× multiplier on the driving-equivalent time. This is the one universal, physics-based formula available (no live "bike traffic" data exists to query).

### 7. Multi-leg / multi-stop trips
For trips with intermediate stops, each leg's mode-adjustment (e.g. the biking formula above) is applied **before** computing the next leg's departure time, so leg 2+ is queried with a correct expected arrival time rather than chaining off an unadjusted leg 1 duration.

### 8. Depart At
Searches the full candidate window (every 5 minutes across 2.5 hours) for the minimum-duration departure, surfacing it alongside "leave now" for comparison — the displayed "time saved" is always a real subtraction between two fetched-or-interpolated numbers, never invented.

### 9. Arrive By — exact precision
Given a target arrival time, the engine finds the **latest candidate that still arrives on time**, then computes the exact departure as:

```
departureTime = targetArrival − predictedDurationMinutes
```

computed precisely rather than snapped to the 5-minute candidate grid, and without any safety buffer subtracted — so "arrive by 6:15" means the recommended leave time lands you at exactly 6:15, not earlier and not later. A reliability percentage (based on how variable the route's historical duration has been) is shown alongside it instead of silently padding the time.

---

## Notifications & background refresh

- **Start At reminders** use `UNCalendarNotificationTrigger` with `repeats: true` — a real recurring OS-level alarm, reliable independent of the app being opened.
- **Reach By reminders** use a one-shot `UNTimeIntervalNotificationTrigger`, recomputed and rescheduled each refresh cycle, since the correct leave time depends on live traffic that changes.
- **Background refresh**: `BackgroundReminderRefresher.swift` registers a `BGAppRefreshTask` (`nm.smartRide.refreshReminders`) so reminders can be recomputed even if the app is never opened that day. Each run immediately re-arms the next request (so task expiration doesn't kill the chain), then recomputes all enabled recurring reminders.
- **Adaptive timing**: the next background check's `earliestBeginDate` is computed dynamically — it narrows as the nearest upcoming reminder approaches (halfway to the deadline, bounded between 15 minutes and 3 hours), rather than running on a fixed interval.
- **Honest limitation**: `BGTaskScheduler`'s `earliestBeginDate` is a floor the OS may delay past, never a guaranteed wake time — iOS decides actual timing based on battery, usage patterns, and system state. This is a deliberate, best-effort, fully-on-device design (no backend/push involved), chosen specifically because notifications should come from the app itself with no visible external automation.

---

## Data model

Built on SwiftData (`@Model` classes):

- **`SavedCommute`** — a named origin/destination/stops combination with alert settings and target arrival.
- **`RecurringReminder`** — a recurring Start At / Reach By schedule tied to specific weekdays.
- **`LoggedTrip`** — a record of a completed trip.
- **`HistoricalSample`** — a (route, day-of-week, time-bucket, duration) data point logged from live checkpoints, feeding the personal-history blend described above.
- **`FavoriteLocation`** — quick-access saved addresses.
- **`AppSettings`** — app-wide preferences (notifications on/off, etc).

---

## Known limitations

Stated plainly, not glossed over:

- **No guaranteed wake time.** Background refresh is best-effort; iOS can delay or skip a scheduled check entirely under system pressure. There is no iOS API that guarantees a notification fires at a precise moment without a backend + push notifications.
- **No server-side traffic source.** All traffic data comes from on-device MapKit requests at the moment they're made — there's no persistent server aggregating traffic across all users.
- **Personal history needs real usage to help.** The historical-blend weighting intentionally caps out slowly (requires several distinct days of real trips) specifically to avoid letting one or two early logged trips over-influence predictions before there's enough data to trust them.

---

## Project layout

```
SmartRide/
├── SmartRideApp.swift              # App entry point, ModelContainer setup, background task registration
├── ContentView.swift                # Home tab
├── MainTabView.swift                # Tab bar root
├── RoutesView.swift                 # Saved commutes tab
├── PlannerView.swift                # Recurring reminder planner tab
├── PlannerCalendarView.swift
├── HistoryView.swift                 # Trip history tab
├── ProfileView.swift                 # Settings tab
├── AllDepartureTimesView.swift       # "View All Times" detail sheet
├── RecommendationEngine.swift        # Core traffic/recommendation logic
├── Models.swift                      # TravelMode, Recommendation, CandidateResult, etc.
├── Components.swift                  # Shared UI cards (Arrive By card, Depart At cards, etc.)
├── RouteMapView.swift                 # Live traffic map + polyline rendering
├── NotificationManager.swift          # Local notification scheduling
├── SmartAlertChecker.swift            # Foreground "traffic worsened" alert check
├── BackgroundReminderRefresher.swift  # BGTaskScheduler-based background refresh
├── RecurringReminderScheduler.swift   # Reminder scheduling + next-alert-time lookup
├── LocationManager.swift              # CoreLocation wrapper
├── LocationSearchCompleter.swift      # MapKit search completion
├── LocationSearchField.swift
├── StopSearchPopover.swift
├── SavedCommute.swift / RecurringReminder.swift / LoggedTrip.swift /
│   HistoricalSample.swift / FavoriteLocation.swift / ReminderItem.swift   # SwiftData models
├── AddCommuteView.swift / AddFavoriteView.swift / AddRecurringReminderView.swift /
│   SaveRouteAsView.swift / RouteSaveMenu.swift                            # Add/edit sheets
├── DemoSeedData.swift                 # Sample data for first-run/demo
├── Info.plist                         # Hand-written (background modes, task identifiers)
└── LaunchScreenView.swift
```
