# Tapline roadmap

This roadmap orders work by proof, not feature count. Each phase must leave captured data safer than the phase before it. Direct BLE support waits until the Apple Watch, queue, and delivery contracts work end to end.

Current status: phase 1 code and package tests are complete. Physical iPhone validation, local-network permission checks, and release work remain open.

## Phase 0: settle the public contract and test the risky APIs

Goal: remove the largest device and policy unknowns before building the product shell.

Work:

- Add the MPL 2.0 `LICENSE`. Completed.
- Add contribution, security-reporting, code-of-conduct, and release policies.
- Publish event schema version `1` and two example receiver fixtures.
- Create a minimal iOS and watchOS workspace targeting iOS 18 and watchOS 11.
- Test microphone permission, wrist-down recording, interruption handling, and file transfer on physical watches.
- Test `transferFile` delivery when the phone is reachable, temporarily unreachable, and relaunched.
- Measure real capture-to-phone latency. Do not turn the measurement into a product guarantee.
- Verify local-network permission behavior against a real LAN endpoint.
- Write short architecture decision records for the database, license, audio encoding, and minimum OS versions.

Frameworks and APIs:

- SwiftUI
- AVFoundation
- WatchConnectivity
- Network
- OSLog

Main risks:

- watchOS may stop or interrupt a recording when the app loses its allowed runtime state.
- WatchConnectivity schedules background file transfers but does not provide an application-level durable-ingestion acknowledgement.
- Simulator behavior can hide microphone, connectivity, and local-network failures.
- The selected open-source license must fit the planned App Store distribution model.

Acceptance tests:

- A physical Apple Watch records 60 seconds after the display dims, or the spike records the exact failure and revises scope.
- Removing Bluetooth or phone reachability during capture does not delete the watch file.
- The same transferred event can arrive twice without creating two phone events.
- A local HTTP receiver gets no traffic before the user enables its destination.
- The repository can be cloned and the documented fixture payloads validate without private credentials.

Out of scope:

- Production UI
- Background promises beyond measured Apple behavior
- BLE device support
- Transcription, WebSockets, MCP, and LLM routing

## Phase 1: build the iPhone destination and local store

Goal: configure and test an HTTP destination without a watch.

Work:

- Implement `CaptureCore`, `CaptureStore`, `DeliveryKit`, and `EndpointSecurity` packages.
- Store immutable events and separate mutable delivery attempts in a local SQLite database.
- Store bearer tokens, basic-auth passwords, client keys, and certificate pins in Keychain.
- Build destination editing for scheme, hostname or IP, port, path, method, headers, authentication, TLS policy, event filters, and retry policy.
- Add a foreground "test destination" action that sends a synthetic `delivery.test` event.
- Add queue and event-detail views with precise status and error information.
- Add offline JSON export and local deletion.

Frameworks and APIs:

- SwiftUI
- Foundation and `URLSession`
- Security and Keychain Services
- CryptoKit
- Network
- GRDB or a small SQLite wrapper

Main risks:

- A flexible template system can become a code-execution or secret-leak feature.
- Self-signed TLS can tempt an unsafe "trust all" implementation.
- Network errors are easy to flatten into messages users cannot act on.

Acceptance tests:

- The app persists a synthetic event before opening a network connection.
- Relaunching the app preserves the event and all delivery states.
- A `2xx` response marks only that destination delivered.
- `401` and `403` pause the destination and require user action.
- `408`, `429`, and `5xx` schedule a bounded retry with jitter and honor `Retry-After` when valid.
- An invalid or untrusted TLS certificate fails closed.
- Export works in airplane mode and contains no Keychain secrets.
- Deleting an event removes its database rows and local media file.

Out of scope:

- Downloaded scripts or JavaScript payload templates
- Authentication browser flows
- Mutual TLS
- Background WebSocket sessions
- Automatic cloud relay

## Phase 2: add deliberate Apple Watch capture

Goal: create button and short-audio events on Apple Watch and retain them locally.

Work:

- Build a one-screen watch app with a large record control and a separate event button.
- Ask for microphone permission in context.
- Record mono AAC-LC in an M4A container, starting with 16 kHz and about 24 kbps.
- Cap first-release clips at 60 seconds.
- Write audio to an application-controlled file and commit event metadata atomically when recording stops.
- Show elapsed time, recording state, storage failure, and interruption state.
- Add an optional complication or Smart Stack widget that opens the capture app.
- Add an App Intent that opens or resumes the capture flow where the OS permits it.

Frameworks and APIs:

- SwiftUI
- AVFoundation
- App Intents
- WidgetKit
- WatchKit lifecycle APIs

Main risks:

- A widget, complication, Shortcut, or Action Button route may launch the app but cannot promise immediate microphone capture from suspension.
- Audio route changes and interruptions can produce incomplete files.
- Long clips cost battery, storage, and transfer time.
- App Review will reject covert or misleading recording behavior.

Acceptance tests:

- Every successful capture has a stable UUID before transfer begins.
- A 60-second recording remains playable after the display turns off under the supported runtime conditions confirmed in phase 0.
- A denied microphone permission leaves a visible failed event without creating an empty audio file.
- A route interruption closes or repairs the M4A file and records an actionable error.
- Killing the watch app after persistence does not lose the capture.
- The app never records without a clear recording state.

Out of scope:

- Always-listening capture
- Direct side-button access
- A generic Ultra Action Button event handler
- Fake workouts used only to gain background time
- On-watch speech recognition

## Phase 3: make the watch-to-phone handoff durable

Goal: transfer watch events to the phone without loss or duplicate user-visible records.

Work:

- Send small button events with queued user info.
- Send audio as a WatchConnectivity file with a compact transfer envelope.
- Keep the watch event and media until the phone returns a Tapline ingestion acknowledgement.
- Deduplicate by event UUID on both devices.
- Reconcile pending watch events when either app activates.
- Expose watch states for waiting, transferred but unacknowledged, acknowledged, and failed.

Frameworks and APIs:

- WatchConnectivity
- FileManager
- OSLog

Main risks:

- WatchConnectivity chooses transfer timing.
- A system transfer completion does not prove that the phone database committed the event.
- Files and metadata can arrive at different times unless the transfer envelope is self-contained.

Acceptance tests:

- Capturing with the phone powered off retains the event on the watch.
- Reconnecting eventually commits the event and media on iPhone.
- Replaying the same transfer ten times produces one event and one media asset.
- The watch deletes its retained copy only after the matching ingestion acknowledgement.
- A corrupt or hash-mismatched asset remains quarantined and visible instead of being delivered.

Out of scope:

- Guaranteed real-time transfer
- Streaming microphone audio from watch to phone
- Sending directly from the watch to arbitrary HTTP servers

## Phase 4: ship reliable HTTP delivery

Goal: complete the smallest useful local-first product.

Work:

- Route each ingested event to every enabled matching destination.
- Deliver metadata-only events as `application/json`.
- Deliver audio as multipart form data with one JSON part and one `audio/mp4` part.
- Set `Idempotency-Key` to the event UUID and include a SHA-256 media digest.
- Use file-backed background `URLSession` tasks where appropriate.
- Track attempts independently per destination.
- Add manual retry, pause, cancel, delete, and redacted request preview.
- Add configurable retention for delivered events and orphaned media cleanup.

Frameworks and APIs:

- Foundation and background `URLSession`
- BackgroundTasks as a supplemental scheduler
- CryptoKit
- Network

Main risks:

- iOS does not guarantee immediate background execution, especially after the user force-quits the app.
- A receiver that ignores idempotency may process a retried event twice.
- Large retry queues can consume storage unless retention and quotas are visible.

Acceptance tests:

- A receiver gets the documented JSON and multipart fixtures byte for byte.
- Disabling the network during upload preserves the event and schedules a retry.
- A process termination during upload does not mark the event delivered.
- Two destinations can reach different final states for one event.
- Retrying after an ambiguous timeout reuses the same idempotency key.
- The app reports queue bytes, oldest pending age, and the last redacted error.
- A user can export and delete all local data without contacting any server.

Out of scope:

- WebSocket as the only delivery path
- A Tapline-hosted relay
- Remote push commands that start recording

## Phase 5: privacy review and first public release

Goal: make the product behavior auditable before adding more integrations.

Work:

- Threat-model recordings, transcripts, endpoint credentials, exports, logs, and BLE identifiers.
- Add database migration and crash-recovery tests.
- Document every permission prompt and every outbound request.
- Publish the event schema, receiver examples, privacy policy, support policy, and release notes.
- Generate a dependency license report and software bill of materials.
- Run App Store privacy-manifest and review-guideline checks.
- Add accessibility, VoiceOver, Dynamic Type, and reduced-motion checks where they apply.
- Ship a TestFlight build before submitting to the App Store.

Acceptance tests:

- A clean install makes no network request before the user configures or tests a destination.
- Static inspection finds no analytics, ad, crash-reporting, or remote-configuration SDK.
- Permission copy states why the microphone and local network are needed.
- All credential fields remain redacted in logs, exports, screenshots, and diagnostics.
- Database migration from every tagged beta fixture preserves queued events.
- A fresh clone can run schema and package tests from the public instructions.

Out of scope:

- Direct Pebble BLE compatibility
- General plugin marketplace
- Hosted accounts, sync, or billing

## Phase 6: add local transcription and receiver integrations

Goal: add useful processing without weakening the local-only baseline.

Work:

- Define `TranscriptionProvider` with disabled, Apple on-device where supported, embedded local model, and HTTP server implementations.
- Treat a transcript as a new event linked to the source audio event.
- Add tested receiver recipes for Home Assistant, n8n, Ollama, and a plain Swift or Python server.
- Add a WebSocket destination only for foreground, low-latency use. Keep HTTP queue delivery as the recovery path.
- Add an MCP client destination after the current Streamable HTTP transport and authentication behavior are verified against the official SDK.

Privacy rule:

The app must name the selected transcription provider and its network behavior before processing begins. "On device" and "local network" are separate modes. Tapline never turns a failed local transcription into a cloud request.

Acceptance tests:

- Disabling transcription leaves audio capture and delivery unchanged.
- An on-device provider works with internet access blocked on supported hardware.
- A LAN provider receives only events that match its filter.
- Deleting source audio applies the user's documented transcript-retention rule.

## Phase 7: investigate open wearable adapters

Goal: decide whether a direct Pebble Index 01 or similar BLE adapter is lawful, maintainable, and technically complete.

Work:

- Publish a clean-room inspection plan before publishing protocol claims.
- Test only owned hardware, consenting accounts, and controlled servers.
- Inventory services, characteristics, properties, notifications, and state transitions with CoreBluetooth.
- Compare host-side PacketLogger and Wireshark captures across one controlled variable at a time.
- Use the official app's documented webhook as the stable integration when direct BLE behavior remains unknown.
- Keep observed bytes, interpretations, and confidence labels separate.
- Require packet fixtures and physical-device integration tests for any public adapter.

Known starting point:

Official Pebble material documents webhook and MCP features, and public mobile-app source contains some pairing identifiers. It does not publish the full ring collection protocol. Tapline must not invent characteristic roles, gesture payloads, audio framing, encryption details, or authentication behavior.

Decision gate:

Ship a direct adapter only if it can pair, receive deliberate events, recover after disconnects, handle firmware-version differences, and do so without copied secrets or a dependency on a private vendor service. Otherwise support the official webhook export path and keep direct BLE marked experimental.

## Work that stays out of scope

- Covert recording
- Always-on microphone capture
- Advertising profiles or behavioral analytics
- Selling or training on user recordings or transcripts
- A mandatory Tapline cloud
- Undocumented claims presented as protocol facts
- Bypassing TLS pinning, platform security, account controls, or access controls in software the tester does not own
- Using workout sessions only to keep unrelated capture code alive

## Release definition

Version 1.0 is complete when phases 0 through 5 pass on supported physical iPhone and Apple Watch models. Later integrations must not delay the core release or become dependencies of capture, export, deletion, and HTTP delivery.
