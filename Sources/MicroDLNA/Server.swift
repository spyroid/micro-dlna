import Darwin
import Foundation

/// Run on a background thread; the application owns the process lifetime.
func runMediaServer(directory: URL, requestedIP: String?) throws {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        throw NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "Media directory does not exist: \(root.path)"])
    }

    guard let ip = requestedIP ?? localIPv4() else {
        throw NSError(
            domain: NSPOSIXErrorDomain, code: Int(ENETDOWN),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "No active LAN IPv4 address found. Connect to Wi-Fi or Ethernet and restart the application."
            ])
    }
    var parsedIP = in_addr()
    guard inet_pton(AF_INET, ip, &parsedIP) == 1 else {
        throw NSError(
            domain: NSPOSIXErrorDomain, code: Int(EINVAL),
            userInfo: [NSLocalizedDescriptionKey: "Expected an IPv4 LAN address: \(ip)"])
    }

    let library = try MediaLibrary(root: root, base: "http://\(ip):8200")
    let device = UPnPDevice(library: library)
    let server = HTTPServer(device: device)
    let listener = try server.listen(ip: ip)
    defer { close(listener) }
    let discovery = try startSSDP(ip: ip, device: device)

    // Keep announcements alive while the HTTP accept loop runs.
    withExtendedLifetime(discovery) {
        server.run(listener: listener)
    }
}
