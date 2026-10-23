import AppKit
import Darwin
import Foundation

// Keep the built-in checks independent of media folders and listening sockets.
if CommandLine.arguments.contains("--self-test") {
    assert(escapeXML("<&\"") == "&lt;&amp;&quot;")
    assert(byteRange("bytes=2-99", size: 10)!.end == 9)
    assert(byteRange("bytes=-3", size: 10)!.start == 7)
    assert(byteRange("bytes=10-", size: 10) == nil)
    assert(byteRange("bytes=1-2,4-5", size: 10) == nil)
    if let ip = localIPv4() {
        var parsed = in_addr()
        assert(inet_pton(AF_INET, ip, &parsed) == 1)
        assert(!ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && ip != "0.0.0.0")
    }
    print("Self-test OK")
    exit(0)
}

// Both positional arguments are optional: microdlna [MEDIA_DIRECTORY [LAN_IP]].
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count <= 2 else {
    print(
        "Usage: microdlna [MEDIA_DIRECTORY [LAN_IP]]\nDefaults: ~/Movies and automatic LAN IPv4"
    )
    exit(1)
}
let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Movies", isDirectory: true)
let mediaDirectory = arguments.first.map { URL(fileURLWithPath: $0) } ?? defaultDirectory
let requestedIP = arguments.count == 2 ? arguments[1] : nil

let application = NSApplication.shared
// Accessory applications live in the menu bar without a Dock icon or a main window.
application.setActivationPolicy(.accessory)
let delegate = ApplicationDelegate(mediaDirectory: mediaDirectory, requestedIP: requestedIP)
application.delegate = delegate
application.run()
