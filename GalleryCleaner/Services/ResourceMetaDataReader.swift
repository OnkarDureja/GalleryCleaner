//
//  ResourceMetaDataReader.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation
import Photos

nonisolated struct ResourceSummary {
    let size: ByteSize
    let originalFilename: String?
    let resourceCount: Int

    static let empty = ResourceSummary(size: .unknown, originalFilename: nil, resourceCount: 0)
}

/// Caches the one-time answer to "does this OS expose PHAssetResource.fileSize".
nonisolated private final class FileSizeSupportCache: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved: Bool?

    func value(resolving compute: () -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let resolved { return resolved }
        let answer = compute()
        resolved = answer
        return answer
    }

    func peek() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return resolved
    }
}

/// `nonisolated` so the index pass reads resources on its own background
/// thread. Under the project's main-actor default this was the call PhotoKit
/// was warning about: resource metadata fetched on demand on the main queue.
nonisolated enum ResourceMetadataReader {

    private static let fileSizeKey = "fileSize"
    private static let supportCache = FileSizeSupportCache()

    /// `nil` until the first resource has been probed, then `true` or `false`.
    /// The store uses this to explain itself rather than silently showing zeros.
    static var fileSizeKeyIsAvailable: Bool? {
        supportCache.peek()
    }

    /// Reads resource records for one asset. This is a Photos-database read:
    /// no file bytes, no iCloud download, and it works even when the original
    /// is not on the device under Optimise Storage. The size it reports is the
    /// original's size, which is what the user would actually reclaim.
    static func summary(for asset: PHAsset) -> ResourceSummary {
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return .empty }

        var total: Int64 = 0
        var measuredAny = false

        // Sum every resource. An edited video keeps the original plus the
        // rendered copy; a Live Photo keeps the still plus the paired movie.
        // Both occupy space, so both count.
        for resource in resources {
            if let bytes = fileSize(of: resource) {
                total += bytes
                measuredAny = true
            }
        }

        let size = measuredAny
            ? ByteSize(bytes: total, source: .measured)
            : ByteSize.unknown

        return ResourceSummary(
            size: size,
            originalFilename: primaryFilename(in: resources),
            resourceCount: resources.count
        )
    }

    // MARK: - Guarded KVC

    /// `PHAssetResource` has no public file size. The usual workaround is a KVC
    /// read of an undocumented key, and a plain `value(forKey:)` on a key that
    /// does not exist raises an Objective-C exception that Swift cannot catch.
    /// That is a hard crash, and it would happen on a device, not in the
    /// simulator. So the key is probed once with `responds(to:)` and never
    /// touched again if the probe fails.
    private static func fileSize(of resource: PHAssetResource) -> Int64? {
        let supported = supportCache.value {
            resource.responds(to: NSSelectorFromString(fileSizeKey))
        }
        guard supported else { return nil }

        guard let raw = resource.value(forKey: fileSizeKey) else { return nil }

        if let number = raw as? NSNumber { return number.int64Value }
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        return nil
    }

    private static func primaryFilename(in resources: [PHAssetResource]) -> String? {
        let preferred: [PHAssetResourceType] = [.fullSizeVideo, .video, .fullSizePhoto, .photo]
        for type in preferred {
            if let match = resources.first(where: { $0.type == type }) {
                return match.originalFilename
            }
        }
        return resources.first?.originalFilename
    }
}

/// Fallback when a real byte count is not available.
///
/// Crude on purpose: a bitrate guess keyed off resolution. It exists so the
/// Large Videos card still has something defensible to show if the undocumented
/// size key disappears. Everything it produces is tagged `.estimated` and the UI
/// prefixes it with a tilde.
nonisolated enum SizeEstimator {

    static func videoBytes(duration: TimeInterval, width: Int, height: Int) -> ByteSize {
        guard duration > 0, width > 0, height > 0 else { return .unknown }

        let pixels = width * height
        let bitsPerSecond: Double

        switch pixels {
        case ...(1280 * 720):   bitsPerSecond = 5_000_000
        case ...(1920 * 1080):  bitsPerSecond = 12_000_000
        case ...(3840 * 2160):  bitsPerSecond = 45_000_000
        default:                bitsPerSecond = 100_000_000
        }

        let bytes = Int64((bitsPerSecond / 8.0) * duration)
        return ByteSize(bytes: bytes, source: .estimated)
    }
}
