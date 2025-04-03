//
//  TestConstants.swift
//
//  Created by Manfred Baldauf on 12.03.24.
//

import Foundation
@testable import Lingohub

public class TestConstants: NSObject {
    public static let apiKey = "test-api-key"
    public static let appVersion = "1.0.0"
    public static let updatedAppVersion = "1.0.1"
    public static let bundleIdentifier = "test-bundle-id"
    public static let updateBundleURL = Bundle.module.url(forResource: "update", withExtension: "zip")!
}
