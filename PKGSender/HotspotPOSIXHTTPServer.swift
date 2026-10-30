import Foundation
import Darwin

/// Hotspot-only HTTP engine.  It deliberately avoids Network.framework and
/// mirrors the simple TCP/HTTP behaviour used by the known-working Go sender:
/// wildcard IPv4 bind, large socket buffers, TCP_NODELAY and ordinary HTTP/1.1
/// byte-range responses.
final class HotspotPOSIXHTTPServer: PKGHTTPServing {
    private let fileURL: URL
    private let onReady: (String) -> Void
    private let onProgress: (LocalHTTPServer.TransferProgress) -> Void
    private let queue = DispatchQueue(label: "pkg.sender.hotspot.posix", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "pkg.sender.hotspot.posix.clients", qos: .userInitiated, attributes: .concurrent)

    private var securityScopeActive = false
    private var fileFD: Int32 = -1
    private var listenFD: Int32 = -1
    private var stopped = false
    private var fileSize: UInt64 = 0
    private var highestPosition: UInt64 = 0
    private var totalWireBytes: UInt64 = 0
    private var speedStartedAt = Date()
    private let port: UInt16 = 8080
    private var boostEnabled: Bool { UserDefaults.standard.string(forKey: "hotspotPerformanceProfile") == "boost" }
    private var socketBufferBytes: Int32 { boostEnabled ? 2_097_152 : 1_048_576 }
    private var transferChunkBytes: Int { boostEnabled ? 2_097_152 : 1_048_576 }

    init(fileURL: URL,
         onReady: @escaping (String) -> Void,
         onProgress: @escaping (LocalHTTPServer.TransferProgress) -> Void) throws {
        self.fileURL = fileURL
        self.onReady = onReady
        self.onProgress = onProgress

        securityScopeActive = fileURL.startAccessingSecurityScopedResource()
        fileFD = open(fileURL.path, O_RDONLY)
        guard fileFD >= 0 else { throw POSIXError(.EIO) }
        var st = stat()
        guard fstat(fileFD, &st) == 0, st.st_size > 0 else {
            close(fileFD); fileFD = -1
            if securityScopeActive { fileURL.stopAccessingSecurityScopedResource(); securityScopeActive = false }
            throw POSIXError(.EINVAL)
        }
        fileSize = UInt64(st.st_size)
    }

    deinit { stop() }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        #if os(iOS)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var buf: Int32 = socketBufferBytes
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else {
            let e = errno; close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        guard listen(fd, 16) == 0 else {
            let e = errno; close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }

        listenFD = fd
        stopped = false
        TransferDiagnostics.begin(engine: "HOTSPOT-POSIX", fileSize: fileSize,
                                  details: "bind=0.0.0.0:\(port) profile=\(boostEnabled ? "BOOST" : "STABLE") sockbuf=\(socketBufferBytes / 1_048_576)MiB chunk=\(transferChunkBytes / 1_048_576)MiB TCP_NODELAY Range")

        guard let ip = hotspotIPv4() else {
            close(fd); listenFD = -1
            throw POSIXError(.EADDRNOTAVAIL)
        }
        let url = "http://\(ip):\(port)/pkg_0.pkg"
        TransferDiagnostics.log("HOTSPOT POSIX READY advertised=\(url) bind=0.0.0.0:\(port)")
        DispatchQueue.main.async { self.onReady(url) }

        clientQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self, !self.stopped else { return }
            self.stopped = true
            if self.listenFD >= 0 { shutdown(self.listenFD, SHUT_RDWR); close(self.listenFD); self.listenFD = -1 }
            if self.fileFD >= 0 { close(self.fileFD); self.fileFD = -1 }
            if self.securityScopeActive { self.fileURL.stopAccessingSecurityScopedResource(); self.securityScopeActive = false }
            TransferDiagnostics.log("HOTSPOT POSIX STOP")
        }
    }

    private func acceptLoop() {
        while !stopped, listenFD >= 0 {
            var peer = sockaddr_storage(); var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &len) }
            }
            if client < 0 { if stopped { break }; continue }
            var one: Int32 = 1
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            #if os(iOS)
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var buf: Int32 = socketBufferBytes
            setsockopt(client, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
            let dupFD = dup(fileFD)
            clientQueue.async { [weak self] in self?.serve(client: client, file: dupFD) }
        }
    }

    private func serve(client: Int32, file: Int32) {
        defer { shutdown(client, SHUT_RDWR); close(client); if file >= 0 { close(file) } }
        guard file >= 0 else { return }
        var request = Data(); var temp = [UInt8](repeating: 0, count: 8192)
        while request.count < 131_072 {
            let n = temp.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return recv(client, base, raw.count, 0)
            }
            if n <= 0 { return }
            request.append(contentsOf: temp.prefix(n))
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let text = String(data: request, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return }
        let fields = first.split(separator: " ")
        guard fields.count >= 2 else { return }
        let method = String(fields[0]).uppercased()
        guard method == "GET" || method == "HEAD" else { sendSimple(client, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return }

        let rangeLine = lines.first { $0.lowercased().hasPrefix("range:") }
        var start: UInt64 = 0, end = fileSize - 1, partial = false
        if let rangeLine, let eq = rangeLine.range(of: "bytes=", options: .caseInsensitive) {
            let value = rangeLine[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2 {
                if !pieces[0].isEmpty, let s = UInt64(pieces[0]) {
                    start = s
                    if !pieces[1].isEmpty, let e = UInt64(pieces[1]) { end = min(e, fileSize - 1) }
                    partial = start < fileSize && start <= end
                } else if pieces[0].isEmpty, let suffix = UInt64(pieces[1]), suffix > 0 {
                    start = suffix >= fileSize ? 0 : fileSize - suffix; partial = true
                }
            }
            if !partial {
                sendSimple(client, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(fileSize)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
        }

        let length = end - start + 1
        var header = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        if partial { header += "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n" }
        header += "Content-Type: application/octet-stream\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        TransferDiagnostics.log("HOTSPOT POSIX \(method) range=\(rangeLine ?? "none") reply=\(partial ? 206 : 200) bytes=\(start)-\(end)")
        guard sendAll(client, Data(header.utf8)) else { return }
        if method == "HEAD" { return }

        var offset = start
        var chunk = [UInt8](repeating: 0, count: transferChunkBytes)
        while offset <= end && !stopped {
            let wanted = Int(min(UInt64(chunk.count), end - offset + 1))
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pread(file, base, wanted, off_t(offset))
            }
            if n <= 0 { break }
            var sent = 0
            while sent < n {
                let w = chunk.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.send(client, base.advanced(by: sent), n - sent, 0)
                }
                if w <= 0 { return }
                sent += w; offset += UInt64(w)
                record(position: offset, bytes: UInt64(w))
            }
        }
    }

    private func sendSimple(_ fd: Int32, _ string: String) { _ = sendAll(fd, Data(string.utf8)) }
    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var done = 0
            while done < raw.count {
                let n = Darwin.send(fd, base.advanced(by: done), raw.count - done, 0)
                if n <= 0 { return false }
                done += n
            }
            return true
        }
    }

    private func record(position: UInt64, bytes: UInt64) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.highestPosition = max(self.highestPosition, min(position, self.fileSize))
            self.totalWireBytes += bytes
            let elapsed = max(Date().timeIntervalSince(self.speedStartedAt), 0.001)
            let speed = Double(self.totalWireBytes) / elapsed
            let p = LocalHTTPServer.TransferProgress(sentBytes: self.highestPosition, totalBytes: self.fileSize, bytesPerSecond: speed)
            DispatchQueue.main.async { self.onProgress(p) }
        }
    }

    private func hotspotIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?; var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "bridge100" || (name.hasPrefix("bridge") && ip.hasPrefix("172.20.10.")) { return ip }
            if name.hasPrefix("bridge") || name.hasPrefix("ap") { fallback = fallback ?? ip }
        }
        return fallback
    }

    static func hotspotIsActive() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.pointee.ifa_name)
            if name == "bridge100" || name.hasPrefix("ap") { return true }
        }
        return false
    }
}
