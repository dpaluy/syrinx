import XCTest
@testable import SyrinxCore

final class ConfigurationTests: XCTestCase {
    func testDefaultConfigurationUsesLoopbackAndBoundedValues() throws {
        let configuration = try ServiceConfiguration.load(environment: [:])

        XCTAssertEqual(configuration.host.value, "127.0.0.1")
        XCTAssertEqual(configuration.port.value, 5092)
        XCTAssertEqual(configuration.maxUploadBytes.value, 25 * 1024 * 1024)
        XCTAssertEqual(configuration.maxEnvelopeBytes.value, 26 * 1024 * 1024)
        XCTAssertEqual(configuration.maxDurationSeconds.value, 3_600)
        XCTAssertEqual(configuration.maxJobs.value, 1)
        XCTAssertEqual(configuration.httpIdleTimeoutMilliseconds.value, 30_000)
        XCTAssertEqual(configuration.httpRequestTimeoutMilliseconds.value, 120_000)
        XCTAssertEqual(configuration.httpHeaderFieldBytes.value, 8 * 1024)
        XCTAssertEqual(configuration.httpHeaderListBytes.value, 16 * 1024)
        XCTAssertEqual(configuration.httpHeaderFieldCount.value, 100)
        XCTAssertEqual(configuration.shutdownTimeoutSeconds.value, 30)
        XCTAssertEqual(configuration.modelID.value, "parakeet-tdt-0.6b-v3")
        XCTAssertNil(configuration.bearerSecret)
    }

    func testEnvironmentValuesUseTheTemporarySyrinxPrefix() throws {
        let environment = [
            "SYRINX_PORT": "6000",
            "SYRINX_MAX_UPLOAD_BYTES": "1024",
            "SYRINX_MAX_ENVELOPE_BYTES": "2048",
            "SYRINX_MAX_DURATION_SECONDS": "90",
            "SYRINX_MAX_JOBS": "2",
            "SYRINX_HTTP_IDLE_TIMEOUT_MILLISECONDS": "1000",
            "SYRINX_HTTP_REQUEST_TIMEOUT_MILLISECONDS": "2000",
            "SYRINX_HTTP_HEADER_FIELD_BYTES": "4096",
            "SYRINX_HTTP_HEADER_LIST_BYTES": "8192",
            "SYRINX_HTTP_HEADER_FIELD_COUNT": "20",
            "SYRINX_SHUTDOWN_TIMEOUT_SECONDS": "15",
            "SYRINX_MODEL_ID": "test-model",
            "SYRINX_API_KEY": "secret"
        ]

        let configuration = try ServiceConfiguration.load(environment: environment)

        XCTAssertEqual(configuration.port.value, 6000)
        XCTAssertEqual(configuration.maxUploadBytes.value, 1024)
        XCTAssertEqual(configuration.maxEnvelopeBytes.value, 2048)
        XCTAssertEqual(configuration.maxDurationSeconds.value, 90)
        XCTAssertEqual(configuration.maxJobs.value, 2)
        XCTAssertEqual(configuration.httpIdleTimeoutMilliseconds.value, 1000)
        XCTAssertEqual(configuration.httpRequestTimeoutMilliseconds.value, 2000)
        XCTAssertEqual(configuration.httpHeaderFieldBytes.value, 4096)
        XCTAssertEqual(configuration.httpHeaderListBytes.value, 8192)
        XCTAssertEqual(configuration.httpHeaderFieldCount.value, 20)
        XCTAssertEqual(configuration.shutdownTimeoutSeconds.value, 15)
        XCTAssertEqual(configuration.modelID.value, "test-model")
        XCTAssertEqual(configuration.bearerSecret, "secret")
    }

    func testInvalidTypedEnvironmentValueFailsValidation() {
        XCTAssertThrowsError(
            try ServiceConfiguration.load(environment: ["SYRINX_PORT": "0"])
        ) { error in
            XCTAssertEqual(
                error as? ConfigurationError,
                .invalidValue(key: "SYRINX_PORT", value: "0", reason: "must be between 1 and 65535")
            )
        }
    }

    func testNonLoopbackHostFailsValidation() {
        XCTAssertThrowsError(
            try ServiceConfiguration.load(environment: ["SYRINX_HOST": "0.0.0.0"])
        ) { error in
            XCTAssertEqual(
                error as? ConfigurationError,
                .invalidValue(
                    key: "SYRINX_HOST",
                    value: "0.0.0.0",
                    reason: "must be the loopback address 127.0.0.1"
                )
            )
        }
    }
}
