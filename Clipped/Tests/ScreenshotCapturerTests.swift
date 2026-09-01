@testable import Clipped
import Testing

struct ScreenshotCapturerTests {
    @Test("Every screenshot mode writes directly to the clipboard")
    func everyModeTargetsClipboard() {
        for mode in ScreenshotCaptureMode.allCases {
            #expect(mode.arguments.contains("-c"))
        }
    }

    @Test("Interactive modes are restricted to their named target")
    func interactiveModesUseExpectedArguments() {
        #expect(ScreenshotCaptureMode.selection.arguments == ["-c", "-i", "-s"])
        #expect(ScreenshotCaptureMode.window.arguments == ["-c", "-i", "-w"])
        #expect(ScreenshotCaptureMode.screen.arguments == ["-c"])
    }
}
