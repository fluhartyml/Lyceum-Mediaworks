//
//  FillVideo.swift
//  mediaworks
//
//  NO BLACK BARS — his words 2026-11-14: "can it do 16:9 no letterbox?" · "most of the videos are letterboxed, probably
//  within 16:9" · "i mean i dont want to see black bars" · and to the plan, "yes build it".
//
// REM  THE PLAN HE SAID YES TO:
// REM   · A wide picture is zoomed until it fills the screen; a little comes off the edges.
// REM   · A picture that zooming would cut too much from (an upright phone video, a square one) is shown whole, with a
// REM     blurred, enlarged copy of itself filling the rest of the screen — no black either way.
// REM   · Apple TV, iPhone and iPad; Settings → Playback → No black bars turns it off.
// REM  BARS INSIDE THE PICTURE count too: many of his videos carry black bars baked into a 16:9 frame (seen 11-14 on the
// REM  mint houz drive: 1920×826 and 1898×800 pictures in 1920×1080 frames). PictureArea finds where the picture really
// REM  is by looking at six frames; the zoom is worked out from that, not from the frame.
// REM  WHERE IT IS MEASURED: the Mac reads its own file (/area on the streaming port) — the same answer for a live
// REM  conversion (E-013) as for the file; a copy on the iPhone is measured on the iPhone.
//

import Foundation
import AVFoundation
import CoreGraphics

/// Where the picture is inside the frame, measured past any black bars baked into the video.
nonisolated enum PictureArea {
    /// The picture's part of the frame, 0–1 from the top left, as the screen shows it (turned when the file says so).
    /// Nil when it can't be told (no picture, too short, every frame dark).
    static func measure(_ url: URL) async -> CGRect? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 1,
              (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        var union: CGRect?
        var frames = 0
        // REM  SIX FRAMES, AND THE LARGEST PICTURE AMONG THEM — a dark scene on its own would look like bars.
        for fraction in [0.1, 0.25, 0.4, 0.55, 0.7, 0.85] {
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            guard let (image, _) = try? await generator.image(at: time), let box = box(image) else { continue }
            frames += 1
            union = union.map { $0.union(box) } ?? box
        }
        guard frames >= 2, var area = union else { return nil }
        // Bars thinner than 2 % are nothing.
        if area.minX < 0.02 { area.size.width += area.minX; area.origin.x = 0 }
        if area.minY < 0.02 { area.size.height += area.minY; area.origin.y = 0 }
        if area.maxX > 0.98 { area.size.width = 1 - area.minX }
        if area.maxY > 0.98 { area.size.height = 1 - area.minY }
        return area
    }

    /// One frame's lit part, or nil for a frame too dark to tell.
    static func box(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 8, height > 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // REM  A ROW OR COLUMN IS PICTURE when more than 3 % of it is brighter than near-black (28 of 255) — bars from an
        // REM  encoder are rarely pure 0, and a lone bright speck in a bar must not count.
        let lit: UInt8 = 28
        var rows = [Int](repeating: 0, count: height), columns = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] > lit { rows[y] += 1; columns[x] += 1 }
        }
        guard let top = rows.firstIndex(where: { $0 > width * 3 / 100 }),
              let bottom = rows.lastIndex(where: { $0 > width * 3 / 100 }),
              let left = columns.firstIndex(where: { $0 > height * 3 / 100 }),
              let right = columns.lastIndex(where: { $0 > height * 3 / 100 }) else { return nil }
        let box = CGRect(x: Double(left) / Double(width), y: Double(top) / Double(height),
                         width: Double(right - left + 1) / Double(width), height: Double(bottom - top + 1) / Double(height))
        return box.width * box.height < 0.15 ? nil : box
    }

    /// "x,y,w,h" — how the Mac answers /area.
    static func text(_ area: CGRect?) -> String {
        guard let area else { return "" }
        return [area.minX, area.minY, area.width, area.height].map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    static func parse(_ text: String) -> CGRect? {
        let n = text.split(separator: ",").compactMap { Double($0) }
        guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }
}

#if os(iOS) || os(tvOS)
import UIKit
import SwiftUI

/// The switch, shared by the iPhone, iPad and Apple TV Settings.
enum NoBlackBars {
    static let key = "noBlackBars"
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

struct NoBlackBarsToggle: View {
    @AppStorage(NoBlackBars.key) private var on = true

    var body: some View {
        Toggle("No black bars", isOn: $on)
        InfoButton("On — a wide video fills the screen; a little comes off its edges. An upright or square video shows whole, with a blurred copy of itself behind it instead of black. Black bars built into a video are found and zoomed past.\n\nOff — every video shows whole, with black bars where its shape differs from the screen.")
    }
}

extension PictureArea {
    @MainActor private static var known: [String: CGRect?] = [:]

    /// The picture's area for what a player is playing: measured here for a file on this device, asked of the Mac for a
    /// stream (/media/ or E-013's /live/). Kept per file for as long as the app runs.
    @MainActor static func of(_ item: AVPlayerItem) async -> CGRect? {
        guard let url = (item.asset as? AVURLAsset)?.url else { return nil }
        let key = url.absoluteString
        if let found = known[key] { return found }
        var area: CGRect?
        if url.isFileURL {
            area = await measure(url)
        } else if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var path: String?
            if parts.path.hasPrefix("/media/") { path = String(parts.path.dropFirst("/media/".count)) }
            if parts.path.hasPrefix("/live/") { path = parts.queryItems?.first { $0.name == "f" }?.value }
            if let path {
                parts.percentEncodedPath = "/area"
                parts.percentEncodedQuery = "f=" + (path.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? path)
                if let ask = parts.url {
                    var request = URLRequest(url: ask)
                    request.timeoutInterval = 20
                    if let (data, response) = try? await URLSession.shared.data(for: request),
                       (response as? HTTPURLResponse)?.statusCode == 200 {
                        area = parse(String(decoding: data, as: UTF8.self))
                    }
                }
            }
        }
        known[key] = area
        return area
    }
}

/// The video, filling the screen with no black bars (or plainly, when the switch is off).
final class FillVideoView: UIView {
    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    private let backdrop = LayerView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    /// Clips the video to its picture, so bars inside the frame never show over the blurred backdrop.
    private let frameClip = UIView()
    private let main = LayerView()
    private var area: CGRect?
    private var size: CGSize = .zero
    private var itemWatch: NSKeyValueObservation?
    private var sizeWatch: NSKeyValueObservation?
    private var settingsWatch: NSObjectProtocol?

    var player: AVPlayer? {
        didSet {
            guard player !== oldValue else { return }
            main.playerLayer.player = player
            backdrop.playerLayer.player = player
            itemWatch = player?.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.itemChanged() } }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
        backdrop.playerLayer.videoGravity = .resizeAspectFill
        main.playerLayer.videoGravity = .resizeAspect
        frameClip.clipsToBounds = true
        addSubview(backdrop)
        addSubview(blur)
        addSubview(frameClip)
        frameClip.addSubview(main)
        settingsWatch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsLayout() }
        }
    }

    required init?(coder: NSCoder) { fatalError("FillVideoView is made in code") }

    deinit { if let settingsWatch { NotificationCenter.default.removeObserver(settingsWatch) } }

    private func itemChanged() {
        let item = player?.currentItem
        area = nil
        size = .zero
        sizeWatch = item?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.player?.currentItem === item else { return }
                    self.size = item.presentationSize
                    self.setNeedsLayout()
                }
            }
        }
        setNeedsLayout()
        guard let item else { return }
        Task { @MainActor [weak self] in
            let found = await PictureArea.of(item)
            guard let self, self.player?.currentItem === item else { return }
            self.area = found
            self.setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        blur.frame = bounds
        let screen = bounds.size
        let picture = area ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let pictureWidth = size.width * picture.width, pictureHeight = size.height * picture.height
        guard NoBlackBars.isOn, pictureWidth > 0, pictureHeight > 0, screen.width > 0, screen.height > 0 else {
            backdrop.isHidden = true
            blur.isHidden = true
            frameClip.frame = bounds
            main.frame = frameClip.bounds
            return
        }
        // REM  ZOOM OR BLUR — filling the screen would cut off (1 − the smaller ratio of the two shapes). Up to 30 %
        // REM  (a 4:3 or a 2.4:1 film on a 16:9 TV, about 25 %) it zooms; past that (upright and square videos, or a wide
        // REM  video on an upright phone) the picture shows whole over its own blurred copy.
        let shapes = (pictureWidth / pictureHeight) / (screen.width / screen.height)
        let zoom = min(shapes, 1 / shapes) >= 0.7
        let scale = zoom ? max(screen.width / pictureWidth, screen.height / pictureHeight)
                         : min(screen.width / pictureWidth, screen.height / pictureHeight)
        let videoFrame = CGRect(x: screen.width / 2 - picture.midX * size.width * scale,
                                y: screen.height / 2 - picture.midY * size.height * scale,
                                width: size.width * scale, height: size.height * scale)
        let shown = CGRect(x: videoFrame.minX + picture.minX * videoFrame.width, y: videoFrame.minY + picture.minY * videoFrame.height,
                           width: picture.width * videoFrame.width, height: picture.height * videoFrame.height).intersection(bounds)
        backdrop.isHidden = zoom
        blur.isHidden = zoom
        frameClip.frame = shown
        main.frame = videoFrame.offsetBy(dx: -shown.minX, dy: -shown.minY)
    }
}
#endif
