// Deploy Center — spoken words: the summary on request (FEA-127, Deploy menu) and, opt-in, the
// end of a deploy (FEA-065). With VoiceOver on, VoiceOver says it; otherwise the Mac's voice.

import AppKit
import AVFoundation
import SwiftUI

@MainActor
enum Speech {
    static let resultsKey = "speakResults"
    private static let synth = AVSpeechSynthesizer()

    static func say(_ text: String) {
        if NSWorkspace.shared.isVoiceOverEnabled {
            AccessibilityNotification.Announcement(text).post()
            return
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: isGerman ? "de-DE" : "en-US")
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }

    /// "3 projects wait, 1 failed, 2 running" – only the parts that are not zero.
    nonisolated static func summary(waiting: Int, failed: Int, running: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append(L("\(waiting) projects wait", "\(waiting) Projekte warten")) }
        if failed > 0 { parts.append(L("\(failed) failed", "\(failed) fehlgeschlagen")) }
        if running > 0 { parts.append(L("\(running) running", "\(running) laufen")) }
        return parts.isEmpty ? L("Nothing waits, nothing failed.", "Nichts wartet, nichts ist fehlgeschlagen.") : parts.joined(separator: ", ") + "."
    }
}
