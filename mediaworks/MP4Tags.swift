// REM  Not on Apple TV (no web pages, Quick Look or file panes there) — the TV has its own screen (TVHome).
#if !os(tvOS)
//
//  MP4Tags.swift
//  mediaworks
//
//  Saving tags WITHOUT copying the film — only the file's index is rewritten.
//
// REM  HIS ASK, 2026-10-08, watching a 1.13 GB film being copied to change seven tags: "why is it doing it that way
// REM  and not just the metadata?" → "yes build it, test it on copies first i just dont see why it is copying the
// REM  file to my macbook and then back yo the network drive?" (A network drive cannot rewrite a file by itself, so
// REM  Apple's only tag writer — which rebuilds the whole file — sends every byte to the Mac and back.)
// REM
// REM  HOW AN MP4 IS LAID OUT: a row of boxes. `mdat` holds the pictures and sound; `moov` is the index — where every
// REM  frame is, and (inside moov/udta/meta/ilst) the iTunes tags. His HandBrake files put moov LAST, after mdat.
// REM  The index points INTO mdat, which comes before it, so the index can move without anything else changing.
// REM
// REM  THE SAVE, IN AN ORDER THAT IS SAFE AT EVERY MOMENT:
// REM  1. Build the new index (same index, new tag list) in memory.
// REM  2. APPEND it to the end of the file. The file now holds two indexes; players use the FIRST, the old one,
// REM     so if anything stops here the film plays exactly as before.
// REM  3. Change the old index's 4-byte name from "moov" to "free" (a box every player skips). Now the new index is
// REM     the only one. Nothing in mdat is ever written to.
// REM  4. Lyceum then re-reads the file; if anything is wrong, step 3 is undone (the old index comes back).
// REM  Each save leaves the previous index behind as an unused "free" box — a few MB, against a film of a GB.
// REM
// REM  ONLY WHEN IT IS SAFE: MP4 / M4V / M4A, the index is the LAST box, every box is a normal size, the tags are
// REM  plain iTunes tags. Anything else — a .mov, an index at the front, tags in other kinds of slot — uses the
// REM  whole-file copy (TagWriter) as before.
//

import Foundation
import AVFoundation

nonisolated enum MP4Tags {
    struct Box {
        let type: String
        let offset: UInt64
        let size: UInt64
        let header: Int
    }

    enum Problem: Error { case notInPlace(String) }

    // MARK: Reading the layout

    /// The top-level boxes of a file, read from their headers only.
    static func topLevel(_ handle: FileHandle) throws -> [Box] {
        let end = try handle.seekToEnd()
        var boxes: [Box] = []
        var at: UInt64 = 0
        while at + 8 <= end {
            try handle.seek(toOffset: at)
            guard let head = try handle.read(upToCount: 16), head.count >= 8 else { break }
            var size = UInt64(be32(head, 0))
            let type = fourCC(head, 4)
            var header = 8
            if size == 1, head.count >= 16 { size = be64(head, 8); header = 16 }
            if size == 0 { size = end - at }
            guard size >= UInt64(header), at + size <= end else { throw Problem.notInPlace("box \(type) runs past the end") }
            boxes.append(Box(type: type, offset: at, size: size, header: header))
            at += size
        }
        return boxes
    }

    /// True when this file's tags can be rewritten without copying it.
    static func canWriteInPlace(_ url: URL) -> Bool {
        guard ["mp4", "m4v", "m4a"].contains(url.pathExtension.lowercased()),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let boxes = try? topLevel(handle), let last = boxes.last else { return false }
        return last.type == "moov" && last.header == 8 && boxes.filter({ $0.type == "moov" }).count == 1
    }

    // MARK: Saving

    /// Writes the edited tags (and picture) into the file's own index. Returns where the old index was, for undo.
    @discardableResult
    static func save(_ url: URL, edits: [TagField: String], picture: PictureEdit?) throws -> UInt64 {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let boxes = try topLevel(handle)
        guard let moov = boxes.last, moov.type == "moov", moov.header == 8 else {
            throw Problem.notInPlace("the index is not the last box")
        }
        try handle.seek(toOffset: moov.offset)
        guard let old = try handle.read(upToCount: Int(moov.size)), old.count == Int(moov.size) else {
            throw Problem.notInPlace("the index could not be read")
        }
        let newMoov = try rebuildMoov(old, edits: edits, picture: picture)

        // 2. Append the new index. The old one is still first, so the file plays as before.
        let end = try handle.seekToEnd()
        try handle.write(contentsOf: newMoov)
        try handle.synchronize()
        // 3. Retire the old index: "moov" → "free".
        try handle.seek(toOffset: moov.offset + 4)
        try handle.write(contentsOf: Data("free".utf8))
        try handle.synchronize()
        _ = end
        return moov.offset
    }

    /// Undoes step 3 after a failed check: the old index is "moov" again and the new one becomes "free".
    static func undo(_ url: URL, oldIndexAt offset: UInt64) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let boxes = try topLevel(handle)
        guard let newest = boxes.last, newest.type == "moov" else { return }
        try handle.seek(toOffset: newest.offset + 4)
        try handle.write(contentsOf: Data("free".utf8))
        try handle.seek(toOffset: offset + 4)
        try handle.write(contentsOf: Data("moov".utf8))
        try handle.synchronize()
    }

    // MARK: Rebuilding the index with new tags

    private struct Child { let type: String; let data: Data }   // data = the whole box, header included

    private static func children(_ box: Data, from start: Int) throws -> [Child] {
        var out: [Child] = []
        var at = start
        while at + 8 <= box.count {
            let size = Int(be32(box, at))
            let type = fourCC(box, at + 4)
            guard size >= 8, at + size <= box.count else { throw Problem.notInPlace("a box inside the index is damaged or too large") }
            out.append(Child(type: type, data: box.subdata(in: at..<(at + size))))
            at += size
        }
        return out
    }

    private static func box(_ type: String, _ body: Data) -> Data {
        var out = Data()
        out.append(be32(UInt32(8 + body.count)))
        out.append(type4(type))
        out.append(body)
        return out
    }

    private static func rebuildMoov(_ moov: Data, edits: [TagField: String], picture: PictureEdit?) throws -> Data {
        var moovKids = try children(moov, from: 8)
        let udtaIndex = moovKids.firstIndex { $0.type == "udta" }
        var udtaKids = try udtaIndex.map { try children(moovKids[$0].data, from: 8) } ?? []

        // meta inside udta is a "full box": 4 bytes of version/flags before its children.
        let metaIndex = udtaKids.firstIndex { $0.type == "meta" }
        var metaFlags = Data([0, 0, 0, 0])
        var metaKids: [Child] = []
        if let metaIndex {
            let meta = udtaKids[metaIndex].data
            guard meta.count >= 12, fourCC(meta, 16) == "hdlr" || fourCC(meta, 16) == "ilst" || fourCC(meta, 16) == "free" else {
                throw Problem.notInPlace("the tag area is not the iTunes kind")
            }
            metaFlags = meta.subdata(in: 8..<12)
            metaKids = try children(meta, from: 12)
        } else {
            // A fresh tag area needs a handler that says "these are iTunes tags".
            var hdlr = Data([0, 0, 0, 0, 0, 0, 0, 0])
            hdlr.append(type4("mdir")); hdlr.append(type4("appl"))
            hdlr.append(Data(count: 9))
            metaKids = [Child(type: "hdlr", data: box("hdlr", hdlr))]
        }

        let ilstIndex = metaKids.firstIndex { $0.type == "ilst" }
        var items = try ilstIndex.map { try children(metaKids[$0].data, from: 8) } ?? []

        // Remove every item being changed (an emptied field is simply left out), then add the new ones.
        var changed = Array(edits.keys)
        if picture != nil { changed.append(.artwork) }
        let shortKeys = Set(changed.compactMap { field -> String? in
            guard let key = field.writeKey, key.space == .iTunes else { return nil }
            return key.key
        } + (changed.contains(.genre) ? ["gnre"] : []))
        let longNames = Set(changed.compactMap { field -> String? in
            guard let key = field.writeKey, key.space.rawValue == "itlk" else { return nil }
            return key.key.components(separatedBy: ".").last
        })
        items.removeAll { item in
            if shortKeys.contains(where: { type4($0) == type4(item.type) }) { return true }
            if item.type == "----", let name = longFormName(item.data), longNames.contains(name) { return true }
            return false
        }
        for (field, text) in edits.sorted(by: { $0.key.number < $1.key.number }) {
            if let item = try item(for: field, text) { items.append(item) }
        }
        if case .replace(let bytes, let isPNG) = picture {
            items.append(Child(type: "covr", data: box("covr", dataBox(type: isPNG ? 14 : 13, bytes))))
        }

        // Put it all back together, sizes recomputed on the way out.
        let ilst = Child(type: "ilst", data: box("ilst", items.reduce(Data()) { $0 + $1.data }))
        if let ilstIndex { metaKids[ilstIndex] = ilst } else { metaKids.append(ilst) }
        let meta = Child(type: "meta", data: box("meta", metaFlags + metaKids.reduce(Data()) { $0 + $1.data }))
        if let metaIndex { udtaKids[metaIndex] = meta } else { udtaKids.append(meta) }
        let udta = Child(type: "udta", data: box("udta", udtaKids.reduce(Data()) { $0 + $1.data }))
        if let udtaIndex { moovKids[udtaIndex] = udta } else { moovKids.append(udta) }
        return box("moov", moovKids.reduce(Data()) { $0 + $1.data })
    }

    /// One tag as an iTunes item box — or nil when the field was emptied (it is then just removed).
    private static func item(for field: TagField, _ text: String) throws -> Child? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let key = field.writeKey else { return nil }
        func whole<T: FixedWidthInteger>(_: T.Type) throws -> T {
            guard let value = T(text) else { throw FileProblem(message: "\(field.number) \(field.label) must be a whole number.") }
            return value
        }
        let payload: Data
        let kind: UInt32
        switch field.kind {
        case .int8: payload = Data([UInt8(bitPattern: try whole(Int8.self))]); kind = 21
        case .int16: payload = be16(UInt16(bitPattern: try whole(Int16.self))); kind = 21
        case .int32: payload = be32(UInt32(bitPattern: try whole(Int32.self))); kind = 21
        case .pair:
            let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { UInt16($0) }
            guard let number = numbers.first else { throw FileProblem(message: "\(field.number) \(field.label) must look like 3/12 or 3.") }
            let total = numbers.count > 1 ? numbers[1] : 0
            var bytes = Data([0, 0]) + be16(number) + be16(total)
            if field == .track { bytes += Data([0, 0]) }   // track is 8 bytes, disc is 6 (iTunes' own layout)
            payload = bytes; kind = 0
        case .rating:
            payload = Data(TagWriter.ratingTag(text).utf8); kind = 1
        default:
            payload = Data(text.utf8); kind = 1
        }
        if key.space.rawValue == "itlk" {
            // Long-form tag: ---- { mean "com.apple.iTunes", name "iTunEXTC", data }
            let name = key.key.components(separatedBy: ".").last ?? key.key
            let body = box("mean", Data([0, 0, 0, 0]) + Data("com.apple.iTunes".utf8))
                + box("name", Data([0, 0, 0, 0]) + Data(name.utf8))
                + dataBox(type: kind, payload)
            return Child(type: "----", data: box("----", body))
        }
        return Child(type: key.key, data: box(key.key, dataBox(type: kind, payload)))
    }

    private static func dataBox(type: UInt32, _ payload: Data) -> Data {
        box("data", be32(type) + Data([0, 0, 0, 0]) + payload)
    }

    /// The `name` inside a long-form "----" item ("iTunEXTC").
    private static func longFormName(_ item: Data) -> String? {
        guard let kids = try? children(item, from: 8),
              let name = kids.first(where: { $0.type == "name" }), name.data.count > 12 else { return nil }
        return String(data: name.data.subdata(in: 12..<name.data.count), encoding: .utf8)
    }

    // MARK: Bytes

    /// A box name as its 4 bytes — "©nam" is 0xA9 n a m, as iTunes writes it.
    static func type4(_ type: String) -> Data {
        Data(type.unicodeScalars.map { $0.value == 0xA9 ? 0xA9 : UInt8(truncatingIfNeeded: $0.value) })
    }
    private static func fourCC(_ d: Data, _ at: Int) -> String {
        String(d.subdata(in: d.startIndex + at..<d.startIndex + at + 4).map { Character(Unicode.Scalar($0)) })
    }
    private static func be32(_ d: Data, _ at: Int) -> UInt32 {
        d.subdata(in: d.startIndex + at..<d.startIndex + at + 4).reduce(0) { $0 << 8 | UInt32($1) }
    }
    private static func be64(_ d: Data, _ at: Int) -> UInt64 {
        d.subdata(in: d.startIndex + at..<d.startIndex + at + 8).reduce(0) { $0 << 8 | UInt64($1) }
    }
    private static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]) }
    private static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 255)]) }
}
#endif
