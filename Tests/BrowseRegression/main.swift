import AppKit
import Darwin
import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

for filename in ["video & clip.mp4", "track.mp3", "photo.png", "ignored.txt"] {
    try Data("fixture".utf8).write(to: root.appendingPathComponent(filename))
}
let library = try MediaLibrary(root: root, base: "http://127.0.0.1:8200")
let device = UPnPDevice(library: library)
precondition(library.files.count == 3)

func browse(
    _ arguments: String, using targetDevice: UPnPDevice = device
) throws -> (status: String, document: XMLDocument) {
    var sockets: [Int32] = [-1, -1]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    defer {
        close(sockets[0])
        close(sockets[1])
    }
    let request = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
              \(arguments)
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """
    targetDevice.control(sockets[0], path: "/cd", action: "Browse", data: Data(request.utf8))
    shutdown(sockets[0], SHUT_WR)

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = recv(sockets[1], &buffer, buffer.count, 0)
        if count <= 0 { break }
        response.append(contentsOf: buffer.prefix(count))
    }
    let text = String(decoding: response, as: UTF8.self)
    let sections = text.components(separatedBy: "\r\n\r\n")
    precondition(sections.count == 2)
    return (sections[0].components(separatedBy: "\r\n")[0], try XMLDocument(xmlString: sections[1]))
}

func check(_ condition: Bool) {
    precondition(condition)
}

func value(_ document: XMLDocument, _ name: String) throws -> String {
    let nodes = try document.nodes(forXPath: "//*[local-name()='\(name)']")
    return nodes.first?.stringValue ?? ""
}

// Computer names may contain Unicode or XML characters; missing names keep the base title.
for (computerName, expected) in [
    (nil, "μDLNA server"),
    ("", "μDLNA server"),
    (" \n ", "μDLNA server"),
    ("  Мак & <Media> \"Studio\"  ", "μDLNA server — Мак & <Media> \"Studio\""),
] as [(String?, String)] {
    let namedDevice = UPnPDevice(library: library, computerName: computerName)
    let description = try XMLDocument(xmlString: namedDevice.description)
    check(try value(description, "friendlyName") == expected)
}
let localName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
let expectedName = localName.isEmpty ? "μDLNA server" : "μDLNA server — \(localName)"
check(try value(XMLDocument(xmlString: device.description), "friendlyName") == expectedName)

let arguments = """
    <ObjectID>0</ObjectID>
    <BrowseFlag>BrowseDirectChildren</BrowseFlag>
    <Filter>*</Filter>
    <StartingIndex>0</StartingIndex>
    <RequestedCount>0</RequestedCount>
    <SortCriteria></SortCriteria>
    """
let formatted = try browse(arguments)
precondition(formatted.status == "HTTP/1.1 200 OK")
check(try value(formatted.document, "NumberReturned") == "3")
check(try value(formatted.document, "TotalMatches") == "3")

// Clients such as VLC classify items using these exact prefixes.
let didlText = try value(formatted.document, "Result")
let didl = try XMLDocument(xmlString: didlText)
let classes = try didl.nodes(forXPath: "//*[local-name()='class']").map { $0.stringValue ?? "" }
precondition(
    classes == [
        "object.item.imageItem.photo", "object.item.audioItem.musicTrack", "object.item.videoItem",
    ])
let titles = try didl.nodes(forXPath: "//*[local-name()='title']").map { $0.stringValue ?? "" }
precondition(titles.contains("video & clip.mp4"))
let artworkURLs = try didl.nodes(forXPath: "//*[local-name()='albumArtURI']")
    .map { $0.stringValue ?? "" }
precondition(
    artworkURLs == [
        "http://127.0.0.1:8200/icons/png.png",
        "http://127.0.0.1:8200/icons/mp3.png",
        "http://127.0.0.1:8200/icons/mp4.png",
    ])
precondition(MediaIcon.images.count == 13)
var backgroundColors: Set<[Int]> = []
for icon in MediaIcon.allCases {
    let image = MediaIcon.images[icon.path]!
    precondition(image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
    let bitmap = NSBitmapImageRep(data: image)!
    precondition(bitmap.pixelsWide == 160 && bitmap.pixelsHigh == 160)
    let background = bitmap.colorAt(x: 15, y: 80)!.usingColorSpace(.deviceRGB)!
    let rgb = [background.redComponent, background.greenComponent, background.blueComponent]
        .map { Int(($0 * 255).rounded()) }
    precondition(backgroundColors.insert(rgb).inserted, "Duplicate background for \(icon.rawValue)")
}
for (fileExtension, mediaType) in mediaTypes {
    precondition(mediaType.icon.rawValue == fileExtension)
}

// Whitespace between argument elements must not alter their values, including empty SortCriteria.
let compact = try browse(arguments.replacingOccurrences(of: "\n", with: ""))
precondition(compact.status == formatted.status)
check(try value(compact.document, "Result") == didlText)
let emptySort = try browse(
    arguments.replacingOccurrences(of: "<SortCriteria></SortCriteria>", with: "<SortCriteria/>"))
precondition(emptySort.status == "HTTP/1.1 200 OK")
let page = try browse(
    arguments.replacingOccurrences(of: "<RequestedCount>0", with: "<RequestedCount>1"))
check(try value(page.document, "NumberReturned") == "1")
check(try value(page.document, "TotalMatches") == "3")
let invalid = try browse(
    arguments.replacingOccurrences(of: "<StartingIndex>0", with: "<StartingIndex>-1"))
precondition(invalid.status == "HTTP/1.1 500 Internal Server Error")
check(try value(invalid.document, "errorCode") == "402")

// Build a hierarchy and verify that links cannot escape the shared directory or create loops.
let shows = root.appendingPathComponent("Shows & Series")
let season = shows.appendingPathComponent("Season 1")
let empty = root.appendingPathComponent("Empty")
let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: outside) }
try Data("nested video".utf8).write(to: shows.appendingPathComponent("episode.mkv"))
try Data("deep video".utf8).write(to: season.appendingPathComponent("episode.avi"))
try Data("private video".utf8).write(to: outside.appendingPathComponent("private.mp4"))
try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("outside"), withDestinationURL: outside)
try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("outside.mp4"),
    withDestinationURL: outside.appendingPathComponent("private.mp4"))
try FileManager.default.createSymbolicLink(
    at: season.appendingPathComponent("loop"), withDestinationURL: shows)

let folderLibrary = try MediaLibrary(root: root, base: "http://127.0.0.1:8200")
let folderDevice = UPnPDevice(library: folderLibrary)
precondition(folderLibrary.files.count == 5)

func folderBrowse(
    _ objectID: String, flag: String = "BrowseDirectChildren", start: Int = 0, count: Int = 0
) throws -> (status: String, document: XMLDocument) {
    let request =
        arguments
        .replacingOccurrences(of: "<ObjectID>0", with: "<ObjectID>\(objectID)")
        .replacingOccurrences(of: "BrowseDirectChildren", with: flag)
        .replacingOccurrences(of: "<StartingIndex>0", with: "<StartingIndex>\(start)")
        .replacingOccurrences(of: "<RequestedCount>0", with: "<RequestedCount>\(count)")
    return try browse(request, using: folderDevice)
}

func listing(_ response: (status: String, document: XMLDocument)) throws -> XMLDocument {
    precondition(response.status == "HTTP/1.1 200 OK")
    return try XMLDocument(xmlString: value(response.document, "Result"))
}

let rootResponse = try folderBrowse("0")
check(try value(rootResponse.document, "TotalMatches") == "5")
let rootListing = try listing(rootResponse)
let containers = try rootListing.nodes(forXPath: "//*[local-name()='container']")
    .compactMap { $0 as? XMLElement }
let showNode = containers.first { element in
    element.children?.contains { $0.localName == "title" && $0.stringValue == "Shows & Series" }
        == true
}!
let showsID = showNode.attribute(forName: "id")!.stringValue!
precondition(showNode.attribute(forName: "parentID")?.stringValue == "0")
precondition(showNode.attribute(forName: "childCount")?.stringValue == "2")
let showsResponse = try folderBrowse(showsID)
check(try value(showsResponse.document, "TotalMatches") == "2")
let showsListing = try listing(showsResponse)
let seasonNode =
    try showsListing.nodes(forXPath: "//*[local-name()='container']").first as! XMLElement
let seasonID = seasonNode.attribute(forName: "id")!.stringValue!
precondition(seasonNode.attribute(forName: "parentID")?.stringValue == showsID)
let seasonResponse = try folderBrowse(seasonID)
check(try value(seasonResponse.document, "TotalMatches") == "1")
let seasonListing = try listing(seasonResponse)
let video = try seasonListing.nodes(forXPath: "//*[local-name()='item']").first as! XMLElement
let videoID = video.attribute(forName: "id")!.stringValue!
precondition(video.attribute(forName: "parentID")?.stringValue == seasonID)
check(try value(seasonListing, "class") == "object.item.videoItem")
let mediaURL = URL(string: try value(seasonListing, "res"))!
let fileIndex = Int(mediaURL.lastPathComponent)!
// Verify the resource points at the nested video, independent of macOS /var aliases.
check(try Data(contentsOf: folderLibrary.files[fileIndex]) == Data("deep video".utf8))

let metadata = try folderBrowse(showsID, flag: "BrowseMetadata")
check(try value(metadata.document, "NumberReturned") == "1")
check(try value(listing(metadata), "class") == "object.container.storageFolder")
check(
    try value(listing(metadata), "albumArtURI")
        == "http://127.0.0.1:8200/icons/folder-dark-gray.png")
let nestedPage = try folderBrowse(showsID, start: 1, count: 1)
check(try value(nestedPage.document, "NumberReturned") == "1")
check(try value(nestedPage.document, "TotalMatches") == "2")
let pastEnd = try folderBrowse(showsID, start: 99)
check(try value(pastEnd.document, "NumberReturned") == "0")
let emptyNode = containers.first { element in
    element.children?.contains { $0.localName == "title" && $0.stringValue == "Empty" } == true
}!
let emptyResponse = try folderBrowse(emptyNode.attribute(forName: "id")!.stringValue!)
check(try value(emptyResponse.document, "TotalMatches") == "0")
let fileChildren = try folderBrowse(videoID)
check(try value(fileChildren.document, "errorCode") == "710")
let unknownObject = try folderBrowse("99999")
check(try value(unknownObject.document, "errorCode") == "701")
print(
    "Browse regression checks passed: server names, media classes, thumbnails, SOAP formatting, folders, pagination, and symlink boundaries"
)
