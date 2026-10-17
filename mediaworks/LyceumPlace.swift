// REM  Mac only — Commander's panes.
//
//  LyceumPlace.swift
//  mediaworks
//
//  THE LYCEUM AS A PLACE IN COMMANDER — his design, 2026-10-17: "i dont like left dedicated and right dedicated i
//  personally may revers and i dont want to limit to the user ... the user selects within the users natural choice of
//  panes to use the drive dropdown to choose a network location or local drive and go from there".
//  So the Lyceum is one more entry in EITHER pane's drive picker — the whole library, across every server, as this Mac
//  sees it — and the usual Commander keys work on it:
//  · COPY or MOVE a local file onto a Lyceum folder = an import into exactly that folder (ImportJobs.swift), sent to the
//    master. Copy keeps the original; Move lets it go once the master says it arrived (his Delete setting).
//  · COPY a Lyceum file onto a local folder = downloaded from the server that holds it.
//  · DELETE in the Lyceum = asked of the server that holds the file (its 30-day Lyceum Trash).
//  Lyceum paths are shown under a made-up folder, /Lyceum Network, which exists on no drive.
//

#if os(macOS)
import Foundation
import UniformTypeIdentifiers

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

@MainActor
enum LyceumPlace {
    static let root = URL(fileURLWithPath: "/Lyceum Network", isDirectory: true)
    static var drive: Drive { Drive(url: root, name: "Lyceum", isLocal: false) }

    static func isInside(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return p == root.path || p.hasPrefix(root.path + "/")
    }

    /// The Lyceum-relative path — "" for the top.
    static func relative(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        return p == root.path ? "" : String(p.dropFirst(root.path.count + 1))
    }

    static func url(_ relative: String, folder: Bool = false) -> URL {
        relative.isEmpty ? root : root.appending(path: relative, directoryHint: folder ? .isDirectory : .notDirectory)
    }

    private static func folder(at relative: String) -> CachedFolder? {
        guard var folder = LibraryCatalog.shared.snapshot?.root else { return nil }
        for part in relative.split(separator: "/").map(String.init) {
            guard let next = folder.folders.first(where: { $0.name == part }) else { return nil }
            folder = next
        }
        return folder
    }

    /// What a pane lists inside the Lyceum.
    static func entries(in url: URL) -> [FolderEntry] {
        let rel = relative(url)
        guard let folder = folder(at: rel) else { return [] }
        let base = rel.isEmpty ? "" : rel + "/"
        let folders = folder.folders.map { FolderEntry(url: Self.url(base + $0.name, folder: true), isFolder: true, size: nil, type: .folder, modified: nil) }
        let files = folder.files.map {
            FolderEntry(url: Self.url(base + $0.name), isFolder: false, size: $0.size,
                        type: UTType(filenameExtension: ($0.name as NSString).pathExtension), modified: $0.modified)
        }
        return (folders + files).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The server holding a Lyceum file — nil when it is this Mac's own.
    static func holder(of relative: String) -> String? { LibraryCatalog.shared.snapshot?.file(at: relative)?.host }

    static func exists(_ relative: String) -> Bool {
        if LibraryCatalog.shared.snapshot?.file(at: relative) != nil { return true }
        let parent = (relative as NSString).deletingLastPathComponent, name = (relative as NSString).lastPathComponent
        return folder(at: parent)?.folders.contains { $0.name == name } ?? false
    }

    // MARK: Into the Lyceum — an import

    /// Each local file (folders walked for media, their inner folders kept) becomes a job for the master, into `folder`.
    /// Returns a one-line report, or a problem.
    static func importFiles(_ urls: [URL], into folder: String, keep: Bool) async -> String {
        let partner = LibraryPartner.shared
        guard let server = partner.decidedMaster.flatMap({ $0 == partner.me ? nil : $0 }) ?? partner.servers.sorted().first
                ?? (partner.thisMacServes ? partner.me : nil) else {
            return "No server to send to — tick one in Settings → General → Mediaworks Machines."
        }
        var sent = 0, problems: [String] = []
        for url in urls {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            let files = isFolder.boolValue ? SendQueue.media(in: url) : (SendQueue.isMedia(url) ? [url] : [])
            if files.isEmpty { problems.append("“\(url.lastPathComponent)” has no audio or video"); continue }
            for file in files {
                // Inside a copied folder, its own folders come along: Folder/Sub/file → <destination>/Folder/Sub.
                var place = folder
                if isFolder.boolValue {
                    let inner = file.deletingLastPathComponent().standardizedFileURL.path
                        .dropFirst(url.deletingLastPathComponent().standardizedFileURL.path.count + 1)
                    place = folder.isEmpty ? String(inner) : folder + "/" + inner
                }
                guard !place.isEmpty else { problems.append("Open a folder inside the Lyceum first — the top holds only folders"); break }
                let size = Int64(LibraryIntake.size(file))
                guard let job = ImportOutbox.shared.add(file, name: file.lastPathComponent, size: size, server: server,
                                                        destination: place, keep: keep) else {
                    problems.append("“\(file.lastPathComponent)” could not be offered"); continue
                }
                var request = CacheRequest(op: .importRegister, device: ImportDesk.me)
                request.picture = try? JSONEncoder().encode([job])
                guard let data = await partner.ask(request, to: server, timeout: 30),
                      let reply = try? JSONDecoder().decode(ImportReply.self, from: data), reply.ok else {
                    ImportOutbox.shared.forget(job.id)
                    problems.append("\(server) did not take “\(file.lastPathComponent)”")
                    continue
                }
                sent += 1
            }
        }
        ImportOutbox.shared.start()
        let head = sent == 0 ? "Nothing sent" : "Sent \(sent) file\(sent == 1 ? "" : "s") to \(server) for “\(folder.isEmpty ? "Lyceum" : folder)”"
            + (keep ? " — the originals stay here" : " — each original goes once \(server) says it arrived")
        return problems.isEmpty ? head : head + ". " + problems.prefix(3).joined(separator: "; ")
    }

    // MARK: Who holds what

    /// Where a request about a Lyceum item goes: nil = this Mac, else a server's name.
    private static func targets(_ rel: String) -> [String?] {
        if LibraryCatalog.shared.snapshot?.file(at: rel) != nil { return [holder(of: rel)] }
        var out: [String?] = []
        if let root = LibraryCatalog.shared.libraryRoot, !rel.isEmpty,
           FileManager.default.fileExists(atPath: root.appending(path: rel).path) { out.append(nil) }
        for (name, slice) in LibraryPartner.shared.slices where folderExists(slice.root, rel) { out.append(name) }
        return out
    }

    private static func folderExists(_ root: CachedFolder, _ rel: String) -> Bool {
        var folder = root
        for part in rel.split(separator: "/").map(String.init) {
            guard let next = folder.folders.first(where: { $0.name == part }) else { return false }
            folder = next
        }
        return true
    }

    /// Where a new top folder goes: the master, else this Mac if it serves, else the first server.
    private static var topTarget: String?? {
        let partner = LibraryPartner.shared
        if let m = partner.decidedMaster { return .some(m == partner.me ? nil : m) }
        if partner.thisMacServes, LibraryCatalog.shared.libraryRoot != nil { return .some(nil) }
        return partner.servers.sorted().first.map { .some($0) }
    }

    /// One request carried out where it belongs. Returns a problem, or nil.
    private static func send(_ request: CacheRequest, to target: String?) async -> String? {
        if let target {
            return await LibraryPartner.shared.ask(request, to: target, timeout: 3600) == nil ? "\(target) did not answer" : nil
        }
        await LibraryCatalog.shared.carryOut(request)
        return nil
    }

    private static func finish(_ problems: [String]) async -> String? {
        await LibraryPartner.shared.refresh()
        return problems.isEmpty ? nil : problems.prefix(3).joined(separator: "; ")
    }

    // MARK: Rename · new folder · move · delete — carried out by the server holding the item

    static func rename(_ url: URL, to name: String) async -> String? {
        let rel = relative(url)
        let isFile = LibraryCatalog.shared.snapshot?.file(at: rel) != nil
        let parent = (rel as NSString).deletingLastPathComponent
        if exists(parent.isEmpty ? name : parent + "/" + name) { return "“\(name)” is already there." }
        var problems: [String] = []
        for target in targets(rel) {
            if let p = await send(CacheRequest(op: isFile ? .renameFile : .renameFolder, path: rel, device: ImportDesk.me, newName: name), to: target) { problems.append(p) }
        }
        return await finish(problems)
    }

    /// Makes "untitled folder" (or "untitled folder 2" …) inside `parent`. Returns its place in Commander, or a problem.
    static func newFolder(in parent: URL) async -> Result<URL, FolderProblem> {
        let parentRel = relative(parent)
        var name = "untitled folder", n = 2
        while exists(parentRel.isEmpty ? name : parentRel + "/" + name) { name = "untitled folder \(n)"; n += 1 }
        let target: String?
        if parentRel.isEmpty {
            guard let top = topTarget else { return .failure(FolderProblem(text: "No server to make it on.")) }
            target = top
        } else {
            guard let first = targets(parentRel).first else { return .failure(FolderProblem(text: "No server holds “\(parentRel)”.")) }
            target = first
        }
        if let p = await send(CacheRequest(op: .newFolder, path: parentRel, device: ImportDesk.me, newName: name), to: target) {
            return .failure(FolderProblem(text: p))
        }
        _ = await finish([])
        return .success(url(parentRel.isEmpty ? name : parentRel + "/" + name, folder: true))
    }
    struct FolderProblem: Error { let text: String }

    /// Moves Lyceum items into another Lyceum folder — on the same server, or handed across to the one holding it.
    static func move(_ rels: [String], to folder: String) async -> String? {
        var problems: [String] = []
        for rel in rels {
            for target in targets(rel) {
                if let p = await send(CacheRequest(op: .moveItem, path: rel, device: ImportDesk.me, newName: folder), to: target) { problems.append(p) }
            }
        }
        return await finish(problems)
    }

    /// Asks the server(s) holding each item to put it in the Lyceum Trash.
    static func trash(_ rels: [String]) async -> String? {
        var problems: [String] = []
        for rel in rels {
            for target in targets(rel) {
                if let p = await send(CacheRequest(op: .trash, path: rel, device: ImportDesk.me), to: target) { problems.append(p) }
            }
        }
        return await finish(problems)
    }

    // MARK: Out of the Lyceum — a download

    /// Copies Lyceum files and folders into a local folder. Never overwrites. Returns what arrived and any problem.
    @discardableResult
    static func export(_ rels: [String], to destination: URL) async -> (arrived: [String], problem: String?) {
        var arrived: [String] = [], problems: [String] = []
        for rel in rels {
            let name = (rel as NSString).lastPathComponent
            let target = destination.appending(path: name)
            if FileManager.default.fileExists(atPath: target.path) { problems.append("“\(name)” is already there"); continue }
            if let file = LibraryCatalog.shared.snapshot?.file(at: rel) {
                if let p = await download(rel, size: file.size, to: target) { problems.append(p) } else { arrived.append(rel) }
            } else if let folder = folder(at: rel) {
                // A folder comes with everything in it, its folders kept.
                var ok = true
                func walk(_ f: CachedFolder, _ path: String, _ dir: URL) async {
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for file in f.files {
                        if let p = await download(path + "/" + file.name, size: file.size, to: dir.appending(path: file.name)) { problems.append(p); ok = false }
                    }
                    for sub in f.folders { await walk(sub, path + "/" + sub.name, dir.appending(path: sub.name, directoryHint: .isDirectory)) }
                }
                await walk(folder, rel, target)
                if ok { arrived.append(rel) }
            }
        }
        return (arrived, problems.isEmpty ? nil : problems.prefix(3).joined(separator: "; "))
    }

    /// One file, from this Mac's library or the server holding it; checked against its size before it counts.
    private static func download(_ rel: String, size: Int64?, to target: URL) async -> String? {
        let name = (rel as NSString).lastPathComponent
        if let host = holder(of: rel) {
            guard let url = await LibraryPartner.shared.previewURL(rel, on: host) else { return "\(host) is not answering" }
            do {
                let (temp, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    try? FileManager.default.removeItem(at: temp)
                    return "\(host) would not send “\(name)” — approve \(ImportDesk.me) on \(host): Settings → General → Devices That May Send Files"
                }
                try FileManager.default.moveItem(at: temp, to: target)
            } catch { return "“\(name)”: \(error.localizedDescription)" }
        } else if let root = LibraryCatalog.shared.libraryRoot {
            do { try FileManager.default.copyItem(at: root.appending(path: rel), to: target) } catch { return "“\(name)”: \(error.localizedDescription)" }
        }
        if let size, Int64(LibraryIntake.size(target)) != size { try? FileManager.default.removeItem(at: target); return "“\(name)” arrived incomplete" }
        return nil
    }

    /// Move out = copy out, checked, and only then the library's copy goes to its Lyceum Trash (fail-safe).
    static func moveOut(_ rels: [String], to destination: URL) async -> String? {
        let (arrived, problem) = await export(rels, to: destination)
        let trashProblem = arrived.isEmpty ? nil : await trash(arrived)
        return [problem, trashProblem].compactMap { $0 }.joined(separator: "; ").nilIfEmpty
    }

    /// Copy within the Lyceum = a copy out to a holding folder, then an import into the new folder.
    static func copyWithin(_ rels: [String], to folder: String) async -> String? {
        let holding = FileManager.default.temporaryDirectory.appending(path: "Lyceum copy \(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: holding, withIntermediateDirectories: true)
        let (arrived, problem) = await export(rels, to: holding)
        let urls = arrived.map { holding.appending(path: ($0 as NSString).lastPathComponent) }
        let report = urls.isEmpty ? nil : await importFiles(urls, into: folder, keep: false)
        return [problem, report.flatMap { $0.hasPrefix("Sent") ? nil : $0 }].compactMap { $0 }.joined(separator: "; ").nilIfEmpty
    }

    // MARK: Playing a Lyceum file in a pane's mini player

    /// Where the mini player plays a Lyceum file from: this Mac's own copy, or the server holding it — whatever its
    /// checkmark, since Commander is for upkeep (the preview route).
    static func playURL(_ url: URL) async -> URL? {
        let rel = relative(url)
        guard let host = holder(of: rel) else { return LibraryCatalog.shared.libraryRoot?.appending(path: rel) }
        return await LibraryPartner.shared.previewURL(rel, on: host)
    }
}
#endif
