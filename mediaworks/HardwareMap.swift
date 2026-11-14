// REM  Mac only — the Hardware map on the status board (amber E-010).
//
//  HardwareMap.swift
//  mediaworks
//
//  E-010, locked 2026-11-09 20:1x: "Hardware map (this Mac). On screen its heading is just Hardware; 'mind map' was your
//  description, never shown. This Mac in the middle, with a line to each thing attached: each drive (name, how it's
//  connected: Thunderbolt, USB or internal, free space), each network port (Ethernet or Wi-Fi, address, link speed), and a
//  mark when one goes missing (a drive unplugged shows orange, not gone)."
//  His revise 2026-11-08: "for the hardware can you use labled Glyphs? the Glyphs kind of have to take up the
//  responsibility because the screen is normally too small to read and images can make up for not being able to read 18
//  point fonts." Shape says what it is; color says how it is (normal, orange missing or low, red failed); a fill shows how
//  full a drive is. Every glyph has a one- or two-word VoiceOver name.
//
// REM  WHERE IT SITS: beside the Network web, on the right (Claude's call 2026-11-14 — the board was already 900 tall, and
// REM  growing it again shrinks everything on the 5-inch screen). Drives in the top row, network ports in the bottom row.
// REM  MISSING, NOT GONE: every external drive and every network port ever seen with an address is remembered (UserDefaults
// REM  "hardwareMap.known"). One not here now stays on the map in orange. A drive retired on purpose: click it, Forget.
// REM  LOW = under 20 GB free, the same line the board uses since his word 2026-11-14 ("yes change it to 20 gb").
// REM  FAILED (red) = a drive that is mounted but whose size can't be read.
// REM  CONNECTION comes from Disk Arbitration's device protocol (Thunderbolt, USB, ...); the internal disk says Internal.
// REM  Disk images, network shares and system volumes are left out — they are not hardware attached to this Mac.
//

#if os(macOS)
import SwiftUI
import DiskArbitration
import SystemConfiguration

struct HardwareMap: View {
    @State private var parts: [Part] = []
    @State private var forgetting: String?
    /// The map's own size before it is scaled to the space it is given.
    @State private var natural = CGSize.zero
    @AppStorage("hardwareMap.known") private var knownRaw = ""

    enum Kind { case internalDrive, externalDrive, ethernet, wifi, port }
    enum Health { case normal, low, missing, failed }

    struct Part: Identifiable, Equatable {
        let id: String
        let kind: Kind
        let name: String
        var lines: [String]
        var health: Health
        /// How full a drive is, 0…1.
        var fullness: Double?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hardware").font(.system(size: 26, weight: .bold)).accessibilityAddTraits(.isHeader)
            // REM  CONTINGENT SIZING — his word 2026-11-14 13:57: "youre supposed to use contengent sizing so enerything fits
            // REM  naturally". The map is laid out at its natural size, then scaled as one piece to the space the board gives
            // REM  it — the same way the page scales the whole board (StandbyBoard.canvas). More drives = smaller, never cut off.
            GeometryReader { g in
                let scale = natural.width > 0 && natural.height > 0
                    ? min(1, g.size.width / natural.width, g.size.height / natural.height) : 1
                map
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
                    .scaleEffect(scale)
                    .frame(width: g.size.width, height: g.size.height)
            }
        }
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .accessibilityIdentifier("standbyHardwareMap")
    }

    // MARK: Drawing

    // REM  LAID OUT, NOT PLACED — his "the hardware needs adjusting" 2026-11-14 13:5x on the MacBook Air: pieces set at fixed
    // REM  spots overlapped — the drives rode up over the heading, each label's background cut off its neighbor's free space
    // REM  ("148.95 GB" lost "free"), and Wi-Fi covered "This Mac". Now drives (three to a row), this Mac and the ports are
    // REM  rows that make room for each other, and the lines are drawn from where each piece actually landed.
    private var map: some View {
        let drives = parts.filter { $0.kind == .internalDrive || $0.kind == .externalDrive }
        let ports = parts.filter { $0.kind == .ethernet || $0.kind == .wifi || $0.kind == .port }
        return VStack(spacing: 28) {
            rows(drives)
            VStack(spacing: 2) {
                Image(systemName: Self.macSymbol).font(.system(size: 52, weight: .semibold))
                Text("This Mac").font(.system(size: 18, weight: .bold))
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 10).fill(.background))
            .accessibilityElement(children: .ignore).accessibilityLabel("This Mac")
            .anchorPreference(key: Centers.self, value: .center) { ["mac": $0] }
            rows(ports)
        }
        .padding(8)
        .backgroundPreferenceValue(Centers.self) { anchors in
            GeometryReader { g in
                if let mac = anchors["mac"] {
                    ForEach(parts) { p in
                        if let at = anchors[p.id] { line(g[mac], g[at], p.health) }
                    }
                }
            }
        }
    }

    /// Pieces three to a row, each as wide as its own words.
    private func rows(_ list: [Part]) -> some View {
        let chunks = stride(from: 0, to: list.count, by: 3).map { Array(list[$0..<min($0 + 3, list.count)]) }
        return VStack(spacing: 16) {
            ForEach(chunks, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: 20) {
                    ForEach(row) { p in item(p).anchorPreference(key: Centers.self, value: .center) { [p.id: $0] } }
                }
            }
        }
    }

    private struct Centers: PreferenceKey {
        static let defaultValue: [String: Anchor<CGPoint>] = [:]
        static func reduce(value: inout [String: Anchor<CGPoint>], nextValue: () -> [String: Anchor<CGPoint>]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private func line(_ a: CGPoint, _ b: CGPoint, _ h: Health) -> some View {
        Path { p in p.move(to: a); p.addLine(to: b) }
            .stroke(h == .normal ? Color.secondary.opacity(0.5) : color(h),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: h == .missing ? [6, 6] : []))
    }

    @ViewBuilder
    private func item(_ p: Part) -> some View {
        let label = VStack(spacing: 2) {
            glyph(p)
            Text(p.name).font(.system(size: 18, weight: .semibold)).lineLimit(1)
            ForEach(p.lines, id: \.self) { Text($0).font(.system(size: 18)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(4).background(RoundedRectangle(cornerRadius: 8).fill(.background))
        if p.health == .missing {
            Button { forgetting = p.id } label: { label }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { forgetting == p.id }, set: { if !$0 { forgetting = nil } })) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(p.name) is not here").font(.lyceumTitle)
                        Text("It stays on the map in orange until it comes back, or until you forget it.").font(.lyceumBody)
                        Button("Forget \(p.name)") { forget(p.id); forgetting = nil }.font(.lyceumBody)
                    }
                    .padding(20).frame(width: 420)
                }
                .accessibilityLabel(spokenName(p))
                .accessibilityValue("missing")
                .accessibilityHint("Offers to forget it")
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenName(p))
                .accessibilityValue(([spoken(p.health)] + p.lines).joined(separator: ", "))
        }
    }

    private func glyph(_ p: Part) -> some View {
        let symbol: String = switch p.kind {
        case .internalDrive: "internaldrive"
        case .externalDrive: "externaldrive"
        case .ethernet: "cable.connector.horizontal"
        case .wifi: "wifi"
        case .port: "network"
        }
        return ZStack {
            Image(systemName: symbol)
            // The fill: the solid glyph, shown from the bottom up to how full the drive is.
            if let f = p.fullness, p.health != .missing {
                Image(systemName: symbol + ".fill")
                    .mask(alignment: .bottom) {
                        GeometryReader { g in
                            Rectangle().frame(height: g.size.height * f).frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
            }
        }
        .font(.system(size: 40))
        .foregroundStyle(color(p.health))
        .opacity(p.health == .missing ? 0.75 : 1)
    }

    private func color(_ h: Health) -> Color {
        switch h {
        case .normal: return .primary
        case .low, .missing: return .orange
        case .failed: return .red
        }
    }

    private func spoken(_ h: Health) -> String {
        switch h {
        case .normal: return "normal"
        case .low: return "low on space"
        case .missing: return "missing"
        case .failed: return "failed"
        }
    }

    /// One or two words (his three-word cap): "Library B", "Wi-Fi", "Ethernet".
    private func spokenName(_ p: Part) -> String {
        switch p.kind {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        default: return p.name.split(separator: " ").prefix(2).joined(separator: " ")
        }
    }

    private static var macSymbol: String {
        (Host.current().localizedName ?? "").localizedCaseInsensitiveContains("macbook") ? "laptopcomputer" : "macmini"
    }

    // MARK: Reading the hardware

    private var known: [String: String] {
        get {
            var out: [String: String] = [:]
            for row in knownRaw.split(separator: "\n") {
                let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
                if parts.count == 2 { out[parts[0]] = parts[1] }
            }
            return out
        }
    }

    private func remember(_ id: String, _ name: String) {
        var k = known
        guard k[id] != name else { return }
        k[id] = name
        knownRaw = k.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
    }

    private func forget(_ id: String) {
        var k = known
        k[id] = nil
        knownRaw = k.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
        parts.removeAll { $0.id == id }
    }

    private func refresh() {
        var now = Self.drives() + Self.ports()
        for p in now where p.kind != .internalDrive { remember(p.id, p.name) }
        let present = Set(now.map(\.id))
        for (id, name) in known where !present.contains(id) {
            let kind: Kind = id.hasPrefix("drive:") ? .externalDrive
                : name == "Wi-Fi" ? .wifi : name == "Ethernet" ? .ethernet : .port
            now.append(Part(id: id, kind: kind, name: name, lines: ["missing"], health: .missing, fullness: nil))
        }
        let drives = now.filter { $0.kind == .internalDrive || $0.kind == .externalDrive }
            .sorted { ($0.kind == .internalDrive ? 0 : 1, $0.name) < ($1.kind == .internalDrive ? 0 : 1, $1.name) }
        let ports = now.filter { $0.kind != .internalDrive && $0.kind != .externalDrive }.sorted { $0.name < $1.name }
        let next = drives + ports
        if next != parts { parts = next }
    }

    private static func drives() -> [Part] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeIsLocalKey, .volumeIsInternalKey,
                                      .volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let session = DASessionCreate(kCFAllocatorDefault)
        var out: [Part] = []
        for url in urls where url.path == "/" || url.path.hasPrefix("/Volumes/") {
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.volumeIsLocal ?? true else { continue }
            var proto: String?
            if let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
               let d = DADiskCopyDescription(disk) as? [String: Any] {
                proto = d[kDADiskDescriptionDeviceProtocolKey as String] as? String
            }
            // Disk images mount through a virtual device — not hardware.
            if let proto, proto.localizedCaseInsensitiveContains("virtual") { continue }
            let isInternal = url.path == "/" || (v?.volumeIsInternal ?? false)
            let name = v?.volumeName ?? url.lastPathComponent
            let id = isInternal && url.path == "/" ? "internal" : "drive:" + (v?.volumeUUIDString ?? name)
            let how = isInternal ? "Internal" : Self.connection(proto)
            guard let total = v?.volumeTotalCapacity, total > 0 else {
                out.append(Part(id: id, kind: isInternal ? .internalDrive : .externalDrive, name: name, lines: [how, "can’t be read"],
                                health: .failed, fullness: nil))
                continue
            }
            let free = url.volumeFreeBytes
            let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
            out.append(Part(id: id, kind: isInternal ? .internalDrive : .externalDrive, name: name, lines: [how, freeText],
                            health: free < DriveInfo.lowBytes ? .low : .normal,
                            fullness: min(1, max(0, 1 - Double(free) / Double(total)))))
        }
        return out
    }

    private static func connection(_ proto: String?) -> String {
        guard let p = proto?.lowercased() else { return "External" }
        if p.contains("thunderbolt") || p.contains("pci") { return "Thunderbolt" }
        if p.contains("usb") { return "USB" }
        if p.contains("sata") { return "SATA" }
        return proto ?? "External"
    }

    /// Ethernet and Wi-Fi ports that are up with an IPv4 address: address and link speed.
    private static func ports() -> [Part] {
        var types: [String: String] = [:]
        for iface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?, let t = SCNetworkInterfaceGetInterfaceType(iface) as String? {
                types[bsd] = t
            }
        }
        var addresses: [String: String] = [:]
        var speeds: [String: UInt64] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let e = pointer.pointee
            let name = String(cString: e.ifa_name)
            guard name.hasPrefix("en"), let addr = e.ifa_addr, (e.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            if addr.pointee.sa_family == UInt8(AF_LINK), let data = e.ifa_data {
                speeds[name] = UInt64(data.assumingMemoryBound(to: if_data.self).pointee.ifi_baudrate)
            } else if addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name] = String(cString: host)
                }
            }
        }
        return addresses.keys.sorted().map { bsd in
            let type = types[bsd]
            let kind: Kind = type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .wifi
                : type == (kSCNetworkInterfaceTypeEthernet as String) ? .ethernet : .port
            let name = kind == .wifi ? "Wi-Fi" : kind == .ethernet ? "Ethernet" : bsd
            var lines = [addresses[bsd] ?? ""]
            if let s = speeds[bsd], s > 0 { lines.append(Self.speed(s)) }
            return Part(id: "port:" + bsd, kind: kind, name: name, lines: lines, health: .normal, fullness: nil)
        }
    }

    /// "1 Gb/s", "866 Mb/s".
    private static func speed(_ bitsPerSecond: UInt64) -> String {
        bitsPerSecond >= 1_000_000_000
            ? String(format: bitsPerSecond % 1_000_000_000 == 0 ? "%.0f Gb/s" : "%.1f Gb/s", Double(bitsPerSecond) / 1e9)
            : "\(bitsPerSecond / 1_000_000) Mb/s"
    }
}
#endif
