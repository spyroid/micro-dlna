import Foundation

func escapeXML(_ value: String) -> String {
    // Escape ampersands first so the entities introduced below are not escaped again.
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Collect the text of SOAP argument elements, ignoring namespace prefixes.
private final class SOAPArguments: NSObject, XMLParserDelegate {
    private(set) var values: [String: String] = [:]
    private var currentElement: String?

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        let elementName = name.components(separatedBy: ":").last!
        currentElement = elementName
        values[elementName] = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let currentElement else { return }
        // XMLParser may deliver one element's text in several callbacks.
        values[currentElement, default: ""] += string
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        // Indentation between elements belongs to the envelope, not to the last argument.
        currentElement = nil
    }
}

let contentDirectoryService = "urn:schemas-upnp-org:service:ContentDirectory:1"
let connectionManagerService = "urn:schemas-upnp-org:service:ConnectionManager:1"
let deviceType = "urn:schemas-upnp-org:device:MediaServer:1"

func soapResponse(_ action: String, _ service: String, _ body: String) -> String {
    """
    <?xml version="1.0"?>\
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
    <s:Body>\
    <u:\(action)Response xmlns:u="\(service)">\(body)</u:\(action)Response>\
    </s:Body>\
    </s:Envelope>
    """
}

func replyWithSOAPFault(_ socket: Int32, _ code: Int, _ message: String) {
    let body = """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">\
        <s:Body><s:Fault>\
        <faultcode>s:Client</faultcode>\
        <faultstring>UPnPError</faultstring>\
        <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">\
        <errorCode>\(code)</errorCode>\
        <errorDescription>\(message)</errorDescription>\
        </UPnPError></detail>\
        </s:Fault></s:Body>\
        </s:Envelope>
        """
    reply(socket, "500 Internal Server Error", body)
}

// These tables generate the service descriptions exposed at /cd.xml and /cm.xml.
// Each argument refers to a state variable whose type is listed in the same document.
typealias ServiceArgument = (
    name: String, direction: String, dataType: String, stateVariable: String
)
typealias ServiceAction = (name: String, arguments: [ServiceArgument])

let contentDirectoryActions: [ServiceAction] = [
    (
        "Browse",
        [
            ("ObjectID", "in", "string", "ObjectID"),
            ("BrowseFlag", "in", "string", "BrowseFlag"),
            ("Filter", "in", "string", "Filter"),
            ("StartingIndex", "in", "ui4", "Index"),
            ("RequestedCount", "in", "ui4", "Count"),
            ("SortCriteria", "in", "string", "SortCriteria"),
            ("Result", "out", "string", "Result"),
            ("NumberReturned", "out", "ui4", "Count"),
            ("TotalMatches", "out", "ui4", "Count"),
            ("UpdateID", "out", "ui4", "SystemUpdateID"),
        ]
    ),
    ("GetSearchCapabilities", [("SearchCaps", "out", "string", "SearchCapabilities")]),
    ("GetSortCapabilities", [("SortCaps", "out", "string", "SortCapabilities")]),
    ("GetSystemUpdateID", [("Id", "out", "ui4", "SystemUpdateID")]),
]

let connectionManagerActions: [ServiceAction] = [
    (
        "GetProtocolInfo",
        [
            ("Source", "out", "string", "SourceProtocolInfo"),
            ("Sink", "out", "string", "SinkProtocolInfo"),
        ]
    ),
    ("GetCurrentConnectionIDs", [("ConnectionIDs", "out", "string", "CurrentConnectionIDs")]),
    (
        "GetCurrentConnectionInfo",
        [
            ("ConnectionID", "in", "i4", "ConnectionID"),
            ("RcsID", "out", "i4", "RcsID"),
            ("AVTransportID", "out", "i4", "AVTransportID"),
            ("ProtocolInfo", "out", "string", "ProtocolInfo"),
            ("PeerConnectionManager", "out", "string", "ConnectionManager"),
            ("PeerConnectionID", "out", "i4", "ConnectionID"),
            ("Direction", "out", "string", "Direction"),
            ("Status", "out", "string", "ConnectionStatus"),
        ]
    ),
]

func serviceDescription(_ actions: [ServiceAction]) -> String {
    var stateVariables: [String: String] = [:]
    let actionList = actions.map { action in
        let argumentList = action.arguments.map { argument in
            stateVariables[argument.stateVariable] = argument.dataType
            return """
                <argument>\
                <name>\(argument.name)</name>\
                <direction>\(argument.direction)</direction>\
                <relatedStateVariable>\(argument.stateVariable)</relatedStateVariable>\
                </argument>
                """
        }.joined()
        return """
            <action><name>\(action.name)</name>\
            <argumentList>\(argumentList)</argumentList></action>
            """
    }.joined()

    // Sort dictionary entries to keep the generated document deterministic.
    let stateTable = stateVariables.sorted { $0.key < $1.key }.map { name, dataType in
        """
        <stateVariable sendEvents="no">\
        <name>\(name)</name><dataType>\(dataType)</dataType>\
        </stateVariable>
        """
    }.joined()

    return """
        <?xml version="1.0"?>\
        <scpd xmlns="urn:schemas-upnp-org:service-1-0">\
        <specVersion><major>1</major><minor>0</minor></specVersion>\
        <actionList>\(actionList)</actionList>\
        <serviceStateTable>\(stateTable)</serviceStateTable>\
        </scpd>
        """
}

struct UPnPDevice {
    let library: MediaLibrary
    let uuid = "uuid:" + UUID().uuidString.lowercased()
    let friendlyName: String
    var base: String { library.base }

    init(library: MediaLibrary, computerName: String? = Host.current().localizedName) {
        self.library = library
        let name = computerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        friendlyName = name.isEmpty ? "μDLNA" : "μDLNA on \(name)"
    }

    var description: String {
        let services = [
            (path: "cd", type: contentDirectoryService, id: "ContentDirectory"),
            (path: "cm", type: connectionManagerService, id: "ConnectionManager"),
        ]
        let serviceList = services.map { service in
            """
            <service>\
            <serviceType>\(service.type)</serviceType>\
            <serviceId>urn:upnp-org:serviceId:\(service.id)</serviceId>\
            <SCPDURL>/\(service.path).xml</SCPDURL>\
            <controlURL>/\(service.path)</controlURL>\
            <eventSubURL>/events/\(service.path)</eventSubURL>\
            </service>
            """
        }.joined()

        return """
            <?xml version="1.0"?>\
            <root xmlns="urn:schemas-upnp-org:device-1-0">\
            <specVersion><major>1</major><minor>0</minor></specVersion>\
            <device>\
            <deviceType>\(deviceType)</deviceType>\
            <friendlyName>\(escapeXML(friendlyName))</friendlyName>\
            <manufacturer>Local</manufacturer>\
            <modelName>μDLNA server</modelName>\
            <UDN>\(uuid)</UDN>\
            <serviceList>\(serviceList)</serviceList>\
            </device></root>
            """
    }

    func control(_ socket: Int32, path: String, action: String, data: Data) {
        let parser = XMLParser(data: data)
        let arguments = SOAPArguments()
        parser.delegate = arguments
        guard parser.parse() else {
            replyWithSOAPFault(socket, 402, "Invalid Args")
            return
        }

        let values = arguments.values
        let body: String
        switch (path, action) {
        case ("/cd", "Browse"):
            guard let objectID = values["ObjectID"], let browseFlag = values["BrowseFlag"],
                let start = Int(values["StartingIndex"] ?? ""),
                let count = Int(values["RequestedCount"] ?? ""), start >= 0, count >= 0
            else {
                replyWithSOAPFault(socket, 402, "Invalid Args")
                return
            }
            if !(values["SortCriteria"] ?? "").isEmpty {
                replyWithSOAPFault(socket, 709, "Unsupported sort criteria")
                return
            }

            guard let index = Int(objectID), library.entries.indices.contains(index) else {
                replyWithSOAPFault(socket, 701, "No Such Object")
                return
            }

            let entries: [String]
            if browseFlag == "BrowseMetadata" {
                entries = [library.metadata(index)]
            } else if browseFlag == "BrowseDirectChildren" && library.entries[index].isDirectory {
                entries = library.entries[index].children.map(library.metadata)
            } else {
                replyWithSOAPFault(socket, 710, "No Such Container")
                return
            }

            // RequestedCount == 0 means all remaining entries, not an empty page.
            let offset = min(start, entries.count)
            let amount = count == 0 ? entries.count - offset : min(count, entries.count - offset)
            let selected = entries[offset..<(offset + amount)]
            let didl = """
                <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">\
                \(selected.joined())\
                </DIDL-Lite>
                """
            // The DIDL document is XML text nested inside the SOAP Result element.
            body = """
                <Result>\(escapeXML(didl))</Result>\
                <NumberReturned>\(amount)</NumberReturned>\
                <TotalMatches>\(entries.count)</TotalMatches>\
                <UpdateID>0</UpdateID>
                """
        case ("/cd", "GetSearchCapabilities"):
            body = "<SearchCaps></SearchCaps>"
        case ("/cd", "GetSortCapabilities"):
            body = "<SortCaps></SortCaps>"
        case ("/cd", "GetSystemUpdateID"):
            body = "<Id>0</Id>"
        case ("/cm", "GetProtocolInfo"):
            let protocols = Set(mediaTypes.values.map { "http-get:*:\($0.mimeType):*" })
                .sorted().joined(separator: ",")
            body = "<Source>\(protocols)</Source><Sink></Sink>"
        case ("/cm", "GetCurrentConnectionIDs"):
            body = "<ConnectionIDs></ConnectionIDs>"
        case ("/cm", "GetCurrentConnectionInfo"):
            replyWithSOAPFault(socket, 706, "Invalid connection reference")
            return
        default:
            replyWithSOAPFault(socket, 401, "Invalid Action")
            return
        }

        let service = path == "/cd" ? contentDirectoryService : connectionManagerService
        reply(socket, "200 OK", soapResponse(action, service, body))
    }
}
