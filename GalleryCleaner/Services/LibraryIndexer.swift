//
//  LibraryIndexer.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation
import Photos

nonisolated struct IndexProgress: Sendable, Equatable {
    let processed: Int
    let total: Int

    static let zero = IndexProgress(processed: 0, total: 0)
}

nonisolated enum IndexEvent: Sendable {
    case started(total: Int)
    case batch([AssetRecord], IndexProgress)
    case finished(IndexProgress)
    case cancelled
}

/// Walks the photo library once and emits records in batches.
///
/// Three things keep this usable at 5000 assets:
///
/// 1. `PHFetchResult` is lazy. We never materialise it into an array of
///    PhotoKit objects; we pull one asset at a time and drop it immediately.
/// 2. Each chunk runs inside an `autoreleasepool`, so the PhotoKit objects and
///    their autoreleased innards are freed every 200 assets instead of piling
///    up until the pass ends.
/// 3. Work happens on a detached utility task and reaches the UI as batches, so
///    the main actor only wakes up about 25 times for a 5000-asset library.
///
/// Marked `nonisolated` because the project defaults every type to the main
/// actor. Without it, anything this type calls with `await` can quietly hop
/// back onto main, which is exactly how a "background" scan ends up blocking
/// taps. Nothing in here touches UI state, so main-actor isolation was never
/// correct for it.
nonisolated struct LibraryIndexer: Sendable {

    /// One definition of "the assets this app cares about", used by both the
    /// index pass and the cheap count check that decides whether anything
    /// actually changed.
    static func makeFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()

        // Without this a fetch returns the user library only. Anything synced
        // from a computer through Finder is `typeiTunesSynced` and is silently
        // absent, which is why a library showing 1200 items in Photos indexed
        // as 112 here.
        //
        // Shared-album assets stay out: they live in someone else's library,
        // take no space on this device, and cannot be deleted, so counting
        // them as clutter would be wrong.
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]

        options.includeHiddenAssets = false
        // Only burst representatives, matching what Photos shows the user.
        // Similar-photo detection will probably want `true` here, since bursts
        // are the richest source of near-identical shots.
        options.includeAllBurstAssets = false
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false)
        ]
        return options
    }

    /// A database count, no asset objects built. Cheap enough to run on every
    /// library change notification.
    static func currentAssetCount() -> Int {
        PHAsset.fetchAssets(with: makeFetchOptions()).count
    }

    func makeStream(
        policy: ResourcePolicy = AppConfig.resourcePolicy,
        batchSize: Int = AppConfig.indexBatchSize
    ) -> AsyncStream<IndexEvent> {

        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {

                let result = PHAsset.fetchAssets(with: Self.makeFetchOptions())
                let total = result.count

                continuation.yield(.started(total: total))

                guard total > 0 else {
                    continuation.yield(.finished(.zero))
                    continuation.finish()
                    return
                }

                var buffer: [AssetRecord] = []
                buffer.reserveCapacity(batchSize)

                var cursor = 0
                while cursor < total {
                    if Task.isCancelled {
                        continuation.yield(.cancelled)
                        continuation.finish()
                        return
                    }

                    let upperBound = min(cursor + batchSize, total)

                    autoreleasepool {
                        for index in cursor..<upperBound {
                            let asset = result.object(at: index)
                            buffer.append(makeRecord(from: asset, policy: policy))
                        }
                    }

                    let progress = IndexProgress(processed: upperBound, total: total)
                    continuation.yield(.batch(buffer, progress))

                    buffer.removeAll(keepingCapacity: true)
                    cursor = upperBound

                    // Gives the main actor room to draw the updated counts.
                    await Task.yield()
                }

                continuation.yield(.finished(IndexProgress(processed: total, total: total)))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Record building

    private func makeRecord(from asset: PHAsset, policy: ResourcePolicy) -> AssetRecord {
        let kind = MediaKind(asset.mediaType)

        let wantsResources: Bool
        switch policy {
        case .all:        wantsResources = true
        case .videosOnly: wantsResources = (kind == .video)
        }

        var summary = ResourceSummary.empty
        if wantsResources {
            summary = ResourceMetadataReader.summary(for: asset)
        }

        var size = summary.size

        // Last resort for videos so Large Videos is never blank just because
        // the undocumented size key went away.
        if kind == .video, !size.isKnown {
            size = SizeEstimator.videoBytes(
                duration: asset.duration,
                width: asset.pixelWidth,
                height: asset.pixelHeight
            )
        }

        let sourceType = asset.sourceType
        let isSynced = sourceType.contains(.typeiTunesSynced)
        let isShared = sourceType.contains(.typeCloudShared)

        return AssetRecord(
            id: asset.localIdentifier,
            kind: kind,
            mediaSubtypeRawValue: asset.mediaSubtypes.rawValue,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: asset.duration,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            burstIdentifier: asset.burstIdentifier,
            isFromSharedAlbum: isShared,
            isSynced: isSynced,
            // `canPerform(.delete)` alone said yes for Finder-synced items, and
            // the deletion then went nowhere. The source type is the real answer.
            canDelete: !isSynced && !isShared && asset.canPerform(.delete),
            originalFilename: summary.originalFilename,
            size: size
        )
    }
}
