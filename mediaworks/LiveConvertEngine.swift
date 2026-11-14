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

    var shortSide: Int { min(naturalWidth, naturalHeight) }
    var pieceCount: Int { max(1, Int((duration / Self.pieceSeconds).rounded(.up))) }
    /// Sizes below the file's own — a file at or under 1080p is never converted, so this is empty for it.
    var tiers: [LiveTier] { LiveTier.allCases.filter { $0.rawValue < shortSide } }

    /// The encoded size of a tier, in the file's own orientation, even numbers only.
    func size(_ tier: LiveTier) -> (width: Int, height: Int) {
        let scale = Double(tier.rawValue) / Double(shortSide)
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

    private enum Stop: Error { case because(String) }

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
        let asset = AVURLAsset(url: source.url)
        let found = Gate<(AVAssetTrack?, AVAssetTrack?)>()
        Task.detached { [asset] in
            let video = try? await asset.loadTracks(withMediaType: .video).first
            let audio = try? await asset.loadTracks(withMediaType: .audio).first
            found.open((video, audio))
        }
        let (videoTrack, audioTrack) = found.wait()
        guard let videoTrack else { throw Stop.because("The file has no picture Apple's frameworks can read.") }

        let t0 = CMTime(seconds: Double(start) * LiveSource.pieceSeconds, preferredTimescale: 90_000)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: t0, end: .positiveInfinity)
        // REM  BT.709 asked for by name — an HDR file comes out in ordinary color instead of washed out.
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderTrackOutput?
        if let audioTrack {
            let settings: [String: Any]? = source.audioPassthrough != nil ? nil
                : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2]
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            audioOut = out
        }
        guard reader.startReading() else { throw Stop.because(reader.error?.localizedDescription ?? "The file could not be read.") }
        defer { reader.cancelReading() }

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
        var audioFinished = audioOut == nil

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
            if audioOut != nil {
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
            guard let audioOut, !audioFinished else { return }
            while !shouldStop {
                guard let sample = heldAudio ?? audioOut.copyNextSampleBuffer() else {
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
            guard let frame = videoOut.copyNextSampleBuffer() else { break }
            guard let image = CMSampleBufferGetImageBuffer(frame) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(frame)
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
                                                         duration: CMSampleBufferGetDuration(frame), frameProperties: properties,
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
        if reader.status == .failed { throw Stop.because(reader.error?.localizedDescription ?? "The file stopped reading.") }
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
