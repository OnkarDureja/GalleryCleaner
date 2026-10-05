//
//  Detectors.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation

// MARK: - Streaming detection

/// A per-asset predicate, evaluated during the index pass.
protocol AssetFilterRule: Sendable {
    var category: CategoryID { get }
    func matches(_ record: AssetRecord) -> Bool
}

struct ScreenshotRule: AssetFilterRule {
    let category = CategoryID.screenshots

    func matches(_ record: AssetRecord) -> Bool {
        record.kind == .photo && record.isScreenshot
    }
}

struct VideoRule: AssetFilterRule {
    let category = CategoryID.videos

    func matches(_ record: AssetRecord) -> Bool {
        record.kind == .video
    }
}

struct LargeVideoRule: AssetFilterRule {
    let category = CategoryID.largeVideos
    let thresholdBytes: Int64

    func matches(_ record: AssetRecord) -> Bool {
        guard record.kind == .video, let bytes = record.size.bytes else { return false }
        return bytes >= thresholdBytes
    }
}

// MARK: - Grouping detection (phase 2)

/// A cluster of assets the user is being offered as interchangeable.
struct AssetGroup: Identifiable, Sendable {
    let id: String
    let representativeID: String
    let memberIDs: [String]
    /// Space freed by keeping the representative and dropping the rest.
    let reclaimableBytes: Int64?
}

/// Produces clusters from the finished index. Needs the whole index up front,
/// and in practice a second pass over thumbnails or bytes, so it cannot run
/// inside `LibraryIndexer`.
protocol GroupingDetector: Sendable {
    var category: CategoryID { get }
    func groups(in index: [AssetRecord]) async throws -> [AssetGroup]
}

// MARK: - Registry

enum DetectionRegistry {

    static let filterRules: [any AssetFilterRule] = [
        ScreenshotRule(),
        VideoRule(),
        LargeVideoRule(thresholdBytes: AppConfig.largeVideoThresholdBytes)
    ]

    /// Empty in phase 1. Duplicate Photos, Similar Photos and Duplicate Videos
    /// report `.unavailable` purely because nothing is registered here. Adding a
    /// detector is the whole integration: the store will pick it up and the
    /// cards will start behaving like the streaming ones.
    static let groupingDetectors: [any GroupingDetector] = []

    static func detector(for category: CategoryID) -> (any GroupingDetector)? {
        groupingDetectors.first { $0.category == category }
    }
}
