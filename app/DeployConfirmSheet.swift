// Deploy Center — "Put this live now?": one question for every way a deploy starts by hand
// (the footer, a row, the palette). A red CI never holds a deploy back: the row shows it, the person decides.

import SwiftUI

/// The question before a deploy. It never deploys by itself: Deploy calls `onDeploy`, and the caller
/// starts the deploy once the sheet is gone (its `onDismiss`), so a question that follows (a closed
/// deploy window) is not lost while this sheet is still closing.
struct DeployConfirmSheet: View {
    let items: [Item]
    /// Under "All": the same name can be on Vercel and on Render.
    let platforms: Bool
    /// What the builds cost and whether the budget holds (`Store.costNote`, already led by a blank line); empty when unknown.
    var costNote: String = ""
    let onDeploy: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Put this live now?", "Jetzt live schalten?")).font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView {
                Text(DeployConfirm.message(items, platforms: platforms) + DeployConfirm.unchangedNote(items) + costNote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
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
