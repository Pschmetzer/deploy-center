// Deploy Center — "Put this live now?": one question for every way a deploy starts by hand
// (the footer, a row, the palette), with a real checkbox for "Only when checks are green".

import SwiftUI

/// The question before a deploy. It never deploys by itself: Deploy calls `onDeploy`, and the caller
/// starts the deploy once the sheet is gone (its `onDismiss`), so a question that follows (a closed
/// deploy window) is not lost while this sheet is still closing.
struct DeployConfirmSheet: View {
    let items: [Item]
    /// Under "All": the same name can be on Vercel and on Render.
    let platforms: Bool
    let onDeploy: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// Remembered, and read by the window when the deploy starts.
    @AppStorage("onlyWhenGreen") private var onlyGreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Put this live now?", "Jetzt live schalten?")).font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView {
                Text(DeployConfirm.message(items, platforms: platforms) + DeployConfirm.unchangedNote(items))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            Toggle(L("Only when checks are green", "Nur wenn die Checks grün sind"), isOn: $onlyGreen)
                .toggleStyle(.checkbox)
                .help(L("Only commits whose checks passed go live", "Nur Commits mit bestandenen Checks gehen live"))
            HStack {
                Spacer()
                Button(L("Cancel", "Abbrechen")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Deploy", "Deployen")) { onDeploy(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
