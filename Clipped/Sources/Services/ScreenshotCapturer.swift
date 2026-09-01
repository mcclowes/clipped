import Foundation

enum ScreenshotCaptureMode: CaseIterable, Identifiable, Sendable {
    case selection
    case window
    case screen

    var id: Self {
        self
    }

    var label: String {
        switch self {
        case .selection: "Capture Selection"
        case .window: "Capture Window"
        case .screen: "Capture Entire Screen"
        }
    }

    var systemImage: String {
        switch self {
        case .selection: "viewfinder"
        case .window: "macwindow"
        case .screen: "display"
        }
    }

    var arguments: [String] {
        switch self {
        case .selection: ["-c", "-i", "-s"]
        case .window: ["-c", "-i", "-w"]
        case .screen: ["-c"]
        }
    }
}

enum ScreenshotCapturer {
    static let executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")

    /// Starts the system screenshot UI without blocking Clipped's main actor. The `-c`
    /// argument writes the result directly to the pasteboard, where the existing monitor
    /// ingests it into history. Interactive cancellation is a normal, successful outcome.
    static func capture(_ mode: ScreenshotCaptureMode) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = mode.arguments
            try process.run()
            process.waitUntilExit()
        }.value
    }
}
