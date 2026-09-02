# Tapline architecture

## Scope

Tapline converts deliberate wearable interactions into durable, user-routed events. The core system has two Apple apps and a set of reusable Swift packages:

```text
Apple Watch                          iPhone
┌────────────────────┐              ┌──────────────────────────┐
│ Capture UI         │              │ Ingestion coordinator    │
│ Audio recorder     │              │ Event and delivery store │
│ Watch outbox       │── WC file ──▶│ Router                   │
│ Transfer reconciler│◀── ACK ──────│ Delivery workers         │
└────────────────────┘              │ Export and deletion      │
                                    └───────┬──────────┬───────┘
                                            │          │
                                      HTTP POST   later adapters
                                            │          │
                                    user-controlled   BLE, MCP,
                                    LAN or internet   WebSocket
                                    destinations
```

`WC` means WatchConnectivity. The acknowledgement in the diagram is a Tapline message sent after the iPhone commits the event and verifies its media. It is not the system's transfer completion callback.

## Architectural rules

These rules are requirements, not aspirations.

1. Persist before transfer. Capture writes to the watch outbox before WatchConnectivity sees it.
2. Persist before delivery. The iPhone commits the event, media record, and destination jobs in one database transaction before opening a network connection.
3. Keep content local by default. A destination must be explicit and enabled.
4. Never require a Tapline-operated server.
5. Make retry safe. Event IDs and media digests remain stable across attempts.
6. Keep facts and interpretations separate. BLE observations include provenance and confidence.
7. Make deletion complete and testable. Deleting an event includes its media and eligible derived events.
8. Make adapters replaceable. Apple Watch, BLE, transcription, and delivery code depend on protocols in shared packages.
9. Fail closed for TLS and authentication. There is no "trust every certificate" option.
10. Keep logs content-free. Diagnostics may include event IDs, byte counts, state changes, and redacted error categories.

## Trust boundaries

Tapline has five distinct trust zones:

| Zone | Trusted for | Not trusted for |
| --- | --- | --- |
| Watch app | Capturing and retaining the user's event | Final network delivery |
| WatchConnectivity | OS-managed transport between paired apps | Exactly-once delivery or application-level persistence |
| iPhone store | Durable queue state and retention | Endpoint acceptance |
| Destination | Its own acknowledgement and processing | Protecting data after receipt |
| Wearable adapter | Converting a documented or observed device event | Defining the canonical event schema |

A successful step never implies success across the next boundary.

## Apple Watch boundaries

### Confirmed capabilities

- A third-party watch app can record audio with AVFoundation after it receives microphone permission and reaches an allowed runtime state.
- WatchConnectivity can move files and queued user information between paired watchOS and iOS apps.
- Complications, widgets, App Intents, notification actions, and normal app UI provide user entry points with different OS scheduling behavior.
- On supported systems, the Apple Watch Ultra Action Button can invoke eligible workout actions or a user-selected Shortcut. It is not a general hardware-button callback for every third-party app.

Primary sources include [WatchConnectivity](https://developer.apple.com/documentation/watchconnectivity), [frontmost app behavior](https://developer.apple.com/documentation/watchkit/taking-advantage-of-frontmost-app-state), [extended runtime sessions](https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions), [Action Button support](https://developer.apple.com/documentation/appintents/actionbuttonarticle), and [interactive widgets](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities).

### Capture trigger matrix

The latency values below are phase 0 engineering budgets, not Apple guarantees. Only physical-device measurements can replace them.

| Trigger | Direct third-party access | Launch or resume behavior | Suspended-state behavior | Requirements | Review or entitlement concern |
| --- | --- | --- | --- | --- | --- |
| In-app SwiftUI control | Yes | App is already active | No cold start | Any supported watch | Lowest risk; recording state must be clear |
| Apple Watch Ultra Action Button | No general callback. Eligible workout apps have documented Action Button integration | A user-configured Shortcut may invoke an App Intent and open Tapline | The system may launch or resume the intent flow, but Tapline cannot promise that audio starts before UI appears | Apple Watch Ultra for the hardware button; exact intent behavior varies by OS and configuration | High risk if the app claims a private hardware event or misuses workout APIs |
| Complication tap | Yes, as a user tap on Tapline's complication | Opens the associated app route | Can request an app launch from suspension | A complication supported by the selected watchOS target | Low risk; stale timeline state must not imply that capture already began |
| Interactive Smart Stack widget | Yes, through a control backed by an App Intent | May run the intent or open the app according to the intent and system state | Can invoke the intent while the main app is not active, but cannot grant arbitrary microphone runtime | Interactive watch widgets require watchOS 11 | Low for event capture; high if represented as guaranteed background recording |
| App Intent or Shortcut | Yes | Siri, Shortcuts, widgets, or the Action Button can invoke the declared intent | System-controlled. The intent may run or open the app, but recording still needs permission and a valid runtime state | Supported watchOS and an eligible intent definition | Intent description and behavior must match. Never imply hands-free covert recording |
| Double Tap gesture | No raw gesture callback. The system activates the visible primary action | Works through the current app UI | Does not wake an arbitrary suspended app as a Tapline gesture event | Supported hardware and watchOS 11 for third-party app support | Low if treated as UI activation; unsupported as a background trigger. See [Apple's Double Tap guidance](https://developer.apple.com/documentation/watchos-apps/enabling-double-tap) |
| Notification action | Yes, for actions declared by Tapline | Invokes the notification action and may launch supporting app code | The system grants only the execution associated with handling the action. It does not grant an open-ended recording session | watchOS notification action support and a delivered Tapline notification | Remote notifications would add a server dependency. Local notifications are acceptable but are not a hardware shortcut. See [notification actions](https://developer.apple.com/documentation/watchos-apps/adding-actions-to-notifications-on-watchos) |
| Digital Crown | Foreground UI receives supported crown interactions | Does not launch Tapline by itself | None | App visible | Low, but it is a UI control rather than a global trigger |
| Side button | No | Opens system UI chosen by watchOS | None | None available to Tapline | Hard platform limit |
| Active workout session | A legitimate workout app can receive workout controls and extended execution appropriate to the workout | Can keep workout UI and processing active under documented rules | Supports the workout, not unrelated indefinite capture | HealthKit capability, workout configuration, and a real workout purpose | High if used as a pretext for background recording. App Review guideline compliance matters |

Expected user-perceived activation budgets for planning are under 250 ms for an already visible in-app control, roughly 0.5 to 2 seconds for a complication or widget route, and roughly 1 to 4 seconds for a Shortcut cold launch. Those ranges are informed estimates only. Low Power Mode, process state, device generation, and system load can move them substantially.

### Audio execution matrix

| Starting state | Can Tapline start recording? | Can recording continue after display sleep? | Design consequence |
| --- | --- | --- | --- |
| Foreground app after permission | Yes | Expected under the supported audio and frontmost-app conditions that phase 0 must verify | Primary capture path |
| App active under a valid user-started recording session | Yes | Often, while the documented runtime conditions continue | Close and preserve the file on interruptions |
| App backgrounded after starting a legitimate session | Limited by the session type and watchOS policy | Possible only where Apple permits that audio or runtime session | Never describe this as general background permission |
| Extended runtime session | Only when Tapline fits one of Apple's session purposes | Time and behavior depend on the declared session type | A session label is not a way to request arbitrary execution |
| Workout session | Yes for a real workout feature | The workout can continue under HealthKit and WatchKit rules | Out of scope for capture-only Tapline |
| Suspended or terminated app | No reliable arbitrary microphone cold start | No | Open or resume the app, then start visible capture |
| Always-listening mode | Not as a dependable third-party watchOS app | No credible indefinite path | Do not implement or market it |

The recorder uses AVFoundation and asks for microphone access through the current platform API. Tapline starts an audio session only after a user action. It records to a local file rather than holding a clip only in memory. AVFoundation interruptions, route changes, low-storage errors, and process termination all become explicit event or recovery states.

Extended runtime sessions and background audio modes are purpose-bound. Apple documents session categories and runtime behavior, but the system retains scheduling control. A generic `WKExtendedRuntimeSession`, a nominal audio background mode, or an active workout does not authorize indefinite voice capture. Apple's [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) also require honest use of background services and conspicuous consent for recording.

### Hard limits

- Third-party apps do not receive the side button as an application event.
- The Double Tap gesture selects the visible primary control on supported watches. It is not a raw gesture stream or a background trigger.
- A suspended app cannot promise an instant cold start of arbitrary microphone capture.
- WatchConnectivity does not promise immediate transfer.
- Background execution is purpose-limited. Tapline must not create a fake workout to gain runtime.
- Always-listening capture is not a credible App Store product design. It conflicts with system execution limits, user expectations, battery constraints, and Apple's privacy rules.

The Apple Watch path therefore supports deliberate, visible, short capture. It cannot reproduce a dedicated ring that owns its button, firmware, microphone pipeline, and BLE protocol.

## Components

### Watch capture app

Responsibilities:

- show explicit idle, recording, saving, queued, and error states;
- capture an in-app button event;
- record a short audio clip;
- commit the event envelope and media metadata to the watch outbox;
- request WatchConnectivity transfer;
- retain the local copy until an iPhone ingestion acknowledgement arrives; and
- reconcile unacknowledged events after activation.

The watch never needs destination credentials. It knows the event schema and transfer protocol only.

### iPhone gateway

Responsibilities:

- ingest watch transfers and future wearable-adapter events;
- validate schema versions, hashes, sizes, and media types;
- deduplicate by event ID;
- create delivery jobs for matching destinations in the same transaction;
- send ingestion acknowledgements to the watch;
- execute retryable deliveries;
- display status without exposing secrets;
- manage export, deletion, and retention; and
- run optional transcription providers.

### Wearable adapters

`WearableTransport` converts hardware-specific input into `CaptureEventDraft`. It does not write directly to destinations.

```swift
public protocol WearableEventSource: Sendable {
    var sourceID: String { get }
    func events() -> AsyncThrowingStream<CaptureEventDraft, Error>
}
```

The first implementation is the WatchConnectivity source. A future BLE implementation uses CoreBluetooth behind the same boundary.

### Event store

The store contains immutable event records, media assets, delivery jobs, attempts, destination definitions, retention decisions, and migration state. SQLite is the practical choice because transactions tie event insertion to job creation.

The database and media directory use iOS Data Protection. Credentials and certificate pins live in Keychain. Database rows refer to credentials by opaque key ID.

### Router and delivery workers

The router evaluates deterministic filters against normalized metadata. It creates one delivery job per matching destination. Delivery workers lease jobs, make requests, and record outcomes.

Downloaded executable templates are forbidden. Version 1 templates allow named fields, JSON object construction, header substitution, and multipart part naming. The renderer rejects access to Keychain values except through the destination's declared authentication method.

## Normalized event model

The public wire model uses JSON names that are stable across Swift versions. Dates use RFC 3339 UTC strings. UUIDs use lowercase canonical text.

```swift
public struct CaptureEvent: Codable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let type: EventType
    public let occurredAt: Date
    public let capturedAt: Date
    public let source: EventSource
    public let payload: EventPayload
    public let media: [MediaReference]
    public let links: EventLinks
}

public enum EventType: String, Codable, Sendable {
    case buttonPressed = "button.pressed"
    case buttonReleased = "button.released"
    case audioStarted = "audio.started"
    case audioCaptured = "audio.captured"
    case transcriptCreated = "transcript.created"
    case deliveryTest = "delivery.test"
}

public struct EventSource: Codable, Sendable {
    public let kind: SourceKind
    public let installationID: UUID
    public let model: String?
    public let osVersion: String?
    public let appVersion: String
    public let adapter: String
}

public struct MediaReference: Codable, Sendable {
    public let id: UUID
    public let role: String
    public let mediaType: String
    public let byteCount: Int64
    public let sha256: String
    public let durationMilliseconds: Int?
    public let sampleRateHertz: Int?
    public let channelCount: Int?
}
```

The persisted Swift model may use tagged enums. The public schema should publish ordinary JSON Schema files and fixtures so non-Swift receivers can implement it.

### Button event example

```json
{
  "schemaVersion": 1,
  "id": "54166df2-a5c9-4a52-87ab-a15d72f4e907",
  "type": "button.pressed",
  "occurredAt": "2026-09-02T18:41:23.194Z",
  "capturedAt": "2026-09-02T18:41:23.211Z",
  "source": {
    "kind": "apple_watch",
    "installationID": "282c937e-9bbc-49d0-9a96-adb95be343e4",
    "model": "Apple Watch",
    "osVersion": "11.0",
    "appVersion": "0.1.0",
    "adapter": "watchconnectivity"
  },
  "payload": {
    "button": "primary",
    "gesture": "press"
  },
  "media": [],
  "links": {}
}
```

### Audio event example

```json
{
  "schemaVersion": 1,
  "id": "02b53d12-3d99-4f8e-9ba3-b4946ade64a8",
  "type": "audio.captured",
  "occurredAt": "2026-09-02T18:44:03.002Z",
  "capturedAt": "2026-09-02T18:44:17.612Z",
  "source": {
    "kind": "apple_watch",
    "installationID": "282c937e-9bbc-49d0-9a96-adb95be343e4",
    "model": "Apple Watch",
    "osVersion": "11.0",
    "appVersion": "0.1.0",
    "adapter": "watchconnectivity"
  },
  "payload": {
    "trigger": "in_app_button",
    "interrupted": false
  },
  "media": [
    {
      "id": "57838188-3d00-4e4b-b63b-a9134a1093c6",
      "role": "audio",
      "mediaType": "audio/mp4",
      "byteCount": 43821,
      "sha256": "35d8a2d9cfe706b29c2ec9f32b7f18be6fbf9f31f1c9e9b7859170ff97da9245",
      "durationMilliseconds": 14610,
      "sampleRateHertz": 16000,
      "channelCount": 1
    }
  ],
  "links": {}
}
```

### Transcript event example

A transcript is a separate derived event. Keeping it separate preserves provenance and lets retention rules treat audio and text differently.

```json
{
  "schemaVersion": 1,
  "id": "ba227cab-eec9-47b8-b56d-1f07dbe13070",
  "type": "transcript.created",
  "occurredAt": "2026-09-02T18:45:01.030Z",
  "capturedAt": "2026-09-02T18:45:01.030Z",
  "source": {
    "kind": "iphone",
    "installationID": "7259148d-a90c-43aa-82f2-1187860e7991",
    "model": "iPhone",
    "osVersion": "18.0",
    "appVersion": "0.1.0",
    "adapter": "local_transcription"
  },
  "payload": {
    "text": "Turn off the greenhouse irrigation at six.",
    "language": "en",
    "provider": "on_device",
    "model": "user-selected-model"
  },
  "media": [],
  "links": {
    "derivedFrom": "02b53d12-3d99-4f8e-9ba3-b4946ade64a8"
  }
}
```

## Media storage and delivery

### Capture format

The proposed watch default is mono AAC-LC in an M4A container, 16 kHz, about 24 kbps, with a 60-second limit. This is a product choice to validate on hardware, not an Apple requirement. At 24 kbps, 60 seconds of encoded audio is about 180 KB before container overhead. The equivalent 16-bit, 16 kHz mono PCM data is about 1.92 MB.

Tapline writes to a temporary file, closes it, validates that AVFoundation can reopen it, calculates its SHA-256 digest, then atomically moves it into the outbox. An incomplete temporary file is recoverable state, not a captured event.

### HTTP contract

Metadata-only events use:

```http
POST /capture HTTP/1.1
Content-Type: application/json
Idempotency-Key: 54166df2-a5c9-4a52-87ab-a15d72f4e907
```

Audio events use `multipart/form-data` with:

- `event`, an `application/json` part;
- `audio`, an `audio/mp4` file part; and
- `Idempotency-Key`, the stable event UUID.

The request includes a digest header or signed digest field derived from the stored media hash. Base64 audio inside JSON is not supported in version 1 because it adds size and memory overhead.

For future large media, Tapline may support a two-step contract that creates metadata first and uploads an asset second. That extension must define atomic receiver behavior and orphan cleanup before release.

## Watch transfer protocol

The watch transfer envelope contains:

```json
{
  "transferVersion": 1,
  "eventID": "02b53d12-3d99-4f8e-9ba3-b4946ade64a8",
  "eventFile": "event.json",
  "mediaFile": "57838188-3d00-4e4b-b63b-a9134a1093c6.m4a",
  "mediaSHA256": "35d8a2d9cfe706b29c2ec9f32b7f18be6fbf9f31f1c9e9b7859170ff97da9245"
}
```

In practice, WatchConnectivity transfers one file URL plus metadata. The implementation may package the event JSON and audio into an application archive or transfer the audio file with the complete compact event envelope in metadata. The phase 0 spike decides between those forms after measuring size and delivery behavior. Either form must let the iPhone validate one self-contained unit.

The iPhone acknowledgement contains the event ID, ingestion result, and phone store revision. The watch accepts it only from the paired application session and deletes its copy only for `committed` or `already_committed`.

## Durable queue

### State model

```text
captured_on_watch
    ↓
watch_transfer_pending
    ↓
phone_ingested
    ↓
queued_per_destination
    ↓
leased → attempting → delivered
                 └──→ retry_wait
                 └──→ paused_auth
                 └──→ failed_permanent
```

The event itself stays immutable. Each destination has a mutable delivery record:

```swift
public struct DeliveryJob: Codable, Sendable, Identifiable {
    public let id: UUID
    public let eventID: UUID
    public let destinationID: UUID
    public var state: DeliveryState
    public var attemptCount: Int
    public var nextAttemptAt: Date?
    public var leaseOwner: UUID?
    public var leaseExpiresAt: Date?
    public var lastHTTPStatus: Int?
    public var lastErrorCode: String?
}
```

Workers claim jobs with a database lease. A crashed worker leaves an expiring lease, not an event stuck forever.

### Retry policy

- Retry connection loss, DNS failure, timeout, HTTP `408`, HTTP `429`, and HTTP `5xx`.
- Honor a valid `Retry-After` value within the configured maximum.
- Use exponential backoff with full jitter and a user-visible cap.
- Pause on `401` and `403` until credentials change or the user resumes the destination.
- Treat most other `4xx` responses as permanent for that request, while preserving the event for export or manual retry.
- Reuse the same idempotency key for every attempt.
- Never delete an event because its retry count reached a limit.

## Destination configuration

```swift
public struct Destination: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var transport: TransportKind
    public var endpoint: Endpoint
    public var method: HTTPMethod
    public var headers: [HeaderTemplate]
    public var authentication: AuthenticationReference?
    public var tls: TLSPolicy
    public var filter: EventFilter
    public var payloadTemplate: PayloadTemplate
    public var retryPolicy: RetryPolicy
    public var networkPolicy: NetworkPolicy
}
```

Configuration supports:

- hostname or IP address;
- explicit port and path;
- HTTP method;
- declared headers;
- bearer token, basic authentication, or no authentication in version 1;
- normal public PKI or an explicitly pinned private certificate;
- event type and source filters;
- documented JSON or multipart templates;
- multiple independent destinations;
- retry limits and delay bounds; and
- `localNetworkOnly`, `anyNetwork`, or `wifiOnly` policy.

Tapline blocks user-defined `Host`, `Content-Length`, connection, cookie, and redirect-sensitive authentication headers. It strips authentication when a redirect changes origin and rejects non-HTTP schemes.

## Local networking and TLS

An app that browses or connects to local network services must provide `NSLocalNetworkUsageDescription`. Bonjour browsing also declares the exact service types in `NSBonjourServices`. Tapline should use one documented type such as `_tapline-capture._tcp` for compatible receivers and should not scan unrelated services. Apple's [local network privacy technote](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) is the implementation reference.

App Transport Security remains enabled. `NSAllowsLocalNetworking` supports unqualified and `.local` hostnames without creating a broad arbitrary-load exception. Numeric private IP addresses and TLS behavior need physical-device tests because name resolution, privacy prompts, and ATS are separate controls. See Apple's [`NSAllowsLocalNetworking` documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

For a private certificate, the user imports or selects a certificate and Tapline pins its public key or certificate digest for one destination. The URL session challenge handler performs [manual server trust authentication](https://developer.apple.com/documentation/Foundation/performing-manual-server-trust-authentication). There is no global bypass and no option to accept an expired or hostname-mismatched certificate silently.

## Background networking and offline behavior

HTTP uploads use file-backed requests and a background `URLSession` configuration where the API permits it. The app persists the request intent before scheduling the task and reconciles system tasks with database jobs on launch.

iOS chooses background execution time. `BGProcessingTask` can ask for later maintenance but cannot promise immediate delivery. A user force-quit can prevent relaunch until the user opens the app again. The UI must describe these states as pending, not failed or delivered.

WebSocket connections are a later foreground optimization. They do not replace the durable HTTP queue. If a WebSocket destination is added, it needs an application ACK keyed by event ID and an HTTP recovery route.

## Audio transcription

```swift
public protocol TranscriptionProvider: Sendable {
    var identity: TranscriptionIdentity { get }
    func transcribe(asset: StoredMedia) async throws -> TranscriptResult
}
```

Provider choices may include:

- disabled;
- Apple's on-device speech APIs when the locale, device, and current API report support;
- a bundled model such as WhisperKit or whisper.cpp; or
- a user-configured HTTP service on the local network.

The product must not label an Apple speech path "on device" unless the active API reports on-device support. It must not upload to a cloud fallback after a local provider fails. A transcript records its provider identity and links to its source event.

## BLE compatibility boundary

The iPhone can use CoreBluetooth to discover and communicate with BLE peripherals whose services and characteristics the app knows and whose access controls permit it. Background restoration has strict relaunch rules documented by Apple in [TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules). It does not make an unknown private protocol public.

For Pebble Index 01, the safe current classification is:

| Claim | Status |
| --- | --- |
| Official mobile software contains BLE pairing code and identifiers | Confirmed by public source code |
| Index supports click gestures, audio capture, webhook export, and MCP-related features | Confirmed by official product documentation |
| Official webhook sends audio and metadata to a configured URL | Confirmed by official documentation and public source code |
| Full GATT characteristic roles and state machine | Unknown publicly |
| On-wire button payloads | Unknown publicly |
| On-wire audio codec, framing, sequencing, and retransmission | Unknown publicly |
| BLE authentication and key exchange details | Unknown publicly |
| Stable public direct-device API | Unknown publicly |

This design reviewed the public mobile-app source at commit [`73080580134796c847344dab78930d4521fcae90`](https://github.com/coredevices/mobileapp/tree/73080580134796c847344dab78930d4521fcae90), dated September 2, 2026. The project says its public repository is a manually synchronized copy of an internal repository, so the snapshot can lag the distributed app.

The snapshot supports a narrower set of confirmed claims:

| Finding | Status and evidence |
| --- | --- |
| iOS pairing searches for service `607B5C9B-3700-4E94-F44A-2DF900BCB0C3` | Confirmed by [pairing source](https://github.com/coredevices/mobileapp/blob/73080580134796c847344dab78930d4521fcae90/libindex/src/iosMain/kotlin/coredevices/libindex/device/IndexPairing.ios.kt#L15-L26) |
| Pairing writes one `0x00` byte with response to characteristic `DAAD3D52-237C-90A7-B54B-8854A134D801` | Confirmed by [pairing source](https://github.com/coredevices/mobileapp/blob/73080580134796c847344dab78930d4521fcae90/libindex/src/iosMain/kotlin/coredevices/libindex/device/IndexPairing.ios.kt#L16-L29) |
| The webhook is an HTTP `POST` using multipart form data | Confirmed by the app's [webhook specification](https://github.com/coredevices/mobileapp/blob/73080580134796c847344dab78930d4521fcae90/experimental/src/commonMain/kotlin/coredevices/ring/external/indexwebhook/INDEX_WEBHOOK_API.md#L16-L25) |
| Webhook audio is AAC-LC in an M4A container, mono, 16 kHz, with media type `audio/mp4` | Confirmed by the [webhook specification](https://github.com/coredevices/mobileapp/blob/73080580134796c847344dab78930d4521fcae90/experimental/src/commonMain/kotlin/coredevices/ring/external/indexwebhook/INDEX_WEBHOOK_API.md#L27-L36) |
| Webhook fields include conditional `audio` and `transcription`, plus `recordedAt` and `client=ring` | Confirmed by the [webhook specification](https://github.com/coredevices/mobileapp/blob/73080580134796c847344dab78930d4521fcae90/experimental/src/commonMain/kotlin/coredevices/ring/external/indexwebhook/INDEX_WEBHOOK_API.md#L37-L61) |
| The app adds `X-Index-Trigger`; user-configured headers supply authentication | Confirmed by the [header and authentication documentation](https://github.com/coredevices/mobileapp/blob/73080580134796c847344dab78930d4521fcae90/experimental/src/commonMain/kotlin/coredevices/ring/external/indexwebhook/INDEX_WEBHOOK_API.md#L63-L75) |
| Failed webhook uploads have no persistent retry queue | Confirmed by the source repository's [webhook notes](https://github.com/coredevices/mobileapp/blob/73080580134796c847344dab78930d4521fcae90/experimental/src/commonMain/kotlin/coredevices/ring/external/indexwebhook/INDEX_WEBHOOK_API.md#L107-L112) |
| The app implements an MCP client with legacy SSE and Streamable HTTP transports and an optional `Authorization` header | Confirmed by [MCP client source](https://github.com/coredevices/mobileapp/blob/73080580134796c847344dab78930d4521fcae90/mcp/src/commonMain/kotlin/coredevices/mcp/client/HttpMcpIntegration.kt#L38-L80). This does not make the app an MCP server |

These facts do not document the collection protocol. The pairing write establishes one role for one characteristic. It says nothing about how the ring encodes gestures or audio after pairing.

Official references:

- [Index 01 getting started](https://help.repebble.com/en/articles/15434751-index-01-getting-started-guide)
- [Index advanced webhook and MCP features](https://help.repebble.com/en/articles/15724406-index-advanced-features-mcp-webhook)
- [Pebble mobile app source snapshot](https://github.com/coredevices/mobileapp/tree/73080580134796c847344dab78930d4521fcae90)

### Inspection policy

Protocol research must use owned devices, consenting accounts, controlled receivers, and software licenses that permit the work. A reproducible investigation may:

1. pin the hardware firmware and companion-app versions;
2. inventory visible GATT services, characteristic UUIDs, properties, and notification timing with CoreBluetooth;
3. capture the research Mac's Bluetooth traffic with PacketLogger and inspect it in Wireshark;
4. change one user action at a time and compare captures;
5. configure the documented webhook to a controlled server and inspect the request with server logs, mitmproxy, or Proxyman; and
6. publish raw observations separately from interpretations.

BLE link encryption can hide over-the-air payloads unless the analyst controls the pairing context and keys. TLS hides application traffic from network capture. Certificate pinning can prevent a debugging proxy. iOS sandboxing, code signing, Keychain protections, and license terms limit inspection of app internals. Tapline will not ship copied credentials, bypass third-party pinning in a production app, or claim that encrypted bytes have a meaning without repeatable evidence.

Until the direct protocol is complete, supported integration should use the official companion app's configured webhook to a user-controlled LAN receiver. An iOS app is not a dependable always-running inbound HTTP server, so the receiver should be Home Assistant, n8n, a small local service, or another host designed to accept connections.

## Security model

Threats in scope:

- another app or backup obtaining stored recordings;
- secrets leaking through logs, exports, redirects, or templates;
- a malicious LAN endpoint impersonating the configured server;
- duplicate event processing after a timeout;
- a crafted BLE peripheral sending oversized or malformed data;
- media and database records becoming inconsistent after a crash; and
- a destination receiving event types the user did not select.

Controls:

- Data Protection for the database and media directory;
- Keychain access control for credentials;
- certificate validation and optional per-destination pinning;
- size, duration, schema, and media-type limits at every ingestion boundary;
- SHA-256 media verification;
- stable idempotency keys;
- transactional job creation;
- origin-safe redirects;
- content-free structured logging; and
- event filters evaluated before request rendering.

End-to-end encryption to an arbitrary destination is not automatic. TLS protects data in transit to the configured server. The destination controls data after receipt. The UI and documentation must say this plainly.

## Retention, export, and deletion

Retention policies apply by event type and delivery state:

- keep until manual deletion;
- delete a configured time after every selected destination acknowledges;
- retain metadata but delete media after acknowledgement; or
- retain failed events indefinitely unless the user acts.

Tapline never deletes the last durable copy while a selected destination remains unacknowledged. Storage pressure produces a warning and can stop new recording. It does not silently erase pending events.

Export writes a versioned manifest, JSON event files, media files, and checksums. It excludes credentials and certificate private keys. Deletion removes database records, media files, derived events according to the selected rule, pending system tasks where possible, and watch copies during the next reconciliation. Flash storage may retain recoverable physical blocks outside the guarantees available to an ordinary app, so the product should promise logical deletion, not forensic erasure.

## Core package boundaries

| Package | Owns | Must not own |
| --- | --- | --- |
| `CaptureCore` | Event schema, IDs, validation, JSON fixtures | Storage, UI, network |
| `CaptureStore` | SQLite schema, migrations, transactions, leases | Keychain secret values |
| `AudioCapture` | Recorder state machine, format validation, hashes | Destination routing |
| `WatchBridge` | Transfer envelope, send, receive, ACK, reconciliation | HTTP delivery |
| `DeliveryKit` | Filters, templates, request construction, retry state | App screens |
| `EndpointSecurity` | Keychain references, trust evaluation, pinning | Event content |
| `TranscriptionKit` | Provider protocol and transcript provenance | Silent provider fallback |
| `WearableTransport` | Hardware adapter protocol and bounded decoding | Canonical persistence policy |

## End-to-end flow

```swift
// watchOS
func stopCapture() async throws {
    let completedFile = try await recorder.stopAndFinalize()
    let media = try mediaValidator.inspectAndHash(completedFile)
    let event = CaptureEvent.audio(media: media, source: watchSource)
    try await watchOutbox.commit(event: event, media: completedFile)
    await watchBridge.scheduleTransfer(eventID: event.id)
}

// iOS WatchConnectivity delegate
func receivedTransfer(file: URL, metadata: [String: Any]) async {
    do {
        let unit = try transferDecoder.validate(file: file, metadata: metadata)
        let result = try await ingestion.ingest(unit)
        await watchBridge.acknowledge(eventID: unit.event.id, result: result)
        await deliveryScheduler.wake()
    } catch {
        await quarantine.record(file: file, error: error)
    }
}

// shared iPhone ingestion boundary
actor IngestionCoordinator {
    func ingest(_ unit: IngestionUnit) async throws -> IngestionResult {
        try validator.validate(unit)
        return try await store.transaction {
            if store.contains(eventID: unit.event.id) { return .alreadyCommitted }
            try store.moveMediaIntoManagedStorage(unit.media)
            try store.insert(unit.event)
            try store.createJobs(router.destinations(for: unit.event))
            return .committed
        }
    }
}

// iPhone delivery worker
func deliverNext() async {
    guard let job = try? await store.leaseNextEligibleJob() else { return }
    do {
        let request = try requestFactory.makeRequest(for: job)
        let response = try await httpClient.send(request)
        try await store.record(classifier.classify(response), for: job)
    } catch {
        try? await store.record(classifier.classify(error), for: job)
    }
}
```

Production code must compensate for media filesystem operations that cannot participate in a SQLite transaction. The store should stage media under a temporary managed name, commit the row, then finalize the name with recovery records that a launch-time reconciler can repair.

## Compatibility and versioning

- The event schema starts at integer version `1`.
- Readers reject unknown major versions and preserve the original file for export.
- New optional fields do not change the major version.
- Renaming or changing the meaning of a field requires a new major version.
- Delivery destinations pin a template version.
- Transfer protocol, database schema, and public event schema use separate version numbers.
- Each release publishes fixture payloads and migration tests.

## Projects and documentation to review

Dependency admission is a security decision. Before adding a package, record its pinned version, license, transitive dependencies, release activity, binary artifacts, network behavior, and removal plan. The status below reflects the September 2, 2026 research snapshot and must be refreshed when implementation starts.

| Resource | What it demonstrates | Reusable part | License and maintenance note | Privacy or security concern |
| --- | --- | --- | --- | --- |
| [Apple WatchConnectivity documentation](https://developer.apple.com/documentation/watchconnectivity) | Session setup and Apple-supported transfer APIs | API patterns and lifecycle handling | Apple documentation and sample-code terms, not a general third-party library | Completion callbacks do not replace Tapline's database ACK |
| [Apple App Intents documentation](https://developer.apple.com/documentation/appintents) | System actions, Shortcuts, and widget integration | Intent definitions and donation patterns | Apple documentation and sample-code terms | An intent invocation must not imply that suspended audio capture is guaranteed |
| [Core Devices mobile app snapshot](https://github.com/coredevices/mobileapp/tree/73080580134796c847344dab78930d4521fcae90) | Index pairing, processing, webhook, and MCP client behavior | Protocol observations and independently reimplemented test fixtures | Actively developed; GPLv3 or commercial terms with an extra App Store permission described in its README | Do not copy GPL-covered implementation into an incompatibly licensed Tapline target; the public mirror may lag internal code |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | Mature SQLite access, migrations, transactions, and observation | `CaptureStore` persistence layer | MIT; active project at the snapshot date | Database encryption is not included merely by adopting GRDB |
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | Apple-platform local Whisper inference | Optional `TranscriptionProvider` | MIT; active project at the snapshot date | Model downloads, model licenses, memory use, and telemetry need separate checks |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | Portable local Whisper inference | Optional native transcription adapter | MIT; active project at the snapshot date | Bundled model size, provenance, and CPU or thermal cost remain Tapline's responsibility |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | Official Swift MCP transports and message types | Later Streamable HTTP destination | Active official SDK; its current license file records an MIT-to-Apache-2.0 transition and CC-BY-4.0 documentation terms | Remote MCP tools can trigger actions beyond delivery, so capability scope and authentication need separate review |
| [Home Assistant iOS](https://github.com/home-assistant/iOS) | A large local-network-aware Apple app | Reference patterns only | Apache 2.0; active project at the snapshot date | Its broad app permissions and dependencies should not be copied wholesale |
| [Ollama](https://github.com/ollama/ollama) and its [OpenAPI document](https://github.com/ollama/ollama/blob/main/docs/openapi.yaml) | Local model HTTP APIs | Receiver recipe and optional post-processing destination | MIT at the snapshot date | LAN exposure without authentication can disclose prompts and model access |
| [n8n](https://github.com/n8n-io/n8n) | Self-hosted webhook workflows | Receiver recipe, not an embedded dependency | Source available under n8n's Sustainable Use License and Enterprise License, not an OSI open-source dependency | Workflow histories may retain audio, transcripts, headers, and execution data |

Tapline should prefer standards and small libraries over importing another companion app's architecture. A reference implementation can teach us where the sharp edges are without becoming a dependency.

## Open questions

These require a spike or a product decision:

- Which exact watchOS runtime state keeps a 60-second AVFoundation recording active across wrist-down on each supported OS and watch generation?
- Should the WatchConnectivity transfer unit be an archive or a media file with a complete metadata envelope?
- Does the first release use GRDB or a smaller SQLite wrapper?
- Will the public license use the recommended MPL 2.0 terms or the more permissive Apache 2.0 terms?
- Which certificate-pin format gives users enough safety without making renewal unmanageable?
- Should deleted source audio cascade to transcripts by default or ask per retention policy?
- Which Index 01 facts remain reproducible across current firmware and the public companion-app build?

An open question is not permission to guess. Each answer should become an architecture decision record with physical-device evidence where the platform behavior matters.

## Feasibility verdict

Build the Apple Watch path first. It is feasible for visible, deliberate button events and short audio clips. It is not a substitute for a dedicated wearable that can wake on its own hardware control, run its own recording firmware, and transfer whenever its protocol permits.

Treat the Pebble compatibility gateway as two different products. The official webhook path is practical now when a user can run a receiving service. Direct Index 01 BLE ingestion is research until the collection protocol is publicly documented or independently reproduced across firmware versions. It must not block version 1.

The first shipping architecture should be Apple Watch capture, WatchConnectivity transfer, an iPhone SQLite queue, and JSON or multipart HTTP delivery. That path proves the event contract and loss-recovery rules that every later adapter needs.

The largest risks are watchOS runtime behavior during audio capture, unpredictable transfer and background-network scheduling, App Review interpretation of recording and background use, TLS configuration that is safe enough for non-experts, and the unpublished parts of the Index protocol.

| Area | Confirmed capability | Uncertain area | Hard limitation |
| --- | --- | --- | --- |
| Watch trigger | Visible app controls, complication routes, App Intents, interactive widgets, and notification actions are available under their documented rules | Cold-launch latency and exact behavior vary by device and system state | No generic side-button callback; no raw background Double Tap event |
| Watch audio | A foreground app with permission can record through AVFoundation and store a local file | Exact wrist-down and interruption behavior needs physical-device tests for every supported OS baseline | No reliable arbitrary microphone start from a suspended or terminated app |
| Watch-to-phone | WatchConnectivity transfers files and queued information between paired apps | Delivery time is system-controlled | Transfer completion is not proof of a phone database commit |
| iPhone delivery | `URLSession` can send JSON and file-backed multipart requests to user-configured endpoints | Background scheduling and private-certificate usability need device tests | No guaranteed immediate execution after suspension or user force-quit |
| Local network | iOS permits user-approved LAN access, Bonjour discovery, and validated TLS | Numeric IP, `.local`, and private PKI combinations need a test matrix | Tapline cannot bypass local-network consent or ATS safely |
| Local transcription | Supported Apple APIs and embedded open-source models can process some clips locally | Availability, language coverage, model size, heat, and speed vary | Tapline cannot call a cloud fallback and still call the path local-only |
| Pebble webhook gateway | Official documentation and source define configurable multipart webhook delivery | Firmware and companion-app updates can change behavior, so fixtures need version labels | An iPhone app is not a dependable always-running inbound webhook server |
| Direct Index BLE | Public source confirms discovery and one pairing write | Gesture payloads, audio framing, security, retries, and most characteristic roles remain unknown | Tapline cannot build a stable adapter by inventing undocumented bytes |
| Always-listening product | None needed for the proposed MVP | Dedicated future hardware could provide a different execution model | Apple Watch cannot credibly provide unrestricted, indefinite third-party capture |
