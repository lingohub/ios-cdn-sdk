//
//  CapturedValue.swift
//

import Foundation
@testable import Lingohub

/// Thread-safe box for values captured inside notification blocks or background threads.
final class CapturedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.lh_withLock { _value } }
        set { lock.lh_withLock { _value = newValue } }
    }
}
