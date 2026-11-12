// Deploy Center for iPhone — Connect to the Mac app: through iCloud Keychain, or by scanning (or
// pasting) the code the Mac shows for a minute. The keys never pass a server of ours.

import AVFoundation
import SwiftUI

struct ConnectMacView: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var scanning = false
    @State private var scanError: String?
    @State private var cameraDenied = false
    @State private var checking = false
    @State private var nothingYet = false
    @State private var found: LinkedKeys?
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                if store.linked != nil {
                    Section {
                        Label(L("Connected to the Mac", "Mit dem Mac verbunden"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if let at = store.linked?.updated {
                            Text(L("Keys from ", "Schlüssel vom ") + at.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale)))
                                .foregroundStyle(.secondary)
                        }
                        Toggle(L("Do not use them on this iPhone", "Auf diesem iPhone nicht nutzen"), isOn: $store.ignoreLink)
                    } footer: {
                        Text(L("To disconnect every device, turn off \"Connect the iPhone app\" in the Mac app's Settings → iPhone.",
                               "Zum Trennen aller Geräte in der Mac-App unter Einstellungen → iPhone \"Mit der iPhone-App verbinden\" ausschalten."))
                    }
                }
                if let k = found {
                    Section {
                        Text(Self.describe(k))
                        Button(L("Connect", "Verbinden")) {
                            if store.adopt(k) { dismiss() }
                            found = nil
                        }
                        .buttonStyle(.borderedProminent)
                        Button(L("Discard", "Verwerfen"), role: .cancel) { found = nil }
                    } header: { Text(L("Code read", "Code gelesen")) } footer: {
                        Text(L("The keys replace the ones typed on this iPhone. Fields the code leaves empty stay as they are.",
                               "Die Schlüssel ersetzen die auf diesem iPhone eingetragenen. Felder, die der Code leer lässt, bleiben, wie sie sind."))
                    }
                }
                Section {
                    if store.linkAvailable {
                        Text(L("1. On the Mac, open Deploy Center → Settings → iPhone.\n2. Turn on \"Connect the iPhone app (iCloud Keychain)\".\n3. This iPhone needs the same Apple ID, with iCloud Keychain (Passwords) on.",
                               "1. Auf dem Mac Deploy Center → Einstellungen → iPhone öffnen.\n2. \"Mit der iPhone-App verbinden (iCloud-Schlüsselbund)\" einschalten.\n3. Dieses iPhone braucht dieselbe Apple-ID, mit eingeschaltetem iCloud-Schlüsselbund (Passwörter)."))
                        Button { Task { await check() } } label: {
                            HStack { Text(L("Check again", "Erneut prüfen")); if checking { Spacer(); ProgressView() } }
                        }
                        if nothingYet && store.linked == nil {
                            Text(L("Nothing arrived yet. This view keeps checking every few seconds.",
                                   "Noch nichts angekommen. Diese Ansicht prüft alle paar Sekunden weiter."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(L("Not available in this build of the app: use the code below.",
                               "In diesem Build der App nicht verfügbar: nimm den Code unten."))
                            .foregroundStyle(.secondary)
                    }
                } header: { Text(L("With your Apple ID", "Mit deiner Apple-ID")) } footer: {
                    if store.linkAvailable {
                        Text(L("iCloud Keychain can take a minute to bring the keys over. End-to-end encrypted, no server of ours.",
                               "Der iCloud-Schlüsselbund braucht manchmal eine Minute. Ende-zu-Ende-verschlüsselt, ohne Server von uns."))
                    }
                }
                Section {
                    Button(L("Scan the code …", "Code scannen …")) { scanError = nil; cameraDenied = false; scanning = true }
                    // Without a camera (or with VoiceOver): the code's text, copied on the Mac.
                    PasteButton(payloadType: String.self) { texts in
                        Task { @MainActor in handle(texts.first ?? "") }
                    }
                    if let e = scanError { Text(e).foregroundStyle(.red) }
                    if cameraDenied { Button(L("Open Settings …", "Einstellungen öffnen …")) { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } } }
                } header: { Text(L("With a QR code", "Mit einem QR-Code")) } footer: {
                    Text(L("On the Mac: Settings → iPhone → Show a QR code for the iPhone. The code holds your keys and works for a few minutes; the keys are then kept on this iPhone only.",
                           "Auf dem Mac: Einstellungen → iPhone → QR-Code fürs iPhone zeigen. Der Code enthält deine Schlüssel und gilt einige Minuten; die Schlüssel bleiben dann nur auf diesem iPhone."))
                }
                Section {
                    Button(L("Delete the keys on this iPhone …", "Schlüssel auf diesem iPhone löschen …"), role: .destructive) { confirmForget = true }
                } footer: {
                    Text(L("Removes every key typed or scanned here. To make a key useless everywhere, delete it at Vercel, Render or GitHub.",
                           "Entfernt jeden hier eingetragenen oder gescannten Schlüssel. Um einen Schlüssel überall unbrauchbar zu machen, lösche ihn bei Vercel, Render oder GitHub."))
                }
            }
            .navigationTitle(L("Connect to the Mac", "Mit dem Mac verbinden"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done", "Fertig")) { dismiss() } } }
            .confirmationDialog(L("Delete the keys on this iPhone?", "Schlüssel auf diesem iPhone löschen?"), isPresented: $confirmForget, titleVisibility: .visible) {
                Button(L("Delete", "Löschen"), role: .destructive) { store.forgetOwnKeys() }
                Button(L("Cancel", "Abbrechen"), role: .cancel) {}
            }
            // While nothing came from the Mac, look again every five seconds.
            .task {
                guard store.linkAvailable else { return }
                while !Task.isCancelled && store.linked == nil {
                    try? await Task.sleep(for: .seconds(5))
                    await store.refreshLink()
                    if store.linked != nil { await store.reload() }
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                QRScanner { text in
                    scanning = false
                    handle(text)
                } cancel: { error, denied in
                    scanning = false
                    scanError = error; cameraDenied = denied
                }
                .ignoresSafeArea()
            }
        }
    }

    private func check() async {
        checking = true; defer { checking = false }
        store.useLinkAgain()    // the person wants the Mac link back, also after "Remove all keys"
        await store.refreshLink()
        nothingYet = store.linked == nil
        if store.linked != nil { await store.reload(); dismiss() }
    }

    private func handle(_ text: String) {
        switch PhoneLink.read(qr: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .keys(let k):
            found = k; scanError = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .notOurs: scanError = L("That is not a Deploy Center code.", "Das ist kein Deploy-Center-Code.")
        case .newerVersion: scanError = L("This code comes from a newer Mac app. Update Deploy Center on this iPhone.",
                                          "Dieser Code kommt von einer neueren Mac-App. Aktualisiere Deploy Center auf diesem iPhone.")
        case .expired: scanError = L("This code is too old. Show a new one on the Mac (and check that both clocks are right).",
                                     "Dieser Code ist zu alt. Zeig auf dem Mac einen neuen (und prüfe, dass beide Uhren stimmen).")
        case .empty: scanError = L("The code holds no Vercel or Render key.", "Der Code enthält keinen Vercel- oder Render-Schlüssel.")
        }
        if let e = scanError {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            AccessibilityNotification.Announcement(e).post()
        }
    }

    /// "Vercel, Render and GitHub, from the Mac at 14:05": what a code holds, never the keys.
    static func describe(_ k: LinkedKeys) -> String {
        var parts: [String] = []
        if !k.vercel.isEmpty { parts.append(k.vercelTeam.isEmpty ? "Vercel" : L("Vercel (with team)", "Vercel (mit Team)")) }
        if !k.render.isEmpty { parts.append("Render") }
        if !k.github.isEmpty { parts.append("GitHub") }
        let time = k.updated.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(appLocale))
        return parts.joined(separator: ", ") + L(", from the Mac at \(time).", ", vom Mac um \(time).")
    }
}

/// The camera, reading one QR code.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    let cancel: (String?, Bool) -> Void      // message, and whether camera access was refused

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController(); c.found = found; c.cancel = cancel; return c
    }
    func updateUIViewController(_ c: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        var cancel: ((String?, Bool) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var camera: AVCaptureDevice?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            let close = button(L("Cancel", "Abbrechen")) { [weak self] in self?.finish { $0.cancel?(nil, false) } }
            let toggle: () -> Void = { [weak self] in self?.toggleTorch() }
            // What to do, for everyone and for VoiceOver: the camera picture alone says nothing.
            let hint = UILabel()
            hint.text = L("Point the camera at the code on the Mac.", "Richte die Kamera auf den Code am Mac.")
            hint.textColor = .white
            hint.font = .preferredFont(forTextStyle: .body)
            hint.adjustsFontForContentSizeCategory = true
            hint.numberOfLines = 0
            hint.textAlignment = .center
            hint.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            hint.layer.cornerRadius = 10
            hint.clipsToBounds = true
            hint.translatesAutoresizingMaskIntoConstraints = false
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    // Canceled while iOS asked: start nothing.
                    guard !self.done else { return }
                    guard ok else {
                        self.finish { $0.cancel?(L("No camera access. Allow it in Settings → Deploy Center, or paste the code.",
                                                   "Kein Zugriff auf die Kamera. Erlaube ihn unter Einstellungen → Deploy Center, oder füge den Code ein."), true) }
                        return
                    }
                    self.start()
                    self.view.addSubview(close)
                    var c = [close.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
                             close.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 12)]
                    if self.camera?.hasTorch == true {
                        let torch = self.button(L("Light", "Licht"), toggle)
                        torch.accessibilityLabel = L("Flashlight", "Taschenlampe")
                        self.view.addSubview(torch)
                        c += [torch.leadingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                              torch.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 12)]
                    }
                    self.view.addSubview(hint)
                    let g = self.view.safeAreaLayoutGuide
                    c += [hint.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 24),
                          hint.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -24),
                          hint.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -32)]
                    NSLayoutConstraint.activate(c)
                    UIAccessibility.post(notification: .screenChanged, argument: hint)
                }
            }
        }

        private func button(_ title: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system, primaryAction: UIAction(title: title) { _ in action() })
            b.setTitleColor(.white, for: .normal)
            b.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            b.titleLabel?.adjustsFontForContentSizeCategory = true
            b.translatesAutoresizingMaskIntoConstraints = false
            return b
        }

        private func start() {
            guard let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam),
                  session.canAddInput(input) else {
                finish { $0.cancel?(L("No camera on this device. Paste the code instead.", "Dieses Gerät hat keine Kamera. Füge den Code stattdessen ein."), false) }; return
            }
            camera = cam
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.frame = view.bounds; layer.videoGravity = .resizeAspectFill
            view.layer.insertSublayer(layer, at: 0)
            preview = layer
            rotate()
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        // iPad and landscape: the preview follows the view and the way the device is held.
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
            rotate()
        }

        private func rotate() {
            guard let c = preview?.connection else { return }
            let angle: CGFloat
            let o: UIInterfaceOrientation?
            if #available(iOS 26, *) { o = view.window?.windowScene?.effectiveGeometry.interfaceOrientation }
            else { o = view.window?.windowScene?.interfaceOrientation }
            switch o ?? .portrait {
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
        }

        private func toggleTorch() {
            guard let cam = camera, cam.hasTorch, (try? cam.lockForConfiguration()) != nil else { return }
            cam.torchMode = cam.torchMode == .on ? .off : .on
            cam.unlockForConfiguration()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            finish { $0.found?(s) }
        }

        private func finish(_ f: (ScannerController) -> Void) {
            guard !done else { return }
            done = true
            if session.isRunning { DispatchQueue.global().async { self.session.stopRunning() } }
            f(self)
        }
    }
}
