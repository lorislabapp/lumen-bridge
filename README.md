# Lumen Bridge

**Native macOS menu-bar app that bridges [Frigate NVR](https://github.com/blakeblackshear/frigate) to Apple's push infrastructure via CloudKit. Zero third-party cloud.**

Part of the Apple-native Bridge pivot for [Lumen for Frigate](https://apps.apple.com/app/id6760238729). Where the current Docker-based [`lumen-push-relay`](https://github.com/lorislabapp/lumen-push-relay) sends events through a Cloudflare Worker, Lumen Bridge writes them to the user's own iCloud private database. Apple then fans out push notifications to every Lumen install on the user's devices (iPhone, iPad, Mac, Apple Watch, Vision Pro) — natively, via APNs, with no third-party relay in the middle.

## Status: **early skeleton** (2026-04-24)

| | State |
|---|---|
| macOS menu-bar SwiftUI shell | ✅ Builds (Swift 6 strict concurrency, macOS 14+) |
| Bonjour `_frigate._tcp` discovery | ✅ Wired, emits to menu-bar UI |
| MQTT client (Frigate subscribe) | ⏳ Stub — wire implementation lands next pass |
| CloudKit writer | ⏳ Account-status check done; record schema + `CKQuerySubscription` wiring next |
| Settings window (MQTT override, rules) | ⏳ Not started |
| HomeKit Accessory Protocol exposure | ⏳ Phase 3 follow-up |
| Mac App Store submission | ⏳ Blocked on HAP stability + TestFlight soak |

Run locally:

```bash
cd ~/GitHub/lumen-bridge
xcodebuild build \
  -project LumenBridge.xcodeproj \
  -scheme LumenBridge \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath /tmp/lumen-bridge-dd \
  CODE_SIGNING_ALLOWED=NO
open /tmp/lumen-bridge-dd/Build/Products/Debug/Lumen\ Bridge.app
```

A bolt icon appears in the menu-bar. Click it to see the status popover (Frigate host + event counters + CloudKit status).

## Architecture

```
Frigate (your network)
    │
    │  MQTT (frigate/events, LAN only)
    ▼
Lumen Bridge (this app, running on your Mac)
    │
    │  CKRecord (FrigateEvent) → iCloud private database
    ▼
Apple CloudKit + APNs
    │
    │  CKQuerySubscription delivers silent push to every
    │  Lumen install under your Apple ID
    ▼
iPhone + iPad + Mac + Apple Watch (cellular) + Vision Pro
```

No Cloudflare. No Docker. No third-party cloud. Everything runs on Apple hardware and through Apple's infrastructure.

## Project structure

```
LumenBridge/
├── App/                  # @main entry, scene wiring
├── MenuBar/              # MenuBarExtra SwiftUI content
├── State/                # @Observable BridgeState + value types
├── MQTT/                 # Frigate MQTT client (stub, MQTTNIO next)
├── CloudKit/             # CKContainer + record persistence
├── Discovery/            # Bonjour NetServiceBrowser for _frigate._tcp
└── Resources/            # Info.plist + LumenBridge.entitlements
```

The project is hand-generated via Ruby `xcodeproj` gem (see `/tmp/generate_bridge_project.rb` in the parent repo for the generator). Re-running regenerates `LumenBridge.xcodeproj` from whatever files are on disk under `LumenBridge/`.

## Roadmap

See [`roadmap-apple-native-bridge.md`](https://github.com/lorislabapp/Lumen-for-Frigate/blob/main/audit-output/roadmap-apple-native-bridge.md) in the main Lumen repo for phase-by-phase breakdown. This repo covers **Phase 3**.

## License

MIT — see [LICENSE](LICENSE).
