//
//  SimilarPhotoDetector.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//
import Foundation
import Photos
import Vision
import ImageIO
import UIKit

/// Finds near-identical photos: the five shots of the same thing, the one you
/// retook because someone blinked, a lightly edited copy.
///
/// Three ideas, in order of how much work they do:
///
/// 1. Time runs. Photos are only ever compared against others taken within a
///    short window, or in the same burst. This is what makes the pass cheap at
///    5000 assets, and it is also the real defence against false positives:
///    two unrelated photos would have to be taken a minute apart *and* score
///    close before they could be wrongly grouped. Every knob lives in
///    `AppConfig.Similarity`.
///
/// 2. Vision feature prints. A hand-rolled perceptual hash is cheaper but
///    breaks on crops and exposure changes, and its threshold would have to be
///    calibrated against one particular library. Vision's distance behaves the
///    same way everywhere, so a threshold chosen once travels.
///
/// 3. Transitive clustering inside a run. If A matches B and B matches C they
///    end up in one set even when A and C are a little further apart, because
///    that is what a burst looks like to the person who took it.
///
/// `nonisolated`, along with every helper in this file. Under the project's
/// main-actor default, `FeaturePrintMaker.make` was an async main-actor
/// function, so the Vision request in it ran synchronously on main for every
/// candidate. That is the stall during the "Comparing" phase.
nonisolated struct SimilarPhotoDetector: GroupingDetector {

    let category = CategoryID.similarPhotos

    /// Pixel-identical sets found here are moved to Duplicate photos.
    let reportsInto: [CategoryID] = [.similarPhotos, .duplicatePhotos]

    /// Leaves its members available. Nothing runs after this one today, and
    /// "similar" is a weaker claim than "identical".
    let claimsAssets = false

    func makeStream(context: GroupingContext) -> AsyncStream<GroupingEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {

                let runs = Self.timeRuns(from: context)
                let candidates = runs.flatMap { $0 }

                continuation.yield(.started(candidates: candidates.count))

                guard !candidates.isEmpty else {
                    continuation.yield(.finished([]))
                    continuation.finish()
                    return
                }

                let assetsByID = Self.fetchAssets(ids: candidates.map(\.id))
                var prints: [String: VNFeaturePrintObservation] = [:]
                var failures = 0
                var processed = 0

                for record in candidates {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    if let asset = assetsByID[record.id] {
                        if let print = await FeaturePrintMaker.make(for: asset) {
                            prints[record.id] = print
                        } else {
                            failures += 1
                        }
                    } else {
                        failures += 1
                    }

                    processed += 1
                    continuation.yield(.progress(processed: processed, total: candidates.count))
                }

                if failures > 0 {
                    print("[Similar] featureprint failed for \(failures) of \(candidates.count) candidates")
                }

                continuation.yield(.finished(Self.assemble(runs: runs, prints: prints)))
                continuation.finish()
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Stage 1: time runs

    static func timeRuns(from context: GroupingContext) -> [[AssetRecord]] {
        var seenIDs = Set<String>()

        let photos = context.index
            .filter {
                $0.kind == .photo
                // Synced photos stay in, so the user sees their sets even
                // though iOS won't let this app remove those items.
                && !$0.isFromSharedAlbum
                && !context.claimedIDs.contains($0.id)
            }
            // Defends against the same asset entering the pool twice. This has
            // been observed with certain edited screenshots, where PhotoKit
            // reports two PHAsset records sharing a burstIdentifier and near
            // (or fully) identical pixels. Without this, the same photo can be
            // compared against itself and reported as a "similar" match with a
            // distance of 0.00, which looks like a bug rather than a real pair.
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }

        var runs: [[AssetRecord]] = []
        var current: [AssetRecord] = []
        var previous: AssetRecord?

        for photo in photos {
            let continuesRun: Bool = {
                guard let previous, !current.isEmpty else { return false }
                guard current.count < AppConfig.Similarity.maxRunLength else { return false }

                // A burst is one moment by definition, whatever the gaps say.
                if let burst = photo.burstIdentifier, burst == previous.burstIdentifier {
                    return true
                }

                // A photo with no creation date cannot be placed in time, so it
                // starts a fresh run rather than being guessed into one.
                guard let date = photo.creationDate, let previousDate = previous.creationDate else {
                    return false
                }

                return date.timeIntervalSince(previousDate) <= AppConfig.Similarity.timeWindowSeconds
            }()

            if continuesRun {
                current.append(photo)
            } else {
                if current.count >= 2 { runs.append(current) }
                current = [photo]
            }

            previous = photo
        }

        if current.count >= 2 { runs.append(current) }
        return runs
    }

    // MARK: - Stage 2: compare inside each run

    static func assemble(
        runs: [[AssetRecord]],
        prints: [String: VNFeaturePrintObservation]
    ) -> [AssetGroup] {

        var groups: [AssetGroup] = []

        for run in runs {
            let usable = run.filter { prints[$0.id] != nil }
            guard usable.count >= 2 else { continue }

            var clusters = UnionFind(count: usable.count)
            var accepted: [(Int, Int, Float)] = []

            for i in 0 ..< usable.count {
                for j in (i + 1) ..< usable.count {
                    // Belt and suspenders alongside the de-dupe in `timeRuns`:
                    // never let two entries that resolve to the same asset id
                    // get compared. A same-id pair would always score a
                    // meaningless 0.00 and silently pass as "similar".
                    guard usable[i].id != usable[j].id else { continue }

                    guard
                        let left = prints[usable[i].id],
                        let right = prints[usable[j].id]
                    else { continue }

                    var distance = Float(0)
                    do {
                        try left.computeDistance(&distance, to: right)
                    } catch {
                        continue
                    }

                    guard distance <= AppConfig.Similarity.maxDistance else { continue }
                    clusters.union(i, j)
                    accepted.append((i, j, distance))
                }
            }

            var membersByRoot: [Int: [AssetRecord]] = [:]
            for index in 0 ..< usable.count {
                membersByRoot[clusters.find(index), default: []].append(usable[index])
            }

            for (root, members) in membersByRoot where members.count >= 2 {
                let widest = accepted
                    .filter { clusters.find($0.0) == root }
                    .map(\.2)
                    .max()

                let ordered = members.sorted { lhs, rhs in
                    let left = lhs.creationDate ?? .distantFuture
                    let right = rhs.creationDate ?? .distantFuture
                    if left != right { return left < right }
                    return lhs.id < rhs.id
                }

                // A cluster this tight is not a set of similar shots, it is one
                // picture stored more than once. Duplicate Photos misses these
                // because it compares file bytes: a re-encoded or re-saved copy
                // has different bytes and identical pixels.
                //
                // Never for screenshots. Two screenshots of the same screen a
                // few seconds apart score as identical while differing in the
                // one line of text that mattered, which is exactly how two
                // captures of this app's own Similar photos screen ended up
                // labelled as one image saved twice. They stay here, as
                // similar shots, where nothing is presented as a copy.
                let hasScreenshot = members.contains { $0.isScreenshot }
                let isSamePicture = !hasScreenshot
                    && (widest ?? 0) <= AppConfig.Similarity.identicalDistance

                groups.append(
                    AssetGroup(
                        id: (isSamePicture ? "px-" : "sim-") + ordered[0].id,
                        members: ordered,
                        reclaimableBytes: GroupMath.reclaimableBytes(keepingFirstOf: ordered),
                        note: isSamePicture
                            ? "Identical image saved as a different file"
                            : note(widestDistance: widest),
                        // "Keep" is fair once the pictures are the same. For
                        // merely similar shots it is not: the app has no basis
                        // for saying which one is the good one.
                        representativeLabel: isSamePicture ? "Keep" : "First",
                        reclassifyAs: isSamePicture ? .duplicatePhotos : nil
                    )
                )
            }
        }

        return groups.sorted { $0.members.count > $1.members.count }
    }

    private static func note(widestDistance: Float?) -> String? {
        guard AppConfig.Similarity.showMeasuredDistance, let widestDistance else { return nil }
        return String(
            format: "Widest match %.2f of %.2f allowed",
            widestDistance,
            AppConfig.Similarity.maxDistance
        )
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

// MARK: - Clustering

/// Shared with `VisualCopyDetector`.
nonisolated struct UnionFind {
    private var parent: [Int]

    init(count: Int) {
        parent = Array(0 ..< count)
    }

    mutating func find(_ index: Int) -> Int {
        var root = index
        while parent[root] != root { root = parent[root] }
        var walker = index
        while parent[walker] != root {
            let next = parent[walker]
            parent[walker] = root
            walker = next
        }
        return root
    }

    mutating func union(_ left: Int, _ right: Int) {
        let a = find(left)
        let b = find(right)
        guard a != b else { return }
        parent[b] = a
    }
}

// MARK: - Feature prints

/// Shared with `VisualCopyDetector`.
nonisolated enum FeaturePrintMaker {

    static func make(for asset: PHAsset) async -> VNFeaturePrintObservation? {
        guard
            let image = await Self.image(for: asset, side: AppConfig.Similarity.featurePrintPixels, fast: false),
            let cgImage = image.cgImage
        else {
            return nil
        }

        let request = VNGenerateImageFeaturePrintRequest()
        // Same framing for every image, so the distance reflects content
        // rather than how two photos happened to be letterboxed.
        request.imageCropAndScaleOption = .scaleFill

        // The orientation is passed through. Without it Vision reads the raw
        // pixel buffer, and a photo stored sideways with a rotation flag looks
        // nothing like a re-saved copy whose pixels were rotated for real.
        // Within one burst every shot is stored the same way, which is why
        // this never showed up in Similar photos; across re-saves it would.
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(image.imageOrientation),
            options: [:]
        )

        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            print("[Similar] featureprint error \(error.localizedDescription)")
            return nil
        }
    }

    /// `.highQualityFormat` rather than `.fastFormat`, which fails with
    /// PHPhotosErrorDomain 3303 when Photos has no derivative cached. Network
    /// stays off: an asset whose data is not on the device is skipped instead
    /// of downloaded behind the user's back.
    ///
    /// `fast` lets Photos hand back a cached thumbnail at roughly the asked
    /// size instead of resampling to it exactly, which is what makes reducing
    /// a whole library to tiny signatures affordable.
    static func image(for asset: PHAsset, side: CGFloat, fast: Bool) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = fast ? .fast : .exact
        options.isSynchronous = false
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            let guardBox = ResumeOnce()
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: side, height: side),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                guard guardBox.claim() else { return }
                continuation.resume(returning: image)
            }
        }
    }
}

/// Kept `private` to this file. `AssetViewerView` has its own private class of
/// the same name, and making this one internal turned the two into a
/// redeclaration. `FeaturePrintMaker` only uses it inside its own body, so it
/// never needed to be visible outside this file.
nonisolated private final class ResumeOnce: @unchecked Sendable {
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

/// Vision takes ImageIO's orientation type, PhotoKit hands back UIKit's.
nonisolated extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:            self = .up
        case .down:          self = .down
        case .left:          self = .left
        case .right:         self = .right
        case .upMirrored:    self = .upMirrored
        case .downMirrored:  self = .downMirrored
        case .leftMirrored:  self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default:    self = .up
        }
    }
}
