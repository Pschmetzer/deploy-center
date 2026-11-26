// Deploy Center for iPhone — the card under the summary: open outages and the health score.

import SwiftUI

struct PhoneHealthCard: View {
    @ObservedObject var store: PhoneStore

    var body: some View {
        let outages = PhoneHealth.outages(store.projects, history: HistoryCache.load)
        let avg = PhoneHealth.average(store.projects, history: HistoryCache.load)
        if !outages.isEmpty || avg != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let avg {
                    Label(L("Health \(avg.score) of 100", "Zustand \(avg.score) von 100")
                          + " (" + (avg.score >= 80 ? L("good", "gut") : (avg.score >= 50 ? L("watch", "beobachten") : L("poor", "schlecht"))) + ") · "
                          + (avg.projects == 1 ? L("1 project read", "1 Projekt gelesen") : L("\(avg.projects) projects read", "\(avg.projects) Projekte gelesen")),
                          systemImage: avg.score >= 80 ? "heart.fill" : (avg.score >= 50 ? "heart" : "heart.slash"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(avg.score >= 80 ? Color.successText : (avg.score >= 50 ? Color.warningText : Color.errorText))
                }
                ForEach(outages) { o in
                    HStack {
                        Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red).accessibilityHidden(true)
                        Text(o.name).lineLimit(1)
                        Spacer()
                        if let s = o.since { Text(L("since ", "seit ") + relative(s)).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L("Outage: ", "Ausfall: ") + o.name + (o.since.map { L(", since ", ", seit ") + relative($0) } ?? ""))
                }
                Text(L("From the histories already loaded; open a project to read its history.", "Aus den schon geladenen Verläufen; ein Projekt öffnen, um seinen Verlauf zu lesen."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }
}
