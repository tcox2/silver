import Foundation

enum SilverLog {
    private static let queue = DispatchQueue(label: "org.tcox.silver.log")
    private static let formatter = ISO8601DateFormatter()
    private static let maximumBytes: UInt64 = 5 * 1_024 * 1_024

    static var fileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Silver", isDirectory: true)
            .appendingPathComponent("silver.log")
    }

    static func info(_ message: String) { write("INFO", message) }
    static func warning(_ message: String) { write("WARN", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        let clean = message.replacingOccurrences(of: "\n", with: " ")
        queue.sync {
            let line = "\(formatter.string(from: Date())) [\(level)] \(clean)\n"
            fputs(line, stderr)
            do {
                let manager = FileManager.default
                let url = fileURL
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? UInt64,
                   size >= maximumBytes {
                    let old = url.deletingPathExtension().appendingPathExtension("old.log")
                    try? manager.removeItem(at: old)
                    try manager.moveItem(at: url, to: old)
                }
                if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } catch {
                fputs("Silver logging failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
