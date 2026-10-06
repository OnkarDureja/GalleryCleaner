//
//  VisualCopyDetector.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 06/10/26.
//

import Foundation
import Photos
import Vision
import UIKit

/// Finds the same picture stored as different files, however far apart they
/// were saved: a photo re-saved from WhatsApp, an image downloaded twice on
/// different days, a copy exported at a smaller size.
///
/// These used to fall through the gap. Duplicate photos compares bytes, and a
/// re-encoded file has different bytes. Similar photos only compares shots
/// from the same minute. So a re-save from last week appeared nowhere.
///
/// Results go into Duplicate photos, because to the person using the app that
/// is what they are. Each set says it is a re-save rather than an exact copy.
///
/// The pass has to look at every photo, so it is built in three tiers of
/// cost:
///
/// 1. A tiny upright reduction of every photo, fetched a few at a time from
///    Photos' own thumbnail cache. From it, a 64-bit difference hash and a
///    16x16 grayscale grid. A few milliseconds per photo.
/// 2. Pair candidates by aspect ratio, then by those two signatures. Pure
///    arithmetic in memory, no PhotoKit at all.
/// 3. Confirm only the surviving pairs with a Vision feature print, at a far
///    stricter threshold than Similar photos uses.
///
/// Two deliberate exclusions:
///
/// - Screenshots. Two screenshots of the same app screen days apart reduce to
///   nearly the same thumbnail while differing in exactly the text that
///   matters. Calling those copies is the false positive most likely to cost
///   someone a photo they wanted.
/// - Pairs from the same moment: same size *and* same burst or within the
///   Similar photos time window. Those are different shots of one scene and
///   belong to Similar photos. A scaled copy is never treated that way, even
///   when it carries the original's capture date.
nonisolated struct VisualCopyDetector: GroupingDetector {

    let category = CategoryID.duplicatePhotos

    /// "Same picture" is nearly as strong a claim as "same bytes", so Similar
    /// photos must not offer these again as merely similar.
    let claimsAssets = true

    func makeStream(context: GroupingContext) -> AsyncStream<GroupingEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {

                let candidates = Self.candidates(from: context)
                continuation.yield(.started(candidates: candidates.count))

                guard candidates.count >= 2 else {
                    continuation.yield(.finished([]))
                    continuation.finish()
                    return
                }

                let assets = Self.fetchAssets(ids: candidates.map(\.id))

                // Tier 1.
                let signatures = await Self.signatures(for: candidates, assets: assets) { processed in
                    continuation.yield(.progress(processed: processed, total: candidates.count))
                }

                if Task.isCancelled {
                    continuation.finish()
                    return
                }

                // Tier 2.
                let pairs = Self.candidatePairs(candidates, signatures: signatures)

                var involved: [String] = []
                var seen = Set<String>()
                for pair in pairs {
                    for id in [pair.left.id, pair.right.id] where seen.insert(id).inserted {
                        involved.append(id)
                    }
                }

                // Tier 3.
                let grandTotal = candidates.count + involved.count
                var processed = candidates.count
                var prints: [String: VNFeaturePrintObservation] = [:]

                for id in involved {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    if let box = assets[id], let print = await FeaturePrintMaker.make(for: box.asset) {
                        prints[id] = print
                    }

                    processed += 1
                    continuation.yield(.progress(processed: processed, total: grandTotal))
                }

                let groups = Self.assemble(pairs: pairs, prints: prints)
                print("[VisualCopy] \(candidates.count) photos, \(pairs.count) candidate pairs, \(groups.count) sets")

                continuation.yield(.finished(groups))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Candidates

    private static func candidates(from context: GroupingContext) -> [AssetRecord] {
        var seen = Set<String>()
        return context.index.filter { record in
            record.kind == .photo
            && !record.isScreenshot
            && !record.isFromSharedAlbum
            && record.pixelWidth > 0
            && record.pixelHeight > 0
            && !context.claimedIDs.contains(record.id)
            && seen.insert(record.id).inserted
        }
    }

    // MARK: - Tier 1: signatures

    /// Bounded concurrency: a handful of thumbnail requests in flight, a new
    /// one started as each finishes. Firing all of them at once would flood
    /// Photos; doing them one by one would leave it idle between requests.
    private static func signatures(
        for candidates: [AssetRecord],
        assets: [String: AssetBox],
        onProgress: @escaping @Sendable (Int) -> Void
    ) async -> [String: TinySignature] {

        let limit = max(1, AppConfig.VisualCopy.concurrentRequests)
        let side = AppConfig.VisualCopy.signaturePixels

        // Progress every few items is plenty, and spares the main actor
        // thousands of wake-ups.
        let reportEvery = 25

        return await withTaskGroup(of: (String, TinySignature?).self) { group in
            var results: [String: TinySignature] = [:]
            results.reserveCapacity(candidates.count)

            var iterator = candidates.makeIterator()
            var inFlight = 0
            var processed = 0

            func launchNext() -> Bool {
                guard let record = iterator.next() else { return false }
                let box = assets[record.id]
                group.addTask {
                    guard let box, !Task.isCancelled else { return (record.id, nil) }
                    let image = await FeaturePrintMaker.image(for: box.asset, side: side, fast: true)
                    return (record.id, image.flatMap(TinySignature.make(from:)))
                }
                return true
            }

            while inFlight < limit, launchNext() { inFlight += 1 }

            while let result = await group.next() {
                let (id, signature) = result
                inFlight -= 1
                processed += 1
                if let signature { results[id] = signature }
                if processed % reportEvery == 0 || processed == candidates.count {
                    onProgress(processed)
                }
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if launchNext() { inFlight += 1 }
            }

            return results
        }
    }

    // MARK: - Tier 2: pairing

    struct Pair {
        let left: AssetRecord
        let right: AssetRecord
        let hashDistance: Int
        let tinyDifference: Double
    }

    private static func candidatePairs(
        _ candidates: [AssetRecord],
        signatures: [String: TinySignature]
    ) -> [Pair] {

        struct Entry {
            let record: AssetRecord
            let signature: TinySignature
            let ratio: Double
        }

        // Width over height, not long side over short side: a re-save keeps
        // its orientation, so a landscape and a portrait photo never pair.
        let entries = candidates
            .compactMap { record -> Entry? in
                guard let signature = signatures[record.id] else { return nil }
                return Entry(
                    record: record,
                    signature: signature,
                    ratio: Double(record.pixelWidth) / Double(record.pixelHeight)
                )
            }
            .sorted { $0.ratio < $1.ratio }

        let tolerance = AppConfig.VisualCopy.aspectTolerance
        let maxHash = AppConfig.VisualCopy.maxHashDistance
        let maxTiny = AppConfig.VisualCopy.maxTinyDifference

        var pairs: [Pair] = []

        // Sorted by ratio, so each entry only looks forward while the ratio is
        // still within tolerance. Within that window it is a plain pairwise
        // check, but the check is two integer and byte comparisons, which
        // stays well under a second even for thousands of 4:3 photos.
        for i in entries.indices {
            let a = entries[i]
            var j = i + 1
            while j < entries.count, entries[j].ratio <= a.ratio * (1 + tolerance) {
                let b = entries[j]
                j += 1

                if isSameMoment(a.record, b.record) { continue }

                let hashDistance = a.signature.hashDistance(to: b.signature)
                guard hashDistance <= maxHash else { continue }

                let tiny = a.signature.meanDifference(to: b.signature)
                guard tiny <= maxTiny else { continue }

                pairs.append(Pair(left: a.record, right: b.record, hashDistance: hashDistance, tinyDifference: tiny))
            }
        }

        // Keep the Vision stage bounded. When the cap bites, the closest pairs
        // survive, since those are the ones most likely to be real copies.
        let cap = AppConfig.VisualCopy.maxConfirmations
        let involvedCount = Set(pairs.flatMap { [$0.left.id, $0.right.id] }).count
        if involvedCount > cap {
            pairs.sort {
                if $0.hashDistance != $1.hashDistance { return $0.hashDistance < $1.hashDistance }
                return $0.tinyDifference < $1.tinyDifference
            }
            var kept: [Pair] = []
            var ids = Set<String>()
            for pair in pairs {
                var next = ids
                next.insert(pair.left.id)
                next.insert(pair.right.id)
                if next.count > cap { continue }
                ids = next
                kept.append(pair)
            }
            print("[VisualCopy] confirmation cap hit: \(involvedCount) photos trimmed to \(ids.count)")
            pairs = kept
        }

        return pairs
    }

    /// Two shots of one moment, which Similar photos owns.
    ///
    /// Time alone was the wrong test. A copy made from an original usually
    /// keeps the original's capture date, so an AirDropped photo and its own
    /// smaller re-save looked like two shots taken in the same second and were
    /// skipped here, then never promoted by Similar either. What actually
    /// separates the cases is the pixel grid: shots from one moment come off
    /// the same camera at the same size, a re-save is almost always scaled. So
    /// a pair only counts as one moment when the time matches *and* the
    /// dimensions do. Photos with no date are never the same moment.
    private static func isSameMoment(_ a: AssetRecord, _ b: AssetRecord) -> Bool {
        guard a.pixelWidth == b.pixelWidth, a.pixelHeight == b.pixelHeight else { return false }
        if let burst = a.burstIdentifier, burst == b.burstIdentifier { return true }
        guard let left = a.creationDate, let right = b.creationDate else { return false }
        return abs(left.timeIntervalSince(right)) <= AppConfig.Similarity.timeWindowSeconds
    }

    // MARK: - Tier 3: confirm and assemble

    private static func assemble(
        pairs: [Pair],
        prints: [String: VNFeaturePrintObservation]
    ) -> [AssetGroup] {

        let maxDistance = AppConfig.VisualCopy.maxDistance

        var records: [String: AssetRecord] = [:]
        var order: [String] = []
        for pair in pairs {
            for record in [pair.left, pair.right] where records[record.id] == nil {
                records[record.id] = record
                order.append(record.id)
            }
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })

        var clusters = UnionFind(count: order.count)

        for pair in pairs {
            guard
                let d = distance(prints[pair.left.id], prints[pair.right.id]),
                d <= maxDistance,
                let i = position[pair.left.id],
                let j = position[pair.right.id]
            else { continue }
            clusters.union(i, j)
        }

        var membersByRoot: [Int: [AssetRecord]] = [:]
        for (index, id) in order.enumerated() {
            guard let record = records[id] else { continue }
            membersByRoot[clusters.find(index), default: []].append(record)
        }

        var groups: [AssetGroup] = []

        for (_, cluster) in membersByRoot where cluster.count >= 2 {
            let keep = bestCopy(in: cluster)

            // Chaining guard. Union-find would happily join A to C through B
            // even when A and C are further apart than the threshold allows.
            // For a "same picture" claim every member has to match the copy
            // being kept, directly.
            let others = cluster
                .filter { $0.id != keep.id }
                .filter { member in
                    guard let d = distance(prints[keep.id], prints[member.id]) else { return false }
                    return d <= maxDistance
                }
                .sorted { ($0.creationDate ?? .distantFuture) < ($1.creationDate ?? .distantFuture) }

            guard !others.isEmpty else { continue }

            let ordered = [keep] + others
            groups.append(
                AssetGroup(
                    id: "vc-" + keep.id,
                    members: ordered,
                    reclaimableBytes: GroupMath.reclaimableBytes(keepingFirstOf: ordered),
                    note: "Same picture, saved again",
                    representativeLabel: "Keep",
                    reclassifyAs: nil
                )
            )
        }

        return groups.sorted { ($0.reclaimableBytes ?? 0) > ($1.reclaimableBytes ?? 0) }
    }

    /// Re-saves lose quality, so the copy worth keeping is the one with the
    /// most pixels, then the biggest file. A copy the app can't delete wins a
    /// tie, since keeping it costs nothing. The oldest breaks what is left.
    private static func bestCopy(in cluster: [AssetRecord]) -> AssetRecord {
        cluster.min { lhs, rhs in
            if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount > rhs.pixelCount }
            if lhs.canDelete != rhs.canDelete { return !lhs.canDelete }
            let leftBytes = lhs.size.bytes ?? 0
            let rightBytes = rhs.size.bytes ?? 0
            if leftBytes != rightBytes { return leftBytes > rightBytes }
            let leftDate = lhs.creationDate ?? .distantFuture
            let rightDate = rhs.creationDate ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
            return lhs.id < rhs.id
        } ?? cluster[0]
    }

    private static func distance(
        _ left: VNFeaturePrintObservation?,
        _ right: VNFeaturePrintObservation?
    ) -> Float? {
        guard let left, let right else { return nil }
        var value = Float(0)
        do {
            try left.computeDistance(&value, to: right)
            return value
        } catch {
            return nil
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

/// Carries a `PHAsset` into a child task. PhotoKit model objects are immutable
/// once fetched, so reading one from several threads is safe; the compiler
/// just has no way to know that.
nonisolated final class AssetBox: @unchecked Sendable {
    let asset: PHAsset
    init(asset: PHAsset) { self.asset = asset }
}

// MARK: - Tiny signature

/// A photo reduced to almost nothing: a 64-bit difference hash and a 16x16
/// grayscale grid, both taken from an upright copy so a sideways original and
/// a rotated re-save line up.
///
/// The hash is the coarse filter (structure, robust to recompression). The
/// grid catches what the hash ignores, such as two photos with the same layout
/// but different brightness.
nonisolated struct TinySignature: Sendable {

    let hash: UInt64
    let grid: [UInt8]

    static func make(from image: UIImage) -> TinySignature? {
        guard let upright = uprightImage(image, side: 32) else { return nil }
        guard
            let hashPixels = grayscale(upright, width: 9, height: 8),
            let grid = grayscale(upright, width: 16, height: 16)
        else { return nil }

        // Each bit says whether a pixel is brighter than its right neighbour.
        var hash: UInt64 = 0
        for row in 0 ..< 8 {
            for column in 0 ..< 8 {
                let left = hashPixels[row * 9 + column]
                let right = hashPixels[row * 9 + column + 1]
                hash <<= 1
                if left > right { hash |= 1 }
            }
        }

        return TinySignature(hash: hash, grid: grid)
    }

    func hashDistance(to other: TinySignature) -> Int {
        (hash ^ other.hash).nonzeroBitCount
    }

    /// 0 for identical grids, 1 for black against white.
    func meanDifference(to other: TinySignature) -> Double {
        guard grid.count == other.grid.count, !grid.isEmpty else { return 1 }
        var total = 0
        for index in grid.indices {
            total += abs(Int(grid[index]) - Int(other.grid[index]))
        }
        return Double(total) / Double(grid.count * 255)
    }

    /// Draws through UIKit so the image's orientation flag is applied. Reading
    /// `cgImage` directly would give the raw, possibly sideways, pixels.
    private static func uprightImage(_ image: UIImage, side: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    private static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
