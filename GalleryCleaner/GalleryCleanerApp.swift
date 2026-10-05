//
//  GalleryCleanerApp.swift
//  GalleryCleaner
//
//  Created by Onkar Dureja on 05/10/26.
//

import SwiftUI

@main
struct GalleryCleanerApp: App {

    @State private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}
