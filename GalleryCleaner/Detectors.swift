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

// MARK: - Grouping detection

/// A set of assets offered to the user as interchangeable.
///
/// `members` is ordered with the one to keep first, so the UI never has to
/// re-derive that decision.
struct AssetGroup: Identifiable, Sendable {
    let id: String
    let members: [AssetRecord]
    /// Bytes freed by keeping the representative and dropping the rest.
    /// Nil when any member's size is unknown, so a partial figure is never
    /// presented as a complete one.
    let reclaimableBytes: Int64?
    /// What the detector wants to say about this specific group, such as how
    /// close the match actually was.
    let note: String?
    /// Badge for the first member. "Keep" is a fair claim for byte-identical
    /// copies and an overclaim for merely similar ones.
    let representativeLabel: String

    /// Set when the detector that found this group believes it belongs to a
    /// different category. Similar Photos uses it for clusters that turn out
    /// to be the same picture stored twice: Duplicate Photos cannot see those
    /// because it compares file bytes, not decoded pixels.
    let reclassifyAs: CategoryID?

    var representative: AssetRecord { members[0] }
    var removableCount: Int { max(members.count - 1, 0) }
}

/// What a detector is given to work with.
///
/// `claimedIDs` holds everything an earlier detector in the same pass already
/// grouped. Similar Photos uses it to stay off assets that Duplicate Photos
/// has taken, so one photo is never counted, and its bytes never promised,
/// in two categories at once.
struct GroupingContext: Sendable {
    let index: [AssetRecord]
    let claimedIDs: Set<String>
}

enum GroupingEvent: Sendable {
    case started(candidates: Int)
    case progress(processed: Int, total: Int)
    case finished([AssetGroup])
}

/// Produces clusters from the finished index.
///
/// Needs the whole index up front plus a second pass over image or file data,
/// so it cannot run inside `LibraryIndexer`.
protocol GroupingDetector: Sendable {
    var category: CategoryID { get }
    /// Whether later detectors should treat this one's members as taken.
    var claimsAssets: Bool { get }
    func makeStream(context: GroupingContext) -> AsyncStream<GroupingEvent>
}

// MARK: - Registry

enum DetectionRegistry {

    static let filterRules: [any AssetFilterRule] = [
        ScreenshotRule(),
        VideoRule(),
        LargeVideoRule(thresholdBytes: AppConfig.largeVideoThresholdBytes)
    ]

    /// Order matters. Duplicates run first and claim their members, so Similar
    /// Photos only ever sees what is left.
    static let groupingDetectors: [any GroupingDetector] = [
        DuplicateDetector(category: .duplicatePhotos, kind: .photo),
        DuplicateDetector(category: .duplicateVideos, kind: .video),
        SimilarPhotoDetector()
    ]

    static func detector(for category: CategoryID) -> (any GroupingDetector)? {
        groupingDetectors.first { $0.category == category }
    }
}
