//
//  AppConfig.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation
import CoreGraphics

/// Controls which assets get a `PHAssetResource` lookup during the index pass.
///
/// `assetResources(for:)` is one Photos-database call per asset. It never touches
/// file bytes and never triggers an iCloud download, but at 5000 assets the calls
/// add up to seconds. Phase 1 only needs byte sizes for videos, so it asks for
/// videos only. Duplicate Photos detection needs sizes for photos too; when that
/// lands, switch this to `.all` and nothing else about the pass changes.
nonisolated enum ResourcePolicy: Sendable {
    case videosOnly
    case all
}

/// Every value in here is an immutable constant, read by the detectors and
/// the indexer on background tasks. `nonisolated` opts these types out of the
/// project's default MainActor isolation, so those reads are plain loads with
/// no actor hop. Safe because nothing here can change after launch.
nonisolated enum AppConfig {

    /// `.all` since Duplicate Photos needs byte sizes for photos too.
    static let resourcePolicy: ResourcePolicy = .all

    /// A video strictly larger than this lands in Large Videos. Decimal
    /// megabytes, the same units ByteCountFormatter shows, so "100 MB" on
    /// screen and this number agree.
    static let largeVideoThresholdBytes: Int64 = 100_000_000

    /// Assets per batch handed to the UI.
    static let indexBatchSize = 200

    /// Fixed column count for asset grids. Deliberately not `.adaptive`: with a
    /// single item an adaptive grid leaves a lone small square in the corner and
    /// the screen reads as unfinished.
    static let gridColumns = 3

    static let gridSpacing: CGFloat = 3

    /// Pixel edge requested from PhotoKit for a grid thumbnail. Fixed rather
    /// than derived from geometry: a GeometryReader has no intrinsic size, so
    /// using one inside a LazyVGrid breaks the cells' square aspect ratio.
    static let thumbnailPixelTarget: CGFloat = 320

    /// Bytes read per video candidate in the quick screen before a whole-file
    /// hash. Videos only: a video that differs in its first half megabyte is
    /// ruled out without reading the rest. Photos skip the screen, because
    /// for them the second request cost more than the bytes it saved.
    static let duplicatePrefixBytes = 512 * 1024

    /// Duplicate-candidate reads in flight at once, per media type.
    ///
    /// Measured on a 5000-item library: 8 photo reads in flight took 43.0s,
    /// 3 took 43.2s. The Photos service evidently works through them one at a
    /// time, so more parallelism buys nothing and only adds load on assetsd,
    /// which was seen restarting during testing. Kept modest for both.
    static let photoHashConcurrency = 3
    static let videoHashConcurrency = 2

    /// Prints a breakdown of what the index found, by media type and by
    /// source, plus a line per synced video. Off now that the video counts
    /// have been checked; switch on again to re-check against a Mac folder.
    static let printLibraryCensus = false

    /// Knobs for finding the same picture saved as different files, at any
    /// date apart. Separate from `Similarity` on purpose: that one groups
    /// different shots of a moment, this one claims two files are one image,
    /// which is a much stronger statement and needs much stricter numbers.
    nonisolated enum VisualCopy {

        /// Edge of the tiny upright image every photo is reduced to for the
        /// cheap first pass.
        static let signaturePixels: CGFloat = 64

        /// Thumbnail requests in flight at once during that pass.
        static let concurrentRequests = 6

        /// Two images only become candidates when their aspect ratios agree
        /// within this fraction. Re-saves scale an image, they don't crop it.
        static let aspectTolerance = 0.015

        /// Most of 64 bits two difference hashes may disagree on. Recompression
        /// moves a few bits; a different picture moves dozens.
        static let maxHashDistance = 6

        /// Mean per-pixel difference on a 16x16 grayscale reduction, 0 to 1.
        static let maxTinyDifference = 0.05

        /// Vision feature-print distance at or below which two candidates are
        /// confirmed as the same picture. Far tighter than the 0.30 used for
        /// similar shots. A starting value: verify it against a few known
        /// re-saves before trusting it on someone else's library.
        static let maxDistance: Float = 0.08

        /// Upper bound on photos sent to Vision for confirmation, so a library
        /// full of near-blank images cannot turn this into a minutes-long pass.
        /// The closest candidate pairs are kept when the cap bites.
        static let maxConfirmations = 800
    }

    /// Every knob for Similar Photos, in one place.
    ///
    /// The threshold is the smallest lever here. Comparisons only ever happen
    /// inside a short time run, so two unrelated photos would have to be taken
    /// within a minute of each other *and* score close before they could be
    /// wrongly grouped. That makes the exact number far less load-bearing than
    /// it looks, which matters when there is no chance to tune it on a device.
    nonisolated enum Similarity {

        /// Vision feature-print distance at or below which two photos are
        /// called similar. 0 means identical feature prints; unrelated images
        /// score far higher. Set strict on purpose: in a cleaner app a false
        /// positive costs more trust than a miss.
        static let maxDistance: Float = 0.30

        /// At or below this distance the two images are not merely similar,
        /// they are the same picture. Happens when one file was re-encoded or
        /// saved in another format: different bytes, identical pixels. Those
        /// belong under Duplicate photos, so they get moved there.
        static let identicalDistance: Float = 0.01

        /// A run of photos breaks when consecutive shots are further apart
        /// than this. Near-identical shots are almost always seconds apart.
        static let timeWindowSeconds: TimeInterval = 60

        /// Hard cap on a single run, so a continuous hour of shooting cannot
        /// chain into one enormous pairwise comparison. Purely a cost control.
        static let maxRunLength = 24

        /// Pixel edge of the image handed to Vision.
        static let featurePrintPixels: CGFloat = 448

        /// Prints the measured distance on each group, so the numbers can be
        /// read off a screen recording without a debugger attached.
        ///
        /// Off now that the threshold is settled: it is an internal number and
        /// it means nothing to someone using the app. Kept as a switch rather
        /// than deleted, since re-tuning needs it again.
        static let showMeasuredDistance = false
    }

    /// Shows how long the index and grouping passes took, in the status line.
    static let showScanTimings = false

    /// Prints one line per thumbnail request and per asset-resolve pass.
    /// Turn off once the pipeline is understood.
    static let thumbnailDiagnostics = false
}
