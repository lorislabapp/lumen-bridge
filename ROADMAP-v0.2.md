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

## Linux Bridge — HomeKit (HAP) parity

**Why** Today the macOS Bridge exposes Frigate cameras as HomeKit motion
sensors via `HAPBridgeManager` (Bouke/HAP, Phase 5). Users running the
Linux daemon (`lumen-bridge-linux`, Docker on a NAS / Pi) get the
CloudKit notifications path but **no Home-app integration** — they'd
have to also run a Mac just for HomeKit, which defeats the point of the
Linux Bridge.

Cross-deferred from `lumen-bridge-linux` because it's the same problem
on a different host: a Frigate user shouldn't need a Mac in the loop to
get cameras into the Home app.

**What** Embed `brutella/hap` (the Go equivalent of Bouke/HAP — actively
maintained, used by Homebridge-on-Go alternatives) inside
`lumen-bridge-linux`:

1. New `internal/hap/` package mirroring the Swift `HAPBridgeManager`
   shape: bridge accessory + per-camera motion sensor child accessories.
2. Setup code (8-digit, `XXX-XX-XXX` format) + setup ID (4-char) are
   generated on first run and persisted in
   `~/.config/lumen-bridge/hap-setup.json` (mode 0600). Stable across
   restarts so the QR stays valid until the user explicitly resets.
3. Pairings persist in `~/.config/lumen-bridge/hap-pairings.db`
   (BoltDB) — reload on daemon restart so users don't re-pair after
   `docker restart`.
4. mDNS announces the bridge on the LAN — same Bonjour service type
   the Apple Home app discovers (`_hap._tcp`).
5. Motion-sensor state is driven by the same MQTT decoder that already
   feeds CloudKit: each `frigate/events` `new` event flips the
   corresponding camera's `MotionDetected` to true; `end` flips back.
6. Config schema gets a `homekit:` block so users can disable it
   entirely (default: enabled if at least one camera is configured):
   ```yaml
   homekit:
     enabled: true              # default true
     bridge_name: "Lumen Bridge"  # appears in Home app
     port: 0                    # 0 = auto-assign
   ```

**Pairing UX** Three surface points so the user finds the code without
SSH'ing into the box:

- `lumen-bridge pair` subcommand: prints the 8-digit code + an ASCII QR
  code rendered to the terminal (`github.com/skip2/go-qrcode` → ASCII
  fallback), plus the X-HM URI for manual entry.
- Health endpoint `GET /hap/setup` (existing health server on
  `:8765`): returns JSON `{ "code": "123-45-678", "uri": "X-HM://...",
  "status": "unpaired" | "paired" }`. Useful for `curl` from the
  homelab dashboard.
- Docker logs: on first boot the daemon logs the code at INFO level
  with a banner so `docker logs lumen-bridge` after `docker run` shows
  it without extra plumbing. Code is logged ONCE then suppressed (we
  don't want it repeating in journald forever).

**Why not depend on the macOS HAP** Each HAP bridge has its own
identity (mDNS instance, accessory UUID, pairing DB). Two bridges
talking to the same Home app would either collide (same accessory
UUIDs) or duplicate (same cameras shown twice). So Linux HAP is a
separate bridge identity, and users either run the macOS Bridge OR the
Linux Bridge for HomeKit — not both. The Lumen iOS Settings → Bridge
section will surface this constraint as a "Active HomeKit bridge:
<which device>" cell, driven by the v0.2 multi-hub presence record.

**Effort** ~12-16h (HAP package wiring, persistence, mDNS, motion
sensor lifecycle, pairing UX on three surfaces, integration tests
against the iOS Home app).

## Linux Bridge — milestone 0.6 catch-up

Re-baseline `lumen-bridge-linux/README.md` Roadmap section after the
HAP work above lands. Current table stops at 1.0 with no HAP entry —
add `0.6.0 HomeKit (HAP) bridge parity with macOS` and shift the
"stable / Docker Hub release" milestone to 1.1.

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

