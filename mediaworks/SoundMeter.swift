//
//  SoundMeter.swift
//  mediaworks
//
//  Measures the loudness of the sound the player is actually putting out — and (E-014) keeps the last 2048 samples of
//  each channel for the visualizers, so one tap serves both.
//
// REM  HIS ASK, 2026-11-09 ~17:4x: "yes build the tv status too make it so you can tell if a video is playing and dropped
// REM  sound". The stats panel could only log what the player REPORTS, and his drops log nothing — the picture keeps going,
// REM  the sound is just gone. So this taps the audio itself (MTAudioProcessingTap on the item's audio mix, after effects)
// REM  and keeps the loudest sample since the last look. PlaybackStats reads it once a second: playing + silent for 3 s
// REM  (not in the first or last 3 s of the file) = "No sound coming out" in the Playback Log, and "Sound back" when it
// REM  returns. It never changes the sound — the tap reads the samples and passes them through untouched.
// REM  LIMIT: this is what Mediaworks hands the TV. If the meter shows sound but he hears none, the loss is past the app
// REM  (tvOS, HDMI, the receiver) — and that split is exactly what we're after.
//

// REM  E-014: the Mac too — a song in its Theater feeds the visualizers through the same tap.
import AVFoundation
import MediaToolbox
import os

/// Shared between the audio thread (writes) and the main thread (reads once a second; the visualizers every frame).
final class SoundMeterBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: (peak: Float(0), frames: 0, readable: true))
    func add(peak: Float, frames: Int) { lock.withLock { $0.peak = max($0.peak, peak); $0.frames += frames } }
    func notReadable() { lock.withLock { $0.readable = false } }
    /// The loudest sample and how many frames passed since the last call, then starts over.
    func take() -> (peak: Float, frames: Int, readable: Bool) {
        lock.withLock { s in let out = s; s.peak = 0; s.frames = 0; return out }
    }

    // MARK: E-014 — the last 2048 samples of each channel, for the visualizers

    static let keep = 2048
    private let ringLock = NSLock()
    private var leftRing = [Float](repeating: 0, count: keep)
    private var rightRing = [Float](repeating: 0, count: keep)
    private var write = 0
    private var lastWrite = Date.distantPast
    private(set) var sampleRate: Double = 44_100
    private(set) var channels = 2
    private(set) var interleaved = false
    /// False when the tap's samples aren't 32-bit float — then nothing is kept and the visualizers idle.
    private var usable = true

    func format(sampleRate: Double, channels: Int, interleaved: Bool, usable: Bool) {
        ringLock.withLock {
            self.sampleRate = sampleRate; self.channels = max(1, channels); self.interleaved = interleaved; self.usable = usable
        }
    }

    /// Called on the audio thread with each buffer the tap passes through.
    func keep(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        ringLock.withLock {
            let list = Array(buffers)
            guard usable, frames > 0, let first = list.first?.mData else { return }
            let a = first.assumingMemoryBound(to: Float.self)
            let b: UnsafeMutablePointer<Float>? = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
            let stride = interleaved ? channels : 1
            for i in 0..<frames {
                let l = a[i * stride]
                let r = interleaved ? (channels > 1 ? a[i * stride + 1] : l) : (b?[i] ?? l)
                leftRing[write] = l
                rightRing[write] = r
                write = (write + 1) % Self.keep
            }
            lastWrite = Date()
        }
    }

    /// The last 2048 samples per channel, oldest first, and whether any arrived in the last quarter second.
    func recent() -> (left: [Float], right: [Float], sampleRate: Double, fresh: Bool) {
        ringLock.withLock {
            let left = Array(leftRing[write...] + leftRing[..<write])
            let right = Array(rightRing[write...] + rightRing[..<write])
            return (left, right, sampleRate, Date().timeIntervalSince(lastWrite) < 0.25)
        }
    }
}

private let meterInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let meterFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<SoundMeterBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let meterPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let box = Unmanaged<SoundMeterBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let asbd = format.pointee
    box.format(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame),
               interleaved: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
               usable: asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32)
    if asbd.mFormatID != kAudioFormatLinearPCM || asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0 || asbd.mBitsPerChannel != 32 {
        box.notReadable()
    }
}

private let meterProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, buffers, framesOut, flagsOut in
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
    let box = Unmanaged<SoundMeterBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    var peak: Float = 0
    for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
        guard let data = buffer.mData else { continue }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let samples = data.bindMemory(to: Float.self, capacity: count)
        for i in 0..<count { peak = max(peak, abs(samples[i])) }
    }
    box.add(peak: peak, frames: Int(framesOut.pointee))
    box.keep(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
}

enum SoundMeter {
    /// Puts a meter on the item's first audio track. Returns the box to read, or nil if the tap couldn't be made.
    @MainActor
    static func attach(to item: AVPlayerItem, track: AVAssetTrack) -> SoundMeterBox? {
        let box = SoundMeterBox()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque()),
            init: meterInit, finalize: meterFinalize, prepare: meterPrepare, unprepare: nil, process: meterProcess)
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else {
            Unmanaged.passUnretained(box).release()
            return nil
        }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        item.audioMix = mix
        SongSound.shared.listen(to: box, item: item)   // E-014
        return box
    }

    /// A 0…1 sample peak as decibels (0 dB = full scale).
    static func decibels(_ peak: Float) -> Double { peak > 0 ? 20 * log10(Double(peak)) : -120 }
    /// Below this, nothing anyone could hear is coming out.
    static let silentBelow: Float = 0.001   // −60 dB
}
