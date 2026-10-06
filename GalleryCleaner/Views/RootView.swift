//
//  RootView.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import SwiftUI

struct RootView: View {

    @Environment(LibraryStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Gallery Cleaner")
        }
        // One idempotent entry point, used on first appearance and on every
        // return to the foreground. The previous version only started a scan
        // when the permission value had just changed, which meant an already
        // authorised launch could sit there doing nothing until Rescan was
        // pressed by hand.
        .task { await store.bootstrap() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.bootstrap() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.permission {
        case .notDetermined:
            PermissionGateView(
                symbol: "photo.stack",
                headline: "Find what's cluttering your library",
                message: "Gallery Cleaner reads your photos and videos on this device to sort them into categories. Nothing leaves the phone.",
                actionTitle: "Allow photo access",
                action: { Task { await store.requestPermission() } }
            )

        case .denied:
            PermissionGateView(
                symbol: "lock",
                headline: "Photo access is off",
                message: "Turn on photo access in Settings and come back. Without it there is nothing to scan.",
                actionTitle: "Open Settings",
                action: { store.openSettings() }
            )

        case .restricted:
            PermissionGateView(
                symbol: "hand.raised",
                headline: "Photo access is restricted",
                message: "A device policy such as Screen Time is blocking access to the photo library. Changing it needs the device passcode.",
                actionTitle: nil,
                action: nil
            )

        case .limited, .authorized:
            CategoryGridView()
        }
    }
}

struct PermissionGateView: View {

    let symbol: String
    let headline: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
