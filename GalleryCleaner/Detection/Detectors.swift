//
//  Detectors.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation

// MARK: - Streaming detection

/// A per-asset predicate, evaluated during the index pass.
nonisolated protocol AssetFilterRule: Sendable {
    var category: CategoryID { get }
    func matches(_ record: AssetRecord) -> Bool
}

nonisolated struct ScreenshotRule: AssetFilterRule {
    let category = CategoryID.screenshots

    func matches(_ record: AssetRecord) -> Bool {
        record.kind == .photo && record.isScreenshot
    }
}

nonisolated struct VideoRule: AssetFilterRule {
    let category = CategoryID.videos

    func matches(_ record: AssetRecord) -> Bool {
        record.kind == .video
    }
}

nonisolated struct LargeVideoRule: AssetFilterRule {
    let category = CategoryID.largeVideos
    let thresholdBytes: Int64

    func matches(_ record: AssetRecord) -> Bool {
        // No readable size means no match, never a crash or a guess.
        guard record.kind == .video, let bytes = record.size.bytes else { return false }
        return bytes > thresholdBytes
    }
}

// MARK: - Grouping detection

/// A set of assets offered to the user as interchangeable.
///
/// `members` is ordered with the one to keep first, so the UI never has to
/// re-derive that decision.
nonisolated struct AssetGroup: Identifiable, Sendable {
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

    /// Extras the app can actually remove. Synced and shared copies stay in
    /// the set so the user sees them, but they are never counted as something
    /// the app can clean up.
    var removableCount: Int {
        members.dropFirst().reduce(0) { $1.canDelete ? $0 + 1 : $0 }
    }
}

/// Shared arithmetic for every grouping detector and the store, so "how much
/// would this free" means the same thing everywhere.
nonisolated enum GroupMath {

    /// Bytes freed by keeping the first member and deleting every other one
    /// the app is allowed to delete. Nil if any of those has an unknown size,
    /// so a partial figure is never presented as a complete one.
    static func reclaimableBytes(keepingFirstOf ordered: [AssetRecord]) -> Int64? {
        var total: Int64 = 0
        for record in ordered.dropFirst() where record.canDelete {
            guard let bytes = record.size.bytes else { return nil }
            total += bytes
        }
        return total
    }
}

/// What a detector is given to work with.
///
/// `claimedIDs` holds everything an earlier detector in the same pass already
/// grouped. Similar Photos uses it to stay off assets that Duplicate Photos
/// has taken, so one photo is never counted, and its bytes never promised,
/// in two categories at once.
nonisolated struct GroupingContext: Sendable {
    let index: [AssetRecord]
    let claimedIDs: Set<String>
}

nonisolated enum GroupingEvent: Sendable {
    case started(candidates: Int)
    case progress(processed: Int, total: Int)
    case finished([AssetGroup])
}

/// Produces clusters from the finished index.
///
/// Needs the whole index up front plus a second pass over image or file data,
/// so it cannot run inside `LibraryIndexer`.
///
/// The protocol and every value type above are `nonisolated`: they are built
/// and read on background threads, and the project-wide main-actor default
/// would otherwise claim them for main.
nonisolated protocol GroupingDetector: Sendable {
    var category: CategoryID { get }

    /// Every category this detector can put groups into. Usually just its
    /// own; Similar photos can also hand pixel-identical sets to Duplicate
    /// photos. The store uses this to know when a category has heard from
    /// every detector that feeds it, so it can stop spinning and publish,
    /// instead of waiting for the whole pass.
    var reportsInto: [CategoryID] { get }

    /// Whether later detectors should treat this one's members as taken.
    var claimsAssets: Bool { get }
    func makeStream(context: GroupingContext) -> AsyncStream<GroupingEvent>
}

nonisolated extension GroupingDetector {
    var reportsInto: [CategoryID] { [category] }
}

// MARK: - Registry

enum DetectionRegistry {

    static let filterRules: [any AssetFilterRule] = [
        ScreenshotRule(),
        VideoRule(),
        LargeVideoRule(thresholdBytes: AppConfig.largeVideoThresholdBytes)
    ]

    /// Order matters, and each step claims what it found:
    ///
    /// 1. Exact photo copies, confirmed by hashing whole files.
    /// 2. The same picture stored as different files, from any date. This is
    ///    the WhatsApp re-save or the double download. It reports into
    ///    Duplicate photos too, since to the user it is a copy.
    /// 3. Similar shots from the same moment, on whatever is left.
    /// 4. Exact video copies, last.
    ///
    /// Videos go last on purpose. Their whole-file reads are the slowest work
    /// in the app, they claim nothing the photo steps need, and running them
    /// second used to hold all three photo categories behind them.
    static let groupingDetectors: [any GroupingDetector] = [
        DuplicateDetector(category: .duplicatePhotos, kind: .photo),
        VisualCopyDetector(),
        SimilarPhotoDetector(),
        DuplicateDetector(category: .duplicateVideos, kind: .video)
    ]

    static func detector(for category: CategoryID) -> (any GroupingDetector)? {
        groupingDetectors.first { $0.category == category }
    }
}
