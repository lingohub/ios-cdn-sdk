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

        LingoHubSDK.shared.swizzleMainBundle()

    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                // Check for updates when app becomes active
                LingoHubSDK.shared.update()

            }
        }
    }
}
