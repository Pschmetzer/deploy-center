// Deploy Center — Site logos: fetched from the site itself, kept on disk for a week.

import SwiftUI
import AppKit
import Charts
import UserNotifications
import ServiceManagement

// MARK: - Logos

extension NSImage {
    /// Mostly light and partly transparent: drawn on white it would vanish.
    var isLightOnClear: Bool {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        var lum = 0.0, weight = 0.0, clear = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let a = Double(px[i + 3]) / 255
            if a < 0.1 { clear += 1; continue }
            // premultiplied: divide by alpha to get the colour back
            let r = Double(px[i]) / 255 / a, g = Double(px[i + 1]) / 255 / a, b = Double(px[i + 2]) / 255 / a
            lum += (0.2126 * r + 0.7152 * g + 0.0722 * b) * a; weight += a
        }
        return clear > n * n / 8 && weight > 0 && lum / weight > 0.85
    }
}

/// Fetches the icon from the site itself (link rel="apple-touch-icon"/"icon", then the usual paths).
/// Without a domain or an icon: a letter on a colour derived from the name.
actor LogoCache {
    static let shared = LogoCache()
    private var cache: [String: NSImage?] = [:]

    /// Logos are kept on disk for a week; an empty file remembers "this site has none".
    private static let dir = Store.cacheDir.appendingPathComponent("logos", isDirectory: true)
    private static let week: TimeInterval = 7 * 24 * 3600

    /// Once at start: logos of sites not seen for a month go, so the folder does not grow for ever.
    nonisolated static func sweep() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files {
            let at = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(at) > 30 * 24 * 3600 { try? fm.removeItem(at: f) }
        }
    }

    /// After a network error the site is asked again at the earliest after this long.
    private static let retryAfter: TimeInterval = 10 * 60
    private var failedAt: [String: Date] = [:]

    /// Frontend and backend of one site ask for the same logo at once: the second waits for the first.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    func image(for domain: String) async -> NSImage? {
        if let hit = cache[domain] { return hit }
        if let running = inFlight[domain] { return await running.value }
        let task = Task { await self.load(domain) }
        inFlight[domain] = task
        let img = await task.value
        inFlight[domain] = nil
        return img
    }

    private func load(_ domain: String) async -> NSImage? {
        if let hit = cache[domain] { return hit }
        if let at = failedAt[domain], Date().timeIntervalSince(at) < Self.retryAfter { return stale(domain) }
        let file = Self.file(domain)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let at = attrs[.modificationDate] as? Date, Date().timeIntervalSince(at) < Self.week,
           let data = try? Data(contentsOf: file) {
            let img = data.isEmpty ? nil : NSImage(data: data)
            cache[domain] = img
            return img
        }
        let (img, data, transient) = await fetch(domain)
        if img == nil && transient {
            // Offline, a timeout, 429 or 5xx: that says nothing about the site. Keep what is on disk
            // (even if older than a week) and ask again later instead of remembering "none" for a week.
            failedAt[domain] = Date()
            return stale(domain)
        }
        failedAt[domain] = nil
        cache[domain] = img
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? (data ?? Data()).write(to: file, options: .atomic)
        return img
    }

    private static func file(_ domain: String) -> URL { dir.appendingPathComponent(domain.replacingOccurrences(of: "/", with: "_")) }

    /// The logo on disk, however old.
    private func stale(_ domain: String) -> NSImage? {
        guard let data = try? Data(contentsOf: Self.file(domain)), !data.isEmpty else { return nil }
        return NSImage(data: data)
    }

    /// The body on 200; `transient` when the answer says nothing about the site (no answer, 429, 5xx).
    /// `limit`: stop reading after that many bytes (the front page: its <head> is enough for the icon links).
    private func get(_ url: URL, limit: Int? = nil) async -> (data: Data?, transient: Bool) {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh) DeployCenter", forHTTPHeaderField: "User-Agent")
        let data: Data, resp: URLResponse
        if let limit {
            guard let (bytes, r) = try? await URLSession.shared.bytes(for: req) else { return (nil, true) }
            var d = Data()
            do {
                for try await b in bytes {
                    d.append(b)
                    if d.count >= limit { break }
                }
            } catch { if d.isEmpty { return (nil, true) } }
            bytes.task.cancel()
            data = d; resp = r
        } else {
            guard let (d, r) = try? await URLSession.shared.data(for: req) else { return (nil, true) }
            data = d; resp = r
        }
        guard let http = resp as? HTTPURLResponse else { return (nil, true) }
        if http.statusCode == 429 || http.statusCode >= 500 { return (nil, true) }
        return (http.statusCode == 200 && !data.isEmpty ? data : nil, false)
    }

    private func fetch(_ domain: String) async -> (NSImage?, Data?, transient: Bool) {
        guard let base = URL(string: "https://\(domain)/") else { return (nil, nil, false) }
        var candidates: [URL] = []
        let page = await get(base, limit: 64 * 1024)
        if page.transient { return (nil, nil, true) }
        // Cut at 64 KB, maybe inside a character: decoded leniently.
        if let html = page.data, case let text = String(decoding: html, as: UTF8.self), !text.isEmpty {
            candidates += Self.iconLinks(in: text).compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        }
        candidates += ["apple-touch-icon.png", "favicon.svg", "favicon.png", "favicon.ico"]
            .compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }
        var transient = false
        for url in candidates {
            let r = await get(url)
            transient = transient || r.transient
            if let data = r.data, let img = NSImage(data: data), img.size.width > 0 { return (img, data, false) }
        }
        return (nil, nil, transient)
    }

    /// apple-touch-icon first: it is large and square.
    static func iconLinks(in html: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"<link[^>]+>"#, options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        var touch: [String] = [], icons: [String] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            let lower = tag.lowercased()
            guard lower.contains("icon"), let href = attr("href", in: tag) else { continue }
            if lower.contains("apple-touch-icon") { touch.append(href) } else { icons.append(href) }
        }
        return touch + icons
    }

    private static func attr(_ name: String, in tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: name + #"\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        return (tag as NSString).substring(with: m.range(at: 1))
    }
}

struct Logo: View {
    let domain: String?
    let name: String
    @State private var image: NSImage?
    /// Measured once when the logo arrives, not on every redraw.
    @State private var lightOnClear = false
    @Environment(\.colorScheme) private var scheme
    @AppStorage("demoMode") private var demoMode = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .padding(3)
                    // A white logo on a transparent ground disappears on white; it gets a dark one.
                    // In dark mode a soft grey instead of a bright white tile.
                    .background(RoundedRectangle(cornerRadius: 8).fill(lightOnClear ? Color(white: 0.18) : (scheme == .dark ? Color(white: 0.88) : Color.white)))
            } else {
                RoundedRectangle(cornerRadius: 8).fill(color.gradient)
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Decoration: the name next to it is read out already.
        .accessibilityHidden(true)
        // In demo mode no real logo, also not the one fetched before demo mode was switched on.
        .task(id: demoMode ? nil : domain) {
            guard let domain, !demoMode else { image = nil; return }
            let img = await LogoCache.shared.image(for: domain)
            lightOnClear = img?.isLightOnClear ?? false
            image = img
        }
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .red, .mint, .cyan]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}
