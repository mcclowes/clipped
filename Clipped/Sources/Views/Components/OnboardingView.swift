import Carbon
import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case shortcut
    case transformations
    case launchAtLogin
    case ready
}

struct OnboardingView: View {
    @Environment(SettingsManager.self) private var settings
    @State private var step: OnboardingStep = .welcome
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 8)

            Spacer()

            // Step content
            Group {
                switch step {
                case .welcome: welcomeStep
                case .shortcut: shortcutStep
                case .transformations: transformationsStep
                case .launchAtLogin: launchStep
                case .ready: readyStep
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            Spacer()

            // Navigation
            HStack {
                if step != .welcome {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if step == .ready {
                    Button("Open Clipped") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("Continue") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            step = OnboardingStep(rawValue: step.rawValue + 1) ?? .ready
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)
        }
        .frame(width: 480, height: 400)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "clipboard.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            Text("Welcome to Clipped")
                .font(.title.bold())

            Text("A lightweight clipboard manager that lives in your menu bar.\nEverything stays on your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
    }

    private var shortcutStep: some View {
        @Bindable var settings = settings

        return VStack(spacing: 16) {
            Image(systemName: "keyboard")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            Text("Open from anywhere")
                .font(.title2.bold())

            Text("Press this shortcut to open your clipboard history from any app.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            KeyRecorderView(
                keyCode: $settings.hotkeyKeyCode,
                modifiers: $settings.hotkeyModifiers,
                onChanged: {
                    HotkeyManager.shared.reregister(
                        id: .panel,
                        keyCode: settings.hotkeyKeyCode,
                        modifiers: settings.hotkeyModifiers
                    )
                }
            )
            .padding(.top, 4)
        }
        .padding(.horizontal, 40)
    }

    private var transformationsStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            Text("Auto-clean your clipboard")
                .font(.title2.bold())

            Text("Clipped can automatically tidy up what you copy.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                transformationRow(
                    icon: "link.badge.plus",
                    title: "Strip tracking parameters",
                    detail: "Removes utm_source, fbclid, and other trackers from URLs"
                )
                transformationRow(
                    icon: "text.justify.leading",
                    title: "Trim whitespace",
                    detail: "Cleans up extra spaces and newlines"
                )
                transformationRow(
                    icon: "curlybraces",
                    title: "Detect code snippets",
                    detail: "Tags developer content for easy filtering"
                )
            }
            .padding(.top, 4)

            Text("You can configure these in settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 40)
    }

    private func transformationRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var launchStep: some View {
        @Bindable var settings = settings

        return VStack(spacing: 16) {
            Image(systemName: "sunrise")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            Text("Start automatically")
                .font(.title2.bold())

            Text("Launch Clipped when you log in so your clipboard history is always available.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .toggleStyle(.switch)
                .padding(.top, 4)
                .frame(width: 200)
        }
        .padding(.horizontal, 40)
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)

            Text("You're all set")
                .font(.title.bold())

            Text(
                "Look for the clipboard icon in your menu bar. Copy anything and it'll appear there.\n\nUse \(HotkeyManager.shared.displayString(for: .panel)) to open from anywhere."
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40)
    }
}
