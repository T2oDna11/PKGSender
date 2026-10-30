import Foundation
import Network

struct FTPEntry: Identifiable, Hashable, Sendable {
    let name: String
    let isDirectory: Bool
    let size: UInt64?
    var id: String { (isDirectory ? "d:" : "f:") + name }

    static func parse(_ line: String) -> FTPEntry? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 9 else { return FTPEntry(name: line, isDirectory: false, size: nil) }
        let isDir = parts[0].first == "d"
        let size = UInt64(parts[4])
        let name = parts[8...].joined(separator: " ")
        return FTPEntry(name: name, isDirectory: isDir, size: size)
    }
}

@MainActor
final class FTPService: ObservableObject {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var entries: [FTPEntry] = []
    @Published private(set) var currentPath = ""

    func reset() {
        state = .idle
        entries = []
        currentPath = ""
    }

    func list(host: String, path: String = "/", port: UInt16 = 2121) async {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { state = .failed("PlayStation IP is empty."); return }
        state = .connecting
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try FTPClient(host: cleanHost, port: port).list(path: path)
            }.value
            currentPath = result.path
            entries = result.entries
            state = .connected
        } catch { state = .failed(error.localizedDescription) }
    }

    func listCheats(host: String, port: UInt16 = 2121) async {
        await list(host: host, path: "/user/data/GoldHEN/cheats", port: port)
    }

    /// Returns the server's real FTP welcome line (for example GoldHEN FTP server v2.2).
    func serverBanner(host: String, port: UInt16 = 2121) async throws -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await Task.detached(priority: .userInitiated) {
            try FTPClient(host: cleanHost, port: port).welcomeBanner()
        }.value
    }

    func upload(host: String, localURL: URL, remotePath: String, port: UInt16 = 2121, progress: (@Sendable (UInt64) -> Void)? = nil) async throws {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Task.detached(priority: .userInitiated) {
            let access = localURL.startAccessingSecurityScopedResource()
            defer { if access { localURL.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: localURL)
            try FTPClient(host: cleanHost, port: port).store(data: data, path: remotePath, progress: progress)
        }.value
    }

    func download(host: String, remotePath: String, port: UInt16 = 2121, progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> Data {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await Task.detached(priority: .userInitiated) {
            try FTPClient(host: cleanHost, port: port).retrieve(path: remotePath, progress: progress)
        }.value
    }

    func delete(host: String, remotePath: String, isDirectory: Bool = false, port: UInt16 = 2121) async throws {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Task.detached(priority: .userInitiated) {
            try FTPClient(host: cleanHost, port: port).delete(path: remotePath, directory: isDirectory)
        }.value
    }

    func createDirectory(host: String, remotePath: String, port: UInt16 = 2121) async throws {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Task.detached(priority: .userInitiated) { try FTPClient(host: cleanHost, port: port).makeDirectory(path: remotePath) }.value
    }

    func rename(host: String, from: String, to: String, port: UInt16 = 2121) async throws {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        try await Task.detached(priority: .userInitiated) { try FTPClient(host: cleanHost, port: port).rename(from: from, to: to) }.value
    }
}

private struct FTPListResult: Sendable {
    let path: String
    let entries: [FTPEntry]
}

private final class FTPClient: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "PKGSender.FTP")
    private var control: NWConnection?
    private var buffer = Data()

    init(host: String, port: UInt16) { self.host = host; self.port = port }

    func welcomeBanner() throws -> String {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw FTPError.invalidPort }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        control = c
        c.start(queue: queue)
        defer { c.cancel(); control = nil }
        try waitReady(c)
        return try readReply(expect: [220])
    }

    func list(path: String) throws -> FTPListResult {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw FTPError.invalidPort }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        control = c
        c.start(queue: queue)
        try waitReady(c)
        _ = try readReply(expect: [220])
        _ = try command("USER anonymous", expect: [230, 331])
        if lastCode == 331 { _ = try command("PASS pkgsender@iphone", expect: [230]) }
        _ = try command("TYPE I", expect: [200])
        _ = try command("CWD \(path)", expect: [250])
        let pwd = try command("PWD", expect: [257])
        let actualPath = quotedPath(from: pwd) ?? path

        let pasv = try command("PASV", expect: [227])
        let endpoint = try parsePASV(pasv)
        let dataConn = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp)
        dataConn.start(queue: queue)
        try waitReady(dataConn)

        sendLine("LIST")
        _ = try readReply(expect: [125, 150])
        let listingData = try readUntilClosed(dataConn)
        _ = try readReply(expect: [226, 250])
        _ = try? command("QUIT", expect: [221])
        c.cancel()

        let text = String(data: listingData, encoding: .utf8) ?? String(decoding: listingData, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        let entries = lines.compactMap { FTPEntry.parse($0) }.filter { $0.name != "." && $0.name != ".." }
        return FTPListResult(path: actualPath, entries: entries)
    }

    func store(data: Data, path: String, progress: (@Sendable (UInt64) -> Void)? = nil) throws {
        try login()
        let pasv = try command("PASV", expect: [227])
        let endpoint = try parsePASV(pasv)
        let dataConn = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp)
        dataConn.start(queue: queue); try waitReady(dataConn)
        sendLine("STOR \(path)"); _ = try readReply(expect: [125, 150])

        if data.isEmpty {
            let sem = DispatchSemaphore(value: 0)
            var sendError: Error?
            dataConn.send(content: Data(), isComplete: true, completion: .contentProcessed { error in
                sendError = error
                sem.signal()
            })
            guard sem.wait(timeout: .now() + 30) == .success else { dataConn.cancel(); throw FTPError.timeout }
            if let sendError { dataConn.cancel(); throw sendError }
        }

        let chunkSize = 256 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            let sem = DispatchSemaphore(value: 0)
            var sendError: Error?
            dataConn.send(content: chunk, isComplete: end == data.count, completion: .contentProcessed { error in
                sendError = error
                sem.signal()
            })
            guard sem.wait(timeout: .now() + 30) == .success else { dataConn.cancel(); throw FTPError.timeout }
            if let sendError { dataConn.cancel(); throw sendError }
            offset = end
            progress?(UInt64(offset))
        }
        dataConn.cancel(); _ = try readReply(expect: [226, 250]); _ = try? command("QUIT", expect: [221]); control?.cancel()
    }

    func retrieve(path: String, progress: (@Sendable (UInt64) -> Void)? = nil) throws -> Data {
        try login()
        let pasv = try command("PASV", expect: [227])
        let endpoint = try parsePASV(pasv)
        guard let dataPort = NWEndpoint.Port(rawValue: endpoint.port) else { throw FTPError.invalidPort }
        let dataConn = NWConnection(host: NWEndpoint.Host(endpoint.host), port: dataPort, using: .tcp)
        dataConn.start(queue: queue)
        try waitReady(dataConn)
        sendLine("RETR \(path)")
        _ = try readReply(expect: [125, 150])
        let data = try readUntilClosed(dataConn, progress: progress)
        _ = try readReply(expect: [226, 250])
        _ = try? command("QUIT", expect: [221])
        control?.cancel()
        return data
    }

    func delete(path: String, directory: Bool) throws {
        try login()
        _ = try command((directory ? "RMD " : "DELE ") + path, expect: [250, 200])
        _ = try? command("QUIT", expect: [221]); control?.cancel()
    }

    func makeDirectory(path: String) throws {
        try login()
        let normalized = path.hasPrefix("/") ? path : "/" + path
        let nsPath = normalized as NSString
        let parent = nsPath.deletingLastPathComponent.isEmpty ? "/" : nsPath.deletingLastPathComponent
        let name = nsPath.lastPathComponent
        guard !name.isEmpty else { throw FTPError.server("Invalid folder name.") }
        _ = try command("CWD " + parent, expect: [250])
        _ = try command("MKD " + name, expect: [257, 250])
        _ = try? command("QUIT", expect: [221]); control?.cancel()
    }

    func rename(from: String, to: String) throws {
        try login()
        _ = try command("RNFR " + from, expect: [350])
        _ = try command("RNTO " + to, expect: [250])
        _ = try? command("QUIT", expect: [221]); control?.cancel()
    }

    private func login() throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw FTPError.invalidPort }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp); control = c; c.start(queue: queue)
        try waitReady(c); _ = try readReply(expect: [220]); _ = try command("USER anonymous", expect: [230, 331])
        if lastCode == 331 { _ = try command("PASS pkgsender@iphone", expect: [230]) }
        _ = try command("TYPE I", expect: [200])
    }

    private var lastCode = 0

    @discardableResult private func command(_ text: String, expect: Set<Int>) throws -> String {
        sendLine(text)
        return try readReply(expect: expect)
    }

    private func sendLine(_ text: String) {
        let sem = DispatchSemaphore(value: 0)
        control?.send(content: Data((text + "\r\n").utf8), completion: .contentProcessed { _ in sem.signal() })
        _ = sem.wait(timeout: .now() + 8)
    }

    private func waitReady(_ conn: NWConnection) throws {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: result = .success(()); sem.signal()
            case .failed(let e): result = .failure(e); sem.signal()
            case .cancelled: if result == nil { result = .failure(FTPError.cancelled); sem.signal() }
            default: break
            }
        }
        guard sem.wait(timeout: .now() + 8) == .success else { conn.cancel(); throw FTPError.timeout }
        try result?.get()
    }

    private func readReply(expect: Set<Int>) throws -> String {
        let deadline = Date().addingTimeInterval(8)
        var accumulated = ""
        var multilineCode: String?
        while Date() < deadline {
            if let line = popLine() {
                accumulated += line + "\n"
                if line.count >= 3, Int(line.prefix(3)) != nil {
                    let codeText = String(line.prefix(3))
                    if line.count > 3 && line[line.index(line.startIndex, offsetBy: 3)] == "-" { multilineCode = codeText; continue }
                    if multilineCode == nil || (multilineCode == codeText && line.count > 3 && line[line.index(line.startIndex, offsetBy: 3)] == " ") {
                        let code = Int(codeText)!
                        lastCode = code
                        guard expect.contains(code) else { throw FTPError.server(accumulated.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        return accumulated
                    }
                }
            } else {
                try receiveMore()
            }
        }
        throw FTPError.timeout
    }

    private func receiveMore() throws {
        let sem = DispatchSemaphore(value: 0)
        var received: Data?
        var error: Error?
        control?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, e in received = data; error = e; sem.signal() }
        guard sem.wait(timeout: .now() + 8) == .success else { throw FTPError.timeout }
        if let error { throw error }
        if let received { buffer.append(received) }
    }

    private func popLine() -> String? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        let line = buffer.subdata(in: 0..<range.lowerBound)
        buffer.removeSubrange(0..<range.upperBound)
        return String(data: line, encoding: .utf8) ?? String(decoding: line, as: UTF8.self)
    }

    private func readUntilClosed(_ conn: NWConnection, progress: (@Sendable (UInt64) -> Void)? = nil) throws -> Data {
        var output = Data()
        while true {
            let sem = DispatchSemaphore(value: 0)
            var chunk: Data?
            var done = false
            var error: Error?
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, e in chunk = data; done = complete; error = e; sem.signal() }
            guard sem.wait(timeout: .now() + 8) == .success else { conn.cancel(); throw FTPError.timeout }
            if let error { conn.cancel(); throw error }
            if let chunk {
                output.append(chunk)
                progress?(UInt64(output.count))
            }
            if done || chunk == nil { break }
        }
        conn.cancel()
        return output
    }

    private func parsePASV(_ reply: String) throws -> (host: String, port: UInt16) {
        guard let a = reply.firstIndex(of: "("), let b = reply[a...].firstIndex(of: ")") else { throw FTPError.badPASV }
        let nums = reply[reply.index(after: a)..<b].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 6 else { throw FTPError.badPASV }
        let ip = nums[0...3].map(String.init).joined(separator: ".")
        let portValue = nums[4] * 256 + nums[5]
        guard let p = UInt16(exactly: portValue) else { throw FTPError.badPASV }
        return (ip == "0.0.0.0" ? host : ip, p)
    }

    private func quotedPath(from reply: String) -> String? {
        guard let a = reply.firstIndex(of: "\"") else { return nil }
        let rest = reply[reply.index(after: a)...]
        guard let b = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<b])
    }

    enum FTPError: LocalizedError {
        case invalidPort, timeout, cancelled, badPASV, server(String)
        var errorDescription: String? {
            switch self {
            case .invalidPort: return "Invalid FTP port."
            case .timeout: return "FTP connection timed out. Make sure GoldHEN FTP Server is enabled on port 2121."
            case .cancelled: return "FTP connection was cancelled."
            case .badPASV: return "GoldHEN returned an invalid FTP passive-mode address."
            case .server(let message): return message
            }
        }
    }
}
