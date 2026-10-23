import Darwin
import Foundation

/// Select an active IPv4 interface that can send SSDP multicast traffic.
func localIPv4() -> String? {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { return nil }
    defer { freeifaddrs(interfaces) }

    var current = interfaces
    var fallback: String?
    let requiredFlags = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)

    while let entry = current {
        defer { current = entry.pointee.ifa_next }
        let interface = entry.pointee
        guard interface.ifa_flags & requiredFlags == requiredFlags,
            interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
            let socketAddress = interface.ifa_addr,
            socketAddress.pointee.sa_family == sa_family_t(AF_INET)
        else { continue }

        var ip = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr
        }
        let hostAddress = UInt32(bigEndian: ip.s_addr)
        // Ignore unspecified and self-assigned link-local addresses (169.254/16).
        guard hostAddress != 0, hostAddress & 0xffff_0000 != 0xa9fe_0000 else { continue }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil else { continue }
        let addressString = String(cString: buffer)

        // macOS names Ethernet and Wi-Fi interfaces en*. Prefer them over virtual interfaces.
        if String(cString: interface.ifa_name).hasPrefix("en") {
            return addressString
        }
        if fallback == nil {
            fallback = addressString
        }
    }
    return fallback
}

func ipv4Address(_ ip: String, _ port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    inet_pton(AF_INET, ip, &address.sin_addr)
    return address
}

func bindSocket(_ socket: Int32, _ ip: String, _ port: UInt16) throws {
    var address = ipv4Address(ip, port)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        throw socketError("Could not bind \(ip):\(port)")
    }
}

/// Preserve errno before reporting startup failures to the menu bar application.
func socketError(_ operation: String) -> NSError {
    let errorCode = errno
    return NSError(
        domain: NSPOSIXErrorDomain, code: Int(errorCode),
        userInfo: [
            NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errorCode)))"
        ])
}

/// A successful send can still write fewer bytes than requested.
func sendAll(_ socket: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let bytesSent = Darwin.send(
                socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            guard bytesSent > 0 else { return false }
            offset += bytesSent
        }
        return true
    }
}
