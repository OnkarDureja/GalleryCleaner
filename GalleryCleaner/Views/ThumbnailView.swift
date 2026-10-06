//
//  ThumbnailView.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import SwiftUI
import Photos
import UIKit

// MARK: - Outcome

/// Why a cell does or does not have a picture.
///
/// The first version collapsed every failure into one grey cloud, which made
/// the UI assert "not on device" for causes that had nothing to do with iCloud.
/// PHPhotosErrorDomain 3303, the one actually hit here, is a derivative
/// generation failure.
enum ThumbnailOutcome: Equatable {
    case pending            // no answer yet, or the identifier hasn't resolved
    case loadedPreview      // degraded image delivered, final still coming
    case loaded
    case unresolvedAsset    // the local identifier did not map to a PHAsset
    case needsNetwork       // PhotoKit says the full image is in iCloud
    case cancelled
    case failed(String)
    case emptyResult        // nil image with no reason given

    var isCloudPending: Bool { self == .needsNetwork }

    var isFailure: Bool {
        switch self {
        case .pending, .loaded, .loadedPreview: return false
        default:                                return true
        }
    }

    /// Short corner marker. Nothing longer is readable at this size.
    var marker: String? {
        switch self {
        case .pending, .loaded, .loadedPreview: return nil
        case .needsNetwork:                     return "icloud"
        case .unresolvedAsset:                  return "questionmark"
        case .cancelled:                        return "clock"
        case .failed:                           return "exclamationmark.triangle"
        case .emptyResult:                      return "photo.badge.exclamationmark"
        }
    }
}

struct ThumbnailUpdate: @unchecked Sendable {
    let outcome: ThumbnailOutcome
    let image: UIImage?
}

/// How a cell frames its asset.
///
/// `.square` is right for a dense grid, where aligned rows matter more than
/// seeing the whole frame. `.natural` is right when there are only a few items
/// and each one is being looked at, because cropping a portrait video into a
/// square there just looks like a mistake. The ratio comes from the index, so
/// it is known before any image loads.
enum ThumbnailAspect: Equatable {
    case square
    case natural(CGFloat)   // width / height

    var value: CGFloat {
        switch self {
        case .square:            return 1
        case .natural(let ratio): return ratio > 0 ? ratio : 1
        }
    }
}

// MARK: - Diagnostics

enum ThumbnailDiagnostics {

    static func log(_ message: String) {
        guard AppConfig.thumbnailDiagnostics else { return }
        print("[Thumb] \(message)")
    }

    static func logResolve(category: String, requested: [String], resolved: [String: PHAsset]) {
        guard AppConfig.thumbnailDiagnostics else { return }
        let missing = requested.filter { resolved[$0] == nil }
        print("[Thumb] resolve category=\(category) requested=\(requested.count) returned=\(resolved.count) missing=\(missing.count)")
        for id in missing.prefix(5) {
            print("[Thumb]   missing id=\(id)")
        }
    }

    static func logRequest(asset: PHAsset, target: CGSize, allowNetwork: Bool) {
        guard AppConfig.thumbnailDiagnostics else { return }
        print("[Thumb] req id=\(asset.localIdentifier) type=\(asset.mediaType.rawValue) px=\(asset.pixelWidth)x\(asset.pixelHeight) target=\(Int(target.width))x\(Int(target.height)) net=\(allowNetwork)")
    }

    static func logResult(assetID: String, image: UIImage?, info: [AnyHashable: Any]?) {
        guard AppConfig.thumbnailDiagnostics else { return }

        let error = info?[PHImageErrorKey] as? NSError
        let errorText = error.map { "\($0.domain)#\($0.code)" } ?? "none"
        let size = image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"

        print("[Thumb] res id=\(assetID) image=\(size) degraded=\(InfoFlags.degraded(info) ? 1 : 0) inCloud=\(InfoFlags.inCloud(info) ? 1 : 0) cancelled=\(InfoFlags.cancelled(info) ? 1 : 0) error=\(errorText)")
    }
}

private enum InfoFlags {
    static func bool(_ info: [AnyHashable: Any]?, _ key: String) -> Bool {
        (info?[key] as? NSNumber)?.boolValue ?? false
    }
    static func degraded(_ info: [AnyHashable: Any]?) -> Bool { bool(info, PHImageResultIsDegradedKey) }
    static func inCloud(_ info: [AnyHashable: Any]?) -> Bool { bool(info, PHImageResultIsInCloudKey) }
    static func cancelled(_ info: [AnyHashable: Any]?) -> Bool { bool(info, PHImageCancelledKey) }
}

// MARK: - Loader

final class ThumbnailLoader: @unchecked Sendable {

    static let shared = ThumbnailLoader()

    private let manager = PHCachingImageManager()

    private init() {}

    /// Emits once or twice.
    ///
    /// `.opportunistic` is the important choice. `.fastFormat` only serves a
    /// derivative that Photos has already rendered; when none exists it fails
    /// with PHPhotosErrorDomain 3303 instead of generating one, which is what
    /// turned a perfectly local video into a grey tile. `.opportunistic`
    /// generates it, at the cost of delivering a degraded image first and the
    /// final image second. Both are forwarded so the cell sharpens in place.
    ///
    /// Network stays off by default. On a device with optimised storage this
    /// path still yields the local degraded thumbnail and then reports
    /// `needsNetwork`, so the grid shows blurry previews rather than nothing.
    func load(
        asset: PHAsset,
        targetSize: CGSize,
        allowNetwork: Bool
    ) -> AsyncStream<ThumbnailUpdate> {

        let manager = self.manager
        let assetID = asset.localIdentifier

        return AsyncStream { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isSynchronous = false
            options.isNetworkAccessAllowed = allowNetwork

            ThumbnailDiagnostics.logRequest(asset: asset, target: targetSize, allowNetwork: allowNetwork)

            let requestID = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in

                ThumbnailDiagnostics.logResult(assetID: assetID, image: image, info: info)

                let isDegraded = InfoFlags.degraded(info)
                let outcome: ThumbnailOutcome

                if image != nil {
                    outcome = isDegraded ? .loadedPreview : .loaded
                } else if InfoFlags.cancelled(info) {
                    outcome = .cancelled
                } else if InfoFlags.inCloud(info) {
                    outcome = .needsNetwork
                } else if let error = info?[PHImageErrorKey] as? NSError {
                    outcome = .failed("\(error.domain)#\(error.code)")
                } else {
                    outcome = .emptyResult
                }

                continuation.yield(ThumbnailUpdate(outcome: outcome, image: image))

                // A degraded result is always followed by another callback.
                if !isDegraded {
                    continuation.finish()
                }
            }

            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    manager.cancelImageRequest(requestID)
                }
            }
        }
    }
}

// MARK: - View

struct ThumbnailView: View {

    let record: AssetRecord
    let asset: PHAsset?
    let allowNetwork: Bool
    let aspect: ThumbnailAspect
    let onOutcome: (String, ThumbnailOutcome) -> Void

    @State private var image: UIImage?
    @State private var outcome: ThumbnailOutcome = .pending

    var body: some View {
        // No GeometryReader. It has no intrinsic size, so inside a grid it
        // swallows whatever height is proposed and the cell stops holding its
        // ratio, which is what pushed the caption badge into the middle.
        Color.clear
            .aspectRatio(aspect.value, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    PlaceholderTile(record: record, outcome: outcome)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: aspect == .square ? 6 : 12))
            // States the hit region outright. `clipped` and `clipShape` each
            // affect drawing and interaction in their own way, so without this
            // the tappable area is not guaranteed to match the drawn square.
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if let marker = outcome.marker {
                    Image(systemName: marker)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(image == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                        .padding(4)
                }
            }
            .task(id: taskKey) { await load() }
    }

    /// Re-runs when the asset finally resolves, and when the user asks for
    /// network previews.
    private var taskKey: String {
        "\(asset?.localIdentifier ?? "unresolved")|\(allowNetwork)"
    }

    private func load() async {
        guard let asset else {
            // Not a failure. The parent resolves identifiers in its own task, so
            // on the first frame every cell legitimately has no asset yet.
            outcome = .pending
            return
        }

        image = nil
        outcome = .pending

        let side = AppConfig.thumbnailPixelTarget
        let stream = ThumbnailLoader.shared.load(
            asset: asset,
            targetSize: CGSize(width: side, height: side),
            allowNetwork: allowNetwork
        )

        for await update in stream {
            // Keep any image we were given, even if a later callback reports
            // that the full-size version lives in iCloud.
            if let delivered = update.image {
                image = delivered
            }
            outcome = update.outcome
        }

        onOutcome(record.id, outcome)
    }
}

/// What a cell shows when there is no picture at all.
///
/// Everything here comes from the index, which is already in memory, so the
/// cell still says what it is. That matters on a device with optimised storage,
/// where a whole screen could land in this state.
private struct PlaceholderTile: View {

    let record: AssetRecord
    let outcome: ThumbnailOutcome

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemFill))

            VStack(spacing: 5) {
                Image(systemName: record.kind == .video ? "film" : "photo")
                    .font(.system(size: 19))
                    .foregroundStyle(.secondary)

                Text(Formatters.dimensions(width: record.pixelWidth, height: record.pixelHeight))
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            if outcome == .pending {
                ProgressView().controlSize(.mini)
            }
        }
    }
}
