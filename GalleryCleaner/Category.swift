//
//  Category.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation
import SwiftUI

/// How a category's membership is worked out.
///
/// `.streaming` categories are per-asset predicates. They resolve inside the
/// index pass and their counts tick up live.
///
/// `.grouping` categories produce clusters and need the complete index plus a
/// second pass over pixel data. They cannot start until the index finishes.
enum DetectionStyle {
    case streaming
    case grouping
}

enum CategoryID: String, CaseIterable, Identifiable, Sendable {
    case screenshots
    case videos
    case duplicatePhotos
    case similarPhotos
    case duplicateVideos
    case largeVideos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshots:     return "Screenshots"
        case .videos:          return "Videos"
        case .duplicatePhotos: return "Duplicate photos"
        case .similarPhotos:   return "Similar photos"
        case .duplicateVideos: return "Duplicate videos"
        case .largeVideos:     return "Large videos"
        }
    }

    var symbolName: String {
        switch self {
        case .screenshots:     return "camera.viewfinder"
        case .videos:          return "play.rectangle.fill"
        case .duplicatePhotos: return "photo.on.rectangle.angled"
        case .similarPhotos:   return "square.on.square"
        case .duplicateVideos: return "film.stack"
        case .largeVideos:     return "internaldrive.fill"
        }
    }

    /// Permanent one-liner saying what the category means.
    ///
    /// Every card needs something in this slot. Without it the cards that have
    /// no dynamic note render with visibly empty space while their neighbours
    /// are full, and the row looks unbalanced for no reason the user can see.
    var blurb: String {
        switch self {
        case .screenshots:     return "Captured on this device"
        case .videos:          return "Everything that plays"
        case .duplicatePhotos: return "Byte-identical copies"
        case .similarPhotos:   return "Near-identical shots"
        case .duplicateVideos: return "Byte-identical copies"
        case .largeVideos:     return "The biggest files you have"
        }
    }

    /// The only place colour enters the grid. Everything else about a card is
    /// identical across categories, so the screen still reads as one surface
    /// while each tile stays recognisable at a glance. System palette only, so
    /// light and dark are handled for free.
    var tint: Color {
        switch self {
        case .screenshots:     return .blue
        case .videos:          return .indigo
        case .duplicatePhotos: return .orange
        case .similarPhotos:   return .pink
        case .duplicateVideos: return .purple
        case .largeVideos:     return .teal
        }
    }

    var detection: DetectionStyle {
        switch self {
        case .screenshots, .videos, .largeVideos:
            return .streaming
        case .duplicatePhotos, .similarPhotos, .duplicateVideos:
            return .grouping
        }
    }
}

/// What a card shows right now.
///
/// `.ready` carries an optional note so a zero is never bare. A count of zero
/// with no explanation reads as a broken app, which is the single most likely
/// thing to go wrong on a device you cannot debug.
enum CategoryState: Equatable {
    case idle
    case scanning(partialCount: Int)
    case ready(count: Int, note: String?)
    case unavailable(reason: String)

    var count: Int? {
        switch self {
        case .scanning(let partial): return partial
        case .ready(let count, _):   return count
        case .idle, .unavailable:    return nil
        }
    }

    var isBusy: Bool {
        if case .scanning = self { return true }
        return false
    }

    /// Placeholder and zero-count categories are navigable on purpose: tapping
    /// one is the only way to read the full explanation of why it is empty.
    var isNavigable: Bool {
        switch self {
        case .ready, .unavailable: return true
        case .idle, .scanning:     return false
        }
    }

    var isPlaceholder: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
