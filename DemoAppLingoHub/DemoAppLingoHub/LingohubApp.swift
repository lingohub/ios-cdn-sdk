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

    private let updateThrottle = UpdateThrottle()

    init() {
        // Configure LingoHub SDK
        LingoHubSDK.shared.configure(withApiKey: "YOUR_API_KEY")

        LingoHubSDK.shared.swizzleMainBundle()

    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active, updateThrottle.shouldCheckForUpdates() {
                // Check for updates when the app becomes active, at most once a day
                LingoHubSDK.shared.update { result in
                    if case .success = result {
                        updateThrottle.markCheckedNow()
                    }
                }
            }
        }
    }
}
