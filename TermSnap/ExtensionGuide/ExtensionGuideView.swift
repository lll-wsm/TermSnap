import SwiftUI

struct ExtensionGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Enable Finder Extension")
                .font(.headline)

            Text("To use \"Open Terminal Here\" in Finder's context menu, enable the TermSnap Finder Extension in System Settings.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Extensions-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)

            Button("I've Enabled It") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 340)
    }
}
