import Darwin
import Foundation

/// Start multicast announcements and answer discovery requests on a background queue.
/// The caller must retain the returned timer for as long as the server runs.
func startSSDP(ip: String, device: UPnPDevice) throws -> DispatchSourceTimer {
    let multicastIP = "239.255.255.250"
    let multicastPort: UInt16 = 1900
    let multicastAddress = ipv4Address(multicastIP, multicastPort)
    let udpSocket = socket(AF_INET, SOCK_DGRAM, 0)
    guard udpSocket >= 0 else { throw socketError("Could not create SSDP socket") }
    var started = false
    defer {
        if !started { close(udpSocket) }
    }

    var reuseAddress: Int32 = 1
    setsockopt(udpSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, 4)
    try bindSocket(udpSocket, "0.0.0.0", multicastPort)

    // Join the SSDP group on the same interface advertised in the device URL.
    var interfaceAddress = ipv4Address(ip, 0).sin_addr
    var membership = ip_mreq(
        imr_multiaddr: multicastAddress.sin_addr,
        imr_interface: interfaceAddress)
    let membershipResult = setsockopt(
        udpSocket, IPPROTO_IP, IP_ADD_MEMBERSHIP,
        &membership, socklen_t(MemoryLayout<ip_mreq>.size))
    guard membershipResult == 0 else {
        throw socketError("Could not join SSDP multicast group")
    }
    setsockopt(
        udpSocket, IPPROTO_IP, IP_MULTICAST_IF,
        &interfaceAddress, socklen_t(MemoryLayout<in_addr>.size))

    let targets = [
        device.uuid, "upnp:rootdevice", deviceType,
        contentDirectoryService, connectionManagerService,
    ]

    func sendDatagram(_ message: String, to destination: sockaddr_in) {
        var destination = destination
        Data(message.utf8).withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(
                        udpSocket, bytes.baseAddress, bytes.count, 0,
                        $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // USN identifies either the device itself or a service/type provided by the device.
    func uniqueServiceName(for target: String) -> String {
        target == device.uuid ? device.uuid : "\(device.uuid)::\(target)"
    }

    let commonHeaders =
        "CACHE-CONTROL: max-age=180\r\n"
        + "LOCATION: \(device.base)/description.xml\r\n"
        + "SERVER: Darwin/1.0 UPnP/1.0 microDLNA/1.0\r\n"

    let timer = DispatchSource.makeTimerSource()
    // Refresh every minute so the 180-second advertisements do not expire.
    timer.schedule(deadline: .now(), repeating: 60)
    timer.setEventHandler {
        for target in targets {
            let announcement =
                "NOTIFY * HTTP/1.1\r\n"
                + "HOST: 239.255.255.250:1900\r\n"
                + commonHeaders
                + "NT: \(target)\r\n"
                + "NTS: ssdp:alive\r\n"
                + "USN: \(uniqueServiceName(for: target))\r\n\r\n"
            sendDatagram(announcement, to: multicastAddress)
        }
    }
    timer.resume()

    DispatchQueue.global().async {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            var peer = sockaddr_in()
            var addressSize = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bytesRead = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(udpSocket, &buffer, buffer.count, 0, $0, &addressSize)
                }
            }
            guard bytesRead > 0 else { continue }

            let message = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
            guard message.hasPrefix("M-SEARCH * HTTP/1.1"),
                message.lowercased().contains("ssdp:discover")
            else { continue }

            let searchTarget =
                message.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("st:") }?
                .dropFirst(3).trimmingCharacters(in: .whitespaces) ?? ""
            let destination = peer

            // ssdp:all requests one unicast response for every advertised target.
            for target in targets where searchTarget == "ssdp:all" || searchTarget == target {
                let response =
                    "HTTP/1.1 200 OK\r\n"
                    + commonHeaders
                    + "EXT:\r\n"
                    + "ST: \(target)\r\n"
                    + "USN: \(uniqueServiceName(for: target))\r\n\r\n"
                DispatchQueue.global().asyncAfter(deadline: .now() + Double.random(in: 0...0.1)) {
                    sendDatagram(response, to: destination)
                }
            }
        }
    }
    started = true
    return timer
}
