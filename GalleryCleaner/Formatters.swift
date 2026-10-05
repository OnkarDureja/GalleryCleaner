//
//  Formatters.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation

enum Formatters {

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Prefixes estimates with a tilde so an approximation never reads as exact.
    static func size(_ size: ByteSize) -> String {
        guard let value = size.bytes else { return "Size unknown" }
        switch size.source {
        case .measured:  return bytes(value)
        case .estimated: return "~" + bytes(value)
        case .unknown:   return "Size unknown"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func dimensions(width: Int, height: Int) -> String {
        "\(width) × \(height)"
    }
}
