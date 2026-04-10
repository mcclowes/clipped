import AppKit

/// Minimal pasteboard surface so `PasteboardMonitor` and `ClipboardManager` can be
/// tested without touching `NSPasteboard.general`. `NSPasteboard` already exposes
/// all of these methods with matching signatures, so the conformance is free.
@MainActor
protocol PasteboardProtocol: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: PasteboardProtocol {}
