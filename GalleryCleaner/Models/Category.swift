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
        case .videos:          return "video.fill"
        case .duplicatePhotos: return "plus.square.fill.on.square.fill"
        case .similarPhotos:   return "photo.stack.fill"
        case .duplicateVideos: return "film.stack.fill"
        case .largeVideos:     return "arrow.up.left.and.arrow.down.right"
        }
    }

    /// How the home card draws this category's icon.
    ///
    /// Two categories need more than one SF Symbol can say. Large videos is a
    /// video camera with a "GB" badge: video, and the storage it takes. Text
    /// rather than a symbol in the badge, because a symbol that small (a
    /// weight, earlier) read as a padlock at card size. Duplicate videos is a video stacked on a copy of itself,
    /// the same stacked-copy idea as Duplicate photos.
    var cardIcon: CardIcon {
        switch self {
        case .largeVideos:     return .sizeBadge("video.fill", label: "GB")
        case .duplicateVideos: return .stacked("video.fill")
        default:               return .symbol(symbolName)
        }
    }

    /// What the number on a card or a header counts, so the same figure never
    /// means different things on different screens without saying so.
    func countNoun(_ count: Int) -> String {
        let one = count == 1
        switch self {
        case .screenshots:     return one ? "screenshot" : "screenshots"
        case .videos:          return one ? "video" : "videos"
        case .largeVideos:     return one ? "video" : "videos"
        case .duplicatePhotos, .duplicateVideos:
            return one ? "extra copy" : "extra copies"
        case .similarPhotos:   return one ? "extra shot" : "extra shots"
        }
    }

    /// The word that has to sit next to a number for it to mean anything.
    ///
    /// Flat categories need none: the title below already says what is being
    /// counted, and "364 screenshots" over "Screenshots" said it twice. Sets
    /// do need one, since the number counts extras, not photos.
    func qualifier(_ count: Int) -> String? {
        switch detection {
        case .streaming: return nil
        case .grouping:  return countNoun(count)
        }
    }

    /// How a size reads next to the count: a total for flat lists, what a
    /// cleanup would free for sets.
    func sizePhrase(_ bytes: Int64) -> String {
        switch detection {
        case .streaming: return Formatters.bytes(bytes)
        case .grouping:  return "\(Formatters.bytes(bytes)) to free"
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
        case .duplicatePhotos: return "Exact copies and re-saves"
        case .similarPhotos:   return "Near-identical shots"
        case .duplicateVideos: return "Exact copies"
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

enum CardIcon {
    case symbol(String)
    /// The symbol drawn twice, a back copy offset up and to the left.
    case stacked(String)
    /// The symbol with a small round badge in its bottom-trailing corner.
    case badged(String, badge: String)
    /// A storage capacity bar, `filled` of it taken by a play segment.
    case storageBar(filled: CGFloat)
    /// The symbol with a round badge in its bottom-trailing corner carrying
    /// a short text label, such as "GB".
    case sizeBadge(String, label: String)
}

/// What a card shows right now.
///
/// `.ready` carries an optional note so a zero is never bare. A count of zero
/// with no explanation reads as a broken app, which is the single most likely
/// thing to go wrong on a device you cannot debug.
enum CategoryState: Equatable {
    case idle
    /// `partialCount` is nil for work that has no meaningful running total.
    /// Duplicate detection is one: a half-finished comparison has found no
    /// groups yet, and printing "0" while it works reads as a finished answer.
    case scanning(partialCount: Int?, detail: String)
    case ready(count: Int, note: String?)
    case unavailable(reason: String)

    var count: Int? {
        switch self {
        case .scanning(let partial, _): return partial
        case .ready(let count, _):      return count
        case .idle, .unavailable:       return nil
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
