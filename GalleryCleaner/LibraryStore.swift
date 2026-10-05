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

@MainActor
@Observable
final class LibraryStore {

    private(set) var permission: PhotoPermissionStatus = .notDetermined
    private(set) var phase: ScanPhase = .idle
    private(set) var progress: IndexProgress = .zero
    private(set) var libraryChangedSinceScan = false

    /// Measured, not guessed. Twenty assets in a simulator says nothing; these
    /// exist so the one run on a real device produces real numbers.
    private(set) var indexDuration: TimeInterval?
    private(set) var groupingDuration: TimeInterval?

    private var indexStartedAt: Date?
    private var groupingStartedAt: Date?

    /// The complete index. Detail screens and the grouping detectors read from
    /// this. Roughly a megabyte at 5000 assets.
    private(set) var records: [AssetRecord] = []

    /// Indices into `records`, per streaming category. Storing offsets rather
    /// than copies keeps a photo that matches two categories stored once.
    private var matches: [CategoryID: [Int]] = [:]

    private var groupsByCategory: [CategoryID: [AssetGroup]] = [:]
    private var groupingPhases: [CategoryID: GroupingPhase] = [:]

    private var videoCount = 0
    private var estimatedSizeVideoCount = 0
    private var unsizedVideoCount = 0

    /// Guards against the same asset entering `records` twice. Seen on real
    /// devices with certain edited screenshots, where PhotoKit's fetch yields
    /// two PHAsset entries sharing a burstIdentifier and near-identical pixels.
    /// Deduping here, at ingest, means every downstream count and every
    /// detector sees each asset exactly once, rather than patching the same
    /// problem separately in each one.
    private var seenAssetIDs = Set<String>()

    private var scanTask: Task<Void, Never>?
    private var groupingTask: Task<Void, Never>?
    private var watcher: PhotoLibraryChangeWatcher?

    // MARK: - Derived

    var progressFraction: Double {
        guard progress.total > 0 else { return 0 }
        return Double(progress.processed) / Double(progress.total)
    }

    var isScanning: Bool { phase == .scanning }

    var scannedAssetCount: Int { records.count }

    // MARK: - Permission

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
        resetResults()

        phase = .scanning
        libraryChangedSinceScan = false
        installWatcherIfNeeded()

        let indexer = LibraryIndexer()

        // Inherits main-actor isolation from this method, so every mutation
        // below is already on the right actor.
        scanTask = Task { [weak self] in
            for await event in indexer.makeStream() {
                guard let self else { return }
                switch event {
                case .started(let total):
                    self.indexStartedAt = Date()
                    self.progress = IndexProgress(processed: 0, total: total)
                    self.records.reserveCapacity(total)

                case .batch(let batch, let progress):
                    self.ingest(batch)
                    self.progress = progress

                case .finished(let progress):
                    self.progress = progress
                    self.phase = .finished
                    if let started = self.indexStartedAt {
                        let elapsed = Date().timeIntervalSince(started)
                        self.indexDuration = elapsed
                        print(String(format: "[Scan] index %d assets in %.2fs (policy: %@)",
                                     self.records.count, elapsed, String(describing: AppConfig.resourcePolicy)))
                    }
                    self.startGroupingPass()

                case .cancelled:
                    self.phase = .cancelled
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        groupingTask?.cancel()
        groupingTask = nil
        if phase == .scanning { phase = .cancelled }
    }

    private func resetResults() {
        records.removeAll(keepingCapacity: false)
        matches.removeAll(keepingCapacity: true)
        groupsByCategory.removeAll()
        groupingPhases.removeAll()
        progress = .zero
        indexDuration = nil
        groupingDuration = nil
        indexStartedAt = nil
        groupingStartedAt = nil
        videoCount = 0
        estimatedSizeVideoCount = 0
        unsizedVideoCount = 0
        seenAssetIDs.removeAll(keepingCapacity: true)
    }

    private func ingest(_ batch: [AssetRecord]) {
        let deduped = batch.filter { seenAssetIDs.insert($0.id).inserted }

        let base = records.count
        records.append(contentsOf: deduped)

        for (offset, record) in deduped.enumerated() {
            if record.kind == .video {
                videoCount += 1
                switch record.size.source {
                case .estimated: estimatedSizeVideoCount += 1
                case .unknown:   unsizedVideoCount += 1
                case .measured:  break
                }
            }

            for rule in DetectionRegistry.filterRules where rule.matches(record) {
                matches[rule.category, default: []].append(base + offset)
            }
        }
    }

    private func installWatcherIfNeeded() {
        guard watcher == nil else { return }
        // `photoLibraryDidChange` arrives on an arbitrary queue, so the weak
        // reference is resolved once here rather than being read again from
        // inside the Task, which was a read of a captured var from
        // concurrently-executing code.
        let watcher = PhotoLibraryChangeWatcher { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.libraryChangedSinceScan = true
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    // MARK: - Grouping pass

    /// Runs after the index completes, one detector at a time. Sequential on
    /// purpose: both detectors read file data, and running them together would
    /// just contend for the same disk while making progress harder to report.
    private func startGroupingPass() {
        groupingTask?.cancel()

        let snapshot = records
        let detectors = DetectionRegistry.groupingDetectors
        guard !detectors.isEmpty else { return }

        for detector in detectors {
            groupingPhases[detector.category] = .idle
        }

        groupingStartedAt = Date()

        groupingTask = Task { [weak self] in
            // Grows as detectors finish. Duplicate Photos claims its members so
            // Similar Photos never re-offers the same asset, and the two
            // categories never promise the same bytes twice.
            var claimed: Set<String> = []

            for detector in detectors {
                // No unwrap here: the context is built from locals only, and
                // unwrapping in both loops is what broke this the last time.
                let context = GroupingContext(index: snapshot, claimedIDs: claimed)

                for await event in detector.makeStream(context: context) {
                    guard let self else { return }
                    switch event {
                    case .started(let candidates):
                        self.groupingPhases[detector.category] = .running(processed: 0, total: candidates)

                    case .progress(let processed, let total):
                        self.groupingPhases[detector.category] = .running(processed: processed, total: total)

                    case .finished(let groups):
                        // A detector may hand back groups that belong to
                        // another category. Its own results replace whatever
                        // was there; reclassified ones are merged into the
                        // target, which has usually already finished.
                        var routed: [CategoryID: [AssetGroup]] = [detector.category: []]
                        for group in groups {
                            routed[group.reclassifyAs ?? detector.category, default: []].append(group)
                        }

                        for (target, list) in routed {
                            if target == detector.category {
                                self.groupsByCategory[target] = list
                            } else {
                                self.groupsByCategory[target, default: []].append(contentsOf: list)
                            }
                            self.groupsByCategory[target]?.sort {
                                ($0.reclaimableBytes ?? 0) > ($1.reclaimableBytes ?? 0)
                            }
                        }

                        self.groupingPhases[detector.category] = .done

                        if detector.claimsAssets {
                            for group in groups {
                                for member in group.members { claimed.insert(member.id) }
                            }
                        }
                    }
                }
            }

            guard let self, let started = self.groupingStartedAt else { return }
            let elapsed = Date().timeIntervalSince(started)
            self.groupingDuration = elapsed
            print(String(format: "[Scan] grouping finished in %.2fs", elapsed))
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
        guard let indices = matches[category] else { return [] }
        return indices.map { records[$0] }
    }

    func groups(for category: CategoryID) -> [AssetGroup] {
        groupsByCategory[category] ?? []
    }

    // MARK: - State derivation

    private func streamingState(for category: CategoryID) -> CategoryState {
        let count = matches[category]?.count ?? 0

        switch phase {
        case .idle:
            return .idle
        case .blocked:
            return .unavailable(reason: "Photo access is off.")
        case .scanning:
            return .scanning(partialCount: count, detail: "Counting")
        case .cancelled:
            return .ready(count: count, note: "Scan stopped early, so this is partial.")
        case .finished:
            return .ready(count: count, note: note(for: category, count: count))
        }
    }

    private func groupingState(for category: CategoryID) -> CategoryState {
        guard DetectionRegistry.detector(for: category) != nil else {
            return .unavailable(reason: "Not built yet. The scan already collects what this needs.")
        }

        switch phase {
        case .idle:
            return .idle
        case .blocked:
            return .unavailable(reason: "Photo access is off.")
        case .scanning:
            return .scanning(partialCount: nil, detail: "Waiting for the scan")
        case .cancelled:
            return .unavailable(reason: "Scan stopped before copies could be compared.")
        case .finished:
            break
        }

        switch groupingPhases[category] ?? .idle {
        case .idle:
            return .scanning(partialCount: nil, detail: "Queued")

        case .running(let processed, let total):
            let detail = total > 0 ? "Comparing \(processed) of \(total)" : "Looking for candidates"
            return .scanning(partialCount: nil, detail: detail)

        case .done:
            let groups = groupsByCategory[category] ?? []
            let removable = groups.reduce(0) { $0 + $1.removableCount }
            return .ready(count: removable, note: groupNote(for: category, groups: groups))
        }
    }

    // MARK: - Notes

    /// Everything that could make a count look wrong, said out loud. A bare
    /// zero on a device with no debugger attached is indistinguishable from a
    /// bug, so every zero carries its reason.
    private func note(for category: CategoryID, count: Int) -> String? {
        var lines: [String] = []

        if permission == .limited {
            lines.append("Limited access: only the \(records.count) item\(records.count == 1 ? "" : "s") you shared were scanned.")
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
            if videoCount == 0 {
                lines.append("No videos in what was scanned.")
            } else {
                if ResourceMetadataReader.fileSizeKeyIsAvailable == false {
                    lines.append("Exact file sizes aren't readable on this system version, so these are estimates from duration and resolution.")
                } else if estimatedSizeVideoCount > 0 {
                    lines.append("\(estimatedSizeVideoCount) of \(videoCount) videos fell back to an estimated size.")
                }
                if unsizedVideoCount > 0 {
                    lines.append("\(unsizedVideoCount) video\(unsizedVideoCount == 1 ? "" : "s") had no size at all and were skipped.")
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

    /// Nil when there is nothing to explain, so the card falls back to the
    /// category's standing description like every other card does. A results
    /// summary here would make these two cards read differently from the rest
    /// of the grid for no reason; the count is already the headline.
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

        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
