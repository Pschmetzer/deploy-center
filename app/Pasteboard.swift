// Deploy Center — One way to put text on the clipboard.

import AppKit

enum Pasteboard {
    /// Replaces the clipboard with `text`. `concealed` marks it for clipboard managers that honour
    /// org.nspasteboard.ConcealedType (keys and codes): they do not keep it in their history.
    static func copy(_ text: String, concealed: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if concealed { pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
    }
}
