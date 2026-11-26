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
    /// The person's own marks on these projects (a note, "critical"); `Store.confirmMarks`. Empty when there are none.
    var marks: String = ""
    let onDeploy: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Put this live now?", "Jetzt live schalten?")).font(.headline).accessibilityAddTraits(.isHeader)
            ScrollView {
                Text(DeployConfirm.message(items, platforms: platforms) + DeployConfirm.headNote(items) + DeployConfirm.freshnessNote(items) + DeployConfirm.unchangedNote(items) + costNote + marks)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            HStack {
                Button(L("Copy list", "Liste kopieren")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DeployConfirm.message(items, platforms: platforms), forType: .string)
                }
                .buttonStyle(.link).font(.caption)
                .help(L("Copies the projects of this deploy as text", "Kopiert die Projekte dieses Deploys als Text"))
                Spacer()
                // Many projects or a red risk: Return must not be the way to go live; Cancel is the default then.
                let careful = items.count > 3 || items.contains { $0.risk?.isRed == true } || !marks.isEmpty
                Button(L("Cancel", "Abbrechen")) { dismiss() }.keyboardShortcut(careful ? .defaultAction : .cancelAction)
                Button(L("Deploy", "Deployen")) { onDeploy(); dismiss() }
                    .keyboardShortcut(careful ? KeyboardShortcut("d", modifiers: .command) : .defaultAction)
                    .accessibilityHint(careful ? L("Shortcut Command D", "Kurzbefehl Befehl D") : "")
                // Cancel is the default button then, so Esc needs its own: a hidden twin.
                if careful {
                    Button("") { dismiss() }.keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
