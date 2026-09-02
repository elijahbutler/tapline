# Tapline

Tapline is a proposed local-first capture system for Apple Watch, iPhone, and open wearable devices. A deliberate button press or short recording becomes a durable event that the user can route to software they control.

The first release will support an Apple Watch capture app, an iPhone queue and gateway, and configurable HTTP destinations. Home Assistant, n8n, Ollama, self-hosted transcription, and MCP integrations can sit behind those destinations without making any one service mandatory.

This repository currently contains the product and system design. It does not contain an implementation yet.

## What Tapline is for

Tapline should let a person:

- start a short recording or send a button event from Apple Watch;
- keep the event on the watch until it can reach the paired iPhone;
- keep it on the iPhone until every selected destination accepts it;
- inspect, export, retry, or delete it;
- send it over the local network without creating a Tapline account; and
- add a compatible BLE wearable without changing the event or delivery model.

Tapline is not an always-listening recorder. Apple Watch does not give third-party apps unrestricted microphone access from a suspended state, nor direct access to the side button or a general-purpose Action Button event. The practical Apple Watch design is deliberate, visible, user-initiated capture. See [Architecture](docs/ARCHITECTURE.md#apple-watch-boundaries).

## Product principles

### Local data is the source of truth

Tapline writes an event to durable storage before it attempts a transfer or network request. A successful upload never becomes the only copy unless the user's retention rule says to delete the local copy.

### No required Tapline service

Capture, storage, retry, export, and delivery must work without a Tapline account, subscription, analytics service, remote feature flag, or hosted control plane. Internet access is optional. A destination may be a private IP address on the same Wi-Fi network.

### The user controls every destination

The app sends nothing until the user creates and enables a destination. Each destination has its own filters, credentials, retry policy, and delivery history. Tapline does not silently fall back to a cloud transcription or AI provider.

### Open formats before private protocols

Event metadata uses versioned JSON. Audio uses a documented media type and ordinary multipart HTTP uploads. Adapters expose narrow Swift protocols. Undocumented BLE bytes stay isolated in an experimental adapter and are never presented as a stable public protocol.

### Privacy is a behavior, not a settings page

- No third-party analytics or advertising SDKs.
- No telemetry by default.
- Recording always has visible in-app state and follows Apple's recording-indicator rules.
- Logs omit audio, transcripts, secrets, and full request bodies.
- Endpoint secrets live in Keychain, not the event database or exported settings.
- Export and deletion work offline.
- Retention is explicit, with "keep until I delete" as a supported choice.

If maintainers later add diagnostics, the first design to consider is a user-configured destination that uses the same visible queue and payload preview as every other event. Adding a hidden maintainer endpoint would violate this policy.

### Failure must be legible

"Sent" means the destination acknowledged the request. A WatchConnectivity handoff is not a delivery receipt. Tapline shows separate states for capture, phone ingestion, queueing, attempt, acknowledgement, and permanent failure.

### Interoperability is part of the product

The normalized event schema, HTTP contract, migration rules, and adapter interfaces belong in the repository. Users should be able to implement a receiver without reverse-engineering the app.

## Initial scope

The first useful release is intentionally small:

1. Configure one or more HTTP endpoints on iPhone.
2. Send an in-app button event or record a short audio clip on Apple Watch.
3. Persist the capture on the watch.
4. Transfer it to iPhone with WatchConnectivity.
5. Persist it again on iPhone.
6. Deliver JSON or multipart audio with retries.
7. Show queued, delivered, and failed events.

WebSockets, MCP, direct Pebble Index 01 BLE ingestion, on-device transcription, OAuth, and mutual TLS follow after the queue and HTTP contract are proven on physical devices.

## Proposed repository layout

```text
Tapline.xcworkspace
Apps/
  TaplineiOS/
  TaplineWatch/
Extensions/
  TaplineWatchWidget/
Packages/
  CaptureCore/
  CaptureStore/
  AudioCapture/
  WatchBridge/
  DeliveryKit/
  EndpointSecurity/
  TranscriptionKit/
  WearableTransport/
docs/
  ARCHITECTURE.md
  ROADMAP.md
```

The packages should remain free of app lifecycle code. `CaptureCore`, `CaptureStore`, and `DeliveryKit` should be usable by a command-line receiver or another Apple-platform app.

## Status

Tapline is in phase 0, specification and device spikes. The implementation order and acceptance tests are in the [roadmap](docs/ROADMAP.md). The [architecture](docs/ARCHITECTURE.md) defines the data model, trust boundaries, delivery behavior, and known Apple Watch and Pebble limits.

## Open-source policy

Source visibility alone is not an open-source license. Before accepting contributions or publishing a binary, the project should add:

- an OSI-approved license;
- `CONTRIBUTING.md`;
- `SECURITY.md` with a private reporting route;
- a dependency and attribution policy;
- a documented release process with reproducible version tags; and
- a protocol versioning and deprecation policy.

The recommended default is [Mozilla Public License 2.0](https://www.mozilla.org/en-US/MPL/2.0/). Its file-level copyleft requires changes to covered source files to remain available while allowing linking with separately licensed receiver and adapter code. Tapline still needs a dependency-by-dependency App Store distribution review. [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) is the simpler permissive alternative. GPL-family licensing needs a deliberate App Store review and should not be adopted casually.

The project should use a [Developer Certificate of Origin](https://developercertificate.org/) sign-off rather than a contributor agreement that gives one party an undisclosed private relicensing advantage. Design changes to the public event schema and adapter interfaces should happen through public architecture decision records.

No license has been selected merely by writing this recommendation. Until a `LICENSE` file is committed, normal copyright restrictions apply.

## Security and privacy reports

Do not open a public issue containing recordings, transcripts, credentials, device identifiers, packet captures, or private endpoint addresses. A private disclosure address will be published with `SECURITY.md` before the first test build leaves the maintainers' devices.

## Primary references

- [Apple Watch Action Button and App Intents](https://developer.apple.com/documentation/appintents/actionbuttonarticle)
- [Apple Watch frontmost app behavior](https://developer.apple.com/documentation/watchkit/taking-advantage-of-frontmost-app-state)
- [Extended runtime sessions](https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions)
- [WatchConnectivity](https://developer.apple.com/documentation/watchconnectivity)
- [Bluetooth development guidelines](https://developer.apple.com/bluetooth/)
- [Local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [App Transport Security local-network setting](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Pebble Index 01 advanced features](https://help.repebble.com/en/articles/15724406-index-advanced-features-mcp-webhook)
- [Pebble mobile app source snapshot](https://github.com/coredevices/mobileapp/tree/73080580134796c847344dab78930d4521fcae90)
- [Model Context Protocol Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
