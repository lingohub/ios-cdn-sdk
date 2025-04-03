//
//  ContentView.swift
//  Test App Lingohub
//
//  Created by Manfred Baldauf on 12.03.25.
//

import SwiftUI
import Lingohub

struct ContentView: View {
    @State private var refreshTrigger = false
    @State private var currentLanguage = "en" // Track the current language

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)

            // Using NSLocalizedString which will be handled by Lingohub's swizzling
            Text(NSLocalizedString("welcome_message", comment: "Welcome message shown on the main screen"))
                .font(.title)
                .multilineTextAlignment(.center)

            Text(NSLocalizedString("app_description", comment: "Brief description of the app"))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(currentLanguage == "en" ?
                   NSLocalizedString("switch_to_german", comment: "Button to switch to German language") :
                    NSLocalizedString("switch_to_english", comment: "Button to switch to English language")) {
                // Toggle between English and German
                let newLanguage = currentLanguage == "en" ? "de" : "en"
                LingohubSDK.shared.setLanguage(newLanguage)
                currentLanguage = newLanguage

                // Force view refresh
                refreshTrigger.toggle()
            }
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(8)

            // Update button
            Button(NSLocalizedString("check_for_updates", comment: "Button to check for content updates")) {
                LingohubSDK.shared.update()

            }
            .padding()
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(8)
            .padding(.top, 10)
        }
        .padding()
        .onAppear {
            setupNotificationObserver()
            // Initialize current language
            if let language = LingohubSDK.shared.language {
                currentLanguage = language
            }
        }
        .id(refreshTrigger) // Force view refresh when this changes
    }

    private func setupNotificationObserver() {
        NotificationCenter.default.removeObserver(self, name: .LingohubDidUpdateLocalization, object: nil)

        NotificationCenter.default.addObserver(
            forName: .LingohubDidUpdateLocalization,
            object: nil,
            queue: .main
        ) { _ in
            // Toggle state to force view refresh
            self.refreshTrigger.toggle()
        }
    }
}

#Preview {
    ContentView()
}
