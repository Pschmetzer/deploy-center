// Deploy Center — Files with names, notes and errors in them are written readable by this user only.

import Foundation

enum PrivateFile {
    /// Writes `data` to `url` in one step with mode 0600: a temporary file is created with that mode,
    /// then moved over the target, so the file is never readable by others, not even briefly.
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        // A new folder is 0700 too: its file names (projects) are private as well (IDEEN-11 221).
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: tmp) }
            else { try fm.moveItem(at: tmp, to: url) }
        } catch { try? fm.removeItem(at: tmp); throw error }
    }
}
