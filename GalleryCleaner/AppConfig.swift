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
enum ResourcePolicy {
    case videosOnly
    case all
}

enum AppConfig {

    /// `.all` since Duplicate Photos needs byte sizes for photos too.
    static let resourcePolicy: ResourcePolicy = .all

    /// A video at or above this size lands in Large Videos.
    static let largeVideoThresholdBytes: Int64 = 50_000_000

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

    /// Bytes read per asset when fingerprinting a duplicate candidate.
    ///
    /// Reading whole files would mean gigabytes of disk on a large library, so
    /// the read is capped and cancelled once this much has been hashed. Any
    /// file smaller than this ends up fully hashed anyway.
    static let duplicateFingerprintBytes = 512 * 1024

    /// Every knob for Similar Photos, in one place.
    ///
    /// The threshold is the smallest lever here. Comparisons only ever happen
    /// inside a short time run, so two unrelated photos would have to be taken
    /// within a minute of each other *and* score close before they could be
    /// wrongly grouped. That makes the exact number far less load-bearing than
    /// it looks, which matters when there is no chance to tune it on a device.
    enum Similarity {

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
        /// read off a screen recording without a debugger attached. Turn off
        /// once the threshold is settled.
        static let showMeasuredDistance = true
    }

    /// Shows how long the index and grouping passes took, in the status line.
    static let showScanTimings = true

    /// Prints one line per thumbnail request and per asset-resolve pass.
    /// Turn off once the pipeline is understood.
    static let thumbnailDiagnostics = true
}
