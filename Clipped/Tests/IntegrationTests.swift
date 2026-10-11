import AppKit
@testable import Clipped
import Foundation
import SwiftUI
import Testing

enum PasteBackBlock: CaseIterable, Sendable {
    case focusNotRestored
    case secureInput
    case secureInputDuringHandoff
    case activationDenied
    case terminated
    case terminatedDuringHandoff
    case waitInterrupted
    case canceled

    @MainActor
    func configure(environment: MockPasteBackEnvironment, editor: MockPasteBackApplication) {
        switch self {
        case .focusNotRestored:
            environment.frontmostApplication = MockPasteBackApplication(processIdentifier: 456)
        case .secureInput:
            environment.isSecureInputEnabled = true
        case .secureInputDuringHandoff:
            environment.onWait = { [weak environment] in environment?.isSecureInputEnabled = true }
        case .activationDenied:
            editor.activationSucceeds = false
        case .terminated:
            editor.isTerminated = true
        case .terminatedDuringHandoff:
            environment.onWait = { [weak editor] in editor?.isTerminated = true }
        case .waitInterrupted:
            environment.onWait = { throw CancellationError() }
        case .canceled:
            break
        }
    }
}

/// Multi-service integration tests. Wires the real `ClipboardManager`,
/// `PasteboardMonitor`, `ClipboardHistory`, and mutation service together with
/// `MockPasteboard` + `MockHistoryStore` (so the real disk and clipboard stay
/// untouched) and drives flows end-to-end. Unlike the per-service unit tests,
/// these exercise the wiring between collaborators.
@MainActor
struct IntegrationTests {
    @Test("The test host skips normal app startup and clipboard monitoring", .bug(id: 131))
    func skipsAppStartupInTests() throws {
        try #require(AppDelegate.isTestHost)
        let delegate = AppDelegate()
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

        #expect(delegate.clipboardManager.settingsManager == nil)
        #expect(!delegate.clipboardManager.isMonitoring)
        #expect(!delegate.screenshotWatcher.isWatching)
    }

    // swiftlint:disable large_tuple
    private func makeRig(persistHistory: Bool = true)
        -> (ClipboardManager, MockPasteboard, MockHistoryStore, MockSettingsManager)
    {
        // swiftlint:enable large_tuple
        let pasteboard = MockPasteboard()
        let manager = ClipboardManager(pasteboard: pasteboard)
        manager.pasteBackEnvironment = MockPasteBackEnvironment()
        manager.stopMonitoring() // We drive `monitor.check()` deterministically.
        let store = MockHistoryStore()
        let settings = MockSettingsManager()
        settings.persistAcrossReboots = persistHistory
        manager.historyStore = store
        manager.settingsManager = settings
        return (manager, pasteboard, store, settings)
    }

    private func capture(_ text: String, on pasteboard: MockPasteboard) {
        pasteboard.stageExternalWrite(types: [.string], strings: [.string: text])
    }

    private var detectedSecret: String {
        "sk_" + "test_EXAMPLEabcdefghij0123456789"
    }

    // MARK: - End-to-end ingest

    @Test("External pasteboard write flows monitor -> ingest -> history -> store")
    func captureToPersistence() async {
        let (manager, pasteboard, store, _) = makeRig()

        capture("Hello world", on: pasteboard)
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.count == 1)
        #expect(manager.items.first?.preview == "Hello world")

        let saved = await store.savedEntries
        #expect(saved.count == 1)
    }

    @Test("Multiple captures land in newest-first order")
    func multipleCapturesOrdering() async {
        let (manager, pasteboard, _, _) = makeRig()

        for text in ["one", "two", "three"] {
            capture(text, on: pasteboard)
            manager.monitor.check()
        }
        await manager.flushPendingSaves()

        #expect(manager.items.map(\.preview) == ["three", "two", "one"])
    }

    @Test("Identical content dedups instead of duplicating")
    func dedupOnRepeatedCapture() async {
        let (manager, pasteboard, _, _) = makeRig()

        capture("repeat", on: pasteboard)
        manager.monitor.check()
        capture("repeat", on: pasteboard) // bumps changeCount, same content
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.count == 1)
    }

    @Test("Recopying a pinned URL skips link metadata requests", .bug(id: 115))
    func pinnedURLSkipsEnrichment() async throws {
        let (manager, pasteboard, _, _) = makeRig(persistHistory: false)
        let url = try #require(URL(string: "https://example.com/pinned"))
        let pinned = ClipboardItem(content: .url(url), contentType: .url, isPinned: true)
        pinned.linkTitle = "Saved title"
        manager.pinnedItems = [pinned]
        let fetcher = MockLinkMetadataFetcher()
        manager.linkMetadataFetcher = fetcher

        capture(url.absoluteString, on: pasteboard)
        manager.monitor.check()
        await manager.awaitPendingEnrichments()

        #expect(await fetcher.fetchCallCount == 0)
        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.map(\.id) == [pinned.id])
        #expect(pinned.linkTitle == "Saved title")
    }

    @Test("Accepted URLs still receive link metadata", .bug(id: 115))
    func acceptedURLReceivesEnrichment() async throws {
        let (manager, pasteboard, _, _) = makeRig(persistHistory: false)
        let url = try #require(URL(string: "https://example.com/accepted"))
        let fetcher = MockLinkMetadataFetcher()
        await fetcher.setMetadata(LinkMetadata(title: "Local fixture"), for: url)
        manager.linkMetadataFetcher = fetcher

        capture(url.absoluteString, on: pasteboard)
        manager.monitor.check()
        await manager.awaitPendingEnrichments()

        #expect(await fetcher.fetchCallCount == 1)
        #expect(manager.items.count == 1)
        #expect(manager.items.first?.linkTitle == "Local fixture")
    }

    @Test("Accepted images receive OCR but a pinned recopy skips extraction", .bug(id: 115))
    func pinnedImageSkipsEnrichment() async throws {
        let (manager, pasteboard, _, _) = makeRig(persistHistory: false)
        let data = TestImageFactory.data(width: 40, height: 30)
        let extractor = MockImageTextExtractor(text: "Local OCR result")
        manager.extractImageText = { data in await extractor.extractText(from: data) }

        pasteboard.stageExternalWrite(types: [.png], data: [.png: data])
        manager.monitor.check()
        await manager.awaitPendingEnrichments()
        let pinned = try #require(manager.items.first)
        #expect(pinned.extractedText == "Local OCR result")
        manager.togglePin(pinned)

        pasteboard.stageExternalWrite(types: [.png], data: [.png: data])
        manager.monitor.check()
        await manager.awaitPendingEnrichments()

        #expect(await extractor.requestedImages == [data])
        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.map(\.id) == [pinned.id])
        #expect(pinned.extractedText == "Local OCR result")
    }

    // MARK: - Settings <-> ingestion

    @Test("persistAcrossReboots=false captures in memory but never saves")
    func noPersistenceWhenDisabled() async {
        let (manager, pasteboard, store, _) = makeRig(persistHistory: false)

        capture("ephemeral", on: pasteboard)
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.count == 1)
        let saved = await store.savedEntries
        #expect(saved.isEmpty)
    }

    @Test("Mask-only secrets remain in encrypted history")
    func maskOnlySecretPersists() async {
        let (manager, pasteboard, store, settings) = makeRig()
        settings.secretHandling = .maskOnly

        capture(detectedSecret, on: pasteboard)
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.first?.containsSecret == true)
        #expect(manager.items.first?.isSensitive == false)
        let saved = await store.savedEntries
        #expect(saved.count == 1)
    }

    @Test("Copying generated secret text preserves classification in masked history", .bug(id: 114))
    func generatedSecretIsClassified() async {
        let (manager, pasteboard, store, settings) = makeRig()
        settings.secretHandling = .maskOnly

        manager.copyText(detectedSecret)
        await manager.flushPendingSaves()

        #expect(pasteboard.string(forType: .string) == detectedSecret)
        #expect(manager.items.first?.containsSecret == true)
        #expect(manager.items.first?.isSensitive == false)
        let saved = await store.savedEntries
        #expect(saved.count == 1)
        #expect(saved.first?.containsSecret == true)
    }

    @Test("Authentication denial leaves generated secret text off the clipboard and history", .bug(id: 114))
    func generatedSecretAuthenticationDenied() {
        let (manager, pasteboard, _, settings) = makeRig(persistHistory: false)
        settings.secretHandling = .requireAuthentication
        capture("Previous clipboard", on: pasteboard)
        var authenticationRequests = 0
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            completion(false)
        }

        manager.copyText(detectedSecret)

        #expect(authenticationRequests == 1)
        #expect(pasteboard.string(forType: .string) == "Previous clipboard")
        #expect(manager.items.isEmpty)
    }

    @Test("Generated secret copies wait for authentication approval", .bug(id: 114))
    func generatedSecretAuthenticationApproved() async throws {
        let (manager, pasteboard, store, settings) = makeRig()
        settings.secretHandling = .requireAuthentication
        capture("Previous clipboard", on: pasteboard)
        var pendingApproval: (@MainActor @Sendable (Bool) -> Void)?
        manager.authenticateSecretAccess = { _, completion in pendingApproval = completion }

        manager.copyText(detectedSecret)
        #expect(pasteboard.string(forType: .string) == "Previous clipboard")
        #expect(manager.items.isEmpty)
        let approve = try #require(pendingApproval)
        approve(true)
        await manager.flushPendingSaves()

        #expect(pasteboard.string(forType: .string) == detectedSecret)
        #expect(manager.items.first?.containsSecret == true)
        let saved = await store.savedEntries
        #expect(saved.count == 1)
        #expect(saved.first?.containsSecret == true)
    }

    @Test("Ordinary generated text copies without authentication", .bug(id: 114))
    func ordinaryGeneratedTextCopies() async {
        let (manager, pasteboard, store, settings) = makeRig()
        settings.secretHandling = .requireAuthentication
        var authenticationRequests = 0
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            completion(false)
        }

        manager.copyText("A normal summary")
        await manager.flushPendingSaves()

        #expect(authenticationRequests == 0)
        #expect(pasteboard.string(forType: .string) == "A normal summary")
        #expect(manager.items.first?.containsSecret == false)
        let saved = await store.savedEntries
        #expect(saved.count == 1)
    }

    @Test("Generated secrets follow memory-only retention and expire", .bug(id: 114), arguments: [false, true])
    func generatedSecretExpires(pinBeforeExpiry: Bool) async throws {
        let (manager, pasteboard, store, settings) = makeRig()
        settings.secretHandling = .treatLikePasswords
        manager.secureRemovalDelay = { _ in .zero }

        manager.copyText(detectedSecret)

        #expect(pasteboard.string(forType: .string) == detectedSecret)
        #expect(manager.items.first?.containsSecret == true)
        #expect(manager.items.first?.isSensitive == true)
        if pinBeforeExpiry {
            try manager.togglePin(#require(manager.items.first))
        }
        await manager.flushPendingSaves()
        let saved = await store.savedEntries
        #expect(saved.isEmpty)
        await manager.awaitPendingSecureRemovals()
        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.isEmpty)
    }

    @Test("Treat-like-passwords secrets stay memory-only and expire")
    func passwordPolicySecretExpires() async {
        let (manager, pasteboard, store, settings) = makeRig()
        settings.secretHandling = .treatLikePasswords
        manager.secureRemovalDelay = { _ in .zero }

        capture(detectedSecret, on: pasteboard)
        manager.monitor.check()
        await manager.flushPendingSaves()

        let saved = await store.savedEntries
        #expect(saved.isEmpty)
        await manager.awaitPendingSecureRemovals()
        #expect(manager.items.isEmpty)
    }

    @Test("A missing paste target copies without sending a keystroke", .bug(id: 116))
    func pasteWithoutTarget() async {
        let (manager, pasteboard, _, _) = makeRig(persistHistory: false)
        let environment = MockPasteBackEnvironment()
        manager.pasteBackEnvironment = environment
        let item = ClipboardItem(content: .text("copy only"), contentType: .plainText)

        await manager.pasteToActiveApp(item)?.value

        #expect(pasteboard.string(forType: .string) == "copy only")
        #expect(environment.pastedProcessIDs.isEmpty)
        #expect(environment.waitCount == 0)
    }

    @Test("Opening history directly pastes plain text into the previously active app", .bug(id: 116))
    func historyWindowPasteTarget() async throws {
        let (manager, pasteboard, _, _) = makeRig(persistHistory: false)
        let environment = MockPasteBackEnvironment()
        let editor = MockPasteBackApplication()
        let clipped = try MockPasteBackApplication(
            bundleIdentifier: #require(Bundle.main.bundleIdentifier), processIdentifier: 456
        )
        environment.frontmostApplication = editor
        manager.pasteBackEnvironment = environment
        editor.onActivate = { [weak editor, weak environment] in
            environment?.frontmostApplication = editor
        }
        var presentations = 0
        let presenter = HistoryWindowPresenter { _ in
            presentations += 1
            environment.frontmostApplication = clipped
        }
        let controller = StatusBarController(history: presenter)
        controller.clipboardManager = manager
        let item = ClipboardItem(content: .richText(Data([1, 2, 3]), "Styled text"), contentType: .richText)

        controller.openHistoryWindow(contentView: EmptyView())
        await manager.pasteMatchingStyle(item)?.value

        #expect(presentations == 1)
        #expect(manager.previousActiveApp?.processIdentifier == editor.processIdentifier)
        #expect(editor.activationCount == 1)
        #expect(environment.pastedProcessIDs == [editor.processIdentifier])
        #expect(pasteboard.string(forType: .string) == "Styled text")
        #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test("Paste dismisses the panel before waiting for the intended app to regain focus", .bug(id: 116))
    func pasteWaitsForFocus() async throws {
        let (manager, pasteboard, _, _) = makeRig(persistHistory: false)
        let environment = MockPasteBackEnvironment()
        let editor = MockPasteBackApplication()
        let clipped = try MockPasteBackApplication(
            bundleIdentifier: #require(Bundle.main.bundleIdentifier), processIdentifier: 456
        )
        environment.frontmostApplication = editor
        manager.pasteBackEnvironment = environment
        manager.captureFrontmostApp()
        environment.frontmostApplication = clipped
        var events: [String] = []
        manager.dismissPanelForPaste = { events.append("dismiss") }
        editor.onActivate = { events.append("activate") }
        environment.onWait = { [weak editor, weak environment] in
            if environment?.waitCount == 3 {
                environment?.frontmostApplication = editor
            }
        }
        let item = ClipboardItem(content: .text("paste after focus"), contentType: .plainText)

        await manager.pasteToActiveApp(item)?.value

        #expect(events == ["dismiss", "activate"])
        #expect(environment.waitCount == 3)
        #expect(environment.pastedProcessIDs == [editor.processIdentifier])
        #expect(pasteboard.string(forType: .string) == "paste after focus")
    }

    @Test("Target capture preserves panel-to-history navigation and refreshes external apps", .bug(id: 116))
    func pasteTargetCaptureTransitions() throws {
        let (manager, _, _, _) = makeRig(persistHistory: false)
        let environment = MockPasteBackEnvironment()
        let firstEditor = MockPasteBackApplication()
        let nextEditor = MockPasteBackApplication(processIdentifier: 789)
        let clipped = try MockPasteBackApplication(
            bundleIdentifier: #require(Bundle.main.bundleIdentifier), processIdentifier: 456
        )
        manager.pasteBackEnvironment = environment

        environment.frontmostApplication = firstEditor
        manager.captureFrontmostApp()
        environment.frontmostApplication = clipped
        manager.captureFrontmostApp()
        #expect(manager.previousActiveApp?.processIdentifier == firstEditor.processIdentifier)

        environment.frontmostApplication = nextEditor
        manager.captureFrontmostApp()
        #expect(manager.previousActiveApp?.processIdentifier == nextEditor.processIdentifier)

        environment.frontmostApplication = nil
        manager.captureFrontmostApp()
        #expect(manager.previousActiveApp == nil)
    }

    @Test(
        "Blocked paste-back keeps the clipboard without sending keys",
        .bug(id: 116),
        arguments: PasteBackBlock.allCases
    )
    func blockedPasteBack(_ block: PasteBackBlock) async {
        let (manager, pasteboard, _, _) = makeRig(persistHistory: false)
        let environment = MockPasteBackEnvironment()
        let editor = MockPasteBackApplication()
        environment.frontmostApplication = editor
        manager.pasteBackEnvironment = environment
        manager.captureFrontmostApp()

        block.configure(environment: environment, editor: editor)

        let item = ClipboardItem(content: .text("copy despite blocked paste"), contentType: .plainText)
        let task = manager.pasteToActiveApp(item)
        if block == .canceled {
            task?.cancel()
        }
        await task?.value

        #expect(environment.pastedProcessIDs.isEmpty)
        #expect(pasteboard.string(forType: .string) == "copy despite blocked paste")
        if block == .focusNotRestored {
            #expect(environment.waitCount > 1)
        }
        if block == .canceled {
            #expect(editor.activationCount == 0)
        }
    }

    @Test("Authentication mode gates copy but leaves paste frictionless")
    func authenticationModeCopyAndPaste() async {
        let (manager, pasteboard, _, settings) = makeRig(persistHistory: false)
        let environment = MockPasteBackEnvironment()
        let editor = MockPasteBackApplication()
        environment.frontmostApplication = editor
        manager.pasteBackEnvironment = environment
        manager.captureFrontmostApp()
        settings.secretHandling = .requireAuthentication
        let item = ClipboardItem(content: .text(detectedSecret), contentType: .plainText)
        item.containsSecret = true
        var authenticationRequests = 0
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            completion(false)
        }

        manager.copyToClipboard(item)
        #expect(authenticationRequests == 1)
        #expect(pasteboard.string(forType: .string) == nil)

        await manager.pasteToActiveApp(item)?.value
        #expect(authenticationRequests == 1)
        #expect(pasteboard.string(forType: .string) == detectedSecret)
        #expect(environment.pastedProcessIDs == [editor.processIdentifier])
    }

    @Test("Denied bulk secret export leaves the clipboard unchanged", .bug(id: 111))
    func deniedBulkSecretExport() {
        let (manager, pasteboard, _, settings) = makeRig(persistHistory: false)
        settings.secretHandling = .requireAuthentication
        capture("keep this clipboard", on: pasteboard)
        let initialChangeCount = pasteboard.changeCount
        let ordinary = ClipboardItem(content: .text("public text"), contentType: .plainText)
        let secret = ClipboardItem(content: .text(detectedSecret), contentType: .plainText)
        var authenticationRequests = 0
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            completion(false)
        }

        manager.exportItems([ordinary, secret])

        #expect(authenticationRequests == 1)
        #expect(pasteboard.string(forType: .string) == "keep this clipboard")
        #expect(pasteboard.changeCount == initialChangeCount)
    }

    @Test("Secret file export waits for approval before delivering bytes", .bug(id: 111), arguments: [false, true])
    func fileExportWaitsForApproval(_ approved: Bool) throws {
        let (manager, _, _, settings) = makeRig(persistHistory: false)
        settings.secretHandling = .requireAuthentication
        let item = ClipboardItem(content: .text(detectedSecret), contentType: .plainText)
        var pendingApproval: (@MainActor @Sendable (Bool) -> Void)?
        var exportedData: Data?
        var completions = 0
        manager.authenticateSecretAccess = { _, completion in pendingApproval = completion }

        manager.exportData(for: item, format: .plainText) { data in
            exportedData = data
            completions += 1
        }
        #expect(exportedData == nil)
        #expect(completions == 0)
        let authorize = try #require(pendingApproval)
        authorize(approved)

        #expect(exportedData == (approved ? Data(detectedSecret.utf8) : nil))
        #expect(completions == (approved ? 1 : 0))
    }

    @Test("Secret image preview waits for approval before creating a file", .bug(id: 111), arguments: [false, true])
    func imagePreviewWaitsForApproval(_ approved: Bool) throws {
        let (manager, _, _, settings) = makeRig(persistHistory: false)
        settings.secretHandling = .requireAuthentication
        let item = ClipboardItem(content: .image(Data([1]), .zero), contentType: .image)
        item.containsSecret = true
        var pendingApproval: (@MainActor @Sendable (Bool) -> Void)?
        var previewedIDs: [UUID] = []
        manager.authenticateSecretAccess = { _, completion in pendingApproval = completion }
        manager.previewImage = { previewedIDs.append($0.id) }

        manager.openImageInPreview(item)

        #expect(previewedIDs.isEmpty)
        let authorize = try #require(pendingApproval)
        authorize(approved)
        #expect(previewedIDs == (approved ? [item.id] : []))
    }

    @Test("Unavailable owner authentication cannot release secret export bytes", .bug(id: 111))
    func unavailableAuthenticationBlocksExport() {
        let (manager, _, _, settings) = makeRig(persistHistory: false)
        settings.secretHandling = .requireAuthentication
        let context = MockUnavailableAuthenticationContext()
        manager.authenticateSecretAccess = { reason, completion in
            ClipboardManager.authenticateOwner(reason: reason, context: context, completion: completion)
        }
        let item = ClipboardItem(content: .text(detectedSecret), contentType: .plainText)
        var exportedData: Data?
        var completions = 0

        manager.exportData(for: item, format: .plainText) {
            exportedData = $0
            completions += 1
        }

        #expect(exportedData == nil)
        #expect(completions == 0)
        #expect(context.evaluations == 0)
    }

    @Test(
        "Sensitive entries require approval for exports in every secret mode",
        .bug(id: 111),
        arguments: SecretHandling.allCases
    )
    func sensitiveExportsRequireApproval(_ handling: SecretHandling) {
        let (manager, pasteboard, _, settings) = makeRig(persistHistory: false)
        settings.secretHandling = handling
        capture("keep this clipboard", on: pasteboard)
        let item = ClipboardItem(content: .text("private password"), contentType: .plainText)
        item.isSensitive = true
        item.containsSecret = false
        let image = ClipboardItem(content: .image(Data([1]), .zero), contentType: .image)
        image.isSensitive = true
        var authenticationRequests = 0
        var fileExports = 0
        var previewExports = 0
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            completion(false)
        }
        manager.previewImage = { _ in previewExports += 1 }

        manager.exportItems([item])
        manager.exportData(for: item, format: .plainText) { _ in fileExports += 1 }
        manager.openImageInPreview(image)

        #expect(authenticationRequests == 3)
        #expect(pasteboard.string(forType: .string) == "keep this clipboard")
        #expect(fileExports == 0)
        #expect(previewExports == 0)
    }

    @Test("A mixed bulk export waits for one approval and preserves every contributor", .bug(id: 111))
    func bulkExportWaitsForApproval() throws {
        let (manager, pasteboard, _, settings) = makeRig(persistHistory: false)
        settings.secretHandling = .requireAuthentication
        capture("keep this clipboard", on: pasteboard)
        let ordinary = ClipboardItem(content: .text("public text"), contentType: .plainText)
        let firstSecret = ClipboardItem(content: .text(detectedSecret), contentType: .plainText)
        let nextSecretText = detectedSecret + "2"
        let nextSecret = ClipboardItem(content: .text(nextSecretText), contentType: .plainText)
        var pendingApproval: (@MainActor @Sendable (Bool) -> Void)?
        var authenticationRequests = 0
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            pendingApproval = completion
        }

        manager.exportItems([ordinary, firstSecret, nextSecret])
        #expect(authenticationRequests == 1)
        #expect(pasteboard.string(forType: .string) == "keep this clipboard")
        let authorize = try #require(pendingApproval)
        authorize(true)

        #expect(pasteboard
            .string(forType: .string) == "public text\n\n---\n\n\(detectedSecret)\n\n---\n\n\(nextSecretText)")
        #expect(authenticationRequests == 1)
    }

    @Test("Detected-secret exports follow the selected mode", .bug(id: 111), arguments: SecretHandling.allCases)
    func secretExportModes(_ handling: SecretHandling) {
        let (manager, pasteboard, _, settings) = makeRig(persistHistory: false)
        settings.secretHandling = handling
        let item = ClipboardItem(content: .text(detectedSecret), contentType: .plainText)
        item.isSensitive = handling == .treatLikePasswords
        let image = ClipboardItem(content: .image(Data([1]), .zero), contentType: .image)
        image.containsSecret = true
        image.isSensitive = item.isSensitive
        var authenticationRequests = 0
        var previewExports = 0
        var exportedData: Data?
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            completion(true)
        }
        manager.previewImage = { _ in previewExports += 1 }

        manager.exportItems([item])
        manager.exportData(for: item, format: .plainText) { exportedData = $0 }
        manager.openImageInPreview(image)

        #expect(pasteboard.string(forType: .string) == detectedSecret)
        #expect(exportedData == Data(detectedSecret.utf8))
        #expect(previewExports == 1)
        #expect(authenticationRequests == (handling == .maskOnly ? 0 : 3))
    }

    @Test("Ordinary exports and empty selections do not request authentication", .bug(id: 111))
    func ordinaryExportsSkipAuthentication() {
        let (manager, pasteboard, _, settings) = makeRig(persistHistory: false)
        settings.secretHandling = .requireAuthentication
        capture("keep this clipboard", on: pasteboard)
        let initialChangeCount = pasteboard.changeCount
        let ordinary = ClipboardItem(content: .text("public text"), contentType: .plainText)
        let image = ClipboardItem(content: .image(Data([1]), .zero), contentType: .image)
        image.containsSecret = true
        var authenticationRequests = 0
        var exportedData: Data?
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            completion(false)
        }

        manager.exportItems([])
        manager.exportItems([image])
        #expect(pasteboard.changeCount == initialChangeCount)

        manager.exportItems([ordinary, image])
        manager.exportData(for: ordinary, format: .markdown) { exportedData = $0 }
        #expect(pasteboard.string(forType: .string) == "public text")
        #expect(exportedData == Data("public text".utf8))
        #expect(authenticationRequests == 0)
    }

    @Test(
        "Extracted sensitive text waits for approval and stays out of saved history",
        .bug(id: 111),
        arguments: [false, true]
    )
    func sensitiveExtractedTextCopy(_ approved: Bool) async throws {
        let (manager, pasteboard, store, _) = makeRig()
        manager.secureRemovalDelay = { _ in .zero }
        capture("keep this clipboard", on: pasteboard)
        let image = ClipboardItem(content: .image(Data([1]), .zero), contentType: .image)
        image.isSensitive = true
        image.extractedText = "private password"
        var pendingApproval: (@MainActor @Sendable (Bool) -> Void)?
        var authenticationRequests = 0
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            pendingApproval = completion
        }

        manager.copyExtractedText(from: image)
        #expect(authenticationRequests == 1)
        #expect(pasteboard.string(forType: .string) == "keep this clipboard")
        #expect(manager.items.isEmpty)
        let authorize = try #require(pendingApproval)
        authorize(approved)
        if approved {
            #expect(manager.items.first?.isSensitive == true)
        }

        await manager.flushPendingSaves()
        await manager.awaitPendingSecureRemovals()
        #expect(pasteboard.string(forType: .string) == (approved ? "private password" : "keep this clipboard"))
        #expect(authenticationRequests == 1)
        #expect(manager.items.isEmpty)
        #expect(await store.savedEntries.isEmpty)
    }

    @Test(
        "Extracted text keeps source secret flags and detects new secrets with one approval",
        .bug(id: 111),
        arguments: [false, true]
    )
    func extractedSecretClassification(_ sourceWasFlagged: Bool) async throws {
        let (manager, pasteboard, store, settings) = makeRig()
        settings.secretHandling = .requireAuthentication
        capture("keep this clipboard", on: pasteboard)
        let image = ClipboardItem(content: .image(Data([1]), .zero), contentType: .image)
        image.containsSecret = sourceWasFlagged
        let text = sourceWasFlagged ? "private password" : detectedSecret
        image.extractedText = text
        var pendingApproval: (@MainActor @Sendable (Bool) -> Void)?
        var authenticationRequests = 0
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            pendingApproval = completion
        }

        manager.copyExtractedText(from: image)
        #expect(authenticationRequests == 1)
        #expect(pasteboard.string(forType: .string) == "keep this clipboard")
        let authorize = try #require(pendingApproval)
        authorize(true)
        await manager.flushPendingSaves()

        #expect(authenticationRequests == 1)
        #expect(pasteboard.string(forType: .string) == text)
        #expect(manager.items.first?.containsSecret == true)
        let saved = await store.savedEntries
        #expect(saved.count == 1)
        #expect(saved.first?.containsSecret == true)
    }

    @Test("Ordinary extracted text copies without authentication and preserves its source", .bug(id: 111))
    func ordinaryExtractedTextCopy() async {
        let (manager, pasteboard, store, settings) = makeRig()
        settings.secretHandling = .requireAuthentication
        capture("keep this clipboard", on: pasteboard)
        let image = ClipboardItem(
            content: .image(Data([1]), .zero), contentType: .image,
            sourceAppName: "Example", sourceAppBundleID: "com.example.editor"
        )
        var authenticationRequests = 0
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            completion(false)
        }

        manager.copyExtractedText(from: image)
        #expect(pasteboard.string(forType: .string) == "keep this clipboard")
        #expect(manager.items.isEmpty)
        image.extractedText = "public label"
        manager.copyExtractedText(from: image)
        await manager.flushPendingSaves()

        #expect(authenticationRequests == 0)
        #expect(pasteboard.string(forType: .string) == "public label")
        #expect(manager.items.first?.sourceAppBundleID == "com.example.editor")
        #expect(manager.items.first?.containsSecret == false)
        #expect(await store.savedEntries.count == 1)
    }

    @Test("Reveal follows the selected secret policy")
    func revealPolicy() {
        let (manager, _, _, settings) = makeRig(persistHistory: false)
        let item = ClipboardItem(content: .text(detectedSecret), contentType: .plainText)
        item.containsSecret = true
        var authenticationRequests = 0
        manager.authenticateSecretAccess = { _, completion in
            authenticationRequests += 1
            completion(true)
        }

        settings.secretHandling = .maskOnly
        var revealedWithoutAuthentication = false
        manager.reveal(item) { revealedWithoutAuthentication = true }
        #expect(revealedWithoutAuthentication == true)
        #expect(authenticationRequests == 0)

        settings.secretHandling = .requireAuthentication
        var revealedAfterAuthentication = false
        manager.reveal(item) { revealedAfterAuthentication = true }
        #expect(revealedAfterAuthentication == true)
        #expect(authenticationRequests == 1)
    }

    @Test("secureMode + timeout 0 drops password-manager content entirely")
    func secureModeSkipsConcealed() async {
        let (manager, pasteboard, _, settings) = makeRig()
        settings.secureMode = true
        settings.secureTimeout = 0

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.stageExternalWrite(
            types: [concealed, .string],
            strings: [.string: "hunter2"]
        )
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.isEmpty)
    }

    @Test("secureMode + timeout > 0 ingests but does not persist")
    func secureModeWithTimeoutIngestsTransiently() async {
        let (manager, pasteboard, store, settings) = makeRig()
        settings.secureMode = true
        settings.secureTimeout = 30 // never elapses during the test

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.stageExternalWrite(
            types: [concealed, .string],
            strings: [.string: "tempsecret"]
        )
        manager.monitor.check()
        await manager.flushPendingSaves()

        #expect(manager.items.count == 1)
        #expect(manager.items.first?.isSensitive == true)
        let saved = await store.savedEntries
        // Pending-removal items must never reach disk.
        #expect(saved.isEmpty)
    }

    @Test("Secure timeout still evicts an item that was pinned before the timer fired")
    func secureRemovalCoversPinnedItems() async throws {
        let (manager, pasteboard, _, settings) = makeRig()
        settings.secureMode = true
        settings.secureTimeout = 30
        manager.secureRemovalDelay = { _ in .zero }

        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.stageExternalWrite(types: [concealed, .string], strings: [.string: "hunter2"])
        manager.monitor.check()

        // The user pins the item before the timeout elapses.
        let item = try #require(manager.items.first)
        manager.togglePin(item)
        #expect(manager.pinnedItems.count == 1)

        await manager.awaitPendingSecureRemovals()

        #expect(manager.items.isEmpty)
        #expect(manager.pinnedItems.isEmpty, "pinning must not let a password outlive its timeout")
    }

    // MARK: - Cap enforcement

    @Test("Size cap evicts the oldest non-pinned items on ingest")
    func maxHistorySizeCapEnforced() async {
        let (manager, pasteboard, _, settings) = makeRig()
        settings.maxHistorySize = 3

        for text in ["a", "b", "c", "d", "e"] {
            capture(text, on: pasteboard)
            manager.monitor.check()
        }
        await manager.flushPendingSaves()

        // Newest 3 survive, oldest evicted by `trimToMaxSize` inside ingest.
        #expect(manager.items.map(\.preview) == ["e", "d", "c"])
    }

    @Test("Pinned items survive the size cap")
    func pinnedSurviveCap() async {
        let (manager, pasteboard, _, settings) = makeRig()
        settings.maxHistorySize = 2

        capture("keep me", on: pasteboard)
        manager.monitor.check()
        // Pin the first one before the cap pushes it out.
        if let first = manager.items.first {
            manager.togglePin(first)
        }

        for text in ["b", "c", "d"] {
            capture(text, on: pasteboard)
            manager.monitor.check()
        }
        await manager.flushPendingSaves()

        #expect(manager.pinnedItems.map(\.preview) == ["keep me"])
        // Unpinned list capped at 2.
        #expect(manager.items.count == 2)
    }
}
