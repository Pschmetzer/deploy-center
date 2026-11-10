// Deploy Center for iPhone — Connect to the Mac app: through iCloud Keychain, or by scanning the
// QR code the Mac shows for a minute. The keys never pass a server of ours.

import AVFoundation
import SwiftUI

struct ConnectMacView: View {
    @ObservedObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var scanError: String?
    @State private var checking = false

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
                    } footer: {
                        Text(L("To disconnect, turn off \"Connect the iPhone app\" in the Mac app's Settings → iPhone.",
                               "Zum Trennen in der Mac-App unter Einstellungen → iPhone \"Mit der iPhone-App verbinden\" ausschalten."))
                    }
                }
                if store.linkAvailable {
                    Section {
                        Text(L("1. On the Mac, open Deploy Center → Settings → iPhone.\n2. Turn on \"Connect the iPhone app (iCloud Keychain)\".\n3. This iPhone needs the same Apple ID, with iCloud Keychain (Passwords) on.",
                               "1. Auf dem Mac Deploy Center → Einstellungen → iPhone öffnen.\n2. \"Mit der iPhone-App verbinden (iCloud-Schlüsselbund)\" einschalten.\n3. Dieses iPhone braucht dieselbe Apple-ID, mit eingeschaltetem iCloud-Schlüsselbund (Passwörter)."))
                        Button {
                            checking = true
                            store.useLinkAgain()
                            Task {
                                await store.reload()
                                checking = false
                                if store.linked != nil { dismiss() }
                            }
                        } label: {
                            HStack { Text(L("Check again", "Erneut prüfen")); if checking { Spacer(); ProgressView() } }
                        }
                    } header: { Text(L("With your Apple ID", "Mit deiner Apple-ID")) } footer: {
                        Text(L("iCloud Keychain can take a minute to bring the keys over. End-to-end encrypted, no server of ours.",
                               "Der iCloud-Schlüsselbund braucht manchmal eine Minute. Ende-zu-Ende-verschlüsselt, ohne Server von uns."))
                    }
                }
                Section {
                    Button(L("Scan the code …", "Code scannen …")) { scanError = nil; scanning = true }
                    if let e = scanError { Text(e).foregroundStyle(.red) }
                } header: { Text(L("With a QR code", "Mit einem QR-Code")) } footer: {
                    Text(L("On the Mac: Settings → iPhone → Show a QR code for the iPhone. The keys are then kept on this iPhone only.",
                           "Auf dem Mac: Einstellungen → iPhone → QR-Code fürs iPhone zeigen. Die Schlüssel bleiben dann nur auf diesem iPhone."))
                }
            }
            .navigationTitle(L("Connect to the Mac", "Mit dem Mac verbinden"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done", "Fertig")) { dismiss() } } }
            .fullScreenCover(isPresented: $scanning) {
                // A wrong or old code keeps the camera open, with the reason over the picture.
                QRScanner { text in
                    switch PhoneLink.read(qr: text) {
                    case .keys(let keys):
                        scanning = false
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        store.adopt(keys); dismiss()
                        return nil
                    case .expired:
                        return L("This code is too old. Show a new one on the Mac and scan it within a minute.",
                                 "Dieser Code ist zu alt. Zeig auf dem Mac einen neuen und scanne ihn innerhalb einer Minute.")
                    case .notOurs:
                        return L("That is not a Deploy Center code.", "Das ist kein Deploy-Center-Code.")
                    }
                } cancel: { error in
                    scanning = false
                    scanError = error
                }
                .ignoresSafeArea()
            }
        }
    }
}

/// The camera, reading one QR code.
struct QRScanner: UIViewControllerRepresentable {
    /// Returns why the code was not taken (the camera stays open), or nil when it was.
    let found: (String) -> String?
    let cancel: (String?) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController(); c.found = found; c.cancel = cancel; return c
    }
    func updateUIViewController(_ c: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> String?)?
        var cancel: ((String?) -> Void)?
        private let session = AVCaptureSession()
        private var done = false
        private var preview: AVCaptureVideoPreviewLayer?
        private let hint = UILabel()
        /// The camera reports the same code many times a second: each rejected one is answered once.
        private var rejected: String?

        // Rotation, Split View and Stage Manager change the size: the camera follows.
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            let close = UIButton(type: .system, primaryAction: UIAction(title: L("Cancel", "Abbrechen")) { [weak self] _ in
                self?.finish { $0.cancel?(nil) }
            })
            close.setTitleColor(.white, for: .normal)
            close.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            close.translatesAutoresizingMaskIntoConstraints = false
            // What to do, for everyone and for VoiceOver: the camera picture alone says nothing.
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
                    guard ok else {
                        self.finish { $0.cancel?(L("No camera access. Allow it in Settings → Deploy Center.",
                                                   "Kein Zugriff auf die Kamera. Erlaube ihn unter Einstellungen → Deploy Center.")) }
                        return
                    }
                    self.start()
                    self.view.addSubview(close)
                    self.view.addSubview(self.hint)
                    let g = self.view.safeAreaLayoutGuide
                    NSLayoutConstraint.activate([
                        close.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
                        close.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
                        self.hint.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 24),
                        self.hint.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -24),
                        self.hint.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -32)])
                    UIAccessibility.post(notification: .screenChanged, argument: self.hint)
                }
            }
        }

        private func start() {
            guard let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam),
                  session.canAddInput(input) else {
                finish { $0.cancel?(L("No camera on this device.", "Dieses Gerät hat keine Kamera.")) }; return
            }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.frame = view.bounds; layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer); preview = layer
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, s != rejected else { return }
            guard let why = found?(s) else { finish { _ in }; return }
            rejected = s
            hint.text = why
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            UIAccessibility.post(notification: .announcement, argument: why)
        }

        private func finish(_ f: (ScannerController) -> Void) {
            guard !done else { return }
            done = true
            if session.isRunning { DispatchQueue.global().async { self.session.stopRunning() } }
            f(self)
        }
    }
}
