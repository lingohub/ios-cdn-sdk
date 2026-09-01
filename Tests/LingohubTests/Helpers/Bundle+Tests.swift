//
//  Bundle+Tests.swift
//
//  Created by Manfred Baldauf on 12.03.24.
//

import Foundation
import XCTest

@testable import Lingohub

@objc public extension Bundle {
    static var tests: Bundle {
        return Bundle(for: MockService.self)
    }

    static var updateBundleURL: URL {
        return tests.url(forResource: "update", withExtension: "zip")!
    }

    static func debugBundleResources() {
        let bundle = tests
         LingoHubLogger.shared.log("Bundle path: \(bundle.bundlePath)")
        if let resourcePath = bundle.resourcePath {
            do {
                let resources = try FileManager.default.contentsOfDirectory(atPath: resourcePath)
                 LingoHubLogger.shared.log("Resources in bundle: \(resources)")

                // Check for .lproj directories specifically
                let lprojDirs = resources.filter { $0.hasSuffix(".lproj") }
                 LingoHubLogger.shared.log("Found .lproj directories: \(lprojDirs)")
            } catch {
                 LingoHubLogger.shared.log("Error listing resources: \(error)")
            }
        } else {
             LingoHubLogger.shared.log("No resource path found in bundle")
        }
    }
}

