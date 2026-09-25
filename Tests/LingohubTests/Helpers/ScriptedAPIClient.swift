//
//  ScriptedAPIClient.swift
//

import Foundation
@testable import Lingohub

/// An `APIClientProtocol` fake that answers checks and downloads from scripts, in
/// order, and records every call. A call beyond its script fails.
final class ScriptedAPIClient: APIClientProtocol, @unchecked Sendable {
    typealias CheckAnswer = Result<BundleInfo, Error>
    typealias DownloadAnswer = Result<URL, Error>

    struct ScriptExhausted: Error {}

    private let lock = NSLock()
    private var checkAnswers: [CheckAnswer]
    private var downloadAnswers: [DownloadAnswer]
    private var _checkedEnvironments: [Environment] = []
    private var _downloadedURLs: [URL] = []

    var checkCount: Int { lock.lh_withLock { _checkedEnvironments.count } }
    /// The environment of every check request, in order.
    var checkedEnvironments: [Environment] { lock.lh_withLock { _checkedEnvironments } }
    var downloadedURLs: [URL] { lock.lh_withLock { _downloadedURLs } }

    init(checks: [CheckAnswer], downloads: [DownloadAnswer] = []) {
        checkAnswers = checks
        downloadAnswers = downloads
    }

    /// Run while a check or a download is in flight, for tests that change the SDK meanwhile.
    var duringCheck: (@Sendable () async -> Void)? {
        get { lock.lh_withLock { _duringCheck } }
        set { lock.lh_withLock { _duringCheck = newValue } }
    }
    var duringDownload: (@Sendable () async -> Void)? {
        get { lock.lh_withLock { _duringDownload } }
        set { lock.lh_withLock { _duringDownload = newValue } }
    }
    private var _duringCheck: (@Sendable () async -> Void)?
    private var _duringDownload: (@Sendable () async -> Void)?

    func checkForUpdates(apiKey: String, appVersion: String, sdkVersion: String, distributionVersion: String?, environment: Environment, deviceIdentifier: String?, languageCode: String?) async throws -> BundleInfo {
        let answer: CheckAnswer = lock.lh_withLock {
            _checkedEnvironments.append(environment)
            return checkAnswers.isEmpty ? .failure(ScriptExhausted()) : checkAnswers.removeFirst()
        }
        await duringCheck?()
        return try answer.get()
    }

    func download(from url: URL, maxSize: Int64?) async throws -> URL {
        let answer: DownloadAnswer = lock.lh_withLock {
            _downloadedURLs.append(url)
            return downloadAnswers.isEmpty ? .failure(ScriptExhausted()) : downloadAnswers.removeFirst()
        }
        await duringDownload?()
        return try answer.get()
    }
}

extension ScriptedAPIClient {
    /// A 200 offering release `id` of the test archive for download from `filesUrl`.
    static func release(filesUrl: String = "https://s3.amazon.de/update.zip", id: String = TestConstants.bundleIdentifier) -> CheckAnswer {
        return .success(BundleInfo(id: id, name: "Test Bundle", filesUrl: URL(string: filesUrl)!, filesSha256: nil))
    }

    /// A 204: nothing new.
    static var noContent: CheckAnswer {
        return .failure(APIError.noContent)
    }

    /// An HTTP error answer, as `APIClient` reports it.
    static func httpError(_ statusCode: Int, infos: [String] = [], retryAfter: TimeInterval? = nil) -> Error {
        return APIError.apiError(statusCode: statusCode, message: "HTTP \(statusCode)", infos: infos, retryAfter: retryAfter)
    }

    /// A completed download: a fresh copy of the test release archive, which the SDK
    /// deletes once installed.
    static func archive() throws -> DownloadAnswer {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("LingohubScriptedDownload-\(UUID().uuidString).zip")
        try FileManager.default.copyItem(at: TestConstants.updateBundleURL, to: copy)
        return .success(copy)
    }
}
