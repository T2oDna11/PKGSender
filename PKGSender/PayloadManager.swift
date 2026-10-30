import Foundation
import Network

/// Sends the bundled PKG USB ELF to GoldHEN's BinLoader (TCP 9090).
/// The ELF is bundled with the IPA so USB transfer can always start offline.
final class PayloadManager {
    static let shared = PayloadManager()

    enum PayloadError: LocalizedError {
        case invalidHost
        case bundledPayloadMissing
        case customPayloadImportFailed(String)
        case readFailed(Error)
        case connectionFailed(String)
        case sendFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidHost: return "Invalid PlayStation IP address."
            case .bundledPayloadMissing: return "Built-in pkgusb.elf is missing from the app bundle."
            case .customPayloadImportFailed(let message): return "Could not import payload: \(message)"
            case .readFailed(let error): return "Could not read built-in payload: \(error.localizedDescription)"
            case .connectionFailed(let message): return "BinLoader connection failed: \(message)"
            case .sendFailed(let message): return "Payload send failed: \(message)"
            }
        }
    }

    private let queue = DispatchQueue(label: "PKGSender.PayloadManager", qos: .userInitiated)
    private init() {}

    private var customPayloadURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("CustomPayload").appendingPathComponent("pkgusb.elf")
    }

    var hasCustomPayload: Bool {
        FileManager.default.fileExists(atPath: customPayloadURL.path)
    }

    func activePayloadName() -> String {
        hasCustomPayload ? "Custom ELF" : "\(bundledVersion()) Built-in"
    }

    func importCustomPayload(from sourceURL: URL) throws {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let data: Data
        do { data = try Data(contentsOf: sourceURL, options: .mappedIfSafe) }
        catch { throw PayloadError.customPayloadImportFailed(error.localizedDescription) }

        guard data.count >= 4,
              data[0] == 0x7F, data[1] == 0x45, data[2] == 0x4C, data[3] == 0x46 else {
            throw PayloadError.customPayloadImportFailed("The selected file is not an ELF payload.")
        }

        let folder = customPayloadURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: customPayloadURL, options: .atomic)
        } catch {
            throw PayloadError.customPayloadImportFailed(error.localizedDescription)
        }
    }

    func restoreBuiltInPayload() throws {
        if FileManager.default.fileExists(atPath: customPayloadURL.path) {
            try FileManager.default.removeItem(at: customPayloadURL)
        }
    }

    private func activePayloadURL() -> URL? {
        if hasCustomPayload { return customPayloadURL }
        return Bundle.main.url(forResource: "pkgusb", withExtension: "elf")
    }

    func bundledVersion() -> String {
        guard let url = Bundle.main.url(forResource: "payload", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String else { return "Built-in" }
        return version
    }

    func sendBuiltInPayload(host: String, port: UInt16 = 9090,
                            completion: @escaping (Result<Void, Error>) -> Void) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            TransferDiagnostics.log("PAYLOAD 9090 ABORT invalid/empty host")
            DispatchQueue.main.async { completion(.failure(PayloadError.invalidHost)) }
            return
        }
        guard let elfURL = activePayloadURL() else {
            TransferDiagnostics.log("PAYLOAD 9090 ABORT active pkgusb.elf missing")
            DispatchQueue.main.async { completion(.failure(PayloadError.bundledPayloadMissing)) }
            return
        }

        let payload: Data
        do { payload = try Data(contentsOf: elfURL, options: .mappedIfSafe) }
        catch {
            TransferDiagnostics.log("PAYLOAD 9090 READ FAILED file=\(elfURL.lastPathComponent) error=\(error.localizedDescription)")
            DispatchQueue.main.async { completion(.failure(PayloadError.readFailed(error))) }
            return
        }

        guard payload.count >= 4,
              payload[0] == 0x7F, payload[1] == 0x45,
              payload[2] == 0x4C, payload[3] == 0x46 else {
            let message = "Active payload is not a valid ELF file."
            TransferDiagnostics.log("PAYLOAD 9090 ABORT invalid ELF bytes=\(payload.count) file=\(elfURL.lastPathComponent)")
            DispatchQueue.main.async { completion(.failure(PayloadError.sendFailed(message))) }
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            TransferDiagnostics.log("PAYLOAD ABORT invalid port=\(port)")
            DispatchQueue.main.async { completion(.failure(PayloadError.invalidHost)) }
            return
        }

        let source = hasCustomPayload ? "custom" : "built-in"
        TransferDiagnostics.log("PAYLOAD BEGIN host=\(trimmed):\(port) source=\(source) file=\(elfURL.lastPathComponent) bytes=\(payload.count)")

        let connection = NWConnection(host: NWEndpoint.Host(trimmed), port: nwPort, using: .tcp)
        let stateQueue = DispatchQueue(label: "PKGSender.PayloadManager.state")
        var finished = false
        var didStartSend = false
        var timeoutWorkItem: DispatchWorkItem?

        func finish(_ result: Result<Void, Error>) {
            stateQueue.async {
                guard !finished else { return }
                finished = true
                timeoutWorkItem?.cancel()

                switch result {
                case .success:
                    TransferDiagnostics.log("PAYLOAD COMPLETE host=\(trimmed):\(port) bytes=\(payload.count)")
                case .failure(let error):
                    TransferDiagnostics.log("PAYLOAD FAILED host=\(trimmed):\(port) error=\(error.localizedDescription)")
                }

                connection.stateUpdateHandler = nil
                connection.cancel()
                DispatchQueue.main.async { completion(result) }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .setup:
                TransferDiagnostics.log("PAYLOAD 9090 STATE setup")

            case .preparing:
                TransferDiagnostics.log("PAYLOAD 9090 STATE preparing")

            case .waiting(let error):
                TransferDiagnostics.log("PAYLOAD 9090 STATE waiting error=\(error.localizedDescription)")

            case .ready:
                stateQueue.async {
                    guard !finished, !didStartSend else { return }
                    didStartSend = true
                    TransferDiagnostics.log("PAYLOAD 9090 STATE ready; SEND START bytes=\(payload.count)")

                    connection.send(content: payload,
                                    contentContext: .defaultMessage,
                                    isComplete: true,
                                    completion: .contentProcessed { error in
                        if let error {
                            TransferDiagnostics.log("PAYLOAD 9090 SEND CALLBACK error=\(error.localizedDescription)")
                            finish(.failure(PayloadError.sendFailed(error.localizedDescription)))
                        } else {
                            TransferDiagnostics.log("PAYLOAD 9090 SEND CALLBACK accepted bytes=\(payload.count)")
                            finish(.success(()))
                        }
                    })
                }

            case .failed(let error):
                TransferDiagnostics.log("PAYLOAD 9090 STATE failed error=\(error.localizedDescription)")
                finish(.failure(PayloadError.connectionFailed(error.localizedDescription)))

            case .cancelled:
                TransferDiagnostics.log("PAYLOAD 9090 STATE cancelled")
                stateQueue.async {
                    if !finished {
                        finish(.failure(PayloadError.connectionFailed("connection cancelled")))
                    }
                }

            @unknown default:
                TransferDiagnostics.log("PAYLOAD 9090 STATE unknown")
            }
        }

        let timeout = DispatchWorkItem {
            stateQueue.async {
                guard !finished else { return }
                let phase = didStartSend ? "send" : "connect"
                TransferDiagnostics.log("PAYLOAD 9090 TIMEOUT phase=\(phase) after=12s")
                finish(.failure(PayloadError.connectionFailed("timeout while waiting for BinLoader (\(phase))")))
            }
        }
        timeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + 12, execute: timeout)

        TransferDiagnostics.log("PAYLOAD 9090 CONNECT START")
        connection.start(queue: queue)
    }
}
