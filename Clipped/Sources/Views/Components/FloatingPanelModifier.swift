import SwiftUI

struct FloatingPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(FloatingPanelHelper())
    }
}

private struct FloatingPanelHelper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
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
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func floatingPanel() -> some View {
        modifier(FloatingPanelModifier())
    }
}
