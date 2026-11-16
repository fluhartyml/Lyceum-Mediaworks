// REM  Mac only — the conversion runs on the Mac that holds the file.
#if os(macOS)
//
//  LiveConvertEngine.swift
//  mediaworks
//
//  E-013 — STREAM LOWER, NEVER TRANSCODE THE FILE. The engine: one run turns a file above 1080p into 6-second HLS
//  pieces at one size (1080p, 720p or 480p), in memory only. LiveConvert.swift serves them.
//
// REM  HIS WORDS, 2026-11-12: "streaming a lower quality without having to perminantly transcode the videos would seem
// REM  better because of future technology and perhaps my homenetwork to the apple tv gets better bandwidth" ·
// REM  "what if the mediaworks server determines from apple tv feedback it needs to transcode down from 1080p to 640x480" ·
// REM  "4k is never needed it is always lower than 4k".
// REM  So: the original is only READ. Nothing is written to any disk — every piece lives in this run's memory and is
// REM  dropped once the player is past it.
//
// REM  HOW A RUN WORKS
// REM   1. Apple's reader decodes the file from piece k's start time (k × 6 s), asking for BT.709 color.
// REM   2. VideoToolbox (the Mac's hardware encoder) makes H.264 at the size of the run, and is FORCED to start a fresh
// REM      keyframe at every 6-second mark. That is what lets a piece be made again later, from a cold start, and come out
// REM      with the same boundaries — a seek restarts the run at the piece asked for.
// REM   3. AVAssetWriter in its HLS mode (.mpeg4AppleHLS) cuts the stream into pieces at those keyframes and hands each one
// REM      over (the delegate below) instead of writing a file.
// REM   4. Sound is passed through untouched when the Apple TV plays it as it is (AAC, Dolby Digital, Dolby Digital Plus);
// REM      anything else becomes AAC stereo.
// REM  PACE: a run stays at most 3 pieces ahead of what the player asked for, so memory stays small and the Mac's encoder
// REM  is free for another device. A minute with no request ends the run.
//

import Foundation
import AVFoundation
import VideoToolbox

/// The sizes a file above 1080p is offered at — never 4K (his "4k is never needed").
nonisolated enum LiveTier: Int, CaseIterable, Sendable {
    case p1080 = 1080
    case p720 = 720
    case p480 = 480

    /// The average the encoder aims for, for 30 frames a second; 60 gets half again.
    var bitrate: Int {
        switch self {
        case .p1080: 6_000_000
        case .p720: 3_000_000
        case .p480: 1_200_000
        }
    }

    /// H.264 High at a fixed level, so the playlist can name it before a frame is made.
    var level: CFString {
        self == .p1080 ? kVTProfileLevel_H264_High_4_2 : kVTProfileLevel_H264_High_4_0
    }
    var codecs: String { self == .p1080 ? "avc1.64002a" : "avc1.640028" }
}

/// What a run needs to know about the file, read once.
nonisolated struct LiveSource: @unchecked Sendable {
    static let pieceSeconds = 6.0

    let url: URL
    let duration: Double
    /// As stored in the file, before turning.
    let naturalWidth: Int
    let naturalHeight: Int
    let transform: CGAffineTransform
    let frameRate: Double
    /// The sound's own format, when it goes through untouched.
    let audioPassthrough: CMFormatDescription?
    let hasAudio: Bool
    let audioCodecs: String?
    /// An anamorphic file's stretch (wide pixels), carried over so the TV stretches it back. Nil for square pixels.
    let pixelAspect: CFDictionary?
    /// Read through Mediaworks' own MKV reader (MKVRemux.swift) instead of Apple's — Apple's frameworks cannot open MKV.
    var isMKV = false

    var shortSide: Int { min(naturalWidth, naturalHeight) }
    var pieceCount: Int { max(1, Int((duration / Self.pieceSeconds).rounded(.up))) }
    /// Sizes below the file's own — a file at or under 1080p is never converted, so this is empty for it.
    // REM  EXCEPT AN MKV (his 11-16: "i want them to be left alone and transcoded and presented to the apple tv"). The Apple
    // REM  TV cannot play an MKV as it is, so every MKV is converted live: at its own size too (up to 1080p), and a picture
    // REM  smaller than 480p is offered once, at its own size. The file itself is only read, never replaced.
    var tiers: [LiveTier] {
        guard isMKV else { return LiveTier.allCases.filter { $0.rawValue < shortSide } }
        let fits = LiveTier.allCases.filter { $0.rawValue <= shortSide }
        return fits.isEmpty ? [.p480] : fits
    }

    /// The encoded size of a tier, in the file's own orientation, even numbers only — never larger than the file.
    func size(_ tier: LiveTier) -> (width: Int, height: Int) {
        let scale = min(1, Double(tier.rawValue) / Double(shortSide))
        return (Int((Double(naturalWidth) * scale / 2).rounded()) * 2, Int((Double(naturalHeight) * scale / 2).rounded()) * 2)
    }

    /// The size as the screen shows it (turned when the file says so).
    func shownSize(_ tier: LiveTier) -> (width: Int, height: Int) {
        let s = size(tier)
        return abs(transform.b) == 1 ? (s.height, s.width) : s
    }

    func peak(_ tier: LiveTier) -> Int {
        let fast = frameRate > 31 ? 1.5 : 1.0
        return Int(Double(tier.bitrate) * fast * 1.5) + 256_000
    }

    func average(_ tier: LiveTier) -> Int {
        Int(Double(tier.bitrate) * (frameRate > 31 ? 1.5 : 1.0)) + 192_000
    }

    /// Nil when Apple's frameworks cannot read it or it holds no picture.
    static func load(_ url: URL) async -> LiveSource? {
        if ["mkv", "webm"].contains(url.pathExtension.lowercased()) { return loadMKV(url) }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true,
              let video = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform, fps, formats) = try? await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions),
              let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return nil }
        var passthrough: CMFormatDescription?
        var codecs: String?
        let audio = try? await asset.loadTracks(withMediaType: .audio).first
        if let audio, let format = try? await audio.load(.formatDescriptions).first {
            switch CMFormatDescriptionGetMediaSubType(format) {
            case kAudioFormatMPEG4AAC: passthrough = format; codecs = "mp4a.40.2"
            case kAudioFormatMPEG4AAC_HE: passthrough = format; codecs = "mp4a.40.5"
            case kAudioFormatAC3: passthrough = format; codecs = "ac-3"
            case kAudioFormatEnhancedAC3: passthrough = format; codecs = "ec-3"
            default: codecs = "mp4a.40.2"     // made into AAC
            }
        }
        return LiveSource(url: url, duration: duration, naturalWidth: Int(size.width), naturalHeight: Int(size.height),
                          transform: transform, frameRate: fps > 0 ? Double(fps) : 30, audioPassthrough: passthrough,
                          hasAudio: audio != nil, audioCodecs: codecs,
                          pixelAspect: formats.first.flatMap { CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as! CFDictionary? })
    }

    /// An MKV the MKV reader can convert (VP9 picture, AAC sound or none) — nil for any other mix, which plays as before.
    static func loadMKV(_ url: URL) -> LiveSource? {
        guard let mkv = try? MKVDemuxer(url), (try? mkv.readHeader()) != nil, MKVRemux.canConvert(url),
              let video = mkv.tracks.values.first(where: { $0.type == 1 }), video.width > 0, video.height > 0,
              let duration = mkv.duration, duration.isFinite, duration > 0 else { return nil }
        var fps = video.defaultDuration.map { 1e9 / Double($0) } ?? 30
        if !(1...120).contains(fps) { fps = 30 }
        var passthrough: CMFormatDescription?
        var codecs: String?
        if let audio = mkv.tracks.values.first(where: { $0.type == 2 }), let asc = audio.codecPrivate, let first = asc.first {
            passthrough = try? MKVRemux.aacFormat(asc: asc, sampleRate: audio.sampleRate, channels: audio.channels)
            codecs = (first >> 3) == 5 ? "mp4a.40.5" : "mp4a.40.2"     // AudioSpecificConfig's object type: 5 = HE-AAC
        }
        var source = LiveSource(url: url, duration: duration, naturalWidth: video.width, naturalHeight: video.height,
                                transform: .identity, frameRate: fps, audioPassthrough: passthrough,
                                hasAudio: passthrough != nil, audioCodecs: passthrough != nil ? codecs : nil, pixelAspect: nil)
        source.isMKV = true
        return source
    }
}

// MARK: - Where a run's frames come from

/// A run's picture and sound, from Apple's reader or from the MKV reader. Pictures come decoded; sound comes as samples.
nonisolated protocol LiveInput: AnyObject {
    var hasAudio: Bool { get }
    /// The next decoded picture — (image, time, duration) — or nil at the end.
    func nextVideo() throws -> (CVImageBuffer, CMTime, CMTime)?
    /// The next sound sample, or nil at the end.
    func nextAudio() throws -> CMSampleBuffer?
    /// Throws if reading stopped on a fault rather than at the end of the file.
    func checkEnded() throws
    func close()
}

/// Apple's reader — what every run used before MKV (unchanged behavior).
nonisolated final class AVLiveInput: LiveInput {
    private let reader: AVAssetReader
    private let videoOut: AVAssetReaderTrackOutput
    private let audioOut: AVAssetReaderTrackOutput?
    var hasAudio: Bool { audioOut != nil }

    init(source: LiveSource, from t0: CMTime) throws {
        let asset = AVURLAsset(url: source.url)
        let found = Gate<(AVAssetTrack?, AVAssetTrack?)>()
        Task.detached { [asset] in
            let video = try? await asset.loadTracks(withMediaType: .video).first
            let audio = try? await asset.loadTracks(withMediaType: .audio).first
            found.open((video, audio))
        }
        let (videoTrack, audioTrack) = found.wait()
        guard let videoTrack else { throw LiveRun.Stop.because("The file has no picture Apple's frameworks can read.") }

        reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: t0, end: .positiveInfinity)
        // REM  BT.709 asked for by name — an HDR file comes out in ordinary color instead of washed out.
        videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        if let audioTrack {
            let settings: [String: Any]? = source.audioPassthrough != nil ? nil
                : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2]
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            audioOut = out
        } else {
            audioOut = nil
        }
        guard reader.startReading() else { throw LiveRun.Stop.because(reader.error?.localizedDescription ?? "The file could not be read.") }
    }

    func nextVideo() throws -> (CVImageBuffer, CMTime, CMTime)? {
        while let frame = videoOut.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(frame) else { continue }
            return (image, CMSampleBufferGetPresentationTimeStamp(frame), CMSampleBufferGetDuration(frame))
        }
        return nil
    }

    func nextAudio() throws -> CMSampleBuffer? { audioOut?.copyNextSampleBuffer() }

    func checkEnded() throws {
        if reader.status == .failed { throw LiveRun.Stop.because(reader.error?.localizedDescription ?? "The file stopped reading.") }
    }

    func close() { reader.cancelReading() }
}

/// The MKV reader (MKVRemux.swift) — VP9 decoded by Apple's own VP9 decoder, AAC handed on as it is.
// REM  STARTING MID-FILE: the reader jumps to the cluster the file's Cues name at or before the piece's start, then keeps the
// REM  compressed frames from the last keyframe before the start and decodes only those — so a jump to minute 90 of a
// REM  10-hour screensaver reads ahead without decoding it all. Pictures before the start are dropped by the run, as with
// REM  Apple's reader.
nonisolated final class MKVLiveInput: LiveInput, @unchecked Sendable {
    private let mkv: MKVDemuxer
    private let videoTrack: UInt64
    private let audioTrack: UInt64?
    private let width: Int, height: Int
    private let frameDuration: CMTime
    private let audioFormat: CMFormatDescription?
    private let audioSampleRate: Double
    private let startNs: Int64
    private var decoder: VTDecompressionSession?
    private var videoFormat: CMVideoFormatDescription?
    private var packets: [(data: Data, ns: Int64, key: Bool)] = []
    /// Compressed frames since the last keyframe, held until the start is reached.
    private var lead: [(data: Data, ns: Int64, key: Bool)] = []
    private var reachedStart = false
    private var sounds: [CMSampleBuffer] = []
    private var ended = false
    private let lock = NSLock()
    private var decoded: [(CVImageBuffer, CMTime)] = []
    private var decodeFault: OSStatus?
    var hasAudio: Bool { audioFormat != nil }

    init(source: LiveSource, from t0: CMTime) throws {
        mkv = try MKVDemuxer(source.url)
        try mkv.readHeader()
        guard let video = mkv.tracks.values.first(where: { $0.type == 1 }), video.codec == "V_VP9" else {
            throw LiveRun.Stop.because("The MKV holds no VP9 picture the MKV reader converts.")
        }
        videoTrack = video.number
        width = video.width
        height = video.height
        frameDuration = video.defaultDuration.map { CMTime(value: Int64($0), timescale: 1_000_000_000) } ?? .invalid
        let audio = mkv.tracks.values.first { $0.type == 2 }
        audioFormat = source.audioPassthrough
        audioTrack = audioFormat != nil ? audio?.number : nil
        audioSampleRate = audio?.sampleRate ?? 48_000
        startNs = Int64((max(0, t0.seconds) * 1e9).rounded())
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        mkv.seek(toNs: startNs, track: videoTrack)
    }

    /// Reads one frame from the file and files it as picture or sound. False at the end.
    private func readOne() throws -> Bool {
        guard !ended else { return false }
        guard let (track, ns, key, data) = try mkv.nextFrame() else { ended = true; return false }
        if track == videoTrack {
            packets.append((data, ns, key))
        } else if let audioTrack, track == audioTrack, let audioFormat {
            let duration = CMTime(value: 1024, timescale: CMTimeScale(audioSampleRate))
            let pts = CMTime(value: ns, timescale: 1_000_000_000)
            if (pts + duration).seconds * 1e9 < Double(startNs) { return true }     // sound from before the start
            if let sample = MKVRemux.sampleBuffer(data, format: audioFormat, pts: pts, duration: duration) { sounds.append(sample) }
        }
        return true
    }

    private func decode(_ packet: (data: Data, ns: Int64, key: Bool)) throws {
        if decoder == nil {
            guard packet.key else { return }                                   // a picture can only start at a keyframe
            let format = try MKVRemux.vp9Format(width: width, height: height, firstFrame: packet.data)
            let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                      imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &session)
            guard status == noErr, let session else { throw LiveRun.Stop.because("Apple's VP9 decoder would not start (\(status)).") }
            decoder = session
            videoFormat = format
        }
        let pts = CMTime(value: packet.ns, timescale: 1_000_000_000)
        guard let decoder, let videoFormat,
              let sample = MKVRemux.sampleBuffer(packet.data, format: videoFormat, pts: pts, duration: frameDuration) else { return }
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, time, _ in
            guard let self else { return }
            self.lock.withLock {
                if status != noErr, status != kVTVideoDecoderBadDataErr { self.decodeFault = status }
                if status == noErr, let image, time.isValid { self.decoded.append((image, time)) }
            }
        }
        if status != noErr, status != kVTVideoDecoderBadDataErr { throw LiveRun.Stop.because("Apple's VP9 decoder stopped (\(status)).") }
    }

    /// Turns the next compressed picture into a decoded one — holding the lead-in until the start is reached.
    private func step() throws -> Bool {
        while packets.isEmpty { if try !readOne() { return false } }
        let packet = packets.removeFirst()
        if !reachedStart {
            if packet.ns < startNs {
                if packet.key { lead = [packet] } else if !lead.isEmpty { lead.append(packet) }
                return true
            }
            reachedStart = true
            if !packet.key { for held in lead { try decode(held) } }
            lead = []
        }
        try decode(packet)
        return true
    }

    func nextVideo() throws -> (CVImageBuffer, CMTime, CMTime)? {
        while true {
            if let fault = lock.withLock({ decodeFault }) { throw LiveRun.Stop.because("Apple's VP9 decoder stopped (\(fault)).") }
            if let (image, time) = lock.withLock({ decoded.isEmpty ? nil : decoded.removeFirst() }) { return (image, time, frameDuration) }
            if try !step() {
                if let decoder { VTDecompressionSessionWaitForAsynchronousFrames(decoder) }
                return lock.withLock { decoded.isEmpty ? nil : decoded.removeFirst() }.map { ($0.0, $0.1, frameDuration) }
            }
        }
    }

    /// Sound is read ahead of the picture only as far as needed — the pictures it passes stay compressed until asked for.
    func nextAudio() throws -> CMSampleBuffer? {
        guard audioFormat != nil else { return nil }
        while sounds.isEmpty { if try !readOne() { return nil } }
        return sounds.removeFirst()
    }

    func checkEnded() throws {
        if let fault = lock.withLock({ decodeFault }) { throw LiveRun.Stop.because("Apple's VP9 decoder stopped (\(fault)).") }
    }

    func close() {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
    }
}

/// One conversion: one file, one size, from one piece onward.
nonisolated final class LiveRun: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    let source: LiveSource
    let tier: LiveTier
    /// The first piece this run makes.
    let start: Int

    private let lock = NSLock()
    private var pieces: [Int: Data] = [:]
    private var initPiece: Data?
    private var nextPiece: Int
    private var wanted: Int
    private var lastAsked = Date()
    private var cancelled = false
    private var done = false
    private var problem: String?

    init(source: LiveSource, tier: LiveTier, start: Int) {
        self.source = source
        self.tier = tier
        self.start = start
        nextPiece = start
        wanted = start
    }

    // MARK: Asking

    func begin() {
        let thread = Thread { [self] in work() }
        thread.name = "Mediaworks live conversion"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func cancel() { lock.withLock { cancelled = true } }

    /// The opening piece every player reads first (the H.264 and sound settings).
    func opening() -> Data? { lock.withLock { initPiece } }

    /// Piece `index` if made — and the player is now at least that far along.
    func piece(_ index: Int) -> Data? {
        lock.withLock {
            lastAsked = Date()
            wanted = max(wanted, index)
            // Pieces well behind the player are let go.
            for old in pieces.keys where old < index - 2 { pieces[old] = nil }
            return pieces[index]
        }
    }

    /// Whether waiting would bring `index` — false when it is behind this run, too far ahead, or the run has ended.
    func willMake(_ index: Int) -> Bool {
        lock.withLock { !cancelled && problem == nil && !done && index >= nextPiece && index <= nextPiece + 2 }
            || has(index)
    }

    func has(_ index: Int) -> Bool { lock.withLock { pieces[index] != nil } }
    var idleSeconds: Double { lock.withLock { Date().timeIntervalSince(lastAsked) } }
    var failure: String? { lock.withLock { problem } }
    var ended: Bool { lock.withLock { cancelled || done || problem != nil } }

    // MARK: The writer's pieces

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        lock.withLock {
            if segmentType == .initialization { initPiece = segmentData }
            else { pieces[nextPiece] = segmentData; nextPiece += 1 }
        }
    }

    // MARK: The work

    enum Stop: Error { case because(String) }

    private func work() {
        do { try convert() } catch Stop.because(let why) { lock.withLock { problem = why } } catch { lock.withLock { problem = error.localizedDescription } }
        lock.withLock { done = true }
    }

    private var shouldStop: Bool { lock.withLock { cancelled } }

    /// Holds the run while it is 3 pieces ahead of the player; ends it after a minute with no request.
    private func pace() {
        while true {
            let (ahead, idle, stop) = lock.withLock { (nextPiece > wanted + 3, Date().timeIntervalSince(lastAsked), cancelled) }
            if stop { return }
            if idle > 60 { cancel(); return }
            if !ahead { return }
            usleep(50_000)
        }
    }

    private func convert() throws {
        let t0 = CMTime(seconds: Double(start) * LiveSource.pieceSeconds, preferredTimescale: 90_000)
        // REM  E-013 MKV LIVE (his 11-16): an MKV's frames come from the MKV reader; everything else from Apple's reader,
        // REM  exactly as before. From here on the run is the same for both.
        let reading: LiveInput = source.isMKV ? try MKVLiveInput(source: source, from: t0) : try AVLiveInput(source: source, from: t0)
        defer { reading.close() }

        // The Mac's hardware encoder, at this run's size.
        let (width, height) = source.size(tier)
        var made: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let encoder = made else { throw Stop.because("The Mac's video encoder would not start (\(status)).") }
        defer { VTCompressionSessionInvalidate(encoder) }
        let fast = source.frameRate > 31 ? 1.5 : 1.0
        let average = Int(Double(tier.bitrate) * fast)
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(encoder, key: key, value: value) }
        set(kVTCompressionPropertyKey_ProfileLevel, tier.level)
        set(kVTCompressionPropertyKey_AverageBitRate, average as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [average * 3 / 16, 1] as CFArray)   // peak 1.5 × average, per second
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, LiveSource.pieceSeconds as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, source.frameRate as CFNumber)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        // REM  ANAMORPHIC — his ask 11-14 ("can it do 16:9 no letterbox"): the picture keeps its own shape, never padded
        // REM  with bars; a file stored squeezed keeps its stretch marker so the TV widens it back.
        if let aspect = source.pixelAspect { set(kVTCompressionPropertyKey_PixelAspectRatio, aspect) }
        VTCompressionSessionPrepareToEncodeFrames(encoder)

        // REM  WE CUT THE PIECES, NOT THE WRITER. Apple's writer will not pass picture and sound through together when it
        // REM  times the pieces itself (error -11875, seen 11-14). With the interval left open it takes both, and we call
        // REM  flushSegment() just before each forced keyframe — so every piece starts on the 6-second mark's frame.
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = .indefinite
        writer.initialSegmentStartTime = t0
        writer.delegate = self

        var videoIn: AVAssetWriterInput?
        var audioIn: AVAssetWriterInput?
        let encoded = EncodedFrames()
        var boundary = t0
        /// The keyframes forced at a 6-second mark, oldest first — each one opens a new piece.
        var cuts: [CMTime] = []
        var heldAudio: CMSampleBuffer?
        var audioFinished = !reading.hasAudio

        func waitFor(_ input: AVAssetWriterInput) {
            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 2000, !shouldStop { usleep(1000); waited += 1 }
        }

        /// The writer starts once the first frame is made — its format is what the passthrough input is told.
        func openWriter(_ first: CMSampleBuffer) throws {
            guard let format = CMSampleBufferGetFormatDescription(first) else { throw Stop.because("The encoder made a frame with no format.") }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            input.transform = source.transform
            writer.add(input)
            videoIn = input
            if reading.hasAudio {
                let audio = source.audioPassthrough != nil
                    ? AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: source.audioPassthrough)
                    : AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                                              AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])
                audio.expectsMediaDataInRealTime = true
                writer.add(audio)
                audioIn = audio
            }
            guard writer.startWriting() else { throw Stop.because(writer.error?.localizedDescription ?? "The piece maker would not start.") }
            writer.startSession(atSourceTime: t0)
        }

        /// Sound that starts before `limit` — never past the next piece's first frame, so each piece holds its own sound.
        func sendAudio(before limit: CMTime) throws {
            guard !audioFinished else { return }
            while !shouldStop {
                guard let sample = try heldAudio ?? reading.nextAudio() else {
                    audioFinished = true
                    return
                }
                heldAudio = nil
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if time >= limit { heldAudio = sample; return }
                let end = time + CMSampleBufferGetDuration(sample)
                if end.isValid, end <= t0 { continue }      // sound from before this run's first piece
                guard let audioIn else { heldAudio = sample; return }
                waitFor(audioIn)
                guard audioIn.append(sample) else { throw Stop.because(writer.error?.localizedDescription ?? "Sound was refused.") }
            }
        }

        func sendEncoded() throws {
            for sample in encoded.take() {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                if videoIn == nil {
                    try openWriter(sample)
                    if cuts.first == time { cuts.removeFirst() }
                } else if cuts.first == time {
                    cuts.removeFirst()
                    try sendAudio(before: time)
                    writer.flushSegment()
                }
                guard let videoIn else { return }
                waitFor(videoIn)
                guard videoIn.append(sample) else { throw Stop.because(writer.error?.localizedDescription ?? "A frame was refused.") }
            }
        }

        let half = CMTime(value: 1, timescale: 2)
        while !shouldStop {
            pace()
            if shouldStop { break }
            guard let (image, time, frameDuration) = try reading.nextVideo() else { break }
            if time < t0 { continue }      // the decoder's lead-in before this run's first piece
            // REM  A KEYFRAME AT EVERY 6-SECOND MARK — the first frame at or past it. A run started later at that piece
            // REM  begins on the same frame, so its pieces line up with this run's.
            var properties: CFDictionary?
            if time >= boundary {
                properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
                cuts.append(time)
                while boundary <= time { boundary = boundary + CMTime(seconds: LiveSource.pieceSeconds, preferredTimescale: 90_000) }
            }
            let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: time,
                                                         duration: frameDuration, frameProperties: properties,
                                                         infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample else { return }
                encoded.add(sample)
            }
            guard result == noErr else { throw Stop.because("The Mac's video encoder stopped (\(result)).") }
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: time)
            try sendEncoded()
            try sendAudio(before: min(time + half, boundary))
        }
        if shouldStop { writer.cancelWriting(); return }
        try reading.checkEnded()
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        try sendEncoded()
        try sendAudio(before: .positiveInfinity)
        guard videoIn != nil else { throw Stop.because("No frames came out of the file past \(Int(t0.seconds)) s.") }
        videoIn?.markAsFinished()
        audioIn?.markAsFinished()
        let finished = Gate<Void>()
        writer.finishWriting { finished.open(()) }
        finished.wait()
        if writer.status == .failed { throw Stop.because(writer.error?.localizedDescription ?? "The last piece could not be made.") }
    }
}

/// Frames the encoder hands back, collected under a lock (its callback may come on its own thread).
nonisolated final class EncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CMSampleBuffer] = []
    func add(_ frame: CMSampleBuffer) { lock.withLock { frames.append(frame) } }
    func take() -> [CMSampleBuffer] { lock.withLock { let all = frames; frames = []; return all } }
}

/// A one-time hand-off from async code to this run's own thread.
nonisolated final class Gate<Value>: @unchecked Sendable {
    private let signal = DispatchSemaphore(value: 0)
    private var value: Value?
    func open(_ value: Value) { self.value = value; signal.signal() }
    func wait() -> Value { signal.wait(); return value! }
}
#endif
