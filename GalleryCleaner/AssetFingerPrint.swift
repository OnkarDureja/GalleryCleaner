//
//  AssetFingerPrint.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import Foundation
import CryptoKit
import Photos

/// Content fingerprint for duplicate confirmation.
///
/// This is deliberately not a whole-file hash. Hashing every candidate in full
/// would mean reading gigabytes off disk on a real library, so the read is
/// capped at `maxBytes` and the request is cancelled as soon as that much has
/// been hashed. The total byte count is folded into the hash first, so two
/// files that happen to share a prefix but differ in length never collide.
///
/// Anything smaller than the cap gets hashed in full, which covers most photos.
///
/// Network access is off. An asset whose data is not on the device produces no
/// fingerprint and is left out of every group rather than guessed at.
enum AssetFingerprint {

    static func compute(
        for asset: PHAsset,
        totalBytes: Int64?,
        maxBytes: Int = AppConfig.duplicateFingerprintBytes
    ) async -> String? {

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
private final class FingerprintSession: @unchecked Sendable {

    private let lock = NSLock()
    private var hasher = SHA256()
    private var hashedBytes = 0
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelRequested = false
    private var isDone = false
    private var continuation: CheckedContinuation<String?, Never>?

    private let maxBytes: Int

    init(maxBytes: Int, totalBytes: Int64?, continuation: CheckedContinuation<String?, Never>) {
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

        cancelRequested = true
        isDone = true
        let digest = finalizeDigestLocked()
        let pending = takeContinuationLocked()
        let idToCancel = requestID
        lock.unlock()

        if let idToCancel {
            PHAssetResourceManager.default().cancelDataRequest(idToCancel)
        }
        pending?.resume(returning: digest)
    }

    func complete(error: Error?) {
        lock.lock()

        guard !isDone else {
            lock.unlock()
            return
        }

        isDone = true
        let digest = hashedBytes > 0 ? finalizeDigestLocked() : nil
        let pending = takeContinuationLocked()
        lock.unlock()

        pending?.resume(returning: digest)
    }

    // Both helpers assume the lock is already held.

    private func finalizeDigestLocked() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func takeContinuationLocked() -> CheckedContinuation<String?, Never>? {
        defer { continuation = nil }
        return continuation
    }
}
