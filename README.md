# Glassday

A personal day planner for iPhone with a frosted-glass interface, a visual daily timeline, and two-way sync with Apple Calendar. It includes home-screen widgets that show your month at a glance.

Glassday is built as a SwiftUI shell around a hand-written HTML/CSS/JS interface. A small native bridge connects that interface to EventKit (Apple Calendar) and WidgetKit.

<p align="center">
  <img src="docs/screenshots/hero.png" alt="Glassday timeline, month view and new task panel" width="100%">
</p>

---

## Features

### Planning
- **Timeline**: your day as a vertical timeline.
  - Pill heights scale with each task's duration.
  - A live "now" line and an "Xm remaining" progress fill show where you are.
  - Free gaps between tasks appear as chips you can tap to fill.
- **Calendar tab** with three views:
  - **Week**: a time grid. Tap an empty slot to add at that time.
  - **Month**: a grid with event bars. Tap a day to see its events below the grid, tap again to open it.
  - **Year**: all 12 months, shaded by how busy each day is.
- **Inbox**: to-dos with no time yet. Your top inbox items also appear as quick bubbles at the top of the Timeline.
- **Overdue**: missed tasks are collected with a one-tap *Move to today*.
- **Repeating tasks**: daily, weekdays or weekly.
- **Overlap warnings** when you schedule over another task.

<p align="center">
  <img src="docs/screenshots/calendar-views.png" alt="Week view, year view and inbox" width="100%">
  <br><sub>Week view · Year view · Inbox</sub>
</p>

### Smart helpers (on-device, no AI service)
- **Natural-language add**: type `Gym tomorrow 6pm for 1h` or `Study every weekday 8pm 90 min`. Glassday picks out the date, time, duration and repeat, and chooses an icon.
- **Plan my day**: fits your inbox to-dos into free gaps, with 10-minute breaks between them.
- **Insights**: planned vs free time, your longest focus window, a completion streak, and a week-load chart.

### Focus
- Tap any task's icon to start a **focus timer** with a countdown ring.
- The screen stays awake while the timer runs.

<p align="center">
  <img src="docs/screenshots/smart-settings.png" alt="Smart planner, settings and dark mode" width="100%">
  <br><sub>Smart planner · Settings with theme colours · Dark mode</sub>
</p>

### Look and feel
- Glassmorphism UI with ambient animated colour blobs.
- **8 theme colours**: Champagne, Rose gold, Emerald, Sapphire, Lavender, Ocean, Sunset and Graphite. Each has its own light and dark version.
- Spring animations, a confetti burst when you complete a task, swipe gestures and native haptics.
- Undo for most actions.

<p align="center">
  <img src="docs/screenshots/themes.png" alt="Rose gold, Emerald, Sapphire, Lavender and dark Champagne themes" width="100%">
  <br><sub>Rose gold · Emerald · Sapphire · Lavender · Champagne (dark)</sub>
</p>

### iPhone integration
- **Two-way Apple Calendar sync**:
  - Scheduled tasks are real calendar events.
  - Changes made in Apple Calendar, or in Google/Outlook accounts added to iOS, appear in Glassday instantly.
- **Widgets**:
  - **Month** (large): Sunday-first month grid with event bars. Tap a day to open it in the app.
  - **Today** (small / medium): what's next today.
- **Deep links**: `glassday://day/YYYY-MM-DD` opens a specific day.

---

## Tech stack

| Layer | Technology |
|---|---|
| UI | Vanilla HTML, CSS and JavaScript in a single file (no framework, no build step) |
| App shell | SwiftUI and `WKWebView` (iOS 17+) |
| Calendar | EventKit (full-access API) |
| Widgets | WidgetKit and SwiftUI |
| Project generation | [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| Fonts | Bricolage Grotesque and Manrope (Google Fonts) |

---

## Project structure

```
Glassday/
├── project.yml                 # XcodeGen spec (targets, bundle IDs, Info.plist keys)
├── setup.sh                    # Installs XcodeGen if needed, generates and opens the project
├── docs/screenshots/           # Images used in this README
├── App/
│   ├── GlassdayApp.swift       # App entry point
│   ├── ContentView.swift       # WKWebView host, deep links, keyboard handling
│   ├── CalendarBridge.swift    # JS ⇄ EventKit bridge, haptics, persistence
│   ├── Resources/
│   │   └── index.html          # The whole Glassday interface
│   └── Assets.xcassets/        # App icon
└── Widget/
    └── GlassdayWidgets.swift   # Month + Today widgets
```

---

## How it works

```
┌──────────────────────────┐      postMessage       ┌──────────────────────┐
│  index.html (WKWebView)  │ ─────────────────────▶ │   CalendarBridge     │
│  UI, local state         │                        │   (Swift)            │
│                          │ ◀───────────────────── │                      │
└──────────────────────────┘   evaluateJavaScript   └──────────┬───────────┘
                                 (GDN.* callbacks)              │ EventKit
                                                                ▼
                         ┌───────────────────┐       ┌────────────────────┐
                         │  Widget extension │ ◀──── │   Apple Calendar   │
                         │  (reads EventKit) │       │   (source of truth │
                         └───────────────────┘       │    for events)     │
                                                     └────────────────────┘
```

### Where data lives
- **Scheduled tasks** are Apple Calendar events. Calendar is the source of truth for them.
- **Kept in the app** (saved in `UserDefaults`):
  - inbox to-dos,
  - per-event icons and colours,
  - completion ticks,
  - settings.

### Bridge messages (page → native)

| `type` | Payload | Purpose |
|---|---|---|
| `ready` | | Page loaded; flush any pending deep link |
| `access` | | Request or confirm calendar access |
| `load` | `from`, `to` (YYYY-MM-DD) | Fetch events in a date window |
| `upsert` | `reqId`, `series?`, `occDate?`, `title`, `date`, `start`, `dur`, `repeat`, `notes`, `calId` | Create or update an event |
| `delete` | `series`, `occDate`, `span` (`one`/`future`) | Remove an event |
| `persist` | `data` (JSON string) | Save app-only state |
| `haptic` | `style` (`light`/`medium`/`success`) | Haptic feedback |
| `awake` | `on` | Keep the screen awake during focus |

### Native → page callbacks
`GDN.access(status)`, `GDN.calendars(list, defaultId)`, `GDN.events(list, from, to)`, `GDN.saved(reqId, id, error)`, `GDN.openDay(key)`, `GDkb(keyboardHeight)`

### Rules for recurring and read-only events
- Edits to a recurring event apply to **this and future** occurrences.
- Events from read-only calendars (holidays, subscriptions) can't be moved. You can still give them an icon and colour.

The interface also runs in a normal browser. Without the bridge it falls back to `localStorage` with sample data, which makes UI work quick to iterate on.

---

## Getting started

### Requirements
- A Mac with **Xcode 15+**
- An iPhone on **iOS 17+**
- An Apple ID (a free account works)

### Setup
```bash
# 1. Homebrew (skip if `brew --version` works)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"

# 2. Point to Xcode and install XcodeGen
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
brew install xcodegen

# 3. Clone, generate, open
git clone https://github.com/<your-username>/Glassday.git
cd Glassday
xcodegen generate
open Glassday.xcodeproj
```

### Run on your iPhone
1. **Xcode → Settings → Accounts**: sign in with your Apple ID.
2. Select the **Glassday** project.
3. For **both** targets (`Glassday` and `GlassdayWidget`), go to **Signing & Capabilities** and set **Team** to your Personal Team.
   - If the bundle ID is taken, change `com.geraldangya` in `project.yml` (or in Xcode) to your own prefix.
4. On your iPhone, turn on **Settings → Privacy & Security → Developer Mode** and restart when asked.
5. Plug in your phone, select it as the run destination, and press **▶ Run**.
6. If prompted, go to **Settings → General → VPN & Device Management** on the phone and trust your developer profile.
7. Open Glassday and allow **Full Access** to Calendar.
8. Add the widget: long-press the home screen, then **Edit → Add Widget → Glassday**.

> **Free Apple ID:** apps signed with a free account expire after **7 days**. Re-run from Xcode to renew; your data stays. A paid Apple Developer Program membership extends this to one year.

### Working on the UI
The whole interface is in `App/Resources/index.html`. You can open it directly in a browser to iterate, then press **▶ Run** in Xcode to test it on the phone.

---

## Roadmap ideas
- [ ] Widget follows the selected theme colour (via an App Group)
- [ ] Apple Reminders sync for inbox to-dos
- [ ] Notifications before tasks start
- [ ] Interactive widget checkboxes (iOS 17 App Intents)
- [ ] Bundle fonts locally for full offline use

---

## License
MIT. Use it, learn from it, and make it yours.
