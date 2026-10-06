//
//  HashCache.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 06/10/26.
//

import Foundation

/// Whole-file digests kept on disk between scans.
///
/// Hashing every byte of every duplicate candidate is the only honest basis
/// for calling two files exact copies, and it is also the slowest thing the
/// app does. Most of those files never change, so the work should be paid
/// once, not on every scan.
///
/// The key ties a digest to one specific version of one specific file:
/// local identifier, modification date and measured size. Any edit changes
/// the modification date, and with it the key, so a stale digest can never be
/// reused for content that changed. A miss just means hashing again.
///
/// A plain JSON file, a few hundred kilobytes at most. No database, because
/// nothing here needs querying, only lookup by exact key.
nonisolated final class HashCache: @unchecked Sendable {

    static let shared = HashCache()

    private let lock = NSLock()
    private var entries: [String: String] = [:]
    private var isLoaded = false
    private var isDirty = false

    private let fileURL: URL? = {
        let fileManager = FileManager.default
        guard let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base.appendingPathComponent("full-file-digests.json")
    }()

    /// Nil when the record has nothing stable enough to key on. Without a
    /// measured size or a modification date, a cached digest could be wrong,
    /// so those files are always hashed fresh.
    ///
    /// `variant` separates the kinds of digest kept for one file: the quick
    /// prefix screen and the whole-file hash. The prefix size is part of the
    /// variant, so changing it in `AppConfig` can never reuse old screens.
    static func key(for record: AssetRecord, variant: String) -> String? {
        guard
            record.size.source == .measured,
            let bytes = record.size.bytes,
            let modified = record.modificationDate
        else { return nil }
        return "\(record.id)|\(modified.timeIntervalSince1970)|\(bytes)|\(variant)"
    }

    func fingerprint(for record: AssetRecord, variant: String) -> Fingerprint? {
        guard let key = Self.key(for: record, variant: variant) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        guard let stored = entries[key] else { return nil }
        return Self.decode(stored)
    }

    func store(_ fingerprint: Fingerprint, for record: AssetRecord, variant: String) {
        guard let key = Self.key(for: record, variant: variant) else { return }
        let encoded = Self.encode(fingerprint)
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        if entries[key] != encoded {
            entries[key] = encoded
            isDirty = true
        }
    }

    /// "1:" or "0:" in front of the digest records whether it covers the
    /// whole file, which the duplicate detector needs to know to skip a
    /// second read.
    private static func encode(_ fingerprint: Fingerprint) -> String {
        (fingerprint.coversWholeFile ? "1:" : "0:") + fingerprint.digest
    }

    private static func decode(_ stored: String) -> Fingerprint? {
        guard stored.count > 2 else { return nil }
        let flag = stored.prefix(2)
        let digest = String(stored.dropFirst(2))
        switch flag {
        case "1:": return Fingerprint(digest: digest, coversWholeFile: true)
        case "0:": return Fingerprint(digest: digest, coversWholeFile: false)
        default:   return nil
        }
    }

    /// Writes only when something changed. Called once per detector run, not
    /// per file.
    func save() {
        lock.lock()
        guard isDirty, let fileURL else {
            lock.unlock()
            return
        }
        let snapshot = entries
        isDirty = false
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            print("[HashCache] save failed: \(error.localizedDescription)")
        }
    }

    private func loadIfNeededLocked() {
        guard !isLoaded else { return }
        isLoaded = true
        guard
            let fileURL,
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        entries = decoded
    }
}
