import Foundation
import Network
import Darwin

final class LocalHTTPServer {

    struct TransferProgress {
        let sentBytes: UInt64
        let totalBytes: UInt64
        let bytesPerSecond: Double

        var fraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(Double(sentBytes) / Double(totalBytes), 1.0)
        }

        var remainingSeconds: Double? {
            guard bytesPerSecond > 0 else { return nil }

            let remaining =
                Double(totalBytes - min(sentBytes, totalBytes))

            return remaining / bytesPerSecond
        }
    }

    private let fileURL: URL
    private let onReady: (String) -> Void
    private let onProgress: (TransferProgress) -> Void
    private let targetPlayStationIP: String?

    /*
     All server state, active stream bookkeeping and transfer statistics
     live on this serial queue.
     */
    private let queue =
        DispatchQueue(label: "pkg.sender.http.server")

    private var listener: NWListener?

    // MARK: - File Lifetime

    private var securityScopeActive = false
    private var masterFileDescriptor: Int32 = -1
    private let cachedFileSize: UInt64

    /*
     stop() no longer immediately closes the master FD while Range
     connections are still using the server.

     Existing streams are allowed to finish/close their duplicated FDs.
     Once activeStreams reaches zero, the master FD and security scope
     can safely be released.
     */
    private var activeStreams: Int = 0
    private var nextDiagnosticStreamID: Int = 1
    private var lastDiagnosticSampleTime = Date.distantPast
    private var stopRequested = false
    private var resourcesReleased = false

    // MARK: - Transfer Statistics

    private var transferStarted = false

    /*
     Progress is based on the furthest byte position requested/sent.

     Speed is NOT calculated from position jumps because PlayStation
     can open parallel Range requests at different offsets.
     */
    private var highestPosition: UInt64 = 0
    private var knownTotalSize: UInt64 = 0

    /*
     Real throughput accounting.

     Every successfully processed NWConnection.send contributes the
     actual number of bytes that were sent.
     */
    private var totalBytesSentForSpeed: UInt64 = 0
    private var speedSampleTime: Date?
    private var speedSamples: [(time: Date, bytes: UInt64)] = []
    private let speedWindow: TimeInterval = 10.0

    private var smoothedSpeed: Double = 0
    private var lastProgressUpdateTime: Date?

    // MARK: - Init

    init(
        fileURL: URL,
        targetPlayStationIP: String? = nil,
        onReady: @escaping (String) -> Void,
        onProgress: @escaping (TransferProgress) -> Void = { _ in }
    ) throws {

        self.fileURL = fileURL
        self.targetPlayStationIP = targetPlayStationIP
        self.onReady = onReady
        self.onProgress = onProgress

        self.securityScopeActive =
            fileURL.startAccessingSecurityScopedResource()

        self.masterFileDescriptor =
            open(fileURL.path, O_RDONLY)

        guard self.masterFileDescriptor >= 0 else {

            if self.securityScopeActive {
                fileURL.stopAccessingSecurityScopedResource()
                self.securityScopeActive = false
            }

            throw ServerError.fileOpenFailed(code: errno)
        }

        var st = stat()

        guard
            fstat(self.masterFileDescriptor, &st) == 0,
            st.st_size > 0
        else {

            close(self.masterFileDescriptor)
            self.masterFileDescriptor = -1

            if self.securityScopeActive {
                fileURL.stopAccessingSecurityScopedResource()
                self.securityScopeActive = false
            }

            throw ServerError.invalidFile(code: errno)
        }

        self.cachedFileSize =
            UInt64(st.st_size)

        do {
            let isHotspotTarget = targetPlayStationIP?.hasPrefix("172.20.10.") == true
            let requestedPort: NWEndpoint.Port = isHotspotTarget ? NWEndpoint.Port(rawValue: 8080)! : .any
            TransferDiagnostics.log("SERVER CONFIG hotspot=\(isHotspotTarget) requestedPort=\(isHotspotTarget ? "8080" : "any") target=\(targetPlayStationIP ?? "nil")")
            self.listener = try NWListener(
                using: .tcp,
                on: requestedPort
            )
        } catch {
            close(self.masterFileDescriptor)
            self.masterFileDescriptor = -1

            if self.securityScopeActive {
                fileURL.stopAccessingSecurityScopedResource()
                self.securityScopeActive = false
            }

            throw ServerError.listenerCreationFailed(message: error.localizedDescription)
        }
    }

    // MARK: - Start

    func start() throws {

        guard let listener = listener else {
            throw ServerError.listenerUnavailable
        }

        stopRequested = false
        TransferDiagnostics.begin(engine: "STABLE-NW", fileSize: cachedFileSize,
                                  details: "chunk=1MiB Network.framework")

        listener.stateUpdateHandler = { [weak self] state in

            guard let self = self else { return }

            switch state {

            case .ready:

                TransferDiagnostics.log("SERVER STATE ready")
                guard let port = listener.port else {
                    print("LocalHTTPServer: port unavailable")
                    return
                }

                guard let ip = self.localIPv4(for: self.targetPlayStationIP) else {
                    print("LocalHTTPServer: Wi-Fi IP unavailable")
                    return
                }

                var allowed =
                    CharacterSet.urlPathAllowed

                allowed.remove(
                    charactersIn: "/"
                )

                let isHotspotTarget = self.targetPlayStationIP?.hasPrefix("172.20.10.") == true
                let filename: String
                if isHotspotTarget {
                    // Keep the URL deliberately simple for RPI prerequisite probing.
                    filename = "pkg_0.pkg"
                } else {
                    filename = self.fileURL.lastPathComponent
                        .addingPercentEncoding(withAllowedCharacters: allowed)
                        ?? "game.pkg"
                }

                let url =
                    "http://\(ip):\(port.rawValue)/\(filename)"

                print(
                    "LocalHTTPServer ready: \(url)"
                )
                TransferDiagnostics.log("SERVER READY ip=\(ip) port=\(port.rawValue) url=\(url)")

                DispatchQueue.main.async {
                    self.onReady(url)
                }

            case .failed(let error):

                TransferDiagnostics.log("SERVER STATE failed error=\(error)")
                print(
                    "LocalHTTPServer FAILED: \(error)"
                )

                listener.cancel()

            case .waiting(let error):

                TransferDiagnostics.log("SERVER STATE waiting error=\(error)")
                print(
                    "LocalHTTPServer WAITING: \(error)"
                )

            case .cancelled:

                TransferDiagnostics.log("SERVER STATE cancelled")
                print(
                    "LocalHTTPServer cancelled"
                )

            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in

            guard let self = self else {
                connection.cancel()
                return
            }

            if self.stopRequested {
                connection.cancel()
                return
            }

            self.handleConnection(
                connection
            )
        }

        listener.start(
            queue: queue
        )
    }

    // MARK: - Stop

    func stop() {

        /*
         Serialize stop with all network callbacks.

         Do NOT close masterFileDescriptor immediately if an existing
         Range stream is still alive.
         */
        queue.async { [weak self] in

            guard let self = self else {
                return
            }

            guard !self.stopRequested else {
                return
            }

            self.stopRequested = true

            self.listener?.cancel()
            self.listener = nil

            print(
                "LocalHTTPServer stop requested. Active streams: \(self.activeStreams)"
            )

            self.releaseResourcesIfPossible()
        }
    }

    deinit {

        listener?.cancel()

        /*
         deinit can only happen when nobody retains this server anymore.

         Duplicated stream descriptors are owned by their stream contexts
         and close independently.
         */

        if masterFileDescriptor >= 0 {
            close(masterFileDescriptor)
            masterFileDescriptor = -1
        }

        if securityScopeActive {
            fileURL.stopAccessingSecurityScopedResource()
            securityScopeActive = false
        }
    }

    private func releaseResourcesIfPossible() {

        guard stopRequested else {
            return
        }

        guard activeStreams == 0 else {

            print(
                "LocalHTTPServer: waiting for \(activeStreams) active stream(s) before releasing file"
            )

            return
        }

        guard !resourcesReleased else {
            return
        }

        resourcesReleased = true

        if masterFileDescriptor >= 0 {

            print(
                "LocalHTTPServer: closing master FD \(masterFileDescriptor)"
            )

            close(masterFileDescriptor)
            masterFileDescriptor = -1
        }

        if securityScopeActive {

            fileURL.stopAccessingSecurityScopedResource()
            securityScopeActive = false
        }

        resetTransferStatistics()

        print(
            "LocalHTTPServer: file resources released"
        )
    }

    // MARK: - Connection

    private func handleConnection(
        _ connection: NWConnection
    ) {

        connection.start(
            queue: queue
        )

        receiveRequest(
            connection,
            accumulatedData: Data()
        )
    }

    private func receiveRequest(
        _ connection: NWConnection,
        accumulatedData: Data
    ) {

        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { [weak self] data, _, isComplete, error in

            guard let self = self else {
                connection.cancel()
                return
            }

            if let error = error {

                print(
                    "Receive error: \(error)"
                )

                connection.cancel()
                return
            }

            var requestData =
                accumulatedData

            if let data = data {
                requestData.append(data)
            }

            if let headerEnd =
                requestData.range(
                    of: Data("\r\n\r\n".utf8)
                ) {

                let headerData =
                    requestData[
                        requestData.startIndex
                        ..<
                        headerEnd.upperBound
                    ]

                guard
                    let request =
                        String(
                            data: headerData,
                            encoding: .utf8
                        )
                else {

                    self.sendError(
                        connection,
                        code: 400,
                        text: "Bad Request"
                    )

                    return
                }

                self.processRequest(
                    request,
                    connection: connection
                )

                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            if requestData.count > 131072 {

                self.sendError(
                    connection,
                    code: 431,
                    text:
                        "Request Header Fields Too Large"
                )

                return
            }

            self.receiveRequest(
                connection,
                accumulatedData: requestData
            )
        }
    }

    // MARK: - HTTP Request

    private func processRequest(
        _ request: String,
        connection: NWConnection
    ) {

        let lines =
            request.components(
                separatedBy: "\r\n"
            )

        guard let firstLine =
            lines.first else {

            sendError(
                connection,
                code: 400,
                text: "Bad Request"
            )

            return
        }

        let parts =
            firstLine.split(
                separator: " "
            )

        guard parts.count >= 2 else {

            sendError(
                connection,
                code: 400,
                text: "Bad Request"
            )

            return
        }

        let method =
            String(parts[0])
                .uppercased()

        guard
            method == "GET"
            || method == "HEAD"
        else {

            sendError(
                connection,
                code: 405,
                text: "Method Not Allowed"
            )

            return
        }

        var rangeHeader: String?
        var userAgent: String?
        var acceptEncoding: String?

        for line in lines {

            let lowercasedLine = line.lowercased()

            if lowercasedLine.hasPrefix("range:") {

                rangeHeader =
                    String(
                        line.dropFirst(
                            "range:".count
                        )
                    )
                    .trimmingCharacters(
                        in: .whitespaces
                    )
            } else if lowercasedLine.hasPrefix("user-agent:") {

                userAgent =
                    String(
                        line.dropFirst(
                            "user-agent:".count
                        )
                    )
                    .trimmingCharacters(
                        in: .whitespaces
                    )
            } else if lowercasedLine.hasPrefix("accept-encoding:") {

                acceptEncoding =
                    String(
                        line.dropFirst(
                            "accept-encoding:".count
                        )
                    )
                    .trimmingCharacters(
                        in: .whitespaces
                    )
            }
        }

        TransferDiagnostics.log(
            "HTTP REQUEST method=\(method) path=\(String(parts[1])) range=\(rangeHeader ?? "none") ua=\(userAgent ?? "none") encoding=\(acceptEncoding ?? "none")"
        )

        sendFile(
            connection,
            method: method,
            rangeHeader: rangeHeader
        )
    }

    // MARK: - Send File

    private func sendFile(
        _ connection: NWConnection,
        method: String,
        rangeHeader: String?
    ) {

        guard !stopRequested else {
            connection.cancel()
            return
        }

        let fileSize =
            cachedFileSize

        guard fileSize > 0 else {

            sendError(
                connection,
                code: 404,
                text: "Empty File"
            )

            return
        }

        knownTotalSize =
            fileSize

        var start: UInt64 = 0
        var end: UInt64 =
            fileSize - 1

        var partial = false

        if let rangeHeader = rangeHeader,
           rangeHeader
            .lowercased()
            .hasPrefix("bytes=") {

            let value =
                String(
                    rangeHeader.dropFirst(6)
                )

            let rangeParts =
                value.split(
                    separator: "-",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )

            if let first =
                rangeParts.first,
               !first.isEmpty,
               let requestedStart =
                UInt64(first) {

                start =
                    requestedStart

                if rangeParts.count > 1,
                   !rangeParts[1].isEmpty,
                   let requestedEnd =
                    UInt64(
                        rangeParts[1]
                    ) {

                    end =
                        min(
                            requestedEnd,
                            fileSize - 1
                        )
                }

                if start < fileSize,
                   start <= end {

                    partial = true

                } else {

                    sendRangeNotSatisfiable(
                        connection,
                        fileSize: fileSize
                    )

                    return
                }
            }
        }

        let contentLength =
            end - start + 1

        var header = ""

        if partial {

            header +=
                "HTTP/1.1 206 Partial Content\r\n"

            header +=
                "Content-Range: bytes \(start)-\(end)/\(fileSize)\r\n"

        } else {

            header +=
                "HTTP/1.1 200 OK\r\n"
        }

        header +=
            "Content-Type: application/octet-stream\r\n"

        header +=
            "Content-Length: \(contentLength)\r\n"

        header +=
            "Accept-Ranges: bytes\r\n"

        header +=
            "Connection: close\r\n"

        header += "\r\n"

        TransferDiagnostics.log(
            "HTTP RESPONSE status=\(partial ? 206 : 200) range=\(start)-\(end) fileSize=\(fileSize) contentLength=\(contentLength)"
        )

        guard
            let headerData =
                header.data(
                    using: .utf8
                )
        else {

            connection.cancel()
            return
        }

        connection.send(
            content: headerData,
            completion:
                .contentProcessed {
                    [weak self] error in

                    guard let self = self else {
                        connection.cancel()
                        return
                    }

                    guard error == nil else {

                        connection.cancel()
                        return
                    }

                    if method == "HEAD" {

                        connection.cancel()
                        return
                    }

                    if !self.transferStarted {

                        self.transferStarted = true

                        self.speedSampleTime =
                            Date()

                        self.totalBytesSentForSpeed =
                            0

                        self.speedSamples =
                            [(time: Date(), bytes: 0)]

                        self.highestPosition =
                            start

                        self.smoothedSpeed =
                            0

                        self.lastProgressUpdateTime =
                            nil
                    }

                    self.streamFile(
                        connection,
                        start: start,
                        end: end,
                        totalSize: fileSize
                    )
                }
        )
    }

    // MARK: - Stream File

    private func streamFile(
        _ connection: NWConnection,
        start: UInt64,
        end: UInt64,
        totalSize: UInt64
    ) {

        guard !stopRequested else {
            connection.cancel()
            return
        }

        guard masterFileDescriptor >= 0 else {

            print(
                "LocalHTTPServer: master FD unavailable"
            )

            connection.cancel()
            return
        }

        /*
         Every Range connection receives its own descriptor.

         pread() does not change the shared file offset, so parallel
         requests cannot interfere with one another.
         */
        let fd =
            dup(masterFileDescriptor)

        guard fd >= 0 else {

            print(
                "LocalHTTPServer: dup() failed errno=\(errno)"
            )

            connection.cancel()
            return
        }

        activeStreams += 1
        let diagnosticStreamID = nextDiagnosticStreamID
        nextDiagnosticStreamID += 1

        print(
            "LocalHTTPServer: stream opened FD=\(fd), range=\(start)-\(end), active=\(activeStreams)"
        )
        TransferDiagnostics.log("STABLE stream#\(diagnosticStreamID) OPEN fd=\(fd) range=\(start)-\(end) length=\(end-start+1) active=\(activeStreams)")

        let stream =
            StreamContext(
                fd: fd,
                start: start,
                end: end,
                diagnosticID: diagnosticStreamID
            )

        sendNextChunk(
            connection,
            stream: stream,
            position: start,
            totalSize: totalSize
        )
    }

    private func sendNextChunk(
        _ connection: NWConnection,
        stream: StreamContext,
        position: UInt64,
        totalSize: UInt64
    ) {

        guard !stream.finished else {
            return
        }

        guard position <= stream.end else {

            reportProgress(
                position: stream.end + 1,
                total: totalSize,
                bytesJustSent: 0
            )

            finishStream(
                connection,
                stream: stream,
                reason: "range complete"
            )

            return
        }

        let remaining =
            stream.end - position + 1

        /*
         Keep the same 1 MB network chunk size that produced the good
         17-18 MB/s results.
         */
        let chunkSize =
            Int(
                min(
                    remaining,
                    UInt64(1024 * 1024)
                )
            )

        /*
         Allocate exactly one chunk.

         Data owns this memory after creation, so the buffer remains
         valid until NWConnection finishes processing the send.
         */
        var buffer =
            [UInt8](
                repeating: 0,
                count: chunkSize
            )

        let bytesRead: Int =
            buffer.withUnsafeMutableBytes { rawBuffer in

                guard let baseAddress =
                    rawBuffer.baseAddress else {

                    return -1
                }

                /*
                 pread() reads from an explicit offset and does not
                 modify fd's current seek position.
                 */
                return Darwin.pread(
                    stream.fd,
                    baseAddress,
                    chunkSize,
                    off_t(position)
                )
            }

        if bytesRead < 0 {

            let errorNumber =
                errno

            print(
                "LocalHTTPServer: pread failed FD=\(stream.fd) position=\(position) errno=\(errorNumber)"
            )

            finishStream(
                connection,
                stream: stream,
                reason:
                    "pread error \(errorNumber)"
            )

            return
        }

        guard bytesRead > 0 else {

            print(
                "LocalHTTPServer: unexpected EOF at \(position)"
            )

            finishStream(
                connection,
                stream: stream,
                reason: "unexpected EOF"
            )

            return
        }

        let data =
            Data(
                buffer.prefix(
                    bytesRead
                )
            )

        connection.send(
            content: data,
            completion:
                .contentProcessed {
                    [weak self] error in

                    guard let self = self else {

                        /*
                         The StreamContext closes its FD in deinit as a
                         final safety net.
                         */
                        connection.cancel()
                        return
                    }

                    guard !stream.finished else {
                        return
                    }

                    if let error = error {

                        print(
                            "LocalHTTPServer: send error FD=\(stream.fd): \(error)"
                        )

                        TransferDiagnostics.log(
                            "STABLE stream#\(stream.diagnosticID) SEND ERROR position=\(position) bytesRead=\(bytesRead) error=\(error)"
                        )

                        self.finishStream(
                            connection,
                            stream: stream,
                            reason: "send error"
                        )

                        return
                    }

                    let sent =
                        UInt64(bytesRead)

                    let nextPosition =
                        position + sent

                    /*
                     Speed receives ONLY actual bytes successfully
                     processed by NWConnection.

                     Range offset jumps can no longer create fake
                     readings such as 146 MB/s.
                     */
                    self.reportProgress(
                        position: nextPosition,
                        total: totalSize,
                        bytesJustSent: sent
                    )

                    self.sendNextChunk(
                        connection,
                        stream: stream,
                        position: nextPosition,
                        totalSize: totalSize
                    )
                }
        )
    }

    // MARK: - Stream Lifetime

    private func finishStream(
        _ connection: NWConnection,
        stream: StreamContext,
        reason: String
    ) {

        guard !stream.finished else {
            return
        }

        stream.finished = true

        let fd =
            stream.fd

        if fd >= 0 {

            close(fd)
            stream.fd = -1
        }

        if activeStreams > 0 {
            activeStreams -= 1
        }

        print(
            "LocalHTTPServer: stream closed FD=\(fd), reason=\(reason), active=\(activeStreams)"
        )
        TransferDiagnostics.log("STABLE stream#\(stream.diagnosticID) CLOSE fd=\(fd) reason=\(reason) active=\(activeStreams)")

        connection.cancel()

        releaseResourcesIfPossible()
    }

    // MARK: - Progress / Real Throughput

    private func reportProgress(
        position: UInt64,
        total: UInt64,
        bytesJustSent: UInt64
    ) {

        let now =
            Date()

        let currentPosition =
            min(
                position,
                total
            )

        /*
         Progress never moves backwards even if PlayStation starts
         another Range slightly behind the current Range.
         */
        if currentPosition >
            highestPosition {

            highestPosition =
                currentPosition
        }

        let visiblePosition =
            min(
                highestPosition,
                total
            )

        /*
         Count real bytes processed by NWConnection.
         */
        if bytesJustSent > 0 {
            totalBytesSentForSpeed += bytesJustSent
        }

        if let sampleTime = speedSampleTime {
            let interval = now.timeIntervalSince(sampleTime)

            /*
             Refresh the displayed value about twice per second, but
             calculate it from a rolling 10-second window of bytes that
             NWConnection actually sent. This keeps Speed and ETA live
             while making short Wi-Fi spikes much less visible.
             */
            if interval >= 0.5 {
                speedSamples.append((time: now, bytes: totalBytesSentForSpeed))

                let cutoff = now.addingTimeInterval(-speedWindow)
                while speedSamples.count > 2 && speedSamples[1].time < cutoff {
                    speedSamples.removeFirst()
                }

                if let oldest = speedSamples.first {
                    let windowInterval = now.timeIntervalSince(oldest.time)
                    let windowBytes = totalBytesSentForSpeed >= oldest.bytes
                        ? totalBytesSentForSpeed - oldest.bytes
                        : 0

                    if windowInterval > 0 {
                        smoothedSpeed = Double(windowBytes) / windowInterval
                    }
                }

                speedSampleTime = now
            }
        } else {
            speedSampleTime = now
            speedSamples = [(time: now, bytes: totalBytesSentForSpeed)]
        }

        // Update UI approximately twice per second.

        let shouldUpdate: Bool

        if visiblePosition >= total {

            shouldUpdate = true

        } else if let lastUpdate =
                    lastProgressUpdateTime {

            shouldUpdate =
                now.timeIntervalSince(
                    lastUpdate
                ) >= 0.5

        } else {

            shouldUpdate = true
        }

        guard shouldUpdate else {
            return
        }

        lastProgressUpdateTime =
            now

        let progress =
            TransferProgress(
                sentBytes: visiblePosition,
                totalBytes: total,
                bytesPerSecond: smoothedSpeed
            )

        if now.timeIntervalSince(lastDiagnosticSampleTime) >= 2.0 {
            lastDiagnosticSampleTime = now
            TransferDiagnostics.log(String(format: "STABLE SAMPLE visible=%llu totalActualBytes=%llu speed=%.2fMiB/s active=%d", visiblePosition, totalBytesSentForSpeed, smoothedSpeed / 1_048_576.0, activeStreams))
        }

        DispatchQueue.main.async {
            self.onProgress(progress)
        }
    }

    private func resetTransferStatistics() {

        transferStarted =
            false

        highestPosition =
            0

        knownTotalSize =
            0

        totalBytesSentForSpeed =
            0

        speedSampleTime =
            nil

        speedSamples =
            []

        smoothedSpeed =
            0

        lastProgressUpdateTime =
            nil
    }

    // MARK: - HTTP Errors

    private func sendError(
        _ connection: NWConnection,
        code: Int,
        text: String
    ) {

        let body =
            Data(
                text.utf8
            )

        let header =
            "HTTP/1.1 \(code) \(text)\r\n"
            +
            "Content-Type: text/plain\r\n"
            +
            "Content-Length: \(body.count)\r\n"
            +
            "Connection: close\r\n\r\n"

        var response =
            Data(
                header.utf8
            )

        response.append(
            body
        )

        connection.send(
            content: response,
            completion:
                .contentProcessed { _ in

                    connection.cancel()
                }
        )
    }

    private func sendRangeNotSatisfiable(
        _ connection: NWConnection,
        fileSize: UInt64
    ) {

        let header =
            "HTTP/1.1 416 Range Not Satisfiable\r\n"
            +
            "Content-Range: bytes */\(fileSize)\r\n"
            +
            "Content-Length: 0\r\n"
            +
            "Connection: close\r\n\r\n"

        connection.send(
            content:
                Data(
                    header.utf8
                ),
            completion:
                .contentProcessed { _ in

                    connection.cancel()
                }
        )
    }

    // MARK: - Local IP

    private func localIPv4(for targetIP: String?) -> String? {
        let interfaces = ipv4Interfaces()
        let interfaceSummary = interfaces.map { "\($0.name)=\($0.address)" }.joined(separator: ", ")
        TransferDiagnostics.log("NET interfaces [\(interfaceSummary)] target=\(targetIP ?? "nil")")

        // First choice: an address that is actually on the same IPv4 subnet as the PS4.
        // This preserves normal router/LAN behaviour and avoids choosing an unrelated en0.
        if let targetIP,
           let target = ipv4Number(targetIP) {
            for item in interfaces where item.netmask != 0 {
                if (item.addressNumber & item.netmask) == (target & item.netmask) {
                    TransferDiagnostics.log("NET selected same-subnet \(item.name)=\(item.address)")
                    return item.address
                }
            }
        }

        // Personal Hotspot can NAT its client-facing address and hide that address from
        // getifaddrs(). In that case iOS may report an internal source (for example
        // 192.168.x.x) even though the PS4 sees the hotspot gateway on its own subnet.
        // Derive the Apple-hotspot gateway from the PS4 address instead of hardcoding .1.
        if let targetIP,
           let target = ipv4Number(targetIP),
           (target & 0xFFFFFFF0) == 0xAC140A00 { // 172.20.10.0/28 Apple hotspot range
            let gateway = (target & 0xFFFFFFF0) | 1
            let derived = ipv4String(gateway)
            TransferDiagnostics.log("NET selected hotspot-derived gateway=\(derived) from target=\(targetIP)")
            return derived
        }

        // Normal fallback: keep the original Wi-Fi preference.
        if let wifi = interfaces.first(where: { $0.name == "en0" }) {
            TransferDiagnostics.log("NET selected fallback en0=\(wifi.address)")
            return wifi.address
        }
        if let bridge = interfaces.first(where: { $0.name.hasPrefix("bridge") || $0.name.hasPrefix("ap") }) {
            TransferDiagnostics.log("NET selected fallback \(bridge.name)=\(bridge.address)")
            return bridge.address
        }

        TransferDiagnostics.log("NET no usable IPv4 address")
        return nil
    }

    private struct IPv4InterfaceInfo {
        let name: String
        let address: String
        let addressNumber: UInt32
        let netmask: UInt32
    }

    private func ipv4Interfaces() -> [IPv4InterfaceInfo] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
        defer { freeifaddrs(addresses) }

        var result: [IPv4InterfaceInfo] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = pointer {
            defer { pointer = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &hostname,
                              socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostname)
            guard ip != "127.0.0.1", !ip.hasPrefix("169.254."), let number = ipv4Number(ip) else { continue }

            var maskNumber: UInt32 = 0
            if let mask = interface.pointee.ifa_netmask,
               mask.pointee.sa_family == UInt8(AF_INET) {
                let sin = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self)
                maskNumber = UInt32(bigEndian: sin.pointee.sin_addr.s_addr)
            }
            result.append(.init(name: name, address: ip, addressNumber: number, netmask: maskNumber))
        }
        return result
    }

    private func ipv4Number(_ string: String) -> UInt32? {
        var addr = in_addr()
        guard string.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    private func ipv4String(_ number: UInt32) -> String {
        var addr = in_addr(s_addr: number.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "0.0.0.0" }
        return String(cString: buffer)
    }

    // MARK: - Stream Context

    /*
     Reference type on purpose.

     All asynchronous send callbacks refer to the same stream object,
     which lets us guarantee that each duplicated FD is closed only once.
     */
    private final class StreamContext {

        var fd: Int32

        let start: UInt64
        let end: UInt64
        let diagnosticID: Int

        var finished = false

        init(
            fd: Int32,
            start: UInt64,
            end: UInt64,
            diagnosticID: Int
        ) {

            self.fd =
                fd

            self.start =
                start

            self.end =
                end

            self.diagnosticID =
                diagnosticID
        }

        deinit {

            /*
             Final safety net.

             Normally finishStream() already closes the FD and changes
             fd to -1.
             */
            if fd >= 0 {
                close(fd)
                fd = -1
            }
        }
    }

    private enum ServerError: LocalizedError {
        case listenerUnavailable
        case fileOpenFailed(code: Int32)
        case invalidFile(code: Int32)
        case listenerCreationFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .listenerUnavailable:
                return "Local server listener is unavailable."
            case .fileOpenFailed(let code):
                return "Could not open the selected PKG (errno \(code): \(String(cString: strerror(code))))."
            case .invalidFile(let code):
                return "Could not read the selected PKG (errno \(code): \(String(cString: strerror(code))))."
            case .listenerCreationFailed(let message):
                return "Could not create the local server listener: \(message)"
            }
        }
    }
}
