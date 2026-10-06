//
//  DuplicateDetector.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation
import Photos

/// Finds exact copies: files whose every byte is the same.
///
/// Three stages, each one only paying for what survived the last:
///
/// 1. Bucket the index on facts already in memory (dimensions, duration,
///    measured size). Free, and it rules out almost everything.
/// 2. Videos only: hash the first `AppConfig.duplicatePrefixBytes` of each
///    survivor, so a large file that differs early is never read in full.
/// 3. Hash the whole file. Photos come straight here, one read each, since
///    for them the cost is the number of requests rather than the bytes.
///
/// Stage 3 is still real disk work, gigabytes on a library full of copies.
/// Two things keep it bearable: reads run a few at a time, and every digest is
/// kept in `HashCache`, so a file is only ever read in full once until it
/// changes. The first scan pays; later scans mostly don't.
///
/// Visually identical files with different bytes are not this detector's job.
/// `VisualCopyDetector` finds those and reports them into the same category.
///
/// `nonisolated` so the bucketing and the hashing stay off the main actor
/// instead of inheriting the project-wide default.
nonisolated struct DuplicateDetector: GroupingDetector {

    let category: CategoryID
    let kind: MediaKind

    /// Byte-identical copies are the strongest claim available, so these
    /// members are taken off the table before anything else runs.
    let claimsAssets = true

    func makeStream(context: GroupingContext) -> AsyncStream<GroupingEvent> {
        let kind = self.kind
        let index = context.index

        return AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let started = Date()
                let label = kind == .video ? "videos" : "photos"

                let buckets = Self.candidateBuckets(from: index, kind: kind)
                let candidates = buckets.flatMap { $0 }

                continuation.yield(.started(candidates: candidates.count))

                guard !candidates.isEmpty else {
                    continuation.yield(.finished([]))
                    continuation.finish()
                    return
                }

                let assets = Self.fetchAssets(ids: candidates.map(\.id))
                let concurrency = kind == .video
                    ? AppConfig.videoHashConcurrency
                    : AppConfig.photoHashConcurrency

                let prefixVariant = "prefix\(AppConfig.duplicatePrefixBytes)"
                var digests: [String: String] = [:]
                var summary = ""

                if kind == .video {
                    // Videos: prefix screen first. A video is large, so ruling
                    // out a non-match after half a megabyte saves real reading.
                    let prefix = await Self.hashAll(
                        candidates,
                        assets: assets,
                        concurrency: concurrency,
                        maxBytes: AppConfig.duplicatePrefixBytes,
                        variant: prefixVariant
                    ) { done in
                        continuation.yield(.progress(processed: done, total: candidates.count))
                    }

                    if Task.isCancelled {
                        HashCache.shared.save()
                        continuation.finish()
                        return
                    }

                    let survivors = Self.prefixMatches(buckets: buckets, prints: prefix.prints)
                    let needsFullRead = survivors.filter { prefix.prints[$0.id]?.coversWholeFile == false }
                    let grandTotal = candidates.count + needsFullRead.count

                    let full = await Self.hashAll(
                        needsFullRead,
                        assets: assets,
                        concurrency: concurrency,
                        maxBytes: nil,
                        variant: "full"
                    ) { done in
                        continuation.yield(.progress(processed: candidates.count + done, total: grandTotal))
                    }

                    for (id, print) in prefix.prints where print.coversWholeFile {
                        digests[id] = print.digest
                    }
                    for (id, print) in full.prints where print.coversWholeFile {
                        digests[id] = print.digest
                    }

                    let fullBytes = needsFullRead
                        .filter { full.readIDs.contains($0.id) }
                        .compactMap(\.size.bytes)
                        .reduce(0, +)
                    summary = "prefix \(prefix.cacheHits) cached, \(prefix.readIDs.count) read | whole-file \(full.cacheHits) cached, \(full.readIDs.count) read (~\(ByteCountFormatter.string(fromByteCount: fullBytes, countStyle: .file)))"

                } else {
                    // Photos: straight to the whole file, one read each.
                    //
                    // Measured on a 5000-item library: photos were bound by
                    // the number of requests to the Photos service, not by
                    // bytes. 3 GB of video took 5s; 2 GB of photos took 43s,
                    // and running eight reads at once instead of three changed
                    // nothing, so the service is handling them one at a time.
                    // The prefix screen meant every photo over 512 KB was
                    // requested twice. Candidates here already share exact
                    // dimensions and byte size, so the screen almost never
                    // rules anything out for photos; it only added requests.
                    let full = await Self.hashAll(
                        candidates,
                        assets: assets,
                        concurrency: concurrency,
                        maxBytes: nil,
                        variant: "full",
                        alsoAccept: prefixVariant
                    ) { done in
                        continuation.yield(.progress(processed: done, total: candidates.count))
                    }

                    for (id, print) in full.prints where print.coversWholeFile {
                        digests[id] = print.digest
                    }

                    let fullBytes = candidates
                        .filter { full.readIDs.contains($0.id) }
                        .compactMap(\.size.bytes)
                        .reduce(0, +)
                    summary = "whole-file \(full.cacheHits) cached, \(full.readIDs.count) read (~\(ByteCountFormatter.string(fromByteCount: fullBytes, countStyle: .file)))"
                }

                HashCache.shared.save()

                if Task.isCancelled {
                    continuation.finish()
                    return
                }

                let groups = Self.assemble(buckets: buckets, fingerprints: digests)

                // Where the time went, in one line. Two guesses about this
                // were wrong before the numbers came in.
                print(String(
                    format: "[Duplicates %@] %d candidates | %@ | %d sets | %.2fs",
                    label,
                    candidates.count,
                    summary,
                    groups.count,
                    Date().timeIntervalSince(started)
                ))

                continuation.yield(.finished(groups))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Hashing

    private struct HashBatch {
        let prints: [String: Fingerprint]
        let cacheHits: Int
        /// Records that were actually read this time, not served from cache.
        let readIDs: Set<String>
    }

    /// Serves what it can from the on-disk cache, and reads the rest a few
    /// at a time. One read at a time left most of the time spent waiting on
    /// the round trip to the Photos service rather than on the disk itself.
    private static func hashAll(
        _ records: [AssetRecord],
        assets: [String: AssetBox],
        concurrency: Int,
        maxBytes: Int?,
        variant: String,
        alsoAccept fallbackVariant: String? = nil,
        onProgress: @escaping @Sendable (Int) -> Void
    ) async -> HashBatch {

        var prints: [String: Fingerprint] = [:]
        var pending: [AssetRecord] = []
        var cacheHits = 0

        for record in records {
            if let cached = HashCache.shared.fingerprint(for: record, variant: variant) {
                prints[record.id] = cached
                cacheHits += 1
            } else if let fallbackVariant,
                      let cached = HashCache.shared.fingerprint(for: record, variant: fallbackVariant),
                      cached.coversWholeFile {
                // A prefix read that reached the end of the file is a
                // whole-file digest already. Saved by earlier builds for
                // small photos, so they aren't read again after this change.
                prints[record.id] = cached
                cacheHits += 1
            } else {
                pending.append(record)
            }
        }

        var done = cacheHits
        if done > 0 { onProgress(done) }

        let limit = max(1, concurrency)

        let read: [String: Fingerprint] = await withTaskGroup(of: (AssetRecord, Fingerprint?).self) { group in
            var results: [String: Fingerprint] = [:]
            var iterator = pending.makeIterator()

            func launchNext() -> Bool {
                guard let record = iterator.next() else { return false }
                let box = assets[record.id]
                let totalBytes = sizeForHash(record)
                group.addTask {
                    guard let box, !Task.isCancelled else { return (record, nil) }
                    let print = await AssetFingerprint.compute(
                        for: box.asset,
                        totalBytes: totalBytes,
                        maxBytes: maxBytes
                    )
                    return (record, print)
                }
                return true
            }

            var started = 0
            while started < limit, launchNext() { started += 1 }

            while let result = await group.next() {
                let (record, print) = result

                // A whole-file request that came back partial is not a
                // whole-file digest, and must never be cached as one.
                if let print, maxBytes != nil || print.coversWholeFile {
                    results[record.id] = print
                    HashCache.shared.store(print, for: record, variant: variant)
                }

                done += 1
                onProgress(done)

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                _ = launchNext()
            }

            return results
        }

        prints.merge(read) { _, new in new }
        return HashBatch(
            prints: prints,
            cacheHits: cacheHits,
            readIDs: Set(pending.map(\.id))
        )
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
            // Shared-album items live in someone else's library. Synced items
            // stay in: the user should see their copies even though iOS won't
            // let this app remove them, and the set makes that clear.
            guard !record.isFromSharedAlbum else { continue }

            let key = BucketKey(
                width: record.pixelWidth,
                height: record.pixelHeight,
                durationMillis: kind == .video ? Int((record.duration * 1000).rounded()) : 0,
                bytes: sizeForHash(record) ?? -1
            )

            buckets[key, default: []].append(record)
        }

        // A bucket of one cannot contain a duplicate.
        return buckets.values.filter { $0.count >= 2 }
    }

    /// Only a measured size counts. An estimated size is derived from duration
    /// and resolution, both already in the key, so it would add nothing and
    /// lend a match false weight.
    private static func sizeForHash(_ record: AssetRecord) -> Int64? {
        record.size.source == .measured ? record.size.bytes : nil
    }

    // MARK: - Stage 2: who survives the prefix screen

    private static func prefixMatches(
        buckets: [[AssetRecord]],
        prints: [String: Fingerprint]
    ) -> [AssetRecord] {
        var survivors: [AssetRecord] = []
        for bucket in buckets {
            var byPrefix: [String: [AssetRecord]] = [:]
            for record in bucket {
                guard let print = prints[record.id] else { continue }
                byPrefix[print.digest, default: []].append(record)
            }
            for (_, members) in byPrefix where members.count >= 2 {
                survivors.append(contentsOf: members)
            }
        }
        return survivors
    }

    // MARK: - Stage 3: assemble from whole-file digests

    private static func assemble(
        buckets: [[AssetRecord]],
        fingerprints: [String: String]
    ) -> [AssetGroup] {

        var groups: [AssetGroup] = []

        for bucket in buckets {
            var byDigest: [String: [AssetRecord]] = [:]

            for record in bucket {
                // No whole-file digest means the data could not be read in
                // full. Leaving the asset out is the honest move; a deletion
                // we never verified is not one to offer.
                guard let digest = fingerprints[record.id] else { continue }
                byDigest[digest, default: []].append(record)
            }

            for (digest, members) in byDigest where members.count >= 2 {
                let ordered = orderedKeepFirst(members)

                groups.append(
                    AssetGroup(
                        id: digest,
                        members: ordered,
                        reclaimableBytes: GroupMath.reclaimableBytes(keepingFirstOf: ordered),
                        note: "Exact copies",
                        representativeLabel: "Keep",
                        reclassifyAs: nil
                    )
                )
            }
        }

        // Biggest win first.
        return groups.sorted { ($0.reclaimableBytes ?? 0) > ($1.reclaimableBytes ?? 0) }
    }

    /// All copies are identical, so which one stays is about what can be
    /// removed. A copy the app cannot delete is kept first: marking it as an
    /// extra would offer the user something that can't be done, and would hide
    /// a deletable copy behind it. After that, the oldest.
    private static func orderedKeepFirst(_ members: [AssetRecord]) -> [AssetRecord] {
        members.sorted { lhs, rhs in
            if lhs.canDelete != rhs.canDelete { return !lhs.canDelete }
            let left = lhs.creationDate ?? .distantFuture
            let right = rhs.creationDate ?? .distantFuture
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Helpers

    private static func fetchAssets(ids: [String]) -> [String: AssetBox] {
        guard !ids.isEmpty else { return [:] }

        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var map: [String: AssetBox] = [:]
        map.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            map[asset.localIdentifier] = AssetBox(asset: asset)
        }
        return map
    }
}
