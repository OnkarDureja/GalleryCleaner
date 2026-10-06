//
//  AssetViewerView.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import SwiftUI
import Photos
import AVKit
import AVFoundation

/// What the detail screens hand to the viewer.
struct ViewerTarget: Identifiable, Equatable {
    let record: AssetRecord
    var id: String { record.id }

    static func == (lhs: ViewerTarget, rhs: ViewerTarget) -> Bool {
        lhs.record.id == rhs.record.id
    }
}

/// Full-screen photo and video playback.
///
/// Loads at full quality rather than reusing the grid thumbnail, and keeps the
/// same rule as everywhere else in the app: network off by default, with an
/// explicit button when the original turns out to live in iCloud.
struct AssetViewerView: View {

    let record: AssetRecord
    let asset: PHAsset?

    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var status: ViewerStatus = .loading
    @State private var allowNetwork = false

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private var isVideo: Bool { record.kind == .video }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Black as a background rather than a ZStack sibling. As a sibling
            // its `ignoresSafeArea` grew the whole stack to full screen, which
            // dragged the controls up under the status bar with it.
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .top) { topBar }
            .task(id: allowNetwork) { await load() }
            .onDisappear {
                player?.pause()
                // Hand the session back so other audio can resume.
                try? AVAudioSession.sharedInstance()
                    .setActive(false, options: .notifyOthersOnDeactivation)
            }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
            }

            Spacer(minLength: 0)

            // Nothing in the top-right for video. AVKit draws its own volume
            // and routing control there, and two separate sets of chrome in
            // one corner is what made that bar feel crammed.
            if !isVideo {
                Text(caption)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch status {
        case .loading:
            ProgressView().tint(.white)

        case .photo:
            if let image {
                zoomableImage(image)
            }

        case .video:
            if let player {
                VideoPlayer(player: player)
                    .onAppear {
                        activatePlaybackAudio()
                        player.play()
                    }
            }

        case .needsNetwork:
            message(
                symbol: "icloud.and.arrow.down",
                title: "Not on this device",
                detail: "The full version lives in iCloud.",
                actionTitle: "Load over network"
            ) {
                allowNetwork = true
            }

        case .unavailable(let reason):
            message(
                symbol: "exclamationmark.triangle",
                title: "Can't open this one",
                detail: reason,
                actionTitle: nil,
                action: nil
            )
        }
    }

    private func zoomableImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = min(max(committedScale * value.magnification, 1), 6)
                    }
                    .onEnded { _ in
                        committedScale = scale
                        if scale <= 1 { resetPan() }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        // Panning only makes sense once the image is bigger
                        // than the screen; otherwise the drag fights dismissal.
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: committedOffset.width + value.translation.width,
                            height: committedOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in committedOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.22)) {
                    if scale > 1 {
                        scale = 1
                        committedScale = 1
                        resetPan()
                    } else {
                        scale = 2.5
                        committedScale = 2.5
                    }
                }
            }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }

    private func message(
        symbol: String,
        title: String,
        detail: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white.opacity(0.7))

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.2))
                    .foregroundStyle(.white)
                    .padding(.top, 4)
            }
        }
        .padding(32)
    }

    /// Without this the app runs on the default ambient audio category, which
    /// obeys the ringer switch. A video with perfectly good audio then plays
    /// in total silence whenever the phone is on silent, and nothing on screen
    /// explains why.
    private func activatePlaybackAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private var caption: String {
        switch record.kind {
        case .video:
            return Formatters.duration(record.duration) + " · " + Formatters.size(record.size)
        default:
            return Formatters.dimensions(width: record.pixelWidth, height: record.pixelHeight)
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let asset else {
            status = .unavailable("This item is no longer in the photo library.")
            return
        }

        status = .loading

        if record.kind == .video {
            let outcome = await AssetViewerLoader.playerItem(for: asset, allowNetwork: allowNetwork)
            switch outcome {
            case .success(let item):
                player = AVPlayer(playerItem: item)
                status = .video
            case .needsNetwork:
                status = .needsNetwork
            case .failure(let reason):
                status = .unavailable(reason)
            }
        } else {
            let outcome = await AssetViewerLoader.image(for: asset, allowNetwork: allowNetwork)
            switch outcome {
            case .success(let loaded):
                image = loaded
                status = .photo
            case .needsNetwork:
                status = .needsNetwork
            case .failure(let reason):
                status = .unavailable(reason)
            }
        }
    }
}

enum ViewerStatus: Equatable {
    case loading
    case photo
    case video
    case needsNetwork
    case unavailable(String)
}

private enum LoadOutcome<Value> {
    case success(Value)
    case needsNetwork
    case failure(String)
}

private enum AssetViewerLoader {

    /// 2048 points rather than `PHImageManagerMaximumSize`. A 5472 x 3648
    /// original decoded at full size is tens of megabytes of bitmap for no
    /// visible gain on a phone screen, even zoomed in.
    private static let maximumEdge: CGFloat = 2048

    static func image(for asset: PHAsset, allowNetwork: Bool) async -> LoadOutcome<UIImage> {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isSynchronous = false
        options.isNetworkAccessAllowed = allowNetwork

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maximumEdge, height: maximumEdge),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                guard once.claim() else { return }

                if let image {
                    continuation.resume(returning: .success(image))
                    return
                }

                continuation.resume(returning: classify(info))
            }
        }
    }

    static func playerItem(for asset: PHAsset, allowNetwork: Bool) async -> LoadOutcome<AVPlayerItem> {
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = allowNetwork

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            PHImageManager.default().requestPlayerItem(
                forVideo: asset,
                options: options
            ) { item, info in
                guard once.claim() else { return }

                if let item {
                    continuation.resume(returning: .success(item))
                    return
                }

                continuation.resume(returning: classify(info))
            }
        }
    }

    private static func classify<Value>(_ info: [AnyHashable: Any]?) -> LoadOutcome<Value> {
        if (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue == true {
            return .needsNetwork
        }
        if let error = info?[PHImageErrorKey] as? NSError {
            return .failure("\(error.domain) \(error.code)")
        }
        return .failure("The photo library returned nothing for this item.")
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
