import Foundation
import XCTest

@testable import Workbench

final class DiskScanCancellationTests: XCTestCase {
    private var temporaryFolder: URL!

    override func setUpWithError() throws {
        temporaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskScanCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryFolder {
            try? FileManager.default.removeItem(at: temporaryFolder)
        }
    }

    func testCancellationStopsDetachedEnumerationAtProgressBarrier() async throws {
        // The scan reports progress every 750 files. Leave another file so a
        // cancelled worker must exit instead of continuing its enumeration.
        for index in 0..<751 {
            let file = temporaryFolder.appendingPathComponent("file-\(index).txt")
            try Data().write(to: file)
        }

        let reachedBarrier = expectation(description: "Enumeration reached its progress barrier")
        let barrier = DiskScanCancellationProgressBarrier(reached: reachedBarrier) {
            $0.customDetail == nil && $0.filesScanned == 750
        }
        let options = DiskSpaceScanOptions(root: temporaryFolder)
        let scan = Task {
            try await DiskSpaceAnalyzerEngine.analyze(options: options) { progress in
                await barrier.observe(progress)
            }
        }

        await fulfillment(of: [reachedBarrier], timeout: 10)
        scan.cancel()
        await barrier.release()

        assertCancelled(await scan.result)
        let observation = await barrier.observation
        XCTAssertTrue(observation.workerObservedCancellation,
                      "Cancellation must reach the detached worker, not only its caller.")
        XCTAssertEqual(observation.subsequentProgressCount, 0,
                       "Enumeration must not continue after the cancelled progress barrier.")
    }

    func testCancellationStopsDetachedDuplicateHashingAtProgressBarrier() async throws {
        let payload = Data(repeating: 42, count: 150_000)
        try payload.write(to: temporaryFolder.appendingPathComponent("original.bin"))
        try payload.write(to: temporaryFolder.appendingPathComponent("copy.bin"))

        let reachedBarrier = expectation(description: "Duplicate hashing reached its progress barrier")
        let barrier = DiskScanCancellationProgressBarrier(reached: reachedBarrier) {
            $0.customDetail?.hasPrefix("Checking duplicates 0 of ") == true
        }
        let options = DiskSpaceScanOptions(root: temporaryFolder)
        let scan = Task {
            try await DiskSpaceAnalyzerEngine.analyze(options: options) { progress in
                await barrier.observe(progress)
            }
        }

        await fulfillment(of: [reachedBarrier], timeout: 10)
        scan.cancel()
        await barrier.release()

        assertCancelled(await scan.result)
        let observation = await barrier.observation
        XCTAssertTrue(observation.workerObservedCancellation,
                      "Cancellation must reach the worker before it hashes the first candidate.")
        XCTAssertEqual(observation.subsequentProgressCount, 0,
                       "A cancelled duplicate pass must not continue to hash completion.")
    }

    private func assertCancelled(
        _ result: Result<DiskSpaceAnalysis, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Unexpected failure: \(error)", file: file, line: line)
        case .success:
            XCTFail("The scan completed instead of stopping its detached worker.", file: file, line: line)
        }
    }
}

private actor DiskScanCancellationProgressBarrier {
    struct Observation: Sendable {
        let workerObservedCancellation: Bool
        let subsequentProgressCount: Int
    }

    private let reached: XCTestExpectation
    private let shouldPause: @Sendable (DiskSpaceScanProgress) -> Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var didReachBarrier = false
    private var isReleased = false
    private var workerObservedCancellation = false
    private var subsequentProgressCount = 0

    init(
        reached: XCTestExpectation,
        shouldPause: @escaping @Sendable (DiskSpaceScanProgress) -> Bool
    ) {
        self.reached = reached
        self.shouldPause = shouldPause
    }

    func observe(_ progress: DiskSpaceScanProgress) async {
        if didReachBarrier {
            subsequentProgressCount += 1
            return
        }
        guard shouldPause(progress) else { return }
        didReachBarrier = true
        reached.fulfill()
        if !isReleased {
            await withCheckedContinuation { continuation = $0 }
        }
        // This runs in the disk worker's task after its callback resumes, so
        // it verifies cancellation reached that worker instead of only its UI.
        workerObservedCancellation = Task.isCancelled
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }

    var observation: Observation {
        Observation(
            workerObservedCancellation: workerObservedCancellation,
            subsequentProgressCount: subsequentProgressCount
        )
    }
}
