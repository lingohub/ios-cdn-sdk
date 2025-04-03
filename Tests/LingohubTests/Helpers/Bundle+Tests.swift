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
         LingohubLogger.shared.log("Bundle path: \(bundle.bundlePath)")
        if let resourcePath = bundle.resourcePath {
            do {
                let resources = try FileManager.default.contentsOfDirectory(atPath: resourcePath)
                 LingohubLogger.shared.log("Resources in bundle: \(resources)")

                // Check for .lproj directories specifically
                let lprojDirs = resources.filter { $0.hasSuffix(".lproj") }
                 LingohubLogger.shared.log("Found .lproj directories: \(lprojDirs)")
            } catch {
                 LingohubLogger.shared.log("Error listing resources: \(error)")
            }
        } else {
             LingohubLogger.shared.log("No resource path found in bundle")
        }
    }
}

