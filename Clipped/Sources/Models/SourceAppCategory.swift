/// Groups of source apps the user can filter by. The bundle-ID databases live here so
/// both the monitor (for tagging dev content) and the filter (for bucketing by source)
/// read from the same source of truth.
enum SourceAppCategory: String, CaseIterable, Identifiable, Codable {
    case communication
    case browser
    case codeEditor
    case terminal

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .communication: "Chat"
        case .browser: "Browser"
        case .codeEditor: "Editor"
        case .terminal: "Terminal"
        }
    }

    var systemImage: String {
        switch self {
        case .communication: "bubble.left.and.bubble.right"
        case .browser: "safari"
        case .codeEditor: "chevron.left.forwardslash.chevron.right"
        case .terminal: "terminal"
        }
    }

    var settingsDescription: String {
        switch self {
        case .communication: "Slack, Messages, Mail, Teams, Discord, Telegram\u{2026}"
        case .browser: "Safari, Chrome, Firefox, Edge, Arc\u{2026}"
        case .codeEditor: "Xcode, VS Code, Cursor, Sublime, JetBrains, Zed\u{2026}"
        case .terminal: "Terminal, iTerm2, Ghostty, Saggar, Alacritty, kitty\u{2026}"
        }
    }

    var bundleIDs: Set<String> {
        switch self {
        case .communication:
            [
                "com.tinyspeck.slackmacgap", // Slack
                "com.apple.iChat", // Messages
                "com.apple.MobileSMS", // Messages (newer bundle)
                "com.apple.mail", // Mail
                "com.microsoft.teams", // Teams v1
                "com.microsoft.teams2", // Teams v2
                "com.microsoft.Outlook", // Outlook
                "com.readdle.smartemail-Mac", // Spark
                "com.hnc.Discord", // Discord
                "net.whatsapp.WhatsApp", // WhatsApp
                "ru.keepcoder.Telegram", // Telegram
                "com.tdesktop.Telegram", // Telegram Desktop
                "com.apple.FaceTime", // FaceTime
                "us.zoom.xos", // Zoom
            ]
        case .browser:
            [
                "com.apple.Safari",
                "com.apple.SafariTechnologyPreview",
                "com.google.Chrome",
                "com.google.Chrome.canary",
                "org.mozilla.firefox",
                "org.mozilla.firefoxdeveloperedition",
                "com.brave.Browser",
                "company.thebrowser.Browser", // Arc
                "com.microsoft.edgemac",
                "com.vivaldi.Vivaldi",
                "com.operasoftware.Opera",
            ]
        case .codeEditor:
            [
                "com.microsoft.VSCode",
                "com.microsoft.VSCodeInsiders",
                "com.apple.dt.Xcode",
                "com.sublimetext.4",
                "com.jetbrains.intellij",
                "com.jetbrains.pycharm",
                "com.jetbrains.WebStorm",
                "com.jetbrains.AppCode",
                "com.jetbrains.goland",
                "dev.zed.Zed",
                "com.todesktop.230313mzl4w4u92", // Cursor
                "com.github.atom",
                "com.panic.Nova",
            ]
        case .terminal:
            [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "io.alacritty",
                "com.github.wez.wezterm",
                "net.kovidgoyal.kitty",
                "dev.warp.Warp-Stable",
                "com.mitchellh.ghostty",
                "com.mcclowes.saggar",
            ]
        }
    }

    static func category(for bundleID: String) -> SourceAppCategory? {
        allCases.first { $0.bundleIDs.contains(bundleID) }
    }
}
