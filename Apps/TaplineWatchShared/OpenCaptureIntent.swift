import AppIntents

struct OpenTaplineCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Tapline capture"
    static let description = IntentDescription(
        "Opens Tapline's visible capture screen. Recording still starts only after you press record."
    )

    // `supportedModes` requires a newer OS than Tapline's watchOS 11 minimum.
    // Keep the compatibility property until that minimum moves forward.
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct TaplineAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenTaplineCaptureIntent(),
            phrases: [
                "Open capture in \(.applicationName)",
                "Record with \(.applicationName)",
            ],
            shortTitle: "Open capture",
            systemImageName: "waveform"
        )
    }
}
