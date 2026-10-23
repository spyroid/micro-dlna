import Foundation

// UPnP classes describe the kind of object; MIME types describe the file format.
let mediaTypes: [String: (mimeType: String, upnpClass: String, icon: MediaIcon)] = [
    "mp3": ("audio/mpeg", "audioItem.musicTrack", .mp3),
    "m4a": ("audio/mp4", "audioItem.musicTrack", .m4a),
    "flac": ("audio/flac", "audioItem.musicTrack", .flac),
    "wav": ("audio/wav", "audioItem.musicTrack", .wav),
    "mp4": ("video/mp4", "videoItem", .mp4),
    "m4v": ("video/mp4", "videoItem", .m4v),
    "mkv": ("video/x-matroska", "videoItem", .mkv),
    "mov": ("video/quicktime", "videoItem", .mov),
    "avi": ("video/x-msvideo", "videoItem", .avi),
    "jpg": ("image/jpeg", "imageItem.photo", .jpg),
    "jpeg": ("image/jpeg", "imageItem.photo", .jpeg),
    "png": ("image/png", "imageItem.photo", .png),
]

struct MediaLibrary {
    struct Entry {
        let url: URL
        let parentID: Int
        let fileIndex: Int?
        var children: [Int] = []

        var isDirectory: Bool { fileIndex == nil }
    }

    let root: URL
    let base: String
    let files: [URL]
    let entries: [Entry]

    init(root: URL, base: String) throws {
        let sharedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = sharedRoot
        self.base = base
        var files: [URL] = []
        // Array indices are UPnP object IDs; 0 always identifies the shared root.
        var entries = [Entry(url: sharedRoot, parentID: -1, fileIndex: nil)]
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        ]

        func scan(_ directory: URL, parentID: Int) throws {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys)
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }

            for url in contents {
                let resolved = url.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(sharedRoot.path + "/"),
                    let resources = try? resolved.resourceValues(forKeys: keys)
                else { continue }

                let objectID = entries.count
                if resources.isDirectory == true {
                    // Skip directory links to prevent cycles, and treat macOS packages as opaque.
                    guard resources.isPackage != true,
                        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink)
                            == false
                    else { continue }
                    entries.append(Entry(url: url, parentID: parentID, fileIndex: nil))
                    entries[parentID].children.append(objectID)
                    // An unreadable child folder must not hide the rest of the shared library.
                    try? scan(url, parentID: objectID)
                } else if resources.isRegularFile == true,
                    mediaTypes[url.pathExtension.lowercased()] != nil
                {
                    entries.append(Entry(url: url, parentID: parentID, fileIndex: files.count))
                    entries[parentID].children.append(objectID)
                    files.append(url)
                }
            }
        }

        // ponytail: catalogue is a startup snapshot; add rescanning when live updates are needed.
        try scan(sharedRoot, parentID: 0)
        self.files = files
        self.entries = entries
    }

    func metadata(_ objectID: Int) -> String {
        let entry = entries[objectID]
        if let fileIndex = entry.fileIndex {
            let file = entry.url
            let mediaType = mediaTypes[file.pathExtension.lowercased()]!
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

            // Media URLs use a separate file index, so folders cannot be streamed as files.
            return """
                <item id="\(objectID)" parentID="\(entry.parentID)" restricted="1">\
                <dc:title>\(escapeXML(file.lastPathComponent))</dc:title>\
                <upnp:class>object.item.\(mediaType.upnpClass)</upnp:class>\
                <upnp:albumArtURI>\(base)\(mediaType.icon.path)</upnp:albumArtURI>\
                <res protocolInfo="http-get:*:\(mediaType.mimeType):*" size="\(size)">\(base)/media/\(fileIndex)</res>\
                </item>
                """
        }

        let title = objectID == 0 ? "μDLNA server" : entry.url.lastPathComponent
        return """
            <container id="\(objectID)" parentID="\(entry.parentID)" restricted="1" childCount="\(entry.children.count)">\
            <dc:title>\(escapeXML(title))</dc:title>\
            <upnp:class>object.container.storageFolder</upnp:class>\
            <upnp:albumArtURI>\(base)\(MediaIcon.folder.path)</upnp:albumArtURI>\
            </container>
            """
    }
}
