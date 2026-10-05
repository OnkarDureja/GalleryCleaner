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

    static let resourcePolicy: ResourcePolicy = .videosOnly

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

    /// Prints one line per thumbnail request and per asset-resolve pass.
    /// Turn off once the pipeline is understood.
    static let thumbnailDiagnostics = true
}
