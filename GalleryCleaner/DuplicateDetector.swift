//
//  DuplicateDetector.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation
import Photos

/// Finds byte-level copies of the same file.
///
/// Not visual similarity. A photo re-encoded by a messaging app is a different
/// file and will not appear here; that is Similar Photos' job.
///
/// Two stages. The first buckets the index on facts already in memory and costs
/// nothing. The second fingerprints only the assets that survived bucketing, so
/// a library of 5000 items usually ends up reading a few dozen files.
struct DuplicateDetector: GroupingDetector {

    let category: CategoryID
    let kind: MediaKind

    /// Byte-identical copies are the strongest claim available, so these
    /// members are taken off the table before Similar Photos runs.
    let claimsAssets = true

    func makeStream(context: GroupingContext) -> AsyncStream<GroupingEvent> {
        let kind = self.kind
        let index = context.index

        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {

                let buckets = Self.candidateBuckets(from: index, kind: kind)
                let candidates = buckets.flatMap { $0 }

                continuation.yield(.started(candidates: candidates.count))

                guard !candidates.isEmpty else {
                    continuation.yield(.finished([]))
                    continuation.finish()
                    return
                }

                let assetsByID = Self.fetchAssets(ids: candidates.map(\.id))
                var fingerprints: [String: String] = [:]
                var processed = 0

                for record in candidates {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    if let asset = assetsByID[record.id] {
                        let print = await AssetFingerprint.compute(
                            for: asset,
                            totalBytes: record.size.source == .measured ? record.size.bytes : nil
                        )
                        if let print {
                            fingerprints[record.id] = print
                        }
                    }

                    processed += 1
                    continuation.yield(.progress(processed: processed, total: candidates.count))
                }

                continuation.yield(.finished(Self.assemble(buckets: buckets, fingerprints: fingerprints)))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Stage 1: free bucketing

    private struct BucketKey: Hashable {
        let width: Int
        let height: Int
        let durationMillis: Int
        /// -1 when the real size is unknown.
        let bytes: Int64
    }

    private static func candidateBuckets(from index: [AssetRecord], kind: MediaKind) -> [[AssetRecord]] {
        var buckets: [BucketKey: [AssetRecord]] = [:]

        for record in index where record.kind == kind {
            // Shared-album assets cannot be deleted by this app, so offering
            // them as removable copies would be a dead end.
            guard !record.isFromSharedAlbum else { continue }

            // Only a measured size belongs in the key. An estimated size is
            // derived from duration and resolution, both of which are already
            // here, so it adds nothing and would lend a match false weight.
            let sizeKey: Int64 = (record.size.source == .measured) ? (record.size.bytes ?? -1) : -1

            let key = BucketKey(
                width: record.pixelWidth,
                height: record.pixelHeight,
                durationMillis: kind == .video ? Int((record.duration * 1000).rounded()) : 0,
                bytes: sizeKey
            )

            buckets[key, default: []].append(record)
        }

        // A bucket of one cannot contain a duplicate.
        return buckets.values.filter { $0.count >= 2 }
    }

    // MARK: - Stage 2: confirm

    private static func assemble(
        buckets: [[AssetRecord]],
        fingerprints: [String: String]
    ) -> [AssetGroup] {

        var groups: [AssetGroup] = []

        for bucket in buckets {
            var byFingerprint: [String: [AssetRecord]] = [:]

            for record in bucket {
                // No fingerprint means the data could not be read. Leaving the
                // asset out is the honest move; guessing from metadata alone
                // would be offering the user a deletion we never verified.
                guard let print = fingerprints[record.id] else { continue }
                byFingerprint[print, default: []].append(record)
            }

            for (print, members) in byFingerprint where members.count >= 2 {
                let ordered = members.sorted { lhs, rhs in
                    let left = lhs.creationDate ?? .distantFuture
                    let right = rhs.creationDate ?? .distantFuture
                    if left != right { return left < right }
                    return lhs.id < rhs.id
                }

                groups.append(
                    AssetGroup(
                        id: print,
                        members: ordered,
                        reclaimableBytes: reclaimable(from: ordered),
                        note: nil,
                        representativeLabel: "Keep",
                        reclassifyAs: nil
                    )
                )
            }
        }

        // Biggest win first.
        return groups.sorted { ($0.reclaimableBytes ?? 0) > ($1.reclaimableBytes ?? 0) }
    }

    /// Keeps the first, drops the rest. Nil if any dropped member's size is
    /// unknown, so the figure is never quietly short.
    private static func reclaimable(from ordered: [AssetRecord]) -> Int64? {
        var total: Int64 = 0
        for record in ordered.dropFirst() {
            guard let bytes = record.size.bytes else { return nil }
            total += bytes
        }
        return total
    }

    // MARK: - Helpers

    private static func fetchAssets(ids: [String]) -> [String: PHAsset] {
        guard !ids.isEmpty else { return [:] }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var map: [String: PHAsset] = [:]
        map.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            map[asset.localIdentifier] = asset
        }
        return map
    }
}
