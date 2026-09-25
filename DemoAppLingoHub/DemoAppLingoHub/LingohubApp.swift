//
//  LingoHubApp.swift
//  Test App LingoHub
//
//  Created by Manfred Baldauf on 12.03.25.
//

import SwiftUI
import Lingohub

@main
struct LingoHubApp: App {
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure LingoHub SDK
        LingoHubSDK.shared.configure(withApiKey: "YOUR_API_KEY")

        // Serves NSLocalizedString, UIKit, and storyboards. SwiftUI views pass
        // `bundle: .lingohub` instead (see ContentView).
        LingoHubSDK.shared.swizzleMainBundle()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                // Check for updates whenever the app becomes active. The SDK paces the
                // requests: at most one check every 15 minutes in release builds.
                LingoHubSDK.shared.update()
            }
        }
    }
}
