// REM  Mac only.
#if os(macOS)
//
//  MKVRemux.swift
//  mediaworks
//
//  THE MKV READER — the second half of roadmap 017. Apple's frameworks cannot open MKV (measured 2026-10-13: AVFoundation
//  lists AVI but no Matroska type), and his Lyceum held 4 MKVs, every one VP9 video + AAC audio (read from their headers).
//  So Mediaworks reads MKV itself — no outside tool (001c):
//    1. Walks the file's EBML structure: tracks, clusters, blocks (all four lacing kinds).
//    2. VP9 video is decoded by Apple's own VP9 decoder (VideoToolbox's supplemental decoder; hardware on Apple silicon)
//       and encoded again as H.264 or HEVC — the Transcode window's choice.
//    3. AAC audio is carried over untouched.
//    4. The result is an ordinary MP4 with the MKV's title; Transcoder checks it runs the same length before keeping it.
//  Anything else inside an MKV (H.264 in MKV, Opus, Vorbis…) is reported by name rather than guessed at.
//

import Foundation
import AVFoundation
import VideoToolbox

nonisolated enum MKVProblem: LocalizedError {
    case notMKV, unsupported(String), broken(String)
    var errorDescription: String? {
        switch self {
        case .notMKV: "This is not an MKV file."
        case .unsupported(let what): "Inside it is \(what), which the MKV reader does not convert yet."
        case .broken(let why): why
        }
    }
}

// MARK: - Reading EBML, a little at a time (the files are a gigabyte and more)

nonisolated final class EBMLReader {
    private let handle: FileHandle
    let fileSize: UInt64
    private var buffer = Data()
    private var bufferStart: UInt64 = 0
    private(set) var position: UInt64 = 0

    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)
    }
    deinit { try? handle.close() }

    private func fill(_ count: Int) throws {
        let have = Int(bufferStart + UInt64(buffer.count) - position)
        guard have < count else { return }
        let keep = buffer.suffix(max(0, have))
        try handle.seek(toOffset: position + UInt64(max(0, have)))
        let more = try handle.read(upToCount: max(count - have, 4 << 20)) ?? Data()
        buffer = Data(keep) + more
        bufferStart = position
    }

    func bytes(_ count: Int) throws -> Data {
        try fill(count)
        let offset = Int(position - bufferStart)
        guard offset + count <= buffer.count else { throw MKVProblem.broken("The MKV ends early.") }
        position += UInt64(count)
        return buffer.subdata(in: buffer.startIndex + offset ..< buffer.startIndex + offset + count)
    }

    func skip(_ count: UInt64) { position += count }
    func seek(_ to: UInt64) { position = to }

    /// An element ID — marker bits kept, as the spec writes IDs.
    func id() throws -> UInt32 {
        let first = try bytes(1)[0]
        let length = first.leadingZeroBitCount + 1
        guard length <= 4 else { throw MKVProblem.broken("A damaged element ID.") }
        var value = UInt32(first)
        if length > 1 { for b in try bytes(length - 1) { value = value << 8 | UInt32(b) } }
        return value
    }

    /// An element size — nil means "unknown" (all ones), used by streamed files for Segment and Cluster.
    func size() throws -> UInt64? {
        let first = try bytes(1)[0]
        let length = first.leadingZeroBitCount + 1
        guard length <= 8 else { throw MKVProblem.broken("A damaged element size.") }
        var value = UInt64(first & (0xFF >> length))
        var allOnes = value == UInt64(0xFF >> length)
        if length > 1 { for b in try bytes(length - 1) { value = value << 8 | UInt64(b); allOnes = allOnes && b == 0xFF } }
        return allOnes ? nil : value
    }

    func uint(_ size: UInt64) throws -> UInt64 { try bytes(Int(size)).reduce(0) { $0 << 8 | UInt64($1) } }
    func float(_ size: UInt64) throws -> Double {
        let d = try bytes(Int(size))
        if size == 4 { return Double(Float(bitPattern: d.reduce(0) { $0 << 8 | UInt32($1) })) }
        if size == 8 { return Double(bitPattern: d.reduce(0) { $0 << 8 | UInt64($1) }) }
        return 0
    }
    func string(_ size: UInt64) throws -> String {
        String(decoding: try bytes(Int(size)).prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// A variable-length integer inside a block (track number, lace sizes).
nonisolated func ebmlVint(_ data: Data, _ at: inout Int, signed: Bool = false) -> Int64? {
    guard at < data.endIndex else { return nil }
    let first = data[at]
    let length = first.leadingZeroBitCount + 1
    guard length <= 8, at + length <= data.endIndex else { return nil }
    var value = Int64(first & (0xFF >> length))
    for i in 1..<length { value = value << 8 | Int64(data[at + i]) }
    at += length
    if signed { value -= (Int64(1) << (7 * length - 1)) - 1 }
    return value
}

// MARK: - The structure

nonisolated struct MKVTrack {
    var number: UInt64 = 0
    var type: UInt64 = 0           // 1 video · 2 audio · 17 subtitles
    var codec = ""
    var codecPrivate: Data?
    var width = 0, height = 0
    var sampleRate = 48_000.0
    var channels = 2
    var defaultDuration: UInt64?   // ns per frame
}

/// Reads an MKV front to back and hands every frame to `frame` — (track, time in ns, keyframe, bytes).
nonisolated final class MKVDemuxer {
    private let r: EBMLReader
    private(set) var tracks: [UInt64: MKVTrack] = [:]
    private(set) var title: String?
    private(set) var duration: Double?       // seconds
    private var scale: UInt64 = 1_000_000   // TimecodeScale, ns

    private static let topLevel: Set<UInt32> = [0x1F43B675, 0x1C53BB6B, 0x1254C367, 0x1941A469, 0x114D9B74, 0x1549A966, 0x1654AE6B, 0x1043A770]

    init(_ url: URL) throws { r = try EBMLReader(url) }

    /// Reads up to the first cluster: the info and the tracks.
    func readHeader() throws {
        guard try r.id() == 0x1A45DFA3, let headerSize = try r.size() else { throw MKVProblem.notMKV }
        r.skip(headerSize)
        guard try r.id() == 0x18538067 else { throw MKVProblem.notMKV }
        _ = try r.size()
        while r.position < r.fileSize {
            let start = r.position
            let id = try r.id()
            guard let size = try r.size() else { throw MKVProblem.broken("An unknown-size element before the first cluster.") }
            switch id {
            case 0x1549A966: try readInfo(end: r.position + size)
            case 0x1654AE6B: try readTracks(end: r.position + size)
            case 0x1F43B675: r.seek(start); return     // first cluster — the frames start here
            default: r.skip(size)
            }
        }
    }

    private func readInfo(end: UInt64) throws {
        var rawDuration: Double?
        while r.position < end {
            let id = try r.id(); guard let size = try r.size() else { return }
            switch id {
            case 0x2AD7B1: scale = try r.uint(size)
            case 0x4489: rawDuration = try r.float(size)
            case 0x7BA9: title = try r.string(size)
            default: r.skip(size)
            }
        }
        duration = rawDuration.map { $0 * Double(scale) / 1e9 }
    }

    private func readTracks(end: UInt64) throws {
        while r.position < end {
            let id = try r.id(); guard let size = try r.size() else { return }
            guard id == 0xAE else { r.skip(size); continue }
            let entryEnd = r.position + size
            var t = MKVTrack()
            while r.position < entryEnd {
                let cid = try r.id(); guard let csize = try r.size() else { break }
                switch cid {
                case 0xD7: t.number = try r.uint(csize)
                case 0x83: t.type = try r.uint(csize)
                case 0x86: t.codec = try r.string(csize)
                case 0x63A2: t.codecPrivate = try r.bytes(Int(csize))
                case 0x23E383: t.defaultDuration = try r.uint(csize)
                case 0xE0:
                    let vEnd = r.position + csize
                    while r.position < vEnd {
                        let vid = try r.id(); guard let vsize = try r.size() else { break }
                        switch vid {
                        case 0xB0: t.width = Int(try r.uint(vsize))
                        case 0xBA: t.height = Int(try r.uint(vsize))
                        default: r.skip(vsize)
                        }
                    }
                case 0xE1:
                    let aEnd = r.position + csize
                    while r.position < aEnd {
                        let aid = try r.id(); guard let asize = try r.size() else { break }
                        switch aid {
                        case 0xB5: t.sampleRate = try r.float(asize)
                        case 0x9F: t.channels = Int(try r.uint(asize))
                        default: r.skip(asize)
                        }
                    }
                default: r.skip(csize)
                }
            }
            tracks[t.number] = t
        }
    }

    /// Every frame, in file order. `frame` returns false to stop.
    func frames(_ frame: (UInt64, Int64, Bool, Data) throws -> Bool) throws {
        while r.position < r.fileSize {
            let id: UInt32
            do { id = try r.id() } catch { return }               // a few stray bytes at the very end
            let size = try r.size()
            guard id == 0x1F43B675 else {
                guard let size else { continue }                    // an unknown-size non-cluster: step into it
                r.skip(size); continue
            }
            let end = size.map { r.position + $0 } ?? r.fileSize
            var clusterTime: Int64 = 0
            while r.position < end {
                let elementStart = r.position
                let cid = try r.id()
                if size == nil, Self.topLevel.contains(cid) { r.seek(elementStart); break }   // next cluster begins
                guard let csize = try r.size() else { continue }
                switch cid {
                case 0xE7: clusterTime = Int64(try r.uint(csize))
                case 0xA3:
                    if try !block(try r.bytes(Int(csize)), clusterTime, simple: true, frame) { return }
                case 0xA0:
                    let gEnd = r.position + csize
                    var data: Data?, isKey = true
                    while r.position < gEnd {
                        let gid = try r.id(); guard let gsize = try r.size() else { break }
                        if gid == 0xA1 { data = try r.bytes(Int(gsize)) }
                        else { if gid == 0xFB { isKey = false }; r.skip(gsize) }
                    }
                    if let data, try !block(data, clusterTime, simple: false, keyHint: isKey, frame) { return }
                default: r.skip(csize)
                }
            }
        }
    }

    private func block(_ d: Data, _ clusterTime: Int64, simple: Bool, keyHint: Bool = true,
                       _ frame: (UInt64, Int64, Bool, Data) throws -> Bool) throws -> Bool {
        var at = d.startIndex
        guard let number = ebmlVint(d, &at), number >= 0, at + 3 <= d.endIndex else { return true }
        let track = UInt64(number)
        let relative = Int64(Int16(bitPattern: UInt16(d[at]) << 8 | UInt16(d[at + 1])))
        let flags = d[at + 2]
        at += 3
        let key = simple ? (flags & 0x80) != 0 : keyHint
        let time = (clusterTime + relative) * Int64(scale)
        let lacing = (flags >> 1) & 0x03
        var sizes: [Int] = []
        if lacing != 0 {
            let count = Int(d[at]) + 1; at += 1
            switch lacing {
            case 1:   // Xiph
                for _ in 0..<(count - 1) {
                    var s = 0
                    while at < d.endIndex { let b = Int(d[at]); at += 1; s += b; if b != 255 { break } }
                    sizes.append(s)
                }
            case 3:   // EBML
                guard let first = ebmlVint(d, &at) else { return true }
                sizes.append(Int(first))
                for _ in 1..<max(count - 1, 1) where count > 2 {
                    guard let delta = ebmlVint(d, &at, signed: true) else { return true }
                    sizes.append(sizes.last! + Int(delta))
                }
            default:  // fixed
                let each = (d.endIndex - at) / count
                sizes = Array(repeating: each, count: count - 1)
            }
            sizes.append(d.endIndex - at - sizes.reduce(0, +))
        } else {
            sizes = [d.endIndex - at]
        }
        let frameNs = Int64(tracks[track].flatMap { t in t.type == 2 ? Int64(1024 * 1e9 / t.sampleRate) : t.defaultDuration.map(Int64.init) } ?? 0)
        for (i, s) in sizes.enumerated() {
            guard s >= 0, at + s <= d.endIndex else { return true }
            if try !frame(track, time + Int64(i) * frameNs, key, d.subdata(in: at ..< at + s)) { return false }
            at += s
        }
        return true
    }
}

// MARK: - Turning it into an MP4

nonisolated enum MKVRemux {
    /// The codecs inside, as the MKV names them — "V_VP9, A_AAC".
    static func codecs(_ url: URL) -> String? {
        guard let d = try? MKVDemuxer(url), (try? d.readHeader()) != nil else { return nil }
        return d.tracks.values.sorted { $0.number < $1.number }.filter { $0.type == 1 || $0.type == 2 }.map(\.codec).joined(separator: ", ")
    }

    static func canConvert(_ url: URL) -> Bool {
        guard let d = try? MKVDemuxer(url), (try? d.readHeader()) != nil else { return false }
        let v = d.tracks.values.filter { $0.type == 1 }, a = d.tracks.values.filter { $0.type == 2 }
        return v.count == 1 && v[0].codec == "V_VP9" && a.allSatisfy { $0.codec == "A_AAC" } && a.count <= 1
    }

    /// Converts `source` into an MP4 at `output`. `progress` gets 0…1.
    static func convert(_ source: URL, to output: URL, hevc: Bool, maxWidth: Int, progress: @escaping (Double) -> Void) throws {
        let mkv = try MKVDemuxer(source)
        try mkv.readHeader()
        guard let video = mkv.tracks.values.first(where: { $0.type == 1 }) else { throw MKVProblem.unsupported("no video") }
        guard video.codec == "V_VP9" else { throw MKVProblem.unsupported(video.codec) }
        let audio = mkv.tracks.values.first { $0.type == 2 }
        if let audio, audio.codec != "A_AAC" { throw MKVProblem.unsupported(audio.codec) }
        guard video.width > 0, video.height > 0 else { throw MKVProblem.broken("The MKV does not give the picture size.") }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        if let title = mkv.title, !title.isEmpty {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierTitle
            item.value = title as NSString
            writer.metadata = [item]
        }

        // The picture: as big as the source, no wider than the chosen standard allows.
        let outW = min(video.width, maxWidth) & ~1
        let outH = (Int(Double(video.height) * Double(outW) / Double(video.width)) & ~1)
        let pixels = Double(outW * outH)
        let bitrate = Int(pixels * (hevc ? 2.4 : 4.0))      // ≈ 5 Mb/s HEVC · 8 Mb/s H.264 at 1080p
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: outW, AVVideoHeightKey: outH,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        videoIn.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: nil)
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if let audio, let asc = audio.codecPrivate {
            audioFormat = try aacFormat(asc: asc, sampleRate: audio.sampleRate, channels: audio.channels)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioIn = input
        }
        guard writer.startWriting() else { throw MKVProblem.broken(writer.error?.localizedDescription ?? "The MP4 could not be started.") }
        writer.startSession(atSourceTime: .zero)

        // Apple's VP9 decoder.
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        var decoder: VTDecompressionSession?
        var videoFormat: CMVideoFormatDescription?
        var lastVideo = CMTime.zero
        var failure: Error?
        let total = Double(mkv.duration ?? 0)

        func wait(_ input: AVAssetWriterInput) {
            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 2000 { usleep(1000); waited += 1 }
        }

        try mkv.frames { track, ns, key, data in
            let pts = CMTime(value: ns, timescale: 1_000_000_000)
            if track == video.number {
                if decoder == nil {
                    guard key else { return true }                             // start at the first keyframe
                    videoFormat = try vp9Format(width: video.width, height: video.height, firstFrame: data)
                    var session: VTDecompressionSession?
                    let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
                    let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: videoFormat!, decoderSpecification: nil,
                                                              imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &session)
                    guard status == noErr, let session else { throw MKVProblem.broken("Apple's VP9 decoder would not start (\(status)).") }
                    decoder = session
                }
                guard let sample = sampleBuffer(data, format: videoFormat!, pts: pts, duration: .invalid) else { return true }
                let status = VTDecompressionSessionDecodeFrame(decoder!, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, time, _ in
                    guard status == noErr, let image, time.isValid, time > lastVideo || lastVideo == .zero else { return }
                    wait(videoIn)
                    if !adaptor.append(image, withPresentationTime: time) { failure = writer.error }
                    lastVideo = time
                }
                if status != noErr, status != kVTVideoDecoderBadDataErr { throw MKVProblem.broken("Apple's VP9 decoder stopped (\(status)).") }
                if total > 0 { progress(min(1, pts.seconds / total)) }
            } else if let audioIn, let audioFormat, track == audio?.number {
                let frameDuration = CMTime(value: 1024, timescale: CMTimeScale(audio!.sampleRate))
                guard let sample = sampleBuffer(data, format: audioFormat, pts: pts, duration: frameDuration) else { return true }
                wait(audioIn)
                if !audioIn.append(sample) { failure = writer.error }
            }
            return failure == nil
        }
        if let decoder { VTDecompressionSessionWaitForAsynchronousFrames(decoder); VTDecompressionSessionInvalidate(decoder) }
        videoIn.markAsFinished()
        audioIn?.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if let failure { throw failure }
        guard writer.status == .completed else { throw writer.error ?? MKVProblem.broken("The MP4 could not be finished.") }
        progress(1)
    }

    /// One frame as a CoreMedia sample.
    private static func sampleBuffer(_ data: Data, format: CMFormatDescription, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = data.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                  sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }

    /// VP9's description for the decoder: the picture size plus a "vpcC" record read from the first keyframe's profile.
    static func vp9Format(width: Int, height: Int, firstFrame: Data) throws -> CMVideoFormatDescription {
        let b0 = firstFrame.first ?? 0x80
        let profile = UInt8(((b0 >> 4) & 0x01) << 1 | ((b0 >> 5) & 0x01))   // frame_marker(2) · profile_low · profile_high
        let bitDepth: UInt8 = profile >= 2 ? 10 : 8
        var vpcC = Data([1, 0, 0, 0])                    // version 1, flags 0
        vpcC.append(contentsOf: [profile, 31,            // profile · level 3.1 (informational)
                                 bitDepth << 4 | 1 << 1 | 0,   // bit depth · 4:2:0 colocated · limited range
                                 1, 1, 1,                // BT.709 primaries, transfer, matrix
                                 0, 0])                  // no codec initialization data
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vpcC": vpcC]] as CFDictionary
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_VP9, width: Int32(width), height: Int32(height),
                                                    extensions: extensions, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw MKVProblem.broken("The VP9 description could not be made (\(status)).") }
        return format
    }

    /// AAC's description: MKV keeps the AudioSpecificConfig; CoreAudio wants it wrapped as an MPEG-4 ES descriptor.
    static func aacFormat(asc: Data, sampleRate: Double, channels: Int) throws -> CMAudioFormatDescription {
        func descriptor(_ tag: UInt8, _ body: Data) -> Data {
            let n = body.count                                                // 4-byte length form, as CoreAudio writes it
            return Data([tag, UInt8(0x80 | (n >> 21) & 0x7F), UInt8(0x80 | (n >> 14) & 0x7F), UInt8(0x80 | (n >> 7) & 0x7F), UInt8(n & 0x7F)]) + body
        }
        let decSpecific = descriptor(0x05, asc)
        let decConfig = descriptor(0x04, Data([0x40, 0x15, 0, 0x18, 0, 0, 0x01, 0xF4, 0, 0, 0x01, 0xF4, 0]) + decSpecific)
        let sl = descriptor(0x06, Data([0x02]))
        let es = descriptor(0x03, Data([0, 0, 0]) + decConfig + sl)
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                               mBitsPerChannel: 0, mReserved: 0)
        var format: CMAudioFormatDescription?
        let status = es.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: es.count,
                                           magicCookie: cookie.baseAddress, extensions: nil, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { throw MKVProblem.broken("The AAC description could not be made (\(status)).") }
        return format
    }
}
#endif
