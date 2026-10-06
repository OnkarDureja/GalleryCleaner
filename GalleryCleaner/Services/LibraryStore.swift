//
//  LibraryStore.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation
import Observation
import Photos

enum ScanPhase: Equatable {
    case idle
    case scanning
    case finished
    case cancelled
    case blocked
}

enum GroupingPhase: Equatable {
    case idle
    case running(processed: Int, total: Int)
    case done
}

/// One pass of the index and everything derived from it.
///
/// The store keeps two of these: the last completed one, which every screen
/// reads, and the one a scan in flight is filling. A rescan used to wipe the
/// results before rebuilding them, so every card dropped back to "scanning"
/// and stopped responding to taps until the whole library had been read again.
/// Building into a separate value and swapping at the end means the screen
/// keeps working on the old answer until the new one is ready.
private struct IndexSnapshot {
    var records: [AssetRecord] = []

    /// Offsets into `records`, per streaming category. Offsets rather than
    /// copies keep a photo that matches two categories stored once.
    var matches: [CategoryID: [Int]] = [:]

    /// Guards against the same asset entering `records` twice. Seen on real
    /// devices with certain edited screenshots, where PhotoKit's fetch yields
    /// two PHAsset entries sharing a burstIdentifier and near-identical pixels.
    var seenIDs = Set<String>()

    var videoCount = 0
    var estimatedSizeVideoCount = 0
    var unsizedVideoCount = 0

    /// What PhotoKit reported for the fetch, adjusted for our own deletions.
    /// The change check compares against this rather than `records.count`,
    /// because deduping can leave `records` shorter than the fetch, and that
    /// gap would otherwise read as "the library changed" forever.
    var fetchCount = 0

    /// Set when a first scan was stopped before reading everything.
    var isPartial = false

    mutating func ingest(_ batch: [AssetRecord]) {
        let deduped = batch.filter { seenIDs.insert($0.id).inserted }
        let base = records.count
        records.append(contentsOf: deduped)
        for (offset, record) in deduped.enumerated() {
            tally(record, at: base + offset)
        }
    }

    /// Returns how many records were actually removed.
    ///
    /// `matches` stores offsets, so removing anything invalidates every index
    /// after it. Rebuilding is O(n) over about a megabyte with no PhotoKit
    /// calls, which is cheaper than patching offsets correctly.
    @discardableResult
    mutating func remove(_ ids: Set<String>) -> Int {
        let before = records.count
        records.removeAll { ids.contains($0.id) }
        let removed = before - records.count
        guard removed > 0 else { return 0 }

        for id in ids { seenIDs.remove(id) }
        fetchCount = max(fetchCount - removed, 0)

        matches.removeAll(keepingCapacity: true)
        videoCount = 0
        estimatedSizeVideoCount = 0
        unsizedVideoCount = 0
        for (offset, record) in records.enumerated() {
            tally(record, at: offset)
        }
        return removed
    }

    private mutating func tally(_ record: AssetRecord, at offset: Int) {
        if record.kind == .video {
            videoCount += 1
            switch record.size.source {
            case .estimated: estimatedSizeVideoCount += 1
            case .unknown:   unsizedVideoCount += 1
            case .measured:  break
            }
        }

        for rule in DetectionRegistry.filterRules where rule.matches(record) {
            matches[rule.category, default: []].append(offset)
        }
    }
}

@MainActor
@Observable
final class LibraryStore {

    private(set) var permission: PhotoPermissionStatus = .notDetermined
    private(set) var phase: ScanPhase = .idle
    private(set) var progress: IndexProgress = .zero

    /// Measured, not guessed, so a real-device run produces real numbers.
    private(set) var indexDuration: TimeInterval?
    private(set) var groupingDuration: TimeInterval?

    /// Raised when the library's asset count no longer matches the last
    /// completed scan. The app never rescans on its own because of this: one
    /// screenshot is not worth re-reading 5000 items, and the user decides
    /// when it is.
    private(set) var libraryChangedSinceScan = false

    private var indexStartedAt: Date?
    private var groupingStartedAt: Date?

    /// The last completed index. Every screen reads from this.
    private var index: IndexSnapshot?

    /// What the scan in flight is building. Only its partial counts are ever
    /// shown, and only on a first scan when there is nothing older to show.
    private var pending = IndexSnapshot()

    private var groupsByCategory: [CategoryID: [AssetGroup]] = [:]
    private var groupingPhases: [CategoryID: GroupingPhase] = [:]
    private var isGroupingPassActive = false

    /// For each grouping category, how many detectors that feed it have not
    /// finished yet. Zero means the category's answer for this pass is final.
    /// Before this, every grouping card kept its spinner until the very last
    /// detector ended, and on a rescan none of them updated until then either.
    private var unfinishedFeeders: [CategoryID: Int] = [:]

    /// Last time each category's progress reached the UI. Detectors report
    /// per item, thousands of times a second at their fastest, and passing
    /// every one through re-rendered the whole grid, toolbar included, far
    /// more often than the screen can draw. That is what the "glassEffect
    /// tried to update multiple times per frame" console line was about.
    private var lastProgressPublish: [CategoryID: Date] = [:]

    /// Assets deleted while a scan or grouping pass was running. That pass
    /// read the library before the deletion, so its results are filtered
    /// through this before they are published.
    private var removedDuringScan = Set<String>()

    /// A change notification that arrived mid-scan. Checked once the index
    /// finishes, since the scan's own fetch may or may not have included it.
    private var changeArrivedDuringScan = false

    /// Bumped on every scan. Results from a superseded scan are dropped even
    /// if one more event slips through before its task notices cancellation.
    private var scanGeneration = 0

    private var changeCheckTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var groupingTask: Task<Void, Never>?
    private var watcher: PhotoLibraryChangeWatcher?

    // MARK: - Derived

    var progressFraction: Double {
        guard progress.total > 0 else { return 0 }
        return Double(progress.processed) / Double(progress.total)
    }

    var isScanning: Bool { phase == .scanning }

    /// True once any scan has produced results the screens can use.
    var hasResults: Bool { index != nil }

    var scannedAssetCount: Int { index?.records.count ?? 0 }

    /// Whether this card is showing older results while newer ones are being
    /// worked out. The card stays tappable; this only drives its spinner.
    func isRefreshing(_ category: CategoryID) -> Bool {
        switch category.detection {
        case .streaming:
            return phase == .scanning && index != nil
        case .grouping:
            guard groupsByCategory[category] != nil else { return false }
            return phase == .scanning || (unfinishedFeeders[category] ?? 0) > 0
        }
    }

    // MARK: - Permission

    /// Safe to call as often as you like. Runs on first appearance and on
    /// every foreground. Starts the very first scan; after that it only checks
    /// whether the library changed and raises the banner if it did.
    func bootstrap() async {
        refreshPermission()
        guard permission.allowsFetch else { return }
        installWatcherIfNeeded()

        switch phase {
        case .idle, .blocked:
            startScan()
        case .finished, .cancelled:
            await checkForLibraryChanges()
        case .scanning:
            break
        }
    }

    func refreshPermission() {
        permission = PhotoLibraryPermission.current()
        if !permission.allowsFetch, phase != .idle {
            phase = .blocked
        }
    }

    func requestPermission() async {
        permission = await PhotoLibraryPermission.request()
        if permission.allowsFetch {
            startScan()
        } else {
            phase = .blocked
        }
    }

    func openLimitedPicker() {
        PhotoLibraryPermission.presentLimitedPicker()
    }

    func openSettings() {
        PhotoLibraryPermission.openSettings()
    }

    // MARK: - Scan

    func startScan() {
        guard permission.allowsFetch else {
            phase = .blocked
            return
        }

        scanTask?.cancel()
        groupingTask?.cancel()
        isGroupingPassActive = false
        unfinishedFeeders.removeAll()
        groupingPhases.removeAll()

        // Only the in-flight state is reset. `index` and `groupsByCategory`
        // stay exactly as they are, so every card that had results keeps them
        // and stays open for the whole scan.
        pending = IndexSnapshot()
        removedDuringScan.removeAll()
        changeArrivedDuringScan = false
        progress = .zero
        indexStartedAt = nil

        scanGeneration += 1
        let generation = scanGeneration

        phase = .scanning
        installWatcherIfNeeded()

        let indexer = LibraryIndexer()

        // The loop runs on the main actor, but it only receives finished
        // batches. All PhotoKit work happens inside the indexer's detached
        // task, which is nonisolated so it cannot be pulled back onto main.
        scanTask = Task { [weak self] in
            for await event in indexer.makeStream() {
                guard let self, self.scanGeneration == generation else { return }

                switch event {
                case .started(let total):
                    self.indexStartedAt = Date()
                    self.progress = IndexProgress(processed: 0, total: total)
                    self.pending.fetchCount = total
                    self.pending.records.reserveCapacity(total)

                case .batch(let batch, let progress):
                    self.pending.ingest(batch)
                    self.progress = progress

                case .finished(let progress):
                    self.progress = progress
                    self.finishIndex()

                case .cancelled:
                    self.settleAfterStoppedScan()
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        groupingTask?.cancel()
        groupingTask = nil
        isGroupingPassActive = false
        unfinishedFeeders.removeAll()

        if phase == .scanning {
            settleAfterStoppedScan()
        }
    }

    private func finishIndex() {
        var fresh = pending
        pending = IndexSnapshot()

        if !removedDuringScan.isEmpty {
            fresh.remove(removedDuringScan)
        }

        index = fresh
        phase = .finished
        libraryChangedSinceScan = false

        if let started = indexStartedAt {
            let elapsed = Date().timeIntervalSince(started)
            indexDuration = elapsed
            print(String(format: "[Scan] index %d assets in %.2fs (policy: %@)",
                         fresh.records.count, elapsed, String(describing: AppConfig.resourcePolicy)))
        }

        if AppConfig.printLibraryCensus {
            Self.printCensus(fresh)
        }

        startGroupingPass(over: fresh.records)

        if changeArrivedDuringScan {
            changeArrivedDuringScan = false
            Task { await self.checkForLibraryChanges() }
        }
    }

    /// A stopped rescan keeps the previous results, which are complete and
    /// still the best answer available. A stopped first scan has nothing older
    /// to fall back on, so what it managed to read becomes the result, marked
    /// partial.
    private func settleAfterStoppedScan() {
        if index != nil {
            pending = IndexSnapshot()
            phase = .finished
            return
        }

        var partial = pending
        pending = IndexSnapshot()
        partial.isPartial = true
        if !removedDuringScan.isEmpty {
            partial.remove(removedDuringScan)
        }
        index = partial
        phase = .cancelled
    }

    private func installWatcherIfNeeded() {
        guard watcher == nil else { return }
        // `photoLibraryDidChange` arrives on an arbitrary queue, so the weak
        // reference is resolved once here rather than being read again from
        // inside the Task.
        let watcher = PhotoLibraryChangeWatcher { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.libraryMayHaveChanged()
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    // MARK: - Grouping pass

    /// Runs after the index completes, one detector at a time. Sequential on
    /// purpose: both detectors read file data, and running them together would
    /// just contend for the same disk while making progress harder to report.
    ///
    /// On a first scan each category is published the moment its detector
    /// finishes, since there is nothing older to protect. On a rescan the new
    /// groups are held back and published together at the end, so a screen
    /// someone is browsing changes once rather than three times.
    private func startGroupingPass(over snapshot: [AssetRecord]) {
        groupingTask?.cancel()

        let detectors = DetectionRegistry.groupingDetectors
        guard !detectors.isEmpty else { return }

        for detector in detectors {
            groupingPhases[detector.category] = .idle
        }

        groupingStartedAt = Date()
        groupingDuration = nil
        isGroupingPassActive = true
        lastProgressPublish.removeAll()

        unfinishedFeeders.removeAll()
        for detector in detectors {
            for target in detector.reportsInto {
                unfinishedFeeders[target, default: 0] += 1
            }
        }

        let generation = scanGeneration

        groupingTask = Task { [weak self] in
            // Grows as detectors finish. Duplicate Photos claims its members so
            // Similar Photos never re-offers the same asset.
            var claimed: Set<String> = []

            var pendingGroups: [CategoryID: [AssetGroup]] = [:]
            for detector in detectors { pendingGroups[detector.category] = [] }

            // Categories that already showed this pass's result, so a later
            // merge into them is shown straight away too.
            var publishedThisPass: Set<CategoryID> = []

            for detector in detectors {
                let context = GroupingContext(index: snapshot, claimedIDs: claimed)
                let detectorStarted = Date()

                for await event in detector.makeStream(context: context) {
                    guard let self, self.scanGeneration == generation else { return }

                    switch event {
                    case .started(let candidates):
                        self.groupingPhases[detector.category] = .running(processed: 0, total: candidates)

                    case .progress(let processed, let total):
                        self.publishProgress(processed: processed, total: total, for: detector.category)

                    case .finished(let groups):
                        // A detector may hand back groups that belong to
                        // another category, such as Similar Photos finding the
                        // same picture saved twice.
                        var touched: Set<CategoryID> = [detector.category]
                        for group in groups {
                            let target = group.reclassifyAs ?? detector.category
                            pendingGroups[target, default: []].append(group)
                            touched.insert(target)
                        }

                        self.groupingPhases[detector.category] = .done

                        for target in touched
                        where self.groupsByCategory[target] == nil || publishedThisPass.contains(target) {
                            self.publishGroups(pendingGroups[target] ?? [], for: target)
                            publishedThisPass.insert(target)
                        }

                        if detector.claimsAssets {
                            for group in groups {
                                for member in group.members { claimed.insert(member.id) }
                            }
                        }
                    }
                }

                guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }

                print(String(
                    format: "[Grouping] %@ (%@) took %.2fs",
                    String(describing: type(of: detector)),
                    detector.category.rawValue,
                    Date().timeIntervalSince(detectorStarted)
                ))

                // A category whose last feeder just finished has its final
                // answer for this pass. Publish it now rather than at the end,
                // so a rescan updates Duplicate photos without waiting on the
                // video reads.
                for target in detector.reportsInto {
                    let remaining = (self.unfinishedFeeders[target] ?? 1) - 1
                    self.unfinishedFeeders[target] = remaining
                    if remaining == 0 {
                        self.publishGroups(pendingGroups[target] ?? [], for: target)
                        publishedThisPass.insert(target)
                    }
                }
            }

            // A stopped pass must not publish what it had half built.
            guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }

            for (category, list) in pendingGroups {
                self.publishGroups(list, for: category)
            }

            self.isGroupingPassActive = false
            self.unfinishedFeeders.removeAll()
            self.removedDuringScan.removeAll()

            if let started = self.groupingStartedAt {
                let elapsed = Date().timeIntervalSince(started)
                self.groupingDuration = elapsed
                print(String(format: "[Scan] grouping finished in %.2fs", elapsed))
            }
        }
    }

    /// At most a few updates a second per category, plus the final one, so
    /// the count still lands exactly when a stage finishes.
    private func publishProgress(processed: Int, total: Int, for category: CategoryID) {
        let now = Date()
        let isLast = processed >= total
        if !isLast, let last = lastProgressPublish[category], now.timeIntervalSince(last) < 0.25 {
            return
        }
        lastProgressPublish[category] = now
        groupingPhases[category] = .running(processed: processed, total: total)
    }

    private func publishGroups(_ groups: [AssetGroup], for category: CategoryID) {
        let survivors = removedDuringScan.isEmpty
            ? groups
            : Self.pruning(groups, removing: removedDuringScan)
        groupsByCategory[category] = survivors.sorted {
            ($0.reclaimableBytes ?? 0) > ($1.reclaimableBytes ?? 0)
        }
    }

    // MARK: - Category access

    func state(for category: CategoryID) -> CategoryState {
        switch category.detection {
        case .grouping:  return groupingState(for: category)
        case .streaming: return streamingState(for: category)
        }
    }

    func records(for category: CategoryID) -> [AssetRecord] {
        guard let index, let offsets = index.matches[category] else { return [] }
        let records = offsets.map { index.records[$0] }

        // `matches` holds offsets in ingest order, which is library order.
        // Large videos is only useful biggest first, and that sort was lost
        // when matches moved from copies to offsets. Unknown sizes go last.
        guard category == .largeVideos else { return records }
        return records.sorted { ($0.size.bytes ?? -1) > ($1.size.bytes ?? -1) }
    }

    func groups(for category: CategoryID) -> [AssetGroup] {
        groupsByCategory[category] ?? []
    }

    // MARK: - State derivation

    private func streamingState(for category: CategoryID) -> CategoryState {
        if phase == .blocked {
            return .unavailable(reason: "Photo access is off.")
        }

        // Any completed result wins over the scan in flight. This is what
        // keeps a card open and its number steady during a rescan.
        if let index {
            let count = index.matches[category]?.count ?? 0
            let note = index.isPartial
                ? "Scan stopped early, so this is partial."
                : note(for: category, count: count, in: index)
            return .ready(count: count, note: note)
        }

        switch phase {
        case .idle:
            return .idle
        case .scanning:
            return .scanning(partialCount: pending.matches[category]?.count ?? 0, detail: category.blurb)
        case .blocked, .finished, .cancelled:
            // Unreachable: blocked is handled above, and the other two always
            // leave an index behind.
            return .ready(count: 0, note: nil)
        }
    }

    private func groupingState(for category: CategoryID) -> CategoryState {
        guard DetectionRegistry.detector(for: category) != nil else {
            return .unavailable(reason: "Not built yet. The scan already collects what this needs.")
        }

        if phase == .blocked {
            return .unavailable(reason: "Photo access is off.")
        }

        if let groups = groupsByCategory[category] {
            let removable = groups.reduce(0) { $0 + $1.removableCount }
            return .ready(count: removable, note: groupNote(for: category, groups: groups))
        }

        switch phase {
        case .idle:
            return .idle
        case .scanning:
            return .scanning(partialCount: nil, detail: "Waiting for the scan")
        case .cancelled:
            return .unavailable(reason: "Scan stopped before copies could be compared.")
        case .blocked, .finished:
            break
        }

        guard isGroupingPassActive else {
            return .unavailable(reason: "The comparison didn't finish. Tap Rescan to run it again.")
        }

        switch groupingPhases[category] ?? .idle {
        case .idle:
            return .scanning(partialCount: nil, detail: "Queued")
        case .running(let processed, let total):
            let detail = total > 0 ? "Comparing \(processed) of \(total)" : "Looking for candidates"
            return .scanning(partialCount: nil, detail: detail)
        case .done:
            return .scanning(partialCount: nil, detail: "Finishing up")
        }
    }

    /// Everything that could make a count look wrong, said out loud. A bare
    /// zero is indistinguishable from a bug, so every zero carries its reason.
    private func note(for category: CategoryID, count: Int, in index: IndexSnapshot) -> String? {
        var lines: [String] = []
        let scanned = index.records.count

        if permission == .limited {
            lines.append("Limited access: only the \(scanned) item\(scanned == 1 ? "" : "s") you shared were scanned.")
        }

        switch category {
        case .screenshots:
            if count == 0 {
                lines.append("Nothing carries the screenshot flag. Images saved from other apps don't have it, even if they look like screenshots.")
            }

        case .videos:
            if count == 0 {
                lines.append("No videos in what was scanned. Live Photos count as photos, not videos.")
            }

        case .largeVideos:
            if index.videoCount == 0 {
                lines.append("No videos in what was scanned.")
            } else {
                if ResourceMetadataReader.fileSizeKeyIsAvailable == false {
                    lines.append("Exact file sizes aren't readable on this system version, so these are estimates from duration and resolution.")
                } else if index.estimatedSizeVideoCount > 0 {
                    lines.append("\(index.estimatedSizeVideoCount) of \(index.videoCount) videos fell back to an estimated size.")
                }
                if index.unsizedVideoCount > 0 {
                    lines.append("\(index.unsizedVideoCount) video\(index.unsizedVideoCount == 1 ? "" : "s") had no size at all and were skipped.")
                }
                if count == 0 {
                    lines.append("Nothing is over \(Formatters.bytes(AppConfig.largeVideoThresholdBytes)).")
                }
            }

        default:
            break
        }

        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    private func groupNote(for category: CategoryID, groups: [AssetGroup]) -> String? {
        var lines: [String] = []

        if permission == .limited {
            lines.append("Limited access: only shared items were compared.")
        }

        if groups.isEmpty {
            switch category {
            case .duplicatePhotos: lines.append("No photo appears twice.")
            case .duplicateVideos: lines.append("No video appears twice.")
            default:               lines.append("Nothing close enough to group.")
            }
        }

        // The card's number is what can actually be removed. Sets made only
        // of synced or shared items would otherwise inflate the picture of
        // what this app can clean, so they are named separately.
        // Only when nothing at all can go. Otherwise the home card would trade
        // its purpose line for this, and the detail screen already folds the
        // locked sets into their own row.
        let lockedSets = groups.filter { $0.removableCount == 0 }.count
        let removable = groups.reduce(0) { $0 + $1.removableCount }
        if lockedSets > 0 && removable == 0 {
            lines.append("\(lockedSets) set\(lockedSets == 1 ? "" : "s") found, but every extra copy is synced or shared, so none can be cleaned here.")
        }

        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    // MARK: - Diagnostics

    /// What the index actually holds, by type and by source, with one line
    /// per synced video. Exists to settle count questions against the folder
    /// on the Mac: the app keys everything by local identifier and drops
    /// repeats at ingest, so any surplus here is what PhotoKit itself reports.
    private static func printCensus(_ index: IndexSnapshot) {
        var counts: [String: Int] = [:]
        for record in index.records {
            let source = record.isSynced ? "synced" : (record.isFromSharedAlbum ? "shared" : "library")
            counts["\(record.kind.rawValue) / \(source)", default: 0] += 1
        }

        print("[Census] fetch reported \(index.fetchCount), indexed \(index.records.count) after de-dupe")
        for key in counts.keys.sorted() {
            print("[Census] \(key): \(counts[key] ?? 0)")
        }

        let syncedVideos = index.records
            .filter { $0.kind == .video && $0.isSynced }
            .sorted { ($0.originalFilename ?? "") < ($1.originalFilename ?? "") }

        let distinct = Set(syncedVideos.map {
            "\($0.originalFilename ?? "?")|\($0.size.bytes ?? -1)|\(Int($0.duration.rounded()))"
        })
        print("[Census] synced videos: \(syncedVideos.count) items, \(distinct.count) distinct by name + size + duration")

        for record in syncedVideos {
            let created = record.creationDate.map { $0.formatted(date: .numeric, time: .standard) } ?? "no date"
            print("[Census]   \(record.originalFilename ?? "?") | \(Formatters.size(record.size)) | \(Formatters.duration(record.duration)) | \(created) | \(record.id.prefix(8))")
        }
    }

    // MARK: - Reacting to library changes

    /// PhotoKit sends a change notification for almost anything: thumbnail
    /// generation, moment recomputation, iCloud metadata sync. Debounce, then
    /// ask a question that has a real answer.
    private func libraryMayHaveChanged() {
        changeCheckTask?.cancel()
        changeCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.checkForLibraryChanges()
        }
    }

    /// Compares a database count against the last scan and raises the banner
    /// on a difference. Never starts a scan.
    ///
    /// The count runs off the main actor. It builds no asset objects, but on
    /// a 5000-item library it is still a database query, and it fires on every
    /// foreground.
    ///
    /// Known limit: an add and a delete between two checks cancel out, and a
    /// limited-access selection swapped for the same number of items looks
    /// unchanged. Both are caught by the next real change.
    func checkForLibraryChanges() async {
        guard permission.allowsFetch else { return }

        guard phase != .scanning else {
            changeArrivedDuringScan = true
            return
        }

        guard index != nil else { return }

        let current = await Task.detached(priority: .utility) {
            LibraryIndexer.currentAssetCount()
        }.value

        // A scan may have started, or a deletion landed, while counting.
        guard phase != .scanning, let latest = index else { return }

        if current != latest.fetchCount {
            libraryChangedSinceScan = true
        }
    }

    // MARK: - Deletion

    enum DeleteOutcome {
        /// Something was removed. `notice` explains anything in the selection
        /// that was not, so a partial delete is never silent.
        case deleted(count: Int, notice: String?)
        /// Nothing was removed, with the reason.
        case nothingRemoved(String)
        /// The user declined the system sheet. Not an error, nothing to say.
        case cancelled
    }

    /// Deletes what can be deleted, says plainly what could not, and only
    /// folds into the index what is verifiably gone.
    ///
    /// PhotoKit presents its own confirmation sheet; this returns once the
    /// user has answered it.
    func delete(ids: Set<String>) async -> DeleteOutcome {
        guard !ids.isEmpty else {
            return .nothingRemoved("Nothing was selected.")
        }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(ids), options: nil)
        var deletable: [PHAsset] = []
        var found = Set<String>()
        var synced = 0
        var shared = 0
        var otherLocked = 0

        fetched.enumerateObjects { asset, _, _ in
            found.insert(asset.localIdentifier)
            let source = asset.sourceType
            if source.contains(.typeiTunesSynced) {
                synced += 1
            } else if source.contains(.typeCloudShared) {
                shared += 1
            } else if !asset.canPerform(.delete) {
                otherLocked += 1
            } else {
                deletable.append(asset)
            }
        }

        // Removed in Photos since the scan. Nothing to delete, but the index
        // should stop showing them.
        let alreadyGone = ids.subtracting(found)
        if !alreadyGone.isEmpty {
            applyDeletion(of: alreadyGone)
        }

        let lockedNotice = Self.lockedNotice(synced: synced, shared: shared, other: otherLocked)

        guard !deletable.isEmpty else {
            return .nothingRemoved(lockedNotice ?? "These items are no longer in your library.")
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(deletable as NSArray)
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain,
               nsError.code == PHPhotosError.Code.userCancelled.rawValue {
                return .cancelled
            }
            return .nothingRemoved("Photos didn't allow the deletion. \(nsError.localizedDescription)")
        }

        // Trust, then verify. Before this, a deletion PhotoKit accepted but
        // did not carry out still vanished from the app, then quietly came
        // back on the next scan. Only what is really gone leaves the index.
        let requested = Set(deletable.map(\.localIdentifier))
        var stillPresent = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: Array(requested), options: nil)
            .enumerateObjects { asset, _, _ in stillPresent.insert(asset.localIdentifier) }

        let removed = requested.subtracting(stillPresent)
        if !removed.isEmpty {
            applyDeletion(of: removed)
        }

        var notes: [String] = []
        if let lockedNotice { notes.append(lockedNotice) }
        if !stillPresent.isEmpty {
            let n = stillPresent.count
            notes.append("\(n) item\(n == 1 ? " was" : "s were") left in place by Photos without an error, so \(n == 1 ? "it stays" : "they stay") here too.")
        }
        let notice = notes.isEmpty ? nil : notes.joined(separator: " ")

        guard !removed.isEmpty else {
            return .nothingRemoved(notice ?? "Nothing was deleted.")
        }
        return .deleted(count: removed.count, notice: notice)
    }

    /// One sentence per reason, each with what the user can actually do.
    private static func lockedNotice(synced: Int, shared: Int, other: Int) -> String? {
        var lines: [String] = []
        if synced > 0 {
            lines.append("\(synced) item\(synced == 1 ? " was" : "s were") synced from a computer through Finder. iOS doesn't let apps delete synced items; sync again from the computer without \(synced == 1 ? "it" : "them") to remove \(synced == 1 ? "it" : "them").")
        }
        if shared > 0 {
            lines.append("\(shared) item\(shared == 1 ? " is" : "s are") from a shared album and belong\(shared == 1 ? "s" : "") to someone else's library.")
        }
        if other > 0 {
            lines.append("\(other) item\(other == 1 ? "" : "s") can't be deleted by this app.")
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// No suppression window is needed for our own deletions any more: the
    /// change check compares against `fetchCount`, which this lowers by
    /// exactly what was removed, so the counts still agree afterwards.
    private func applyDeletion(of removed: Set<String>) {
        if var current = index {
            current.remove(removed)
            index = current
        }

        for (category, groups) in groupsByCategory {
            groupsByCategory[category] = Self.pruning(groups, removing: removed)
        }

        if phase == .scanning || isGroupingPassActive {
            removedDuringScan.formUnion(removed)
        }
    }

    /// Drops deleted members, then drops any set that no longer has anything
    /// to compare. A one-member "duplicate set" is not a finding.
    private static func pruning(_ groups: [AssetGroup], removing removed: Set<String>) -> [AssetGroup] {
        groups.compactMap { group in
            let survivors = group.members.filter { !removed.contains($0.id) }
            guard survivors.count >= 2 else { return nil }

            return AssetGroup(
                id: group.id,
                members: survivors,
                reclaimableBytes: GroupMath.reclaimableBytes(keepingFirstOf: survivors),
                note: group.note,
                representativeLabel: group.representativeLabel,
                reclassifyAs: group.reclassifyAs
            )
        }
        .sorted { ($0.reclaimableBytes ?? 0) > ($1.reclaimableBytes ?? 0) }
    }
}
