# Glassday review: HIG, design and flows (Nov 2026)

How this was done: I read every file in the brief. The UI was rendered in the iOS Simulator (iPhone 18 Pro, your installed build) and in a 375pt browser preview. Contrast ratios were computed with the WCAG formula; the HIG skill's `hig_checker.py` mis-reads 3-digit hex like `#fff`, so on-accent pairs were recomputed by hand. Each finding is marked **Seen** (observed running), **Traced** (followed through the code) or **Measured** (computed).

Skills used:
- `mobile-app-design:ios-review`, `apple-hig-expert`, `mobile-app-design:ios-flows` and `figma:figma-swiftui` all exist and ran.
- UXKIN is not connected, so the flow advice comes from Apple's conventions, not from comparing real apps.
- `figma-swiftui` translates between Figma and SwiftUI. There is no Figma file, so I used only its SwiftUI rules: semantic colours, SF Symbols and system patterns. The SwiftUI critique is in section F.

## Executive summary

1. **What's good, leave it alone:** the single-file HTML UI is well built. Event delegation means listeners don't leak. Escaping (`esc()`) is consistent. Reduced motion is respected. Safe-area insets are handled everywhere. The sheet keyboard handling (`GDkb` → `--kb`) works. The bridge validates its inputs. Calendar data from EventKit renders correctly (Seen).
2. **P0-1:** if iOS kills WKWebView's content process, which is common under memory pressure in the background, the app stays blank until it is force-quit. Nothing handles that termination.
3. **P0-2:** keep-awake (`isIdleTimerDisabled`) is never reset when the app goes to the background or the web view dies.
4. **P0-3:** if the bridge can't find an occurrence when you edit a Calendar event, it silently creates a **duplicate** event. Deletes that fail tell the page nothing, so the page says "Deleted" anyway.
5. **P1-1:** the system Calendar prompt appears over the splash on first launch, with no explanation first (Seen).
6. **P1-2:** when access is denied, the app shows only text. There is no button to open Settings (Seen).
7. **P1-3:** the task sheet has no Cancel or close control. It can only be dismissed by dragging or tapping outside (Seen).
8. Also confirmed: text never scales with Dynamic Type (Seen at AX3). The timeline replays its entrance animation every 30 s (Seen). White icons and text on 5 of the 8 task colours fall below 3:1 (Measured).
9. **Signing is consistent.** `build-ipa.sh` builds unsigned and Sideloadly signs both bundles. The gap is that a missing widget only prints a warning (P0-4).
10. **Needs your decision:** syncing the widget with the theme requires an App Group. It is written up as a plan in P3-1 and not built.

## Findings

### P0: ship-blockers

| ID | Finding | Where | Why it matters | Fix |
|---|---|---|---|---|
| P0-1 | No handler for web content process termination | `App/ContentView.swift:37-53` (no `navigationDelegate`) | When iOS reclaims WebContent memory in the background, the app comes back as a blank screen. `pageReady` stays `true`, so deep links are sent into a page that isn't there. (Traced) | Add a `WKNavigationDelegate`. In `webViewWebContentProcessDidTerminate`, call `bridge.pageWillReload()` to reset `pageReady`/`range` and turn keep-awake off, then `reload()`. |
| P0-2 | Keep-awake leaks past the focus session | `App/CalendarBridge.swift:59-60`, `App/ContentView.swift:14-16` | The `awake` flag is only cleared when JS sends `{on:false}`. A crash, reload or kill leaves the screen unable to sleep, which drains the battery. (Traced) | On `scenePhase == .background`, force `isIdleTimerDisabled = false`. When the page becomes visible again, it re-sends `awake:true` if a timer is still running. |
| P0-3 | Edit can duplicate an event; delete fails silently | `CalendarBridge.swift:203-210, 238-251`; `index.html:1288-1291, 1303` | If `occurrence()` returns nil (the event was deleted or moved in Calendar since the last load), `upsert` falls through to `EKEvent(eventStore:)` and makes a **new** event. `delete` does nothing and sends no reply, while the page shows "Deleted from Apple Calendar". `span:"all"` quietly drops to `.futureEvents` when `calendarItem(withIdentifier:)` fails. (Traced) | When a `series` is given but not found, reply with an error and don't create anything. Make `delete` report "not found" and errors through `GDN.saved`. Only the page's reload restores the truth. |
| P0-4 | IPA can ship without the widget | `build-ipa.sh:17`; `make-ipa.sh` | The script warns and keeps going. Sideloadly then installs an app with no widgets. `make-ipa.sh` is an older copy with no check at all. (Traced) | Exit 1 if `PlugIns/GlassdayWidget.appex` or its executable is missing. Make `make-ipa.sh` call `build-ipa.sh`. |

### P1: HIG violations and flow friction

| ID | Finding | Where | Why it matters | Fix |
|---|---|---|---|---|
| P1-1 | Calendar permission requested cold, over the splash | `index.html:1392`; `CalendarBridge.swift:68-82` | HIG (Requesting permission): ask in context and explain the value first. The prompt covers the splash before the user has seen the app. (Seen) | Add a `status` message that reports without prompting. When status is `notDetermined`, show a "Connect Apple Calendar" card on the Timeline. Its button sends `access`. Inbox and local tasks keep working. |
| P1-2 | Denied state is a dead end; write-only is mislabelled | `index.html:738, 903-905`; `CalendarBridge.swift:79-81` | HIG: when access is denied, offer a way to Settings. Today it is text only (Seen). `.writeOnly` is reported as "denied", so the copy says access is off when it is partly on. | Add a `settings` bridge message that opens `UIApplication.openSettingsURLString`. Give the banner and Settings row an "Open Settings" button. Report `writeOnly` as `limited` and tell the user Full Access is needed. |
| P1-3 | Every foreground calls `requestAccess()` | `CalendarBridge.swift:91-94` | This re-sends calendars, re-fetches events and reloads every widget timeline on each activation. Once P1-1 lands it would also re-prompt. (Traced) | `appBecameActive` sends status only. It refreshes data only when status actually changed or access is granted (one `pushEvents`). Widgets reload only when status changes. |
| P1-4 | Sheet has no visible Cancel or close | `index.html:1053-1059` | HIG (Sheets): give a clear way to dismiss. Dragging the grabber isn't discoverable and VoiceOver can't do it. (Seen) | Add a 44pt ✕ button with `aria-label="Close"` in the sheet header. |
| P1-5 | Timeline replays its entrance animation every 30 s | `index.html:1379` with `.tl-row` animation at `:122` | `render()` rebuilds the DOM, so every row runs `rise` again. That is a visible flicker twice a minute. It also happens on every tick and theme change. (Seen) | Run entrance animations only when `render(anim)` asks for them: add a `.still` class on `#view` for plain re-renders. |
| P1-6 | Focus timer stops while the app is in the background | `index.html:1171-1178` | `setInterval` is suspended in the background. After 10 minutes away, the timer still shows the old remaining time. (Traced) | Store `F.endAt`, derive `left` from `Date.now()`, and re-tick on `visibilitychange`. |
| P1-7 | In-app Light/Dark doesn't reach native UI | `index.html:673-677`; `ContentView.swift` | With in-app Dark on a light system, the status bar stays dark-on-dark and the time and date pickers and keyboard stay light. (Traced) | The page sends `scheme {mode}`. The model publishes it and `ContentView` applies `.preferredColorScheme`. |
| P1-8 | Version numbers are hardcoded in the generated plists | `project.yml:26-58`; generated `App/Info.plist:20,33` | XcodeGen writes a literal `1.0`/`1`, so changing `MARKETING_VERSION` does nothing and the app and widget can drift apart. Both plists are generated and gitignored, so `project.yml` is the only source. That also settles the `CFBundleURLTypes` question: there is one source. | Add `CFBundleShortVersionString: $(MARKETING_VERSION)` and `CFBundleVersion: $(CURRENT_PROJECT_VERSION)` to both targets' `info.properties`. |
| P1-9 | Tap targets under 44pt | `index.html:73` (today chevron 22×22), `:140` (check 30×30), `:373` (colour 34×34), `:81` (week arrows 30×34) | HIG minimum hit target is 44×44. (Measured in the rendered DOM) | Grow the hit area with a transparent `::after` inset to 44pt. The visuals stay the same. |

### P2: polish (★ = being implemented in this pass)

| ID | Finding | Where | Why it matters | Fix |
|---|---|---|---|---|
| P2-1 ★ | Dynamic Type is ignored | All px sizes in `index.html`; `ContentView.swift` | At AX3 nothing changes (Seen). Low-vision users get no help. | Set `WKWebView.pageZoom` from `preferredContentSizeCategory`, from 0.9 up to a cap of 1.2 so the layout still fits on a 375pt phone, and update it on `didChangeNotification`. This scales the whole layout without a CSS rewrite. |
| P2-2 ★ | VoiceOver gaps | `index.html:716` (ring reads "0/8"), `:707` (strip: no selected or today state), `:746` (now line reads only "14:42"), `:787` (week blocks have no time), `:790` (week slots not reachable), `:1070` (colours read as "Colour #F08A7E"), `:465` (toast isn't announced), `:463` (sheet has no label), `:725` (tabs have no current state) | Every control should say what it is and its state. | Add `aria-label`, `aria-current` and `aria-pressed`. Make the toast `role=status`. Label the sheet with `aria-labelledby`. Give colours names. Read the now line as "Now, 14:42". |
| P2-3 ★ | Theme colours fail contrast in light mode | `index.html:640-662` | Light-mode accent text on the background: champagne 2.9, sunset 2.32, rose 3.24, ocean 3.47, emerald 4.22, lavender 4.3. White on the accent fill: sunset 2.63, champagne 3.49, rose 3.8, ocean 4.05. Sunset dark on-accent is 2.23. `--ink3` on the light background is 2.54. (Measured) | Add `--accent-ink`, a darker text-safe variant per theme, for accent-coloured text. Use dark on-accent text where white fails. Darken light `--ink3` to `#6e6e75`. Dark mode already passes for 7 of 8 themes. |
| P2-4 ★ | Task colours: white glyphs and text below 3:1 | `--c` pills, bars and week blocks | White on `#EFA92E` 2.02, `#7BB662` 2.41, `#F08A7E` 2.43, `#33A6A0` 2.96, `#8E7FE6` 3.32. Small text on week blocks is unreadable. (Measured) | Compute `--on` from luminance. Use dark ink when white is below 3:1. Calendar colours from EventKit get the same treatment. |
| P2-5 ★ | Widget gold fails contrast | `Widget/GlassdayWidgets.swift:8, 207, 321` | Gold on white is 3.52 for the 12pt weekday label. White on gold is 3.52 for today's number. (Measured) | Use an adaptive gold: `#8E6F42` in light mode (4.66 for white on it, 4.6 as text) and `#D2B07A` in dark mode (8.7 on the dark background). |
| P2-6 ★ | Widget VoiceOver | `GlassdayWidgets.swift:201-236, 378-401` | A day cell reads "10, Lecture, Lab" with no month or count, and the "+ 2" isn't spoken. | Combine children and add an `accessibilityLabel` per day cell and per row: "Tuesday 10 November, 3 events: …" and "Lecture, 09:00 to 11:00". |
| P2-7 ★ | `NeedAccessView` asks the user to open the app instead of opening it | `GlassdayWidgets.swift:51-65` | Both widgets open the app on tap, but the Month widget has no `widgetURL`, and the copy is an instruction. | Change the copy to "Tap to connect Apple Calendar". Add `.widgetURL(glassday://day/<today>)` to the Month widget so it lands on the Timeline, where P1-1's card is. |
| P2-8 ★ | Today widget at midnight | `GlassdayWidgets.swift:269-277` | Entries stop at the last event. Until WidgetKit runs the `.after(midnight)` reload, which can be late, the widget shows yesterday. | Also fetch tomorrow and add a midnight entry built from tomorrow's items. |
| P2-9 ★ | Each widget refresh creates a new `EKEventStore` | `GlassdayWidgets.swift:25` | `EKEventStore` is costly to create. Rebuilding the grid is cheap (at most 42 cells, once an hour), so a per-month cache isn't worth it. The store is the cost. | Use one shared `static let store`. |
| P2-10 ★ | Google Fonts stylesheet blocks rendering | `index.html:16` | It wasn't the cause in the simulator: the CSS loads in 0.18 s. On a slow or captive network, though, the first paint waits for it. The fallback stack (`ui-rounded`, `system-ui`) is fine. | Load it non-blocking (`media="print" onload`). Bundling the fonts locally stays P3-2. |
| P2-11 ★ | Native mode also writes to localStorage | `index.html:561` | There are two stores, and after a failed `persist` the stale localStorage copy is what loads (`:556`). | Write localStorage only when not native. Keep the one-time read for migration. |
| P2-12 ★ | Edge cases in `json()` and `persist` | `CalendarBridge.swift:317-327, 56` | The string path doesn't escape U+2029 (iOS 17's JSC accepts it, but be consistent). `persist` has no size limit. | Escape both characters on every path. Refuse payloads over 1 MB and warn the page through `GDN.notice`. |
| P2-13 ★ | Deep links accept impossible dates and extra path parts | `ContentView.swift:76-79`; `CalendarBridge.swift:281`; `index.html:1029` | `glassday://day/2026-13-45` passes the regex, and the page then holds an invalid `sel`. `glassday://day/a/b/2026-11-03` is also accepted. Only the `day` host reaches the bridge, so other hosts can't get through. | Require exactly one path component, and check the date round-trips through `Calendar` (and through JS `Date`). |
| P2-14 ★ | Now line strikes through the live task's text | `index.html:145-148, 759` | Seen in the preview: the red line runs through "78m remaining". | Inside a row, stop the line at the edge of the pill. |
| P2-15 ★ | iOS time popover detaches from its field | `index.html:1374-1376` | Seen: the `focusin` auto-scroll runs 320 ms after focus, after iOS has anchored the time picker popover, so the popover floats over the wrong field. | Auto-scroll only for text inputs and textareas, not for date, time or select. |
| P2-16 ★ | `Calendar.current` is captured at init | `CalendarBridge.swift:22` | After a time-zone change while the app is alive, day keys come out wrong. | Make it a computed property. |
| P2-17 | Widget fonts are fixed sizes | `GlassdayWidgets.swift` | Widgets don't grow with Dynamic Type. The Month grid can't take larger text, but the Today widget could. | Not done this pass because it risks the layout. Plan: give the Today widget text styles with `.dynamicTypeSize(...DynamicTypeSize.xxLarge)`. |
| P2-18 | Month widget starts on Sunday; the app's month starts on Monday | `GlassdayWidgets.swift:104` vs `index.html:827` | The two grids don't line up. The README says Sunday-first is deliberate. | Your call. Matching the app means `firstWeekday = 2` and moving `letters`. |
| P2-19 | 4–5 s blank on cold launch in the simulator | `ContentView.swift` | Seen. Fonts are ruled out. It is most likely the WebContent process starting up. Needs a check on a real device. | If it shows up on a device, create the web view early (in `App.init`) and keep the launch colour behind it, which already matches. |

### P3: roadmap, written as a plan, not built

| ID | Item | Plan |
|---|---|---|
| P3-1 | **Widget follows the theme (App Group)** | Needs a provisioning change. Add `com.apple.security.application-groups: [group.com.geraldangya.glassday]` to **both** targets in `project.yml` (`entitlements:` with `properties:`). In `CalendarBridge` `persist`, also write `{palette, theme}` to `UserDefaults(suiteName:)`. Read it in `WidgetBackground`/`Palette` and call `WidgetCenter.reloadAllTimelines()` when the palette changes. Sideloadly with a free account supports App Groups but rewrites the identifier, so test that path first. |
| P3-2 | Bundle the fonts | Put the OFL `.woff2` files for Bricolage Grotesque and Manrope in `App/Resources/fonts/` and use `@font-face` with relative URLs. No bundler needed. |
| P3-3 | ~~Notifications before tasks~~ | **Done** (requested during the review): per-task alerts with location, see `App/Alerts.swift` and the README *Alerts* section. |
| P3-4 | Reminders sync for the Inbox | `EKEntityType.reminder` behind a second primer. |
| P3-5 | Interactive widget checkboxes | An App Intent `ToggleDone(series, date)`. Needs the App Group from P3-1 for tick state. |
| P3-6 | Landscape and iPad | Portrait-only on iPhone (`TARGETED_DEVICE_FAMILY: "1"`) is the right call. The layout is a 480px column, and the week grid in landscape would leave ~6 hours visible. Revisit only with a real two-column iPad layout. |
| P3-7 | Dynamic Type in widgets | See P2-17. |
| P3-8 | Reduce Transparency | When it is on, use solid `--glass` (WebKit has no media query for this, so the native side would pass `UIAccessibility.isReduceTransparencyEnabled`). |

## Answers to the specific checks (A–G)

**A. HIG / platform**
- **Usage string.** "Glassday shows and edits your Apple Calendar events so your plans stay in sync." It is clear and says the app also writes, so keep it. `NSCalendarsUsageDescription` is unused on iOS 17+ but does no harm.
- **Denied and write-only.** See P1-2.
- **Widget when unauthorized.** It shows `NeedAccessView`. Both widgets open the app when tapped, but the copy reads as an instruction (P2-7).
- **contentMarginsDisabled.** It is used deliberately with 12–14pt manual padding, which is fine for an edge-to-edge grid. On iPad and in StandBy, reading `@Environment(\.widgetContentMargins)` would be better.
- **supportedFamilies and containerBackground.** Both are correct.
- **Month cell tap targets.** Your brief assumed 21×17. That is only the number badge. The `Link` wraps the whole cell, which is `maxWidth/maxHeight: .infinity`. A large widget is about 338×354pt, so each cell is about 46×45pt. `Link` works per element in large widgets, so per-day links do work. **Keep them.** The Month widget has no `widgetURL`, so taps outside a cell just open the app (P2-7 adds today's date).
- **Deep links.** `open(url)` returns early unless `scheme == "glassday" && host == "day"`, so other hosts can't get through. The path problems are in P2-13.
- **Safe area.** The HTML uses `viewport-fit=cover` with `env(safe-area-inset-*)` for the header, dock, sheet footer and the focus close button (`index.html:8, 334, 356, 400`). That passes. Status bar contrast is P1-7.
- **Portrait lock and iPhone only.** Both are justified (P3-6).

**B. Bridge robustness**
- **json().** Arrays and objects go through `JSONSerialization`, then U+2028 and U+2029 are replaced. Strings use the array trick, but only U+2028 is replaced (P2-12). Every `title`, `notes`, `calId` and `cal` reaches `run()` through `json(out)`. Nothing is interpolated raw.
- **Changing recurrence on a series** uses `.futureEvents`. Going from weekly to one-off with `.futureEvents` turns this and later occurrences into a single event and ends the original series before it. That is the expected "this and future" behaviour, and the sheet copy already says so (`index.html:1067`).
- **span "all".** `calendarItem(withIdentifier:)` returns the first occurrence of a recurring event, so `.futureEvents` there removes all of them for daily, weekly, monthly and yearly rules alike. It is correct when it resolves. The silent fallback is P0-3.
- **persist.** See P2-12.
- **awake.** See P0-2.
- **EKEventStoreChanged before pageReady** is safe. `run()` is guarded by `window.GDN &&`, and `pushEvents()` returns when `range` is nil.
- **appBecameActive.** See P1-3.

**C. Keyboard (traced)**
- `keyboardWillChangeFrame` passes the overlap to `GDkb`. That sets `--kb`, which moves `.sheet` up (`bottom:var(--kb)`, `max-height:calc(92% - var(--kb))`). The header and footer are `flex:none`, so Save stays pinned above the keyboard.
- The keyboard end frame already includes WKWebView's form accessory bar (◀ ▶ Done), so it doesn't push the layout. No `inputAccessoryView` hack is needed.
- `scrollView.isScrollEnabled = false` and the three `setContentOffset(.zero)` calls stop iOS from shifting the page.
- The one real problem is the popover anchoring (P2-15).

**D. Accessibility**
- **Reduce Motion is already handled.** `index.html:440` cuts every animation and transition to 0.01 ms, and the JS `reduce` flag gates the confetti and smooth scrolls. That includes the ambient blobs, which end on their final frame.
- VoiceOver, Dynamic Type and contrast are covered in P2-1 to P2-6.

**E. Signing**
- **Consistent.** `CODE_SIGN_STYLE: Automatic` with no team is right for Xcode runs. `build-ipa.sh` turns signing off and Sideloadly re-signs both the app and the `.appex`.
- **The plist question.** XcodeGen regenerates both plists from `project.yml` on every `xcodegen generate`, and both are gitignored. So `project.yml` is the single source, and P1-8 makes the version follow `MARKETING_VERSION`.
- **Widget plist.** It only needs `NSExtensionPointIdentifier: com.apple.widgetkit-extension`. No principal class is needed for WidgetKit, so it is correct as is.

**F. SwiftUI and widget quality (figma-swiftui lens)**
- **What's good.** The widget views follow system patterns: `containerBackground`, `widgetAccentable` and `Link`. They use dynamic `Color(cgColor:)`. `.primary` and `.secondary` adapt to the colour scheme.
- **Where they drift.** Hand-mixed colours (`Palette.gold` and `WidgetBackground` RGB literals) instead of an asset-catalog colour with light and dark variants. Fixed font sizes (P2-17). `"+ \(n)"` is built by string concatenation and isn't localisable.
- **Should any HTML surface be SwiftUI?** Not now. The timeline, week and month views are the product. Their custom layout and animation would cost far more in SwiftUI and gain little.
- **The one surface where native would win is the task editor sheet.** It would get native sheet detents, a free Cancel button, Dynamic Type and a real `DatePicker`. Even so, the fixes above close most of that gap for a small fraction of the effort.
- **Recommendation:** keep everything in HTML. If you ever go native, start with the editor as a `.sheet` driven by a bridge message.

**G. HTML / CSS / JS**
- **Shared state.** See P2-11.
- **Listener leaks: none.** Every document-level listener is added once. Wheel listeners are attached to elements that get replaced with the sheet. `darkMQ` and `visualViewport` listeners are added once.
- **Fonts.** See P2-10 and P3-2.
- **Confetti.** It uses the Web Animations API on `transform` and `opacity`, so it runs on the compositor and doesn't block scrolling. The cost is the full `render()` that follows 260 ms later and replays the entrance animations (P1-5).

## Fix status

Everything in P0, P1 and the ★ P2 items was fixed on branch `review/hig-fixes`, one commit per finding (`fix(P0-1): …` and so on). P2-17, P2-18, P2-19 and all P3 items are written up above but not built.

## Verification checklist

| # | Check | Result | How |
|---|---|---|---|
| 1 | Cold launch, access not decided → clear prompt → Allow → timeline fills | **Pass** | Seen in Simulator: Connect card → Connect → system prompt → Allow Full Access → Japan Trip appears |
| 2 | Access denied → clear message and a way to Settings | **Pass** | Seen: banner with *Open Settings* opens Glassday's Settings page; granting there and returning syncs |
| 3 | `Gym tomorrow 6pm for 1h` → date, time, duration, repeat, icon | **Pass** | Run in the browser: 11 Nov, 18:00–19:00, 1h, Once, dumbbell |
| 4 | Edit a repeating task's time → this and future change, past don't | **Pass for Calendar events / by design for local tasks** | Traced: `upsert` saves an existing recurring occurrence with `.futureEvents` (`CalendarBridge.swift` upsert). Local repeating tasks (used when Calendar access is off) change every repeat, and the editor says so. Not run against the Calendar app. |
| 5 | Delete a repeating task → 3-way prompt; each path correct | **Pass (traced)** | The `del` handler shows This one / This and future / All. The bridge maps them to `.thisEvent` on the occurrence, `.futureEvents` on the occurrence, and `.futureEvents` on the first occurrence. Failures are now reported (P0-3). Not checked in the Calendar app. |
| 6 | `glassday://day/2026-11-03` → opens that day | **Pass** | Seen via `simctl openurl` (iOS asks "Open in Glassday?" first). `2026-13-45` is ignored. |
| 7 | Focus running → background → idle timer re-enabled | **Pass (traced)** | `scenePhase == .background` clears `isIdleTimerDisabled`. Back in the foreground the page re-asserts it only if the timer runs, and the countdown is correct (seen in the browser: a 2 min jump shows 12:58). |
| 8 | Month widget renders this month; tap opens a day; Today shows next event | **Not seen (traced, builds)** | The widget wasn't added to the Simulator home screen. Day cells link to their day; title and empty areas now open today. Month shows per-day event rows, not spanning bars. |
| 9 | Widget with access revoked → NeedAccessView, no crash | **Pass (traced)** | `CalData.items` returns `[]` when not authorized, `entry.authorized` is false, and the view shows *Tap to connect Apple Calendar*. |
| 10 | Keyboard: title, then end time → panel above keyboard, Save reachable | **Pass (traced, partly seen)** | `GDkb` → `--kb` lifts the sheet. Its footer (Save) is pinned. Seen: the keyboard plus accessory bar doesn't shift the layout. On iOS 27 the time fields open a popover, not the keyboard; P2-15 keeps it anchored. |
| 11 | Dark mode × 8 themes → readable text | **Pass (measured)** | Dark on-accent text is ≥ 7:1 on all 8 themes (Sunset fixed). Task glyphs and text are ≥ 3.5:1 (P2-4). |
| 12 | VoiceOver through a timeline day | **Pass (names checked; VoiceOver not run)** | Accessible names read in the DOM: pills, gap chips ("1h free from 08:00. Add a task here"), now line ("Now, 15:03"), checks, ring, strip, tabs. |
