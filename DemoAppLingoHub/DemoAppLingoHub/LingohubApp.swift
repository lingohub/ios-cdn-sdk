//
//  Test_App_LingohubApp.swift
//  Test App Lingohub
//
//  Created by Manfred Baldauf on 12.03.25.
//

import SwiftUI
import Lingohub

@main
struct LingohubApp: App {
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure Lingohub SDK
        LingohubSDK.shared.configure(withApiKey: "YOUR_API_KEY")

        LingohubSDK.shared.swizzleMainBundle()

    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                // Check for updates when app becomes active
                LingohubSDK.shared.update()

            }
        }
    }
}
