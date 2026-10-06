//
//  AssetRecord.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation
import Photos

nonisolated enum MediaKind: String, Sendable {
    case photo
    case video
    case audio
    case unknown

    init(_ mediaType: PHAssetMediaType) {
        switch mediaType {
        case .image: self = .photo
        case .video: self = .video
        case .audio: self = .audio
        default:     self = .unknown
        }
    }
}

/// Where a byte count came from. The UI shows this, because an estimate the user
/// thinks is exact is worse than no number at all.
nonisolated enum ByteSizeSource: String, Sendable {
    case measured   // read off PHAssetResource
    case estimated  // derived from duration and resolution
    case unknown    // no size available at all
}

nonisolated struct ByteSize: Hashable, Sendable {
    let bytes: Int64?
    let source: ByteSizeSource

    static let unknown = ByteSize(bytes: nil, source: .unknown)

    var isKnown: Bool { bytes != nil }
}

/// Everything the app knows about one asset, flattened into a value type.
///
/// Deliberately holds no `PHAsset`. Keeping 5000 live PhotoKit objects around
/// works but ties memory to the Photos database; this keeps the index to roughly
/// a megabyte and lets the detail screens re-fetch only what they display.
///
/// `mediaSubtypeRawValue` is stored instead of `PHAssetMediaSubtype` so the whole
/// record is trivially `Sendable` and can cross from the background index task to
/// the main actor without ceremony.
///
/// `nonisolated` so the background index and detectors can build and read
/// records without borrowing main-actor isolation from the project default.
nonisolated struct AssetRecord: Identifiable, Hashable, Sendable {

    let id: String                  // localIdentifier
    let kind: MediaKind
    let mediaSubtypeRawValue: UInt
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let creationDate: Date?
    let modificationDate: Date?
    let burstIdentifier: String?
    let isFromSharedAlbum: Bool

    /// Came onto the phone through a Finder (or iTunes) sync. iOS only removes
    /// these when the computer syncs again without them, so the app shows them
    /// but never offers to delete them.
    let isSynced: Bool

    /// Whether this app is allowed to remove the asset. False for shared-album
    /// assets and for anything synced from a computer, even where PhotoKit's
    /// own `canPerform(.delete)` says yes: for synced items that answer was
    /// wrong, and the deletion went nowhere. Detectors still group these so
    /// the user sees them; selection and bulk actions skip them.
    let canDelete: Bool
    let originalFilename: String?
    let size: ByteSize

    var mediaSubtypes: PHAssetMediaSubtype {
        PHAssetMediaSubtype(rawValue: mediaSubtypeRawValue)
    }

    var isScreenshot: Bool {
        mediaSubtypes.contains(.photoScreenshot)
    }

    var pixelCount: Int {
        pixelWidth * pixelHeight
    }
}
