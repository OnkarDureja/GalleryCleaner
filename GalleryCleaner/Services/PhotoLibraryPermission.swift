import Foundation
import Photos
// `presentLimitedLibraryPicker(from:)` is an extension on PHPhotoLibrary that
// ships in PhotosUI, not in Photos. Without this import the call does not exist.
import PhotosUI
import UIKit

nonisolated enum PhotoPermissionStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted:    self = .restricted
        case .denied:        self = .denied
        case .authorized:    self = .authorized
        case .limited:       self = .limited
        @unknown default:    self = .denied
        }
    }

    /// Both `.authorized` and `.limited` return assets from a fetch. Under
    /// `.limited` the fetch only returns the assets the user picked, so every
    /// count in the app is a count of that subset, not of the library.
    var allowsFetch: Bool {
        self == .authorized || self == .limited
    }
}

enum PhotoLibraryPermission {

    /// Nonisolated: it only reads PhotoKit's authorization status, which is
    /// thread-safe, and the change watcher calls it off the main actor.
    nonisolated static func current() -> PhotoPermissionStatus {
        PhotoPermissionStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    static func request() async -> PhotoPermissionStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return PhotoPermissionStatus(status)
    }

    @MainActor
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Opens the system sheet that lets the user change which assets are shared.
    /// Needs a presenting view controller, which SwiftUI does not hand us, so we
    /// reach for the active scene's root. Returns silently if there isn't one
    /// rather than force-unwrapping anything.
    @MainActor
    static func presentLimitedPicker() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        guard let root = scene?.keyWindow?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root)
    }
}

/// Watches for library changes so stale counts can be flagged.
///
/// This matters most under limited access: the user changes their selection in
/// the system picker, comes back, and every count on screen is now wrong. We do
/// not rescan automatically, we just raise a flag and let the user tap Rescan.
///
/// Declared `nonisolated` on purpose. Xcode 26 projects default to MainActor
/// isolation for every type, but PhotoKit calls `photoLibraryDidChange(_:)` on
/// an arbitrary queue, so claiming main-actor isolation here would be a lie the
/// compiler correctly refuses to accept. The registration flag is guarded by a
/// lock instead, and the callback hops to the main actor at the call site.
nonisolated final class PhotoLibraryChangeWatcher: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {

    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var isRegistered = false

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
    }

    func start() {
        guard PhotoLibraryPermission.current().allowsFetch else { return }

        lock.lock()
        let wasRegistered = isRegistered
        isRegistered = true
        lock.unlock()

        guard !wasRegistered else { return }
        PHPhotoLibrary.shared().register(self)
    }

    func stop() {
        lock.lock()
        let wasRegistered = isRegistered
        isRegistered = false
        lock.unlock()

        guard wasRegistered else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    deinit {
        if isRegistered {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange()
    }
}
