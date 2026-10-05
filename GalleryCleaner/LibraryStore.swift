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

@MainActor
@Observable
final class LibraryStore {

    private(set) var permission: PhotoPermissionStatus = .notDetermined
    private(set) var phase: ScanPhase = .idle
    private(set) var progress: IndexProgress = .zero
    private(set) var libraryChangedSinceScan = false

    /// The complete index. Detail screens and, later, grouping detectors read
    /// from this. Roughly a megabyte at 5000 assets.
    private(set) var records: [AssetRecord] = []

    /// Indices into `records`, per category. Storing offsets rather than copies
    /// keeps a photo that is both a screenshot and a duplicate from being stored
    /// twice.
    private var matches: [CategoryID: [Int]] = [:]

    private var videoCount = 0
    private var estimatedSizeVideoCount = 0
    private var unsizedVideoCount = 0

    private var scanTask: Task<Void, Never>?
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
                    self.progress = IndexProgress(processed: 0, total: total)
                    self.records.reserveCapacity(total)

                case .batch(let batch, let progress):
                    self.ingest(batch)
                    self.progress = progress

                case .finished(let progress):
                    self.progress = progress
                    self.phase = .finished

                case .cancelled:
                    self.phase = .cancelled
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if phase == .scanning { phase = .cancelled }
    }

    private func resetResults() {
        records.removeAll(keepingCapacity: false)
        matches.removeAll(keepingCapacity: true)
        progress = .zero
        videoCount = 0
        estimatedSizeVideoCount = 0
        unsizedVideoCount = 0
    }

    private func ingest(_ batch: [AssetRecord]) {
        let base = records.count
        records.append(contentsOf: batch)

        for (offset, record) in batch.enumerated() {
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
        let watcher = PhotoLibraryChangeWatcher { [weak self] in
            Task { @MainActor in
                self?.libraryChangedSinceScan = true
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    // MARK: - Category access

    func state(for category: CategoryID) -> CategoryState {
        switch category.detection {
        case .grouping:
            guard DetectionRegistry.detector(for: category) != nil else {
                return .unavailable(
                    reason: "Not built yet. The scan already collects what this needs."
                )
            }
            // Reached once a detector is registered; wire its progress here.
            return .idle

        case .streaming:
            let count = matches[category]?.count ?? 0

            switch phase {
            case .idle:
                return .idle
            case .blocked:
                return .unavailable(reason: "Photo access is off.")
            case .scanning:
                return .scanning(partialCount: count)
            case .cancelled:
                return .ready(count: count, note: "Scan stopped early, so this is partial.")
            case .finished:
                return .ready(count: count, note: note(for: category, count: count))
            }
        }
    }

    func records(for category: CategoryID) -> [AssetRecord] {
        guard let indices = matches[category] else { return [] }
        return indices.map { records[$0] }
    }

    /// Everything that could make a count look wrong, said out loud. A bare zero
    /// on a device you cannot attach a debugger to is indistinguishable from a
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
}
