import Foundation

/// Lightweight transfer logger used by both HTTP engines.
/// It intentionally logs only coarse events/2-second samples so diagnostics
/// do not become the transfer bottleneck.
enum TransferDiagnostics {
    private static let queue = DispatchQueue(label: "pkg.sender.transfer.diagnostics")
    private static var sessionID = ""
    private static var startedAt = Date()

    private static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("PKGSender-Diagnostic.log")
    }

    static func begin(engine: String, fileSize: UInt64, details: String = "") {
        queue.async {
            sessionID = String(UUID().uuidString.prefix(8))
            startedAt = Date()
            let mb = Double(fileSize) / 1_048_576.0
            appendLocked("\n============================================================")
            let sizeText = String(format: "%.1f", mb)
            appendLocked("SESSION \(sessionID) START engine=\(engine) file=\(sizeText)MiB \(details)")
        }
    }

    static func log(_ message: String) {
        // Drop high-frequency request/range/sample chatter. Keep session,
        // lifecycle, network selection, RPI results and all failures.
        let noisyPrefixes = [
            "STABLE SAMPLE",
            "STABLE stream#",
            "HTTP REQUEST",
            "HTTP RESPONSE",
            "HOTSPOT POSIX GET",
            "HOTSPOT POSIX HEAD"
        ]
        guard !noisyPrefixes.contains(where: { message.hasPrefix($0) }) else { return }
        queue.async { appendLocked(message) }
    }

    private static func appendLocked(_ message: String) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let line = String(format: "[%8.3fs] %@\n", elapsed, message)
        guard let data = line.data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Diagnostics must never break a transfer.
        }
    }
}
