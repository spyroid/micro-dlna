import Darwin
import Foundation

func reply(
    _ socket: Int32,
    _ status: String,
    _ body: String,
    head: Bool = false,
    headers: String = "Content-Type: text/xml; charset=\"utf-8\"\r\n"
) {
    reply(socket, status, Data(body.utf8), head: head, headers: headers)
}

func reply(
    _ socket: Int32,
    _ status: String,
    _ body: Data,
    head: Bool = false,
    headers: String = "Content-Type: text/xml; charset=\"utf-8\"\r\n"
) {
    let responseHeaders =
        "HTTP/1.1 \(status)\r\n"
        + headers
        + "Content-Length: \(body.count)\r\n"
        + "Connection: close\r\n\r\n"

    _ = sendAll(socket, Data(responseHeaders.utf8))
    // HEAD returns the same headers as GET, but omits the body.
    if !head {
        _ = sendAll(socket, body)
    }
}

/// Parse a single HTTP byte range and return inclusive file offsets.
func byteRange(_ header: String, size: UInt64) -> (start: UInt64, end: UInt64)? {
    guard size > 0, header.hasPrefix("bytes=") else { return nil }
    let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }

    // A suffix range such as "bytes=-500" requests the last 500 bytes.
    if parts[0].isEmpty {
        guard let count = UInt64(parts[1]), count > 0 else { return nil }
        return (size - min(size, count), size - 1)
    }

    guard let start = UInt64(parts[0]), start < size else { return nil }
    let end: UInt64
    if parts[1].isEmpty {
        end = size - 1
    } else {
        guard let requestedEnd = UInt64(parts[1]) else { return nil }
        end = min(requestedEnd, size - 1)
    }
    return start <= end ? (start, end) : nil
}

struct HTTPServer {
    let device: UPnPDevice

    private func serve(_ socket: Int32) {
        defer { close(socket) }

        // Bound stalled clients and avoid SIGPIPE if a player disconnects during a send.
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, 4)

        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let headerSeparator = Data("\r\n\r\n".utf8)

        // TCP reads may contain only part of the headers, or headers plus some body bytes.
        while requestData.range(of: headerSeparator) == nil {
            let bytesRead = recv(socket, &buffer, buffer.count, 0)
            guard bytesRead > 0 else { return }
            requestData.append(contentsOf: buffer.prefix(bytesRead))
            guard requestData.count <= 65_536 else { return }
        }

        let headerBoundary = requestData.range(of: headerSeparator)!
        let headerText = String(decoding: requestData[..<headerBoundary.lowerBound], as: UTF8.self)
        let headerLines = headerText.components(separatedBy: "\r\n")
        let requestLine = headerLines[0].split(separator: " ")
        guard requestLine.count == 3 else { return }

        let method = String(requestLine[0])
        let path = String(requestLine[1])
        let isHead = method == "HEAD"
        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }

        // Only fixed-length request bodies are supported; cap SOAP payloads at 64 KiB.
        guard headers["transfer-encoding"] == nil,
            let bodyLength = Int(headers["content-length"] ?? "0"),
            (0...65_536).contains(bodyLength)
        else {
            reply(socket, "400 Bad Request", "")
            return
        }

        let bodyStart = headerBoundary.upperBound
        while requestData.count - bodyStart < bodyLength {
            let remaining = bodyLength - (requestData.count - bodyStart)
            let bytesRead = recv(socket, &buffer, min(buffer.count, remaining), 0)
            guard bytesRead > 0 else { return }
            requestData.append(contentsOf: buffer.prefix(bytesRead))
        }

        if method == "GET" || isHead {
            switch path {
            case "/description.xml":
                reply(socket, "200 OK", device.description, head: isHead)
            case "/cd.xml":
                reply(socket, "200 OK", serviceDescription(contentDirectoryActions), head: isHead)
            case "/cm.xml":
                reply(socket, "200 OK", serviceDescription(connectionManagerActions), head: isHead)
            case let iconPath where iconPath.hasPrefix("/icons/"):
                guard let image = MediaIcon.images[iconPath] else {
                    reply(socket, "404 Not Found", "", head: isHead)
                    return
                }
                reply(
                    socket, "200 OK", image, head: isHead,
                    headers: "Content-Type: image/png\r\nCache-Control: public, max-age=86400\r\n")
            default:
                serveMedia(socket, path: path, rangeHeader: headers["range"], head: isHead)
            }
        } else if method == "POST" && (path == "/cd" || path == "/cm") {
            // SOAPAction contains a quoted service URN followed by #ActionName.
            let soapAction = (headers["soapaction"] ?? "").replacingOccurrences(of: "\"", with: "")
            let action = soapAction.components(separatedBy: "#").last ?? ""
            let body = requestData.subdata(in: bodyStart..<(bodyStart + bodyLength))
            device.control(socket, path: path, action: action, data: body)
        } else {
            reply(socket, "405 Method Not Allowed", "")
        }
    }

    private func serveMedia(_ socket: Int32, path: String, rangeHeader: String?, head: Bool) {
        guard path.hasPrefix("/media/"), let index = Int(path.dropFirst(7)),
            device.library.files.indices.contains(index)
        else {
            reply(socket, "404 Not Found", "", head: head)
            return
        }

        // Recheck symlinks: a file may have changed since the catalogue was built.
        let file = device.library.files[index].resolvingSymlinksInPath()
        guard file.path.hasPrefix(device.library.root.path + "/"),
            let handle = try? FileHandle(forReadingFrom: file)
        else {
            reply(socket, "404 Not Found", "", head: head)
            return
        }
        defer { try? handle.close() }

        do {
            let size = try handle.seekToEnd()
            var start: UInt64 = 0
            var end = size == 0 ? 0 : size - 1
            if let rangeHeader {
                guard let range = byteRange(rangeHeader, size: size) else {
                    reply(
                        socket, "416 Range Not Satisfiable", "", head: head,
                        headers: "Content-Range: bytes */\(size)\r\n")
                    return
                }
                (start, end) = range
            }

            var remaining = size == 0 ? 0 : end - start + 1
            let contentRange =
                rangeHeader == nil
                ? "" : "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
            let status = rangeHeader == nil ? "200 OK" : "206 Partial Content"
            let mimeType =
                mediaTypes[file.pathExtension.lowercased()]?.mimeType
                ?? "application/octet-stream"
            let responseHeaders =
                "HTTP/1.1 \(status)\r\n"
                + "Content-Type: \(mimeType)\r\n"
                + "Content-Length: \(remaining)\r\n"
                + "Accept-Ranges: bytes\r\n"
                + contentRange
                + "Connection: close\r\n\r\n"
            guard sendAll(socket, Data(responseHeaders.utf8)), !head else { return }

            // Stream in 256 KiB chunks instead of loading the whole file into memory.
            try handle.seek(toOffset: start)
            while remaining > 0 {
                guard let chunk = try handle.read(upToCount: Int(min(remaining, 262_144))),
                    !chunk.isEmpty, sendAll(socket, chunk)
                else { return }
                remaining -= UInt64(chunk.count)
            }
        } catch {
            // Headers may already be sent; closing the connection ends a failed stream.
            return
        }
    }

    /// Prepare the listener before starting SSDP, so failed HTTP startup is not advertised.
    func listen(ip: String) throws -> Int32 {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw socketError("Could not create HTTP socket") }
        var reuseAddress: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, 4)
        do {
            try bindSocket(listener, ip, 8200)
            guard Darwin.listen(listener, 16) == 0 else {
                throw socketError("Could not listen for HTTP connections")
            }
            return listener
        } catch {
            close(listener)
            throw error
        }
    }

    func run(listener: Int32) {
        print(
            "μDLNA server: \(device.library.files.count) files, \(device.base) — Ctrl+C to stop")

        // ponytail: at most eight simultaneous requests; use an event loop for more clients.
        let availableSlots = DispatchSemaphore(value: 8)
        while true {
            availableSlots.wait()
            let client = accept(listener, nil, nil)
            if client < 0 {
                availableSlots.signal()
                continue
            }
            DispatchQueue.global().async {
                serve(client)
                availableSlots.signal()
            }
        }
    }
}
