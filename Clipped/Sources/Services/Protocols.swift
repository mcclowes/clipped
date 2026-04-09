import AppKit

// MARK: - Pasteboard abstraction

/// Abstracts pasteboard access so ClipboardManager can be tested without NSPasteboard.
@MainActor
protocol PasteboardReading: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
    func data(forType dataType: NSPasteboard.PasteboardType) -> Data?
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

// NSPasteboard already has all the required methods; nonisolated(unsafe) bridges
// the non-MainActor NSPasteboard into our @MainActor protocol for use in the app.
extension NSPasteboard: @preconcurrency PasteboardReading {}

// MARK: - History store abstraction

/// Abstracts history persistence so ClipboardManager can be tested without file I/O.
@MainActor
protocol HistoryStoring {
    func save(items: [ClipboardItem], pinnedItems: [ClipboardItem])
    func load() -> (items: [ClipboardItem], pinned: [ClipboardItem])
    func clear()
}

extension HistoryStore: HistoryStoring {}
