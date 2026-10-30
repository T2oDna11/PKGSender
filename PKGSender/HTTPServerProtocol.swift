import Foundation

protocol PKGHTTPServing: AnyObject {
    func start() throws
    func stop()
}

extension LocalHTTPServer: PKGHTTPServing {}

func makePKGHTTPServer(
    fileURL: URL,
    targetPlayStationIP: String? = nil,
    onReady: @escaping (String) -> Void,
    onProgress: @escaping (LocalHTTPServer.TransferProgress) -> Void
) throws -> any PKGHTTPServing {
    // Select the experimental POSIX engine for the known iPhone Personal
    // Hotspot subnet. Keep the proven Network.framework server everywhere else.
    let isHotspotTarget = targetPlayStationIP?.hasPrefix("172.20.10.") == true

    if isHotspotTarget || HotspotPOSIXHTTPServer.hotspotIsActive() {
        TransferDiagnostics.log(
            "ENGINE selected HOTSPOT-POSIX target=\(targetPlayStationIP ?? "nil")"
        )
        return try HotspotPOSIXHTTPServer(
            fileURL: fileURL,
            onReady: onReady,
            onProgress: onProgress
        )
    }

    TransferDiagnostics.log(
        "ENGINE selected STABLE-NW target=\(targetPlayStationIP ?? "nil")"
    )
    return try LocalHTTPServer(
        fileURL: fileURL,
        targetPlayStationIP: targetPlayStationIP,
        onReady: onReady,
        onProgress: onProgress
    )
}
