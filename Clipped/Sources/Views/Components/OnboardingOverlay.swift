import SwiftUI

struct OnboardingOverlay: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "clipboard.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)

                Text("Welcome to Clipped")
                    .font(.headline)

                Text(
                    "Your clipboard history lives up here in the menu bar. Copy anything and it'll appear in this panel.\n\nUse \(HotkeyManager.displayString) to open from anywhere."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                Button("Get Started") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 280)
            .background(.regularMaterial)
            .clipShape(.rect(cornerRadius: 16))
            .shadow(radius: 20)
        }
        .transition(.opacity)
    }
}
