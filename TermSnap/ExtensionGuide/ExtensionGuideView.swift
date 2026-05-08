import SwiftUI

struct ExtensionGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(NSLocalizedString("Enable Finder Extension", comment: ""))
                .font(.headline)

            Text(NSLocalizedString("To use \"Open Terminal Here\" in Finder's context menu, enable the TermSnap Finder Extension in System Settings.", comment: ""))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button(NSLocalizedString("Open System Settings", comment: "")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Extensions-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)

            Button(NSLocalizedString("I've Enabled It", comment: "")) {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 340)
    }
}
