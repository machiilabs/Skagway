import XCTest
@testable import Skagway

/// `withDeadline` must give control back even when the work ignores cancellation
/// (the stuck MPEG-2 parse that stalled idle fill overnight).
final class AsyncDeadlineTests: XCTestCase {
    func testReturnsResultBeforeDeadline() async throws {
        let value = try await withDeadline(seconds: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testPassesThroughOperationError() async {
        struct Boom: Error {}
        do {
            _ = try await withDeadline(seconds: 5) { () async throws -> Int in throw Boom() }
            XCTFail("expected Boom")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    func testThrowsDeadlineExceededWithoutWaitingForWorkThatIgnoresCancellation() async {
        let start = Date()
        do {
            _ = try await withDeadline(seconds: 0.2) { () async throws -> Int in
                Thread.sleep(forTimeInterval: 3)
                return 1
            }
            XCTFail("expected DeadlineExceeded")
        } catch {
            XCTAssertEqual(error as? DeadlineExceeded, DeadlineExceeded())
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testCallerCancellationReturnsPromptly() async {
        let task = Task {
            try await withDeadline(seconds: 30) { () async throws -> Int in
                Thread.sleep(forTimeInterval: 3)
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let start = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        if case .success = result {
            XCTFail("expected cancellation")
        }
    }

    func testTaskLocalReachesTheOperation() async throws {
        let seen = try await ThumbnailService.$isBackgroundFill.withValue(true) {
            try await withDeadline(seconds: 5) { ThumbnailService.isBackgroundFill }
        }
        XCTAssertTrue(seen)
    }
}
