# Lumen Bridge — v0.2 Roadmap

Captured 2026-04-27 during the v0.1 push. Items below were intentionally
**deferred from v0.1** — they're polish/feature work, none of them block
the first App Store submission.

## Multi-hub presence (cross-device "who's running")

**Why** Kevin pointed out that when Bridge runs on the Mac AND on the
Apple TV (and Lumen for Frigate runs on iPhone/iPad/Watch/Vision), the
user has no UI feedback about *which other hubs are active right now*.
Today each instance only shows its own state.

**What** Each instance writes a `BridgePresence` record to the user's
private CloudKit DB:
- `id`: device persistent UUID
- `platform`: macOS / tvOS / iOS / watchOS / visionOS
- `name`: localised device name (e.g. "Kevin's MacBook Pro")
- `lastSeen`: refreshed every 60s while the app is foreground
- `version`: `MARKETING_VERSION + CURRENT_PROJECT_VERSION`

Other instances `CKQuerySubscription` on `BridgePresence` records,
filter to those with `lastSeen > now()-180s`, and surface them as a
small "Other devices" section:
- Mac MainWindow: a row in the sidebar's footer
- tvOS TVHomeView: a third status card
- Lumen iOS: a Settings cell "Bridge actif sur : <device name>"

**Effort** ~3-4h (schema, refresh task, debounce, UI on three platforms,
localisation).

## QR HomeKit pairing on Apple TV

**Why** Currently the HAP pairing QR is rendered only on the macOS
Bridge (`MainWindow.swift:380-400`). To pair from the couch, the user
has to walk to the Mac. If the QR were also displayed on the Apple TV
(at the focus-default size), pairing from the couch becomes a one-step
"sortir l'iPhone, scan, done".

**What** Sync the HAP setup-code (8-digit) over `NSUbiquitousKeyValueStore`
(it's already in iCloud Keychain via `kSecAttrSynchronizable`, but KVS
is enough — the code itself is not particularly sensitive once HAP is
paired). On tvOS, regenerate the same QR via `CIFilter.qrCodeGenerator()`
(reuse the existing helper) and show it as a focusable card on
`TVHomeView`.

**Effort** ~1h.

## Layered tvOS App Icon — proper 3-layer art

**Why** The current Brand Assets stack (`App Icon.imagestack`,
`App Icon - App Store.imagestack`) shipped with v0.1 has the SAME image
in Front, Middle, and Back layers. tvOS expects each layer to render
*different* art so the parallax tilt produces depth. With identical
layers the parallax effect either does nothing or visibly distorts.
v0.1 ships with Back+Middle blanked (transparent) so only Front renders
— icon stays static, but no longer looks broken.

**What** Re-author the icon with three distinct layers:
- **Back**: ellipse + neon glow background only (no bird)
- **Middle**: bird shadow / depth element
- **Front**: origami bird

Use Apple's Icon Composer or Sketch/Figma → export each layer as a PNG
at the four required sizes (400×240, 800×480, 1280×768, 2560×1536 — the
last one is the @2x for App Store icon, which v0.1 also doesn't ship).
Drop into the existing `imagestack` directories.

**Effort** ~1h (designer time to split, 30min to drop in + verify).

## Other reminders

- v0.1 ships without any `@2x` for App Icon - App Store. Apple TV uses
  the @1x at 1280×768. Adding @2x at 2560×1536 is a polish improvement
  for high-end displays.
- Top Shelf images are flattened-alpha PNGs (per Apple requirement) but
  the artwork could be improved — currently a generic frigate landscape.
- The two strings with inline ternary plurals
  (`"\(count) Frigate camera\(count == 1 ? "" : "s") exposed."` in
  `SettingsView.swift:80` and the analogous accessory line in
  `MainWindow.swift:395`) need a Stringsdict pluralization rule. Park
  for a dedicated Loc-pluralization pass.
- `MenuBarContent.metric()` passes its label as a `String` instead of
  `LocalizedStringKey`, so "received" / "forwarded" stay English in
  fr-FR builds. Fix is a small refactor of the function signature.

