//
//  ContentView.swift
//  Test App LingoHub
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

            // Using NSLocalizedString which will be handled by LingoHub's swizzling
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
                LingoHubSDK.shared.setLanguage(newLanguage)
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
                LingoHubSDK.shared.update()

            }
            .padding()
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(8)
            .padding(.top, 10)
        }
        .padding()
        .onAppear {
            // Initialize with the language the SDK is currently serving
            if let language = LingoHubSDK.shared.currentLanguageCode {
                currentLanguage = language
            }
        }
        // Refresh the view whenever LingoHub activates new translations.
        // SwiftUI manages this subscription's lifetime, so repeated appearances
        // don't accumulate observers.
        .onReceive(NotificationCenter.default.publisher(for: .LingoHubDidUpdateLocalization).receive(on: RunLoop.main)) { _ in
            refreshTrigger.toggle()
        }
        .id(refreshTrigger) // Force view refresh when this changes
    }
}

#Preview {
    ContentView()
}
