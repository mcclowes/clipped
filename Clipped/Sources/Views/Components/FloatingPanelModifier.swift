import AppKit
import SwiftUI

struct FloatingPanelModifier: ViewModifier {
    let hideFromScreenSharing: Bool

    func body(content: Content) -> some View {
        content
            .background(FloatingPanelHelper(hideFromScreenSharing: hideFromScreenSharing))
    }
}

private struct FloatingPanelHelper: NSViewRepresentable {
    let hideFromScreenSharing: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let hide = hideFromScreenSharing
        DispatchQueue.main.async {
            if let window = view.window {
                window.level = .floating
                window.isMovableByWindowBackground = true
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                window.backgroundColor = .clear
                window.isOpaque = false
                window.hasShadow = true
                window.sharingType = hide ? .none : .readOnly
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let hide = hideFromScreenSharing
        DispatchQueue.main.async {
            nsView.window?.sharingType = hide ? .none : .readOnly
        }
    }
}

extension View {
    func floatingPanel(hideFromScreenSharing: Bool = true) -> some View {
        modifier(FloatingPanelModifier(hideFromScreenSharing: hideFromScreenSharing))
    }
}
