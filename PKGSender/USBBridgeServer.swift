import Foundation
import Network
import Darwin

/// USB-side file service for PKG Sender. usbmux on the PS4 connects to this
/// localhost TCP listener over Lightning; no Wi-Fi path is involved.
struct USBTransferSnapshot {
    let fraction: Double
    let sentBytes: UInt64
    let totalBytes: UInt64
    let bytesPerSecond: Double
    let remainingSeconds: Double?
}

final class USBBridgeServer {
    static let shared = USBBridgeServer()

    private let queue = DispatchQueue(label: "PKGSender.USBBridge", qos: .userInitiated)
    private var listener: NWListener?
    private var selectedURL: URL?
    private var selectedFD: Int32 = -1
    private var selectedSize: UInt64 = 0
    private var hasSecurityScope = false
    private var transferArmed = false
    private var coveredRanges: [(UInt64, UInt64)] = []
    private var coveredBytes: UInt64 = 0
    private var transferStartedAt: Date?
    private var lastSampleAt: Date?
    private var lastSampleBytes: UInt64 = 0
    private var smoothedSpeed: Double = 0
    private var transferFinished = false
    private var transferObserver: ((USBTransferSnapshot) -> Void)?
    private(set) var port: UInt16 = 11112

    private init() {}
    deinit { closeSelectedFile() }

    func setTransferObserver(_ observer: ((USBTransferSnapshot) -> Void)?) {
        queue.async { [weak self] in self?.transferObserver = observer }
    }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    /// Call whenever Home's primary PKG selection changes.
    func setSelectedFile(_ url: URL?) {
        queue.async { [weak self] in self?.setSelectedFileLocked(url) }
    }

    /// Arms the currently selected PKG for the USB payload. The payload may be
    /// launched before or after this call; it polls INFO until the file is armed.
    func armSelectedFile() {
        queue.async { [weak self] in
            guard let self, self.selectedFD >= 0 else { return }
            self.resetTransferMetricsLocked()
            self.transferArmed = true
            self.log("FILE armed for USB transfer")
        }
    }

    func disarm() {
        queue.async { [weak self] in
            self?.transferArmed = false
        }
    }

    /// Ends one USB transfer cleanly while keeping the localhost listener alive
    /// for the next payload. Releases the file descriptor/security scope and
    /// removes the progress observer so the next send starts from a clean state.
    func endTransferCycle() {
        queue.async { [weak self] in
            guard let self else { return }
            self.transferArmed = false
            self.transferObserver = nil
            self.closeSelectedFile()
        }
    }

    private func startLocked() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] s in self?.log("listener \(s)") }
            listener = l
            l.start(queue: queue)
            log("READY localhost:\(port)")
        } catch {
            log("LISTENER ERROR \(error)")
        }
    }

    private func closeSelectedFile() {
        if selectedFD >= 0 { Darwin.close(selectedFD); selectedFD = -1 }
        if hasSecurityScope { selectedURL?.stopAccessingSecurityScopedResource() }
        selectedURL = nil
        selectedSize = 0
        hasSecurityScope = false
        transferArmed = false
        resetTransferMetricsLocked()
    }

    private func setSelectedFileLocked(_ url: URL?) {
        closeSelectedFile()
        guard let url else { log("FILE cleared"); return }
        let scoped = url.startAccessingSecurityScopedResource()
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            log("FILE open failed errno=\(errno) \(url.lastPathComponent)")
            return
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            Darwin.close(fd); if scoped { url.stopAccessingSecurityScopedResource() }
            log("FILE stat failed errno=\(errno)")
            return
        }
        selectedURL = url
        selectedFD = fd
        selectedSize = UInt64(max(0, st.st_size))
        hasSecurityScope = scoped
        log("FILE ready name=\(url.lastPathComponent) bytes=\(selectedSize)")
    }

    private func accept(_ c: NWConnection) {
        log("CLIENT accepted")
        c.start(queue: queue)
        receiveCommand(c, buffer: Data())
    }

    private func receiveCommand(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { self.log("CLIENT receive error \(error)"); c.cancel(); return }
            var b = buffer
            if let data { b.append(data) }
            while let nl = b.firstIndex(of: 0x0A) {
                let lineData = b[..<nl]
                b.removeSubrange(...nl)
                let line = String(decoding: lineData, as: UTF8.self)
                self.handle(line: line, on: c)
            }
            if complete { self.log("CLIENT closed"); c.cancel(); return }
            self.receiveCommand(c, buffer: b)
        }
    }

    private func handle(line: String, on c: NWConnection) {
        let parts = line.split(separator: " ")
        guard let cmd = parts.first else { return }
        if cmd == "HELLO" {
            send(Data("PKGBRIDGE/2 READY\n".utf8), on: c)
            return
        }
        if cmd == "INFO" {
            guard selectedFD >= 0, let url = selectedURL else {
                send(Data("ERR NO_FILE\n".utf8), on: c); return
            }
            guard transferArmed else {
                send(Data("WAIT NOT_ARMED\n".utf8), on: c); return
            }
            let safeName = url.lastPathComponent.replacingOccurrences(of: "\n", with: "_")
            send(Data("OK \(selectedSize) \(safeName)\n".utf8), on: c)
            return
        }
        if cmd == "READ", parts.count == 3,
           let off = UInt64(parts[1]), let requested = Int(parts[2]), requested > 0 {
            guard selectedFD >= 0, off < selectedSize else {
                send(Data("ERR RANGE\n".utf8), on: c); return
            }
            let count = min(requested, 16 * 1024 * 1024, Int(selectedSize - off))
            var data = Data(count: count)
            let got: Int = data.withUnsafeMutableBytes { raw in
                guard let p = raw.baseAddress else { return -1 }
                return Darwin.pread(selectedFD, p, count, off_t(off))
            }
            guard got >= 0 else { send(Data("ERR READ \(errno)\n".utf8), on: c); return }
            if got < data.count { data.removeSubrange(got..<data.count) }
            recordTransferredRangeLocked(offset: off, count: got)
            // 19P: send the small protocol header separately so we do not copy
            // the entire PKG chunk into a second combined Data allocation.
            let header = Data("DATA \(off) \(got)\n".utf8)
            send(header, on: c)
            if got > 0 {
                send(data, on: c)
            }
            return
        }
        send(Data("ERR COMMAND\n".utf8), on: c)
    }

    private func resetTransferMetricsLocked() {
        coveredRanges.removeAll(keepingCapacity: true)
        coveredBytes = 0
        transferStartedAt = nil
        lastSampleAt = nil
        lastSampleBytes = 0
        smoothedSpeed = 0
        transferFinished = false
    }

    /// Counts unique file bytes requested by the PS4 payload. BGFT performs a few
    /// probe/retry reads and parallel ranges, so simply summing READ sizes would
    /// over-report progress. Merging ranges keeps progress monotonic and accurate.
    private func recordTransferredRangeLocked(offset: UInt64, count: Int) {
        guard transferArmed, count > 0, selectedSize > 0 else { return }
        let start = offset
        let end = min(selectedSize, offset + UInt64(count))
        guard end > start else { return }

        var mergedStart = start
        var mergedEnd = end
        var result: [(UInt64, UInt64)] = []
        result.reserveCapacity(coveredRanges.count + 1)
        var inserted = false

        for range in coveredRanges {
            if range.1 < mergedStart {
                result.append(range)
            } else if mergedEnd < range.0 {
                if !inserted {
                    result.append((mergedStart, mergedEnd))
                    inserted = true
                }
                result.append(range)
            } else {
                mergedStart = min(mergedStart, range.0)
                mergedEnd = max(mergedEnd, range.1)
            }
        }
        if !inserted { result.append((mergedStart, mergedEnd)) }
        coveredRanges = result
        coveredBytes = coveredRanges.reduce(0) { $0 + ($1.1 - $1.0) }

        let now = Date()
        if transferStartedAt == nil {
            transferStartedAt = now
            lastSampleAt = now
            lastSampleBytes = coveredBytes
        }

        if let sampleAt = lastSampleAt {
            let dt = now.timeIntervalSince(sampleAt)
            if dt >= 0.35 || coveredBytes >= selectedSize {
                let delta = coveredBytes >= lastSampleBytes ? coveredBytes - lastSampleBytes : 0
                let instant = dt > 0 ? Double(delta) / dt : 0
                if instant > 0 {
                    smoothedSpeed = smoothedSpeed > 0 ? (smoothedSpeed * 0.72 + instant * 0.28) : instant
                }
                lastSampleAt = now
                lastSampleBytes = coveredBytes
            }
        }

        let fraction = min(1, Double(coveredBytes) / Double(selectedSize))
        let remaining: Double?
        if smoothedSpeed > 0 {
            remaining = Double(selectedSize - min(coveredBytes, selectedSize)) / smoothedSpeed
        } else {
            remaining = nil
        }
        let snapshot = USBTransferSnapshot(
            fraction: fraction,
            sentBytes: min(coveredBytes, selectedSize),
            totalBytes: selectedSize,
            bytesPerSecond: smoothedSpeed,
            remainingSeconds: remaining
        )
        transferObserver?(snapshot)

        if fraction >= 1, !transferFinished {
            transferFinished = true
            log("TRANSFER COMPLETE bytes=\(coveredBytes) speed=\(Int(smoothedSpeed)) B/s")
        }
    }

    private func send(_ data: Data, on c: NWConnection) {
        c.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.log("SEND error \(error)") }
        })
    }

    private func log(_ s: String) {
        // Keep only lifecycle/failure diagnostics. READ/progress chatter is
        // intentionally excluded so logging never competes with USB transfer.
        let important = s.contains("ERROR") || s.contains("error") ||
            s.contains("failed") || s.contains("COMPLETE") || s.hasPrefix("READY")
        guard important else { return }

        let line = "[USBBridge] \(s)\n"
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let u = dir.appendingPathComponent("PKGSender-USBBridge.log")
        let d = Data(line.utf8)
        if FileManager.default.fileExists(atPath: u.path), let h = try? FileHandle(forWritingTo: u) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: d)
        } else {
            try? d.write(to: u, options: .atomic)
        }
    }
}
