// Deploy Center — The costs sheet and the saving picture that can be shared from it.

import SwiftUI
import AppKit
import Charts

/// What VoiceOver's chart reader (Audio Graphs) gets: one value per day.
struct CostChartDescriptor: AXChartDescriptorRepresentable {
    let days: [Costs.Day]
    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXCategoricalDataAxisDescriptor(title: L("Day", "Tag"), categoryOrder: days.map(\.day))
        let top = max(1, days.map(\.build).max() ?? 1)
        let y = AXNumericDataAxisDescriptor(title: "USD", range: 0...top, gridlinePositions: []) { $0.formatted(.currency(code: "USD")) }
        let series = AXDataSeriesDescriptor(name: L("Build costs", "Build-Kosten"), isContinuous: false,
                                            dataPoints: days.map { .init(x: $0.day, y: $0.build) })
        return AXChartDescriptor(title: L("Vercel build costs per day", "Vercel-Build-Kosten pro Tag"),
                                 summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

struct CostsSheet: View {
    let costs: Costs
    @Environment(\.dismiss) private var dismiss
    @State private var hovered: String?
    @State private var sharing = false
    /// Settings → Costs; 0 = no budget, then neither the line nor the sentence.
    @AppStorage("monthlyBudget") private var budget = 0.0
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
    /// Today as the billing data names days (UTC).
    static func today() -> String { dayFormat.string(from: Date()) }
    private var last7: [Costs.Day] { Array(costs.days.suffix(7)) }
    private var average: Double { Self.dailyPace(costs.days, today: Self.today()) }

    /// Build costs per day at the current pace: the last 7 whole days. Today is not over yet and
    /// would pull the average down.
    static func dailyPace(_ days: [Costs.Day], today: String) -> Double {
        let whole = Array(days.filter { $0.day != today }.suffix(7))
        return whole.isEmpty ? 0 : whole.map(\.build).reduce(0, +) / Double(whole.count)
    }

    /// Days in the month of `today` ("yyyy-MM-dd", UTC like the billing data); 30 when unreadable.
    static func daysInMonth(_ today: String) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let d = dayFormat.date(from: today), let r = cal.range(of: .day, in: .month, for: d) else { return 30 }
        return r.count
    }

    /// The sentence under the costs when a monthly budget is set. With the 1st of the month in the
    /// data (the sheet reads 14 days): what is left until the month ends. Otherwise the pace of the
    /// last 7 whole days against the budget. Nil without a budget or without data.
    static func budgetLine(budget: Double, days: [Costs.Day], today: String) -> (text: String, over: Bool)? {
        guard budget > 0 else { return nil }
        let usd = FloatingPointFormatStyle<Double>.Currency(code: "USD")
        let b = budget.formatted(usd), month = String(today.prefix(7))
        if days.contains(where: { $0.day == month + "-01" }) {
            let spent = days.filter { $0.day.hasPrefix(month) && $0.day <= today }.map(\.build).reduce(0, +)
            let left = budget - spent
            if left >= 0 {
                return (L("Budget \(b): \(left.formatted(usd)) left until the end of the month (\(spent.formatted(usd)) so far)",
                          "Budget \(b): noch \(left.formatted(usd)) bis Monatsende (bisher \(spent.formatted(usd)))"), false)
            }
            return (L("Budget \(b): \((-left).formatted(usd)) over this month", "Budget \(b): diesen Monat \((-left).formatted(usd)) darüber"), true)
        }
        guard let pace = Store.monthPace(days, today: today) else { return nil }
        let diff = abs(budget - pace).formatted(usd)
        return pace <= budget
            ? (L("Budget \(b) a month: ≈ \(diff) to spare at this pace", "Budget \(b) im Monat: bei diesem Tempo ≈ \(diff) Luft"), false)
            : (L("Budget \(b) a month: ≈ \(diff) over at this pace", "Budget \(b) im Monat: bei diesem Tempo ≈ \(diff) darüber"), true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Costs", "Kosten")).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            summary
            chart
            ranking
            Text(L("From Vercel's billing data. Total incl. other usage, 7 days: ", "Aus Vercels Abrechnung. Gesamt inkl. sonstiger Nutzung, 7 Tage: ")
                 + last7.map(\.total).reduce(0, +).formatted(.currency(code: "USD")))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Done", "Fertig")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Vercel builds, last 7 days", "Vercel-Builds, letzte 7 Tage")).font(.caption).foregroundStyle(.secondary)
            Text(costs.week, format: .currency(code: "USD")).font(.title3.weight(.semibold).monospacedDigit())
            Text(L("≈ ", "≈ ") + (average * 30).formatted(.currency(code: "USD")) + L(" a month at this pace", " im Monat bei diesem Tempo"))
                .font(.caption).foregroundStyle(.secondary)
                .help(L("From the last 7 whole days; today is not over yet", "Aus den letzten 7 ganzen Tagen; heute ist noch nicht vorbei"))
            if let s = costs.saving(today: Self.today()) {
                Text(L("per day: ", "pro Tag: ") + s.before.formatted(.currency(code: "USD")) + L(" before, ", " vorher, ")
                     + s.after.formatted(.currency(code: "USD")) + L(" since", " seitdem"))
                    .font(.caption.weight(.medium)).foregroundStyle(s.after < s.before ? .green : .orange)
                if s.after < s.before {
                    Button(L("Share the saving …", "Ersparnis teilen …")) { sharing = true }
                        .buttonStyle(.link).font(.caption)
                        .popover(isPresented: $sharing) { SavingShare(before: s.before, after: s.after) }
                        .help(L("Copies a picture and a sentence with your saving, without project names",
                                "Kopiert ein Bild und einen Satz mit deiner Ersparnis, ohne Projektnamen"))
                }
            } else if let off = costs.offDay {
                Text(L("Auto-deploy off since \(off); the saving shows after a full day", "Auto-Deploy aus seit \(off); die Ersparnis zeigt sich nach einem ganzen Tag"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let line = Self.budgetLine(budget: budget, days: costs.days, today: Self.today()) {
                Text(line.text).font(.caption.weight(.medium)).foregroundStyle(line.over ? Color.warningText : .secondary)
            }
        }
    }

    /// The projects that cost the most this week.
    @ViewBuilder private var ranking: some View {
        let top = costs.projects.filter { $0.build > 0 }.sorted { $0.build > $1.build }.prefix(8)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("By project, 7 days", "Nach Projekt, 7 Tage")).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(top), id: \.name) { p in
                    HStack {
                        Text(Demo.mask(p.name)).lineLimit(1)
                        Spacer()
                        if let n = p.builds { Text(L("\(n) builds", "\(n) Builds")).foregroundStyle(.secondary) }
                        Text(p.build, format: .currency(code: "USD")).monospacedDigit()
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var chart: some View {
        let today = Self.today()
        // The budget as a day's share of it, so it sits on the same scale as the bars.
        let daily = budget > 0 ? budget / Double(Self.daysInMonth(today)) : 0
        return VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(costs.days) { d in
                    // A day over twice the average stands out; today is lighter: it is not over yet.
                    BarMark(x: .value("Day", String(d.day.suffix(2))), y: .value("USD", d.build))
                        .foregroundStyle(d.build > 2 * average && average > 0 ? Color.orange.gradient : Color.accentColor.gradient)
                        .opacity(d.day == today ? 0.45 : 1)
                    if let off = costs.offDay, d.day == off {
                        RuleMark(x: .value("Day", String(d.day.suffix(2)))).foregroundStyle(.green).lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    }
                }
                if daily > 0 {
                    RuleMark(y: .value("USD", daily)).foregroundStyle(.red.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel() } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel() } }
            .chartXSelection(value: $hovered)
            .overlay(alignment: .topTrailing) {
                // The value of the day under the pointer, with its full date.
                if let h = hovered, let d = costs.days.first(where: { String($0.day.suffix(2)) == h }) {
                    Text(d.day + ": " + d.build.formatted(.currency(code: "USD")) + (d.day == today ? L(" (so far)", " (bisher)") : ""))
                        .font(.caption2.monospacedDigit()).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
                }
            }
            .frame(height: 140)
            .accessibilityChartDescriptor(CostChartDescriptor(days: costs.days))
            // What the chart spans (14 days, the total above is 7), and what its colours mean.
            HStack(spacing: 10) {
                Text(L("last \(costs.days.count) days", "letzte \(costs.days.count) Tage"))
                HStack(spacing: 3) { RoundedRectangle(cornerRadius: 1).fill(Color.orange).frame(width: 7, height: 7); Text(L("over 2× the average", "über 2× Schnitt")) }
                if costs.days.contains(where: { $0.day == today }) {
                    HStack(spacing: 3) { RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.45)).frame(width: 7, height: 7); Text(L("today, so far", "heute, bisher")) }
                }
                if costs.offDay != nil {
                    HStack(spacing: 3) { Rectangle().fill(Color.green).frame(width: 7, height: 1.5); Text(L("auto-deploy off", "Auto-Deploy aus")) }
                }
                if daily > 0 {
                    HStack(spacing: 3) { Rectangle().fill(Color.red.opacity(0.7)).frame(width: 7, height: 1.5); Text(L("budget per day", "Budget pro Tag")) }
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The picture before it goes anywhere: copy it, save it as PNG, or hand it to the share menu.
struct SavingShare: View {
    let before: Double, after: Double
    @State private var copied = false
    /// Rendered once when the popover opens, not on every redraw.
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SavingCard(before: before, after: after).scaleEffect(0.7).frame(width: 364, height: 200)
            Text(SavingCard.text(before: before, after: after)).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).frame(width: 364, alignment: .leading)
            HStack {
                Button(copied ? L("Copied ✓", "Kopiert ✓") : L("Copy picture and text", "Bild und Text kopieren")) {
                    SavingCard.copy(before: before, after: after, image: image); copied = true
                    // Back to its words after a moment, like the other copy buttons.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Button(L("Save as PNG …", "Als PNG sichern …")) { save() }
                if let img = image {
                    ShareLink(item: Image(nsImage: img), subject: Text("Deploy Center"),
                              message: Text(SavingCard.text(before: before, after: after)),
                              preview: SharePreview(L("Build cost saving", "Build-Ersparnis"), image: Image(nsImage: img)))
                }
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).frame(width: 364, alignment: .leading)
            }
        }
        .padding(16)
        .onAppear { if image == nil { image = SavingCard.render(before: before, after: after) } }
    }

    @State private var saveError: String?

    private func save() {
        saveError = nil
        guard let img = image, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            saveError = L("The picture could not be made.", "Das Bild ließ sich nicht erzeugen."); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = L("deploy-center-saving.png", "deploy-center-ersparnis.png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Not silent: no rights in the folder, a full disk.
        do { try png.write(to: url) } catch {
            saveError = L("Not saved: ", "Nicht gesichert: ") + error.localizedDescription
        }
    }
}

/// A picture of the saving to post somewhere: two numbers and the app's name, nothing about the projects.
struct SavingCard: View {
    let before: Double, after: Double
    private var month: Double { max(0, before - after) * 30 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill").foregroundStyle(.white)
                    .padding(7).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                Text("Deploy Center").font(.headline).foregroundStyle(.white)
            }
            Text(L("My build bill since I turned off auto-deploy", "Meine Build-Kosten, seit Auto-Deploy aus ist"))
                .font(.title3.weight(.semibold)).foregroundStyle(.white)
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading) {
                    Text(L("before", "vorher")).font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text(before, format: .currency(code: "USD")).font(.title.weight(.bold).monospacedDigit()).foregroundStyle(.red.opacity(0.9))
                    Text(L("a day", "pro Tag")).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.5))
                VStack(alignment: .leading) {
                    Text(L("now", "jetzt")).font(.caption).foregroundStyle(.white.opacity(0.6))
                    Text(after, format: .currency(code: "USD")).font(.title.weight(.bold).monospacedDigit()).foregroundStyle(.green)
                    Text(L("a day", "pro Tag")).font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
            Text(L("≈ ", "≈ ") + month.formatted(.currency(code: "USD").precision(.fractionLength(0))) + L(" a month saved", " im Monat gespart"))
                .font(.title2.weight(.bold)).foregroundStyle(.white)
            Text("github.com/Pschmetzer/deploy-center").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .padding(28).frame(width: 520, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.18, green: 0.11, blue: 0.32)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    /// The sentence that goes with the picture.
    static func text(before: Double, after: Double) -> String {
        let m = (max(0, before - after) * 30).formatted(.currency(code: "USD").precision(.fractionLength(0)))
        return L("I turned off auto-deploy and now deploy by hand: builds went from \(before.formatted(.currency(code: "USD"))) to \(after.formatted(.currency(code: "USD"))) a day, about \(m) a month saved. https://github.com/Pschmetzer/deploy-center",
                 "Ich habe Auto-Deploy ausgeschaltet und deploye jetzt von Hand: Builds von \(before.formatted(.currency(code: "USD"))) auf \(after.formatted(.currency(code: "USD"))) am Tag, etwa \(m) im Monat gespart. https://github.com/Pschmetzer/deploy-center")
    }

    /// Picture and sentence on the clipboard at once; a chat or post takes whichever it can.
    @MainActor static func render(before: Double, after: Double) -> NSImage? {
        let r = ImageRenderer(content: SavingCard(before: before, after: after)); r.scale = 2
        return r.nsImage
    }

    @MainActor static func copy(before: Double, after: Double, image: NSImage? = nil) {
        let pb = NSPasteboard.general; pb.clearContents()
        var items: [NSPasteboardWriting] = [text(before: before, after: after) as NSString]
        if let img = image ?? render(before: before, after: after) { items.insert(img, at: 0) }
        pb.writeObjects(items)
    }
}
