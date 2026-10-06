//
//  AssetFingerPrint.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation
import CryptoKit
import Photos

/// The result of hashing an asset's primary resource.
nonisolated struct Fingerprint: Sendable, Hashable {
    let digest: String

    /// True when every byte of the file went into `digest`. A prefix read of a
    /// file smaller than the cap is complete too, and needs no second pass.
    let coversWholeFile: Bool
}

/// Content fingerprint for duplicate confirmation.
///
/// Two modes. With `maxBytes` set, the read stops once that many bytes have
/// been hashed, which is the cheap screen. With `maxBytes` nil the whole file
/// is hashed, which is what "exact copy" is allowed to rest on.
///
/// The total byte count, when known, is folded in first in both modes. That
/// way a complete prefix read and a whole-file read of the same file produce
/// the same digest, and the duplicate detector can compare them directly.
///
/// Network access is off. An asset whose data is not on the device produces no
/// fingerprint and is left out of every group rather than guessed at.
///
/// `nonisolated` on purpose. With the project's main-actor default this was an
/// async main-actor function, so every `await` on it from the detector's
/// background task hopped back onto main, and the resource lookup inside ran
/// there. Nonisolated, it stays on whichever background thread called it.
nonisolated enum AssetFingerprint {

    static func compute(
        for asset: PHAsset,
        totalBytes: Int64?,
        maxBytes: Int?
    ) async -> Fingerprint? {

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = primary(in: resources) else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            let session = FingerprintSession(
                maxBytes: maxBytes,
                totalBytes: totalBytes,
                continuation: continuation
            )

            let requestID = PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { session.append($0) },
                completionHandler: { session.complete(error: $0) }
            )

            session.attach(requestID: requestID)
        }
    }

    /// Prefers the untouched original over a rendered edit. Two copies of the
    /// same photo share an original even when one of them has been edited.
    private static func primary(in resources: [PHAssetResource]) -> PHAssetResource? {
        let order: [PHAssetResourceType] = [.photo, .video, .fullSizePhoto, .fullSizeVideo]
        for type in order {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }
}

/// Holds hashing state across PhotoKit's callbacks, which arrive on an
/// arbitrary queue. Every mutation is behind the lock, and the continuation is
/// resumed exactly once.
nonisolated private final class FingerprintSession: @unchecked Sendable {

    private let lock = NSLock()
    private var hasher = SHA256()
    private var hashedBytes = 0
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelRequested = false
    private var isDone = false
    private var continuation: CheckedContinuation<Fingerprint?, Never>?

    /// Nil means read to the end.
    private let maxBytes: Int?

    init(maxBytes: Int?, totalBytes: Int64?, continuation: CheckedContinuation<Fingerprint?, Never>) {
        self.maxBytes = maxBytes
        self.continuation = continuation

        if let totalBytes {
            var value = totalBytes.littleEndian
            withUnsafeBytes(of: &value) { hasher.update(bufferPointer: $0) }
        }
    }

    func attach(requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        self.requestID = requestID
        // The cap can be reached before this call lands, since the data handler
        // may fire synchronously.
        let shouldCancel = cancelRequested
        lock.unlock()

        if shouldCancel {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
        }
    }

    func append(_ data: Data) {
        lock.lock()

        guard !isDone else {
            lock.unlock()
            return
        }

        guard let maxBytes else {
            // Whole-file mode: hash everything, finish in `complete`.
            hasher.update(data: data)
            hashedBytes += data.count
            lock.unlock()
            return
        }

        let remaining = maxBytes - hashedBytes
        if remaining > 0 {
            let slice = data.count <= remaining ? data : data.prefix(remaining)
            hasher.update(data: slice)
            hashedBytes += slice.count
        }

        guard hashedBytes >= maxBytes else {
            lock.unlock()
            return
        }

        // Cap reached. Even if this chunk happened to end exactly at the end
        // of the file, we cannot know that here, so it is marked partial and
        // the detector will hash it whole if it matters.
        cancelRequested = true
        isDone = true
        let print = Fingerprint(digest: finalizeDigestLocked(), coversWholeFile: false)
        let pending = takeContinuationLocked()
        let idToCancel = requestID
        lock.unlock()

        if let idToCancel {
            PHAssetResourceManager.default().cancelDataRequest(idToCancel)
        }
        pending?.resume(returning: print)
    }

    func complete(error: Error?) {
        lock.lock()

        guard !isDone else {
            lock.unlock()
            return
        }

        isDone = true

        // Any error means the digest covers an unknown part of the file. The
        // old version returned it anyway, which could pair two different files
        // that failed at the same point. Nothing is safer than something here.
        let print: Fingerprint? = (error == nil && hashedBytes > 0)
            ? Fingerprint(digest: finalizeDigestLocked(), coversWholeFile: true)
            : nil
        let pending = takeContinuationLocked()
        lock.unlock()

        pending?.resume(returning: print)
    }

    // Both helpers assume the lock is already held.

    private func finalizeDigestLocked() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func takeContinuationLocked() -> CheckedContinuation<Fingerprint?, Never>? {
        defer { continuation = nil }
        return continuation
    }
}
