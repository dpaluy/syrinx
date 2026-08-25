import Foundation
import XCTest
@testable import SyrinxCore

final class AudioPreparationPolicyTests: XCTestCase {
    func testPolicyUsesConfigurationLimitsAndFixedTarget() throws {
        let configuration = try ServiceConfiguration.load(environment: [
            "SYRINX_MAX_UPLOAD_BYTES": "1024",
            "SYRINX_MAX_DURATION_SECONDS": "90"
        ])

        let policy = try AudioPreparationPolicy(configuration: configuration)

        XCTAssertEqual(policy.maxUploadBytes, 1_024)
        XCTAssertEqual(policy.maxDurationSeconds, 90)
        XCTAssertEqual(policy.targetSampleRate, 16_000)
        XCTAssertEqual(policy.targetChannels, 1)
        XCTAssertEqual(policy.targetSampleFormat, .float32)
        XCTAssertEqual(policy.maxTargetSamples, 1_440_000)
    }

    func testDefaultConfigurationProducesRequiredBounds() throws {
        let policy = try AudioPreparationPolicy(
            configuration: ServiceConfiguration.load(environment: [:])
        )

        XCTAssertEqual(policy.maxUploadBytes, 25 * 1024 * 1024)
        XCTAssertEqual(policy.maxDurationSeconds, 3_600)
        XCTAssertEqual(policy.maxTargetSamples, 57_600_000)
    }

    func testDurationMultiplicationOverflowIsRejected() throws {
        XCTAssertThrowsError(
            try AudioPreparationPolicy(maxUploadBytes: 1, maxDurationSeconds: Int.max)
        ) { error in
            XCTAssertEqual(error as? AudioPreparationError, .configurationArithmeticOverflow)
        }
    }

    func testNonPositiveBoundsAreRejected() {
        for value in [0, -1] {
            XCTAssertThrowsError(
                try AudioPreparationPolicy(maxUploadBytes: value, maxDurationSeconds: 1)
            ) { error in
                XCTAssertEqual(error as? AudioPreparationError, .invalidConfiguration)
            }
            XCTAssertThrowsError(
                try AudioPreparationPolicy(maxUploadBytes: 1, maxDurationSeconds: value)
            ) { error in
                XCTAssertEqual(error as? AudioPreparationError, .invalidConfiguration)
            }
        }
    }

    func testTargetSampleCeilingAcceptsExactAndRejectsOneOver() throws {
        let policy = try AudioPreparationPolicy(maxUploadBytes: 1, maxDurationSeconds: 1)

        XCTAssertNoThrow(try policy.validateTargetSampleCount(16_000))
        XCTAssertThrowsError(try policy.validateTargetSampleCount(16_001)) { error in
            XCTAssertEqual(error as? AudioPreparationError, .sampleLimitExceeded)
        }
    }

    func testCheckedArithmeticTableRejectsOverflow() throws {
        let cases: [(Int, Int, Bool)] = [
            (1, 16_000, true),
            (Int.max / 16_000, 16_000, true),
            (Int.max / 16_000 + 1, 16_000, false),
            (Int.max, 2, false)
        ]

        for (duration, targetRate, shouldSucceed) in cases {
            let result = AudioPreparationPolicy.checkedProduct(duration, targetRate)
            XCTAssertEqual(result != nil, shouldSucceed, "duration=\(duration), rate=\(targetRate)")
        }
    }
}
