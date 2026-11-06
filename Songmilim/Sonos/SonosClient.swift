import Foundation
import Network

// MARK: - מודלים

struct SonosPlayer: Identifiable, Hashable {
    let id: String      // RINCON_xxxxxxxx
    let name: String    // שם החדר
    let host: String    // כתובת IPv4 ברשת הביתית
}

struct SonosGroup: Identifiable, Hashable {
    let coordinator: SonosPlayer
    let members: [SonosPlayer]
    var id: String { coordinator.id }
    var name: String { members.map(\.name).joined(separator: " + ") }
}

struct NowPlaying: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var artURL: URL?
    var isPlaying = false

    var summary: String {
        [title, artist].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct SonosFavorite: Identifiable, Hashable {
    let id: String
    let title: String
    let uri: String
    let metadata: String
    let artURL: URL?
}

enum SonosError: LocalizedError {
    case notFound
    case invalidHost
    case request(String, Int)

    var errorDescription: String? {
        switch self {
        case .notFound: "לא נמצאו רמקולי Sonos ברשת. ודא שהטלפון מחובר לאותה רשת Wi‑Fi ושאישרת גישה לרשת המקומית."
        case .invalidHost: "כתובת IP לא תקינה"
        case .request(let action, let code): "הרמקול לא הגיב לפקודה \(action) (\(code))"
        }
    }
}

// MARK: - שליטה מקומית (UPnP / SOAP על פורט 1400)

/// שליחת פקודות ישירות לרמקולים ברשת הביתית – בלי ענן ובלי סיסמאות.
/// רק מכשירים שנמצאים ברשת שלך יכולים לדבר עם הרמקולים.
enum SonosClient {
    enum Service {
        case avTransport, renderingControl, groupRenderingControl, zoneGroupTopology, contentDirectory

        var path: String {
            switch self {
            case .avTransport: "/MediaRenderer/AVTransport/Control"
            case .renderingControl: "/MediaRenderer/RenderingControl/Control"
            case .groupRenderingControl: "/MediaRenderer/GroupRenderingControl/Control"
            case .zoneGroupTopology: "/ZoneGroupTopology/Control"
            case .contentDirectory: "/MediaServer/ContentDirectory/Control"
            }
        }

        var urn: String {
            switch self {
            case .avTransport: "urn:schemas-upnp-org:service:AVTransport:1"
            case .renderingControl: "urn:schemas-upnp-org:service:RenderingControl:1"
            case .groupRenderingControl: "urn:schemas-upnp-org:service:GroupRenderingControl:1"
            case .zoneGroupTopology: "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
            case .contentDirectory: "urn:schemas-upnp-org:service:ContentDirectory:1"
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    /// מוודא שהכתובת היא IPv4 פרטית (רשת ביתית) בלבד – מונע שליחת פקודות החוצה לאינטרנט
    static func isValidLocalHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }),
              host.split(separator: ".").count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168): return true
        case (172, let b) where (16...31).contains(b): return true
        default: return false
        }
    }

    @discardableResult
    static func call(_ host: String, _ service: Service, _ action: String,
                     _ args: [(String, String)] = []) async throws -> [String: String] {
        guard isValidLocalHost(host), let url = URL(string: "http://\(host):1400\(service.path)") else {
            throw SonosError.invalidHost
        }
        let argsXML = args.map { "<\($0.0)>\(xmlEscape($0.1))</\($0.0)>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service.urn)">\(argsXML)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SonosError.request(action, code) }
        return FlatXMLParser.parse(data)
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func artURL(_ raw: String?, host: String) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") { return URL(string: raw) }
        return URL(string: "http://\(host):1400\(raw)")
    }
}

// MARK: - גילוי רמקולים ברשת (Bonjour)

enum SonosDiscovery {
    /// מוצא רמקול אחד ברשת ומחזיר את כתובת ה-IPv4 שלו.
    /// מספיק אחד – ממנו מקבלים את רשימת כל החדרים.
    static func findHost(timeout: TimeInterval = 6) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "songmilim.sonos.discovery")
            let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: .tcp)
            var finished = false
            var connections: [NWConnection] = []

            func finish(_ result: Result<String, Error>) {
                guard !finished else { return }
                finished = true
                browser.cancel()
                connections.forEach { $0.cancel() }
                continuation.resume(with: result)
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    let params = NWParameters.tcp
                    if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                        ip.version = .v4
                    }
                    let connection = NWConnection(to: result.endpoint, using: params)
                    connections.append(connection)
                    connection.stateUpdateHandler = { state in
                        guard case .ready = state,
                              case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint,
                              case let .ipv4(address) = host else { return }
                        let ip = address.rawValue.map(String.init).joined(separator: ".")
                        finish(.success(ip))
                    }
                    connection.start(queue: queue)
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed(let error) = state { finish(.failure(error)) }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(SonosError.notFound)) }
        }
    }
}

// MARK: - פענוח XML

/// מחזיר מילון של שם-אלמנט → טקסט, עבור כל האלמנטים ה"עליים"
final class FlatXMLParser: NSObject, XMLParserDelegate {
    private var values: [String: String] = [:]
    private var text = ""

    static func parse(_ data: Data) -> [String: String] {
        let delegate = FlatXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.values
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if !text.isEmpty { values[elementName] = text }
        text = ""
    }
}

/// פענוח DIDL-Lite (מטא-דאטה של שירים ומועדפים)
final class DIDLParser: NSObject, XMLParserDelegate {
    struct Item {
        var id = ""
        var fields: [String: String] = [:]
    }

    private var items: [Item] = []
    private var current: Item?
    private var text = ""

    static func parse(_ xml: String) -> [Item] {
        let delegate = DIDLParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" || elementName == "container" {
            current = Item(id: attributeDict["id"] ?? "")
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName == "item" || elementName == "container" {
            if let current { items.append(current) }
            current = nil
        } else if current != nil, !text.isEmpty {
            current?.fields[elementName] = text
        }
        text = ""
    }
}

/// פענוח מבנה החדרים והקבוצות
final class ZoneGroupParser: NSObject, XMLParserDelegate {
    private var groups: [SonosGroup] = []
    private var coordinatorID = ""
    private var members: [SonosPlayer] = []

    static func parse(_ xml: String) -> [SonosGroup] {
        let delegate = ZoneGroupParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.parse()
        return delegate.groups
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "ZoneGroup":
            coordinatorID = attributeDict["Coordinator"] ?? ""
            members = []
        case "ZoneGroupMember":
            // Invisible = סאב-וופר / רמקולי סראונד – לא חדר בפני עצמו
            guard attributeDict["Invisible"] != "1",
                  let id = attributeDict["UUID"],
                  let name = attributeDict["ZoneName"],
                  let location = attributeDict["Location"],
                  let host = URL(string: location)?.host else { return }
            members.append(SonosPlayer(id: id, name: name, host: host))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard elementName == "ZoneGroup",
              let coordinator = members.first(where: { $0.id == coordinatorID }) else { return }
        let others = members.filter { $0.id != coordinatorID }.sorted { $0.name < $1.name }
        groups.append(SonosGroup(coordinator: coordinator, members: [coordinator] + others))
    }
}
