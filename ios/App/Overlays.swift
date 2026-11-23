// Toast, the covers for screen recording and the lock, and the welcome page.

import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// A short note at the bottom. VoiceOver hears it; errors (and everything while VoiceOver runs)
/// stay until closed, other notes for a few seconds.
struct Toast: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject var store: PhoneStore
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            if store.messageIsError { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityHidden(true) }
            Text(text).font(.callout)
            Button { store.message = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close message", "Meldung schließen"))
                .accessibilityInputLabels([L("Close", "Schließen"), L("Dismiss", "Ausblenden")])
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 2)
        .background(reduceTransparency ? AnyShapeStyle(Color(.secondarySystemBackground)) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16).padding(.bottom, 12)
        .accessibilityElement(children: .contain)
        .task(id: store.messageSerial) {
            AccessibilityNotification.Announcement(store.messageIsError ? L("Error: ", "Fehler: ") + text : text).post()
            guard !store.messageIsError, !UIAccessibility.isVoiceOverRunning else { return }
            // Switch Control needs longer to reach the close button (IDEEN-12 C48).
            let slow = UIAccessibility.isSwitchControlRunning
            try? await Task.sleep(for: .seconds(slow ? 20 : 5))
            if store.message == text { store.message = nil }
        }
    }
}

/// Shown while the screen is recorded or mirrored.
struct CapturedCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "record.circle").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(L("Hidden while the screen is recorded", "Verdeckt, solange der Bildschirm aufgenommen wird"))
                    .font(.headline).multilineTextAlignment(.center)
            }.padding()
        }
    }
}

struct LockCover: View {
    @ObservedObject var store: PhoneStore
    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Deploy Center").font(.headline)
                if store.locked {
                    Button(L("Unlock", "Entsperren")) { Task { await store.unlock() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await store.unlock() }   // at launch; on return the scene phase asks
    }
}

struct Welcome: View {
    @ObservedObject var store: PhoneStore
    @Binding var settings: Bool
    @Binding var connect: Bool
    var body: some View {
        ContentUnavailableView {
            Label(L("Your deploys, on the go", "Deine Deploys, unterwegs"), systemImage: "paperplane.fill")
        } description: {
            Text(L("Connect to Deploy Center on your Mac, or add a Vercel token or a Render API key. Keys go only to Vercel, Render and GitHub.",
                   "Verbinde dich mit Deploy Center auf deinem Mac, oder füge ein Vercel-Token oder einen Render-API-Key hinzu. Schlüssel gehen nur an Vercel, Render und GitHub."))
            Text(L("A Vercel token needs the scope of the team whose projects you want to see. A Render API key sees every workspace of its account.",
                   "Ein Vercel-Token braucht als Bereich das Team, dessen Projekte du sehen willst. Ein Render-API-Key sieht alle Workspaces seines Kontos."))
                .font(.footnote)
        } actions: {
            Button(L("Connect to the Mac", "Mit dem Mac verbinden")) { connect = true }.buttonStyle(.borderedProminent)
            Button(L("Enter a token", "Token eingeben")) { settings = true }
            Link(L("Create a Vercel token", "Vercel-Token anlegen"), destination: URL(string: "https://vercel.com/account/tokens")!)
            Link(L("Create a Render API key", "Render-API-Key anlegen"), destination: URL(string: "https://dashboard.render.com/u/settings#api-keys")!)
            Button(L("Try the demo", "Demo ausprobieren")) { store.demo = true }
        }
    }
}
