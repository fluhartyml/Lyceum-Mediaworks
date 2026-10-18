// REM  Mac only — the Mac (a mini once published, 012a) is the media server.
#if os(macOS)
//
//  DLNAServer.swift
//  mediaworks
//
//  SMART TVs — roadmap 017 / 018 (LOCKED): "Transcodes, both to standardize the library and to serve smart TVs over DLNA"
//  · "A Theater app on the Apple TV reads from the mini; smart TVs get DLNA." And 003: "Your folders, playlists, tags and
//  file metadata are the front door" — so a TV sees the library AS ITS FOLDERS, plus the playlists, never a flat wall.
//    · SSDP announces the library on the home network (UDP 239.255.255.250:1900) and answers TVs that search for it.
//    · A UPnP MediaServer:1 with ContentDirectory (Browse) and ConnectionManager — what every DLNA TV speaks.
//    · Files stream from the same code the Apple TV uses (Range requests), with the DLNA headers some TVs insist on.
//    · An unchecked file is not served (PL9 — "not synchronized"), here as everywhere.
//  Off until the user turns it on in Settings: it makes the library visible to every TV on the network.
//

import Foundation
import Network
import Darwin

// MARK: - What a TV sees (pure — tested on its own)

nonisolated enum DLNAContent {
    /// "0" root · "f/<path>" folder · "i/<path>" file · "pl" the playlists · "p/<name>" one playlist.
    struct Answer { var didl: String; var returned: Int; var total: Int }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func mime(_ name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "aiff", "aif": "audio/aiff"
        case "flac": "audio/flac"
        default: nil
        }
    }

    static func clock(_ seconds: Double?) -> String? {
        guard let s = seconds, s.isFinite, s > 0 else { return nil }
        let t = Int(s)
        return String(format: "%d:%02d:%02d.000", t / 3600, t / 60 % 60, t % 60)
    }

    static func folder(_ root: CachedFolder, _ path: String) -> CachedFolder? {
        var f = root
        for part in path.split(separator: "/").map(String.init) {
            guard let next = f.folders.first(where: { $0.name == part }) else { return nil }
            f = next
        }
        return f
    }

    static func file(_ root: CachedFolder, _ path: String) -> CachedFile? {
        var parts = path.split(separator: "/").map(String.init)
        guard let name = parts.popLast(), let f = folder(root, parts.joined(separator: "/")) else { return nil }
        return f.files.first { $0.name == name }
    }

    private static func playable(_ f: CachedFile) -> Bool { f.isChecked && mime(f.name) != nil && f.kind != "other" }

    static func item(_ f: CachedFile, path: String, parent: String, base: String) -> String {
        let mime = mime(f.name) ?? "video/mp4"
        let isAudio = mime.hasPrefix("audio")
        let cls = isAudio ? "object.item.audioItem.musicTrack" : "object.item.videoItem"
        let title = f.info?.title ?? (f.name as NSString).deletingPathExtension
        let url = base + "/media/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        var attrs = "protocolInfo=\"http-get:*:\(mime):DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\""
        if let size = f.size { attrs += " size=\"\(size)\"" }
        if let d = clock(f.info?.length) { attrs += " duration=\"\(d)\"" }
        if let r = f.info?.resolution?.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "×", with: "x") { attrs += " resolution=\"\(xml(r))\"" }
        var out = "<item id=\"\(xml("i/" + path))\" parentID=\"\(xml(parent))\" restricted=\"1\"><dc:title>\(xml(title))</dc:title><upnp:class>\(cls)</upnp:class>"
        if let a = f.info?.artist { out += "<upnp:artist>\(xml(a))</upnp:artist><dc:creator>\(xml(a))</dc:creator>" }
        if let a = f.info?.album { out += "<upnp:album>\(xml(a))</upnp:album>" }
        if let g = f.info?.genre { out += "<upnp:genre>\(xml(g))</upnp:genre>" }
        if let y = f.info?.year { out += "<dc:date>\(y)-01-01</dc:date>" }
        if let s = f.info?.summary { out += "<dc:description>\(xml(s))</dc:description>" }
        return out + "<res \(attrs)>\(xml(url))</res></item>"
    }

    static func container(id: String, parent: String, title: String, count: Int) -> String {
        "<container id=\"\(xml(id))\" parentID=\"\(xml(parent))\" childCount=\"\(count)\" restricted=\"1\" searchable=\"0\"><dc:title>\(xml(title))</dc:title><upnp:class>object.container.storageFolder</upnp:class></container>"
    }

    static func wrap(_ body: String) -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:dlna=\"urn:schemas-dlna-org:metadata-1-0/\">" + body + "</DIDL-Lite>"
    }

    /// The children of one object, or the object itself (BrowseMetadata).
    static func browse(_ id: String, metadata: Bool, start: Int, count: Int,
                       root: CachedFolder, playlists: [String: [String]], title: String, base: String) -> Answer? {
        var children: [String] = []
        func page(_ all: [String]) -> Answer {
            let slice = all.dropFirst(start).prefix(count == 0 ? all.count : count)
            return Answer(didl: wrap(slice.joined()), returned: slice.count, total: all.count)
        }
        func folderChildren(_ f: CachedFolder, prefix: String, myID: String) -> [String] {
            let subs = f.folders.filter { $0.fileCount > 0 }.map { sub in
                container(id: "f/" + prefix + sub.name, parent: myID, title: sub.name, count: sub.folders.count + sub.files.filter(playable).count)
            }
            let files = f.files.filter(playable).map { item($0, path: prefix + $0.name, parent: myID, base: base) }
            return subs + files
        }
        let lists = playlists.filter { !$0.value.isEmpty }.keys.sorted { a, b in
            LibraryCache.playlistOrder(a, b)
        }

        if id == "0" {
            if metadata { return Answer(didl: wrap(container(id: "0", parent: "-1", title: title, count: root.folders.count + 1)), returned: 1, total: 1) }
            children = (lists.isEmpty ? [] : [container(id: "pl", parent: "0", title: "Playlists", count: lists.count)])
                + folderChildren(root, prefix: "", myID: "0")
            return page(children)
        }
        if id == "pl" {
            if metadata { return Answer(didl: wrap(container(id: "pl", parent: "0", title: "Playlists", count: lists.count)), returned: 1, total: 1) }
            return page(lists.map { container(id: "p/" + $0, parent: "pl", title: $0, count: playlists[$0]?.count ?? 0) })
        }
        if id.hasPrefix("p/") {
            let name = String(id.dropFirst(2))
            guard let list = playlists[name] else { return nil }
            if metadata { return Answer(didl: wrap(container(id: id, parent: "pl", title: name, count: list.count)), returned: 1, total: 1) }
            return page(list.compactMap { path in file(root, path).flatMap { playable($0) ? item($0, path: path, parent: id, base: base) : nil } })
        }
        if id.hasPrefix("f/") {
            let path = String(id.dropFirst(2))
            guard let f = folder(root, path) else { return nil }
            let parent = path.contains("/") ? "f/" + (path as NSString).deletingLastPathComponent : "0"
            if metadata { return Answer(didl: wrap(container(id: id, parent: parent, title: f.name, count: f.folders.count + f.files.count)), returned: 1, total: 1) }
            return page(folderChildren(f, prefix: path + "/", myID: id))
        }
        if id.hasPrefix("i/") {
            let path = String(id.dropFirst(2))
            guard let f = file(root, path), playable(f) else { return nil }
            let parent = path.contains("/") ? "f/" + (path as NSString).deletingLastPathComponent : "0"
            return Answer(didl: wrap(item(f, path: path, parent: parent, base: base)), returned: 1, total: 1)
        }
        return nil
    }

    /// Pulls one SOAP argument's text out of a request body.
    static func argument(_ name: String, in body: String) -> String? {
        guard let open = body.range(of: "<\(name)>") ?? body.range(of: "<\(name) ", options: .literal).flatMap({ r in body.range(of: ">", range: r.upperBound..<body.endIndex) }),
              let close = body.range(of: "</\(name)>", range: open.upperBound..<body.endIndex) else { return nil }
        return String(body[open.upperBound..<close.lowerBound])
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - The server

@MainActor
@Observable
final class DLNAServer {
    static let shared = DLNAServer()

    var isOn: Bool = UserDefaults.standard.bool(forKey: "dlnaOn") {
        didSet { UserDefaults.standard.set(isOn, forKey: "dlnaOn"); isOn ? start() : stop() }
    }
    private(set) var status = "Off"
    private(set) var lastTV: String?

    @ObservationIgnored private var http: NWListener?
    @ObservationIgnored private var ssdp: Int32 = -1
    @ObservationIgnored private var ssdpSource: DispatchSourceRead?
    @ObservationIgnored private var notifyTimer: Timer?
    @ObservationIgnored private var port: UInt16 = 0
    @ObservationIgnored private var updateID = 1

    private let uuid: String = {
        if let u = UserDefaults.standard.string(forKey: "dlnaUUID") { return u }
        let u = UUID().uuidString.lowercased(); UserDefaults.standard.set(u, forKey: "dlnaUUID"); return u
    }()
    private var name: String { "Lyceum Mediaworks — \(Host.current().localizedName ?? "Mac")" }

    func startIfOn() { if isOn { start() } }

    private func start() {
        guard http == nil else { return }
        guard let listener = try? NWListener(using: .tcp, on: 8200) ?? NWListener(using: .tcp) else { status = "Could not open a port."; return }
        listener.newConnectionHandler = { c in MainActor.assumeIsolated { DLNAServer.shared.accept(c) } }
        listener.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .ready = state, let p = DLNAServer.shared.http?.port?.rawValue {
                        DLNAServer.shared.port = p
                        DLNAServer.shared.openSSDP()
                    }
                    if case .failed(let e) = state { DLNAServer.shared.status = "Stopped: \(e.localizedDescription)" }
                }
            }
        }
        listener.start(queue: .main)
        http = listener
        status = "Starting…"
    }

    private func stop() {
        sendNotify(alive: false)
        notifyTimer?.invalidate(); notifyTimer = nil
        ssdpSource?.cancel(); ssdpSource = nil
        if ssdp >= 0 { close(ssdp); ssdp = -1 }
        http?.cancel(); http = nil
        status = "Off"
    }

    // MARK: Where we are

    /// This Mac's address on the home network (IPv4, not loopback).
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [String: String] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            found[String(cString: ifa.ifa_name)] = String(cString: host)
        }
        return found["en0"] ?? found["en1"] ?? found.values.first { $0.hasPrefix("192.168.") || $0.hasPrefix("10.") || $0.hasPrefix("172.") }
    }

    private var base: String { "http://\(Self.localAddress() ?? "127.0.0.1"):\(port)" }
    private var location: String { base + "/description.xml" }

    // MARK: SSDP

    private func openSSDP() {
        guard ssdp < 0 else { return }
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { status = "Could not open the announcement socket."; return }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { close(s); status = "Port 1900 is taken — another DLNA server may be running."; return }
        var group = ip_mreq(imr_multiaddr: in_addr(s_addr: inet_addr("239.255.255.250")), imr_interface: in_addr(s_addr: INADDR_ANY))
        setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, &group, socklen_t(MemoryLayout<ip_mreq>.size))
        var ttl: UInt8 = 4
        setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))
        ssdp = s
        let source = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { DLNAServer.shared.readSSDP() } }
        source.resume()
        ssdpSource = source
        sendNotify(alive: true)
        notifyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { DLNAServer.shared.sendNotify(alive: true) } }
        status = "Serving smart TVs at \(base)"
    }

    private static let types = ["upnp:rootdevice", "urn:schemas-upnp-org:device:MediaServer:1",
                                "urn:schemas-upnp-org:service:ContentDirectory:1", "urn:schemas-upnp-org:service:ConnectionManager:1"]

    private func usn(_ type: String) -> String { type.hasPrefix("uuid:") ? type : "uuid:\(uuid)::\(type)" }

    private func readSSDP() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(ssdp, &buffer, buffer.count, 0, $0, &len) } }
        guard n > 0 else { return }
        let text = String(decoding: buffer[0..<n], as: UTF8.self)
        guard text.hasPrefix("M-SEARCH") else { return }
        let st = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("st:") }
            .map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) } ?? ""
        let answer: [String]
        switch st {
        case "ssdp:all": answer = Self.types + ["uuid:\(uuid)"]
        case "uuid:\(uuid)": answer = [st]
        default: answer = Self.types.contains(st) ? [st] : []
        }
        for type in answer {
            let reply = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\nLOCATION: \(location)\r\nSERVER: macOS/27 UPnP/1.0 LyceumMediaworks/1.0\r\nST: \(type)\r\nUSN: \(usn(type == "uuid:\(uuid)" ? type : type))\r\nContent-Length: 0\r\n\r\n"
            let bytes = Array(reply.utf8)
            _ = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(ssdp, bytes, bytes.count, 0, $0, len) } }
        }
        var ip = [CChar](repeating: 0, count: 64)
        inet_ntop(AF_INET, &from.sin_addr, &ip, 64)
        lastTV = String(cString: ip)
    }

    private func sendNotify(alive: Bool) {
        guard ssdp >= 0 else { return }
        var to = sockaddr_in()
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = in_port_t(1900).bigEndian
        to.sin_addr.s_addr = inet_addr("239.255.255.250")
        for type in Self.types + ["uuid:\(uuid)"] {
            var msg = "NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nNT: \(type)\r\nNTS: \(alive ? "ssdp:alive" : "ssdp:byebye")\r\nUSN: \(usn(type))\r\n"
            if alive { msg += "CACHE-CONTROL: max-age=1800\r\nLOCATION: \(location)\r\nSERVER: macOS/27 UPnP/1.0 LyceumMediaworks/1.0\r\n" }
            msg += "\r\n"
            let bytes = Array(msg.utf8)
            _ = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(ssdp, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
    }

    // MARK: HTTP — description, the two services, and the files

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        var data = Data()
        func more() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, complete, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let chunk { data.append(chunk) }
                        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
                            if complete || data.count > 1_000_000 { c.cancel() } else { more() }
                            return
                        }
                        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
                        let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                        let have = data.count - end.upperBound
                        if have < length, !complete { more(); return }
                        let body = String(decoding: data[end.upperBound...], as: UTF8.self)
                        DLNAServer.shared.handle(c, head: head, body: body, raw: data[..<end.upperBound])
                    }
                }
            }
        }
        more()
    }

    private func reply(_ c: NWConnection, _ status: String, type: String = "text/xml; charset=\"utf-8\"", body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nServer: macOS/27 UPnP/1.0 LyceumMediaworks/1.0\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in c.cancel() })
    }

    private func handle(_ c: NWConnection, head: String, body: String, raw: Data) {
        let line = head.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { c.cancel(); return }
        let method = String(parts[0]), path = String(parts[1])
        if (method == "GET" || method == "HEAD"), path.hasPrefix("/media/") {
            // The file itself — the same streaming the Apple TV uses, with the DLNA headers TVs look for.
            LibraryCatalog.shared.streamForDLNA(c, request: head)
            return
        }
        switch (method, path) {
        case ("GET", "/description.xml"): reply(c, "200 OK", body: descriptionXML)
        case ("GET", "/ContentDirectory.xml"): reply(c, "200 OK", body: Self.contentDirectorySCPD)
        case ("GET", "/ConnectionManager.xml"): reply(c, "200 OK", body: Self.connectionManagerSCPD)
        case ("POST", "/control/ContentDirectory"): reply(c, "200 OK", body: contentDirectory(head: head, body: body))
        case ("POST", "/control/ConnectionManager"): reply(c, "200 OK", body: connectionManager(head: head))
        case ("SUBSCRIBE", _), ("UNSUBSCRIBE", _):
            let h = "HTTP/1.1 200 OK\r\nSID: uuid:\(UUID().uuidString.lowercased())\r\nTIMEOUT: Second-1800\r\nContent-Length: 0\r\n\r\n"
            c.send(content: Data(h.utf8), completion: .contentProcessed { _ in c.cancel() })
        default: reply(c, "404 Not Found", body: "")
        }
    }

    private func soap(_ action: String, service: String, _ inner: String) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:\(service):1\">\(inner)</u:\(action)Response></s:Body></s:Envelope>"
    }

    private func action(_ head: String) -> String {
        let soapAction = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("soapaction:") } ?? ""
        return soapAction.components(separatedBy: "#").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) ?? ""
    }

    private func contentDirectory(head: String, body: String) -> String {
        switch action(head) {
        case "GetSearchCapabilities": return soap("GetSearchCapabilities", service: "ContentDirectory", "<SearchCaps></SearchCaps>")
        case "GetSortCapabilities": return soap("GetSortCapabilities", service: "ContentDirectory", "<SortCaps></SortCaps>")
        case "GetSystemUpdateID": return soap("GetSystemUpdateID", service: "ContentDirectory", "<Id>\(updateID)</Id>")
        default:
            let snapshot = LibraryCatalog.shared.snapshot
            let id = DLNAContent.argument("ObjectID", in: body) ?? "0"
            let metadata = DLNAContent.argument("BrowseFlag", in: body) == "BrowseMetadata"
            let start = Int(DLNAContent.argument("StartingIndex", in: body) ?? "0") ?? 0
            let count = Int(DLNAContent.argument("RequestedCount", in: body) ?? "0") ?? 0
            let answer = snapshot.flatMap {
                DLNAContent.browse(id, metadata: metadata, start: start, count: count, root: $0.root,
                                   playlists: $0.playlists ?? [:], title: name, base: base)
            } ?? DLNAContent.Answer(didl: DLNAContent.wrap(""), returned: 0, total: 0)
            return soap("Browse", service: "ContentDirectory",
                        "<Result>\(DLNAContent.xml(answer.didl))</Result><NumberReturned>\(answer.returned)</NumberReturned><TotalMatches>\(answer.total)</TotalMatches><UpdateID>\(updateID)</UpdateID>")
        }
    }

    private func connectionManager(head: String) -> String {
        switch action(head) {
        case "GetCurrentConnectionIDs": return soap("GetCurrentConnectionIDs", service: "ConnectionManager", "<ConnectionIDs>0</ConnectionIDs>")
        case "GetCurrentConnectionInfo":
            return soap("GetCurrentConnectionInfo", service: "ConnectionManager",
                        "<RcsID>-1</RcsID><AVTransportID>-1</AVTransportID><ProtocolInfo></ProtocolInfo><PeerConnectionManager></PeerConnectionManager><PeerConnectionID>-1</PeerConnectionID><Direction>Output</Direction><Status>OK</Status>")
        default:
            let source = ["video/mp4", "video/quicktime", "audio/mp4", "audio/mpeg", "audio/wav", "audio/aiff", "audio/flac"]
                .map { "http-get:*:\($0):*" }.joined(separator: ",")
            return soap("GetProtocolInfo", service: "ConnectionManager", "<Source>\(source)</Source><Sink></Sink>")
        }
    }

    private var descriptionXML: String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">
        <specVersion><major>1</major><minor>0</minor></specVersion>
        <device>
        <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
        <dlna:X_DLNADOC>DMS-1.50</dlna:X_DLNADOC>
        <friendlyName>\(DLNAContent.xml(name))</friendlyName>
        <manufacturer>Lyceum Mediaworks</manufacturer>
        <modelName>Lyceum Mediaworks</modelName>
        <modelNumber>\(BuildStamp.number)</modelNumber>
        <UDN>uuid:\(uuid)</UDN>
        <serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><serviceId>urn:upnp-org:serviceId:ContentDirectory</serviceId><SCPDURL>/ContentDirectory.xml</SCPDURL><controlURL>/control/ContentDirectory</controlURL><eventSubURL>/event/ContentDirectory</eventSubURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId><SCPDURL>/ConnectionManager.xml</SCPDURL><controlURL>/control/ConnectionManager</controlURL><eventSubURL>/event/ConnectionManager</eventSubURL></service>
        </serviceList>
        </device>
        </root>
        """
    }

    private static func scpd(_ actions: String, _ variables: String) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><specVersion><major>1</major><minor>0</minor></specVersion><actionList>\(actions)</actionList><serviceStateTable>\(variables)</serviceStateTable></scpd>"
    }
    private static func arg(_ name: String, _ dir: String, _ v: String) -> String {
        "<argument><name>\(name)</name><direction>\(dir)</direction><relatedStateVariable>\(v)</relatedStateVariable></argument>"
    }
    private static func act(_ name: String, _ args: [String]) -> String { "<action><name>\(name)</name><argumentList>\(args.joined())</argumentList></action>" }
    private static func sv(_ name: String, _ type: String, events: Bool = false, values: [String] = []) -> String {
        "<stateVariable sendEvents=\"\(events ? "yes" : "no")\"><name>\(name)</name><dataType>\(type)</dataType>"
            + (values.isEmpty ? "" : "<allowedValueList>" + values.map { "<allowedValue>\($0)</allowedValue>" }.joined() + "</allowedValueList>")
            + "</stateVariable>"
    }

    static let contentDirectorySCPD = scpd(
        act("Browse", [arg("ObjectID", "in", "A_ARG_TYPE_ObjectID"), arg("BrowseFlag", "in", "A_ARG_TYPE_BrowseFlag"),
                       arg("Filter", "in", "A_ARG_TYPE_Filter"), arg("StartingIndex", "in", "A_ARG_TYPE_Index"),
                       arg("RequestedCount", "in", "A_ARG_TYPE_Count"), arg("SortCriteria", "in", "A_ARG_TYPE_SortCriteria"),
                       arg("Result", "out", "A_ARG_TYPE_Result"), arg("NumberReturned", "out", "A_ARG_TYPE_Count"),
                       arg("TotalMatches", "out", "A_ARG_TYPE_Count"), arg("UpdateID", "out", "A_ARG_TYPE_UpdateID")])
        + act("GetSearchCapabilities", [arg("SearchCaps", "out", "SearchCapabilities")])
        + act("GetSortCapabilities", [arg("SortCaps", "out", "SortCapabilities")])
        + act("GetSystemUpdateID", [arg("Id", "out", "SystemUpdateID")]),
        sv("A_ARG_TYPE_ObjectID", "string") + sv("A_ARG_TYPE_Result", "string") + sv("A_ARG_TYPE_BrowseFlag", "string", values: ["BrowseMetadata", "BrowseDirectChildren"])
        + sv("A_ARG_TYPE_Filter", "string") + sv("A_ARG_TYPE_SortCriteria", "string") + sv("A_ARG_TYPE_Index", "ui4")
        + sv("A_ARG_TYPE_Count", "ui4") + sv("A_ARG_TYPE_UpdateID", "ui4") + sv("SearchCapabilities", "string")
        + sv("SortCapabilities", "string") + sv("SystemUpdateID", "ui4", events: true))

    static let connectionManagerSCPD = scpd(
        act("GetProtocolInfo", [arg("Source", "out", "SourceProtocolInfo"), arg("Sink", "out", "SinkProtocolInfo")])
        + act("GetCurrentConnectionIDs", [arg("ConnectionIDs", "out", "CurrentConnectionIDs")])
        + act("GetCurrentConnectionInfo", [arg("ConnectionID", "in", "A_ARG_TYPE_ConnectionID"), arg("RcsID", "out", "A_ARG_TYPE_RcsID"),
                                           arg("AVTransportID", "out", "A_ARG_TYPE_AVTransportID"), arg("ProtocolInfo", "out", "A_ARG_TYPE_ProtocolInfo"),
                                           arg("PeerConnectionManager", "out", "A_ARG_TYPE_ConnectionManager"), arg("PeerConnectionID", "out", "A_ARG_TYPE_ConnectionID"),
                                           arg("Direction", "out", "A_ARG_TYPE_Direction"), arg("Status", "out", "A_ARG_TYPE_ConnectionStatus")]),
        sv("SourceProtocolInfo", "string", events: true) + sv("SinkProtocolInfo", "string", events: true) + sv("CurrentConnectionIDs", "string", events: true)
        + sv("A_ARG_TYPE_ConnectionStatus", "string", values: ["OK", "ContentFormatMismatch", "InsufficientBandwidth", "UnreliableChannel", "Unknown"])
        + sv("A_ARG_TYPE_ConnectionManager", "string") + sv("A_ARG_TYPE_Direction", "string", values: ["Input", "Output"])
        + sv("A_ARG_TYPE_ProtocolInfo", "string") + sv("A_ARG_TYPE_ConnectionID", "i4") + sv("A_ARG_TYPE_AVTransportID", "i4") + sv("A_ARG_TYPE_RcsID", "i4"))
}

import SwiftUI

/// Settings → General: smart TVs.
struct DLNASettingsSection: View {
    @State private var server = DLNAServer.shared
    var body: some View {
        Section {
            Toggle("Serve the library to smart TVs (DLNA)", isOn: $server.isOn)
                .info("Samsung, LG, Sony and other DLNA TVs find “Lyceum Mediaworks” on the home network and browse your folders and playlists. Unchecked files are not shown. Standard MP4s play best — Window → Transcode makes them.")
            Text(server.status).foregroundStyle(.secondary)
            if let tv = server.lastTV { Text("Last asked by \(tv)").foregroundStyle(.secondary) }
        } header: {
            Text("Smart TVs").font(.lyceumHeadline)
        }
    }
}
#endif
