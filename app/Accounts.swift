// Deploy Center — several accounts per host with a switcher. The names of the accounts are plain
// settings; every key lives only in the keychain. Switching hands the chosen key to the script
// (`deploys <host> set-key`, key on stdin), which tries it first and saves it only when the host
// takes it. The app never puts a key on a command line or into a log.

import SwiftUI
import Security

protocol SecretStore {
    func read(service: String, account: String) -> String?
    func write(_ secret: String, service: String, account: String) -> Bool
    func delete(service: String, account: String)
}

struct KeychainSecrets: SecretStore {
    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(service: String, account: String) -> String? {
        var q = query(service, account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    func write(_ secret: String, service: String, account: String) -> Bool {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(service, account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var q = query(service, account); q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    func delete(service: String, account: String) { SecItemDelete(query(service, account) as CFDictionary) }
}

enum Accounts {
    static func service(_ host: String) -> String { "deploy-center-accounts-" + host }
    private static func namesKey(_ host: String) -> String { "accounts.names." + host }
    private static func activeKey(_ host: String) -> String { "accounts.active." + host }

    /// A label: letters, digits, spaces, dots, dashes, at most 40 characters; no key can sneak in as a name.
    static func cleanLabel(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 40, t.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " .-_".unicodeScalars.contains($0) }) else { return nil }
        return t
    }
    /// A key as the hosts' keys look: no spaces, quotes or backslashes (the script refuses them as well).
    static func cleanKey(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) && $0 != "'" && $0 != "\"" && $0 != "\\" }) else { return nil }
        return t
    }

    static func names(_ host: String, _ d: UserDefaults = .standard) -> [String] { d.stringArray(forKey: namesKey(host)) ?? [] }
    static func active(_ host: String, _ d: UserDefaults = .standard) -> String? { d.string(forKey: activeKey(host)) }

    /// Adds an account. The first one becomes the active one (it is the key the script already uses only when
    /// the person saved it with the same key; switching is what hands it over). False when the label or key is
    /// unusable, the label exists or the keychain refused.
    @discardableResult
    static func add(host: String, label: String, key: String, secrets: SecretStore = KeychainSecrets(), _ d: UserDefaults = .standard) -> Bool {
        guard let l = cleanLabel(label), let k = cleanKey(key), !names(host, d).contains(l) else { return false }
        guard secrets.write(k, service: service(host), account: l) else { return false }
        d.set(names(host, d) + [l], forKey: namesKey(host))
        return true
    }

    static func remove(host: String, label: String, secrets: SecretStore = KeychainSecrets(), _ d: UserDefaults = .standard) {
        secrets.delete(service: service(host), account: label)
        d.set(names(host, d).filter { $0 != label }, forKey: namesKey(host))
        if active(host, d) == label { d.removeObject(forKey: activeKey(host)) }
    }

    /// The key of an account, for the hand-over only.
    static func key(host: String, label: String, secrets: SecretStore = KeychainSecrets()) -> String? {
        secrets.read(service: service(host), account: label)
    }

    static func markActive(host: String, label: String, _ d: UserDefaults = .standard) {
        if names(host, d).contains(label) { d.set(label, forKey: activeKey(host)) }
    }

    /// Hands the account's key to the script. Nil on success, else a message (never with the key in it).
    static func activate(host: String, label: String, secrets: SecretStore = KeychainSecrets(), _ d: UserDefaults = .standard) async -> String? {
        guard let key = key(host: host, label: label, secrets: secrets) else {
            return L("The key of this account is not in the keychain any more.", "Der Schlüssel dieses Kontos ist nicht mehr im Schlüsselbund.")
        }
        do {
            _ = try await Tool.run([host, "set-key"], stdin: key, timeout: 60)
            markActive(host: host, label: label, d)
            return nil
        } catch {
            return error.localizedDescription.replacingOccurrences(of: key, with: "…")
        }
    }
}

/// In Settings → Platforms: the accounts of each host that works with a key, and the switch.
struct AccountsCard: View {
    @ObservedObject var store: Store
    @State private var host = ""
    @State private var label = ""
    @State private var key = ""
    @State private var message: String?
    @State private var tick = 0

    private var hosts: [ProviderInfo] { store.enabledProviders.filter { $0.id != "vercel" } }

    var body: some View {
        if !hosts.isEmpty {
            Section(L("Accounts", "Konten")) {
                ForEach(hosts) { h in
                    let names = Accounts.names(h.id), active = Accounts.active(h.id)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(h.label).font(.callout.weight(.semibold))
                        ForEach(names, id: \.self) { n in
                            HStack {
                                Image(systemName: n == active ? "checkmark.circle.fill" : "circle").foregroundStyle(n == active ? Color.good : Color.secondary).accessibilityHidden(true)
                                Text(n)
                                Spacer()
                                if n != active {
                                    Button(L("Switch", "Wechseln")) {
                                        Task { guard await OwnerCheck.confirm(L("switch the \(h.id) account to \(n)", "das \(h.id)-Konto auf \(n) umschalten")) else { return }
                                            message = await Accounts.activate(host: h.id, label: n); tick += 1; if message == nil, let p = Platform.allCases.first(where: { $0.cli == h.id }) { await store.load(p, fresh: true) } }
                                    }
                                }
                                Button(role: .destructive) { Accounts.remove(host: h.id, label: n); tick += 1 } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).accessibilityLabel(L("Remove account \(n)", "Konto \(n) entfernen"))
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(n == active ? L("active", "aktiv") : "")
                        }
                        if host == h.id {
                            TextField(L("Name, e.g. Work", "Name, z. B. Arbeit"), text: $label)
                            SecureField(L("API key (saved in the keychain only)", "API-Schlüssel (nur im Schlüsselbund)"), text: $key)
                            HStack {
                                Button(L("Save account", "Konto speichern")) {
                                    if Accounts.add(host: h.id, label: label, key: key) { label = ""; key = ""; host = ""; message = nil }
                                    else { message = L("Name or key not usable, or the name exists.", "Name oder Schlüssel unbrauchbar, oder der Name existiert schon.") }
                                    tick += 1
                                }
                                Button(L("Cancel", "Abbrechen")) { host = ""; label = ""; key = "" }
                            }
                        } else {
                            Button(L("Add an account …", "Konto hinzufügen …")) { host = h.id }.buttonStyle(.link)
                        }
                    }
                    .id(tick)
                }
                if let m = message { ErrorText(m) }
                Text(L("Keys stay in the macOS keychain. Switching saves the key for the script, which tries it first.",
                       "Schlüssel bleiben im macOS-Schlüsselbund. Beim Wechsel wird der Schlüssel fürs Skript gespeichert; es prüft ihn zuerst."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
