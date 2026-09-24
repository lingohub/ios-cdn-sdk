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

            // SwiftUI looks strings up without going through the swizzled
            // NSLocalizedString path; `bundle: .lingohub` serves downloaded
            // translations, falling back to the strings bundled with the app.
            Text("welcome_message", bundle: .lingohub, comment: "Welcome message shown on the main screen")
                .font(.title)
                .multilineTextAlignment(.center)

            // The same for LocalizedStringResource-based code
            Text(lh: LocalizedStringResource("app_description", comment: "Brief description of the app"))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                // Toggle between English and German
                let newLanguage = currentLanguage == "en" ? "de" : "en"
                LingoHubSDK.shared.setLanguage(newLanguage)
                currentLanguage = newLanguage

                // Force view refresh
                refreshTrigger.toggle()
            } label: {
                if currentLanguage == "en" {
                    Text("switch_to_german", bundle: .lingohub, comment: "Button to switch to German language")
                } else {
                    Text("switch_to_english", bundle: .lingohub, comment: "Button to switch to English language")
                }
            }
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)

            // Update button
            Button {
                LingoHubSDK.shared.update()
            } label: {
                Text("check_for_updates", bundle: .lingohub, comment: "Button to check for content updates")
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
