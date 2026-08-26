import XCTest
@testable import SyrinxClient

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testMapsServiceStatusesToUserVisibleStates() {
        let service = FakeLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.checkboxIsOn)

        service.status = .requiresApproval
        XCTAssertEqual(controller.refresh(), .requiresApproval)
        XCTAssertTrue(controller.checkboxIsOn)
        XCTAssertEqual(controller.statusMessage, "Needs approval")

        service.status = .notFound
        XCTAssertEqual(controller.refresh(), .notFound)
        XCTAssertFalse(controller.checkboxIsOn)
    }

    func testToggleUsesInjectedServiceAndRefreshesActualStatus() {
        let service = FakeLoginItemService(status: .disabled)
        let controller = LoginItemController(service: service)

        XCTAssertEqual(controller.setEnabled(true), .enabled)
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(controller.status, .enabled)

        XCTAssertEqual(controller.setEnabled(false), .disabled)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertEqual(controller.status, .disabled)
    }

    func testRegisterFailureKeepsActualDisabledStatusAndShowsError() {
        let service = FakeLoginItemService(
            status: .disabled,
            registerError: TestError(message: "register failed")
        )
        let controller = LoginItemController(service: service)

        let status = controller.setEnabled(true)
        XCTAssertEqual(status, .disabled)
        XCTAssertEqual(controller.status, .disabled)
        XCTAssertFalse(controller.checkboxIsOn)
        XCTAssertEqual(controller.operationError, "register failed")
        XCTAssertTrue(controller.statusMessage.contains("Disabled"))
        XCTAssertTrue(controller.statusMessage.contains("register failed"))
    }

    func testUnregisterFailureKeepsActualEnabledStatusAndCheckboxOn() {
        let service = FakeLoginItemService(
            status: .enabled,
            unregisterError: TestError(message: "unregister failed")
        )
        let controller = LoginItemController(service: service)

        let status = controller.setEnabled(false)
        XCTAssertEqual(status, .enabled)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.checkboxIsOn)
        XCTAssertEqual(controller.operationError, "unregister failed")
        XCTAssertTrue(controller.statusMessage.contains("Enabled"))
        XCTAssertTrue(controller.statusMessage.contains("unregister failed"))
    }
}

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class FakeLoginItemService: LoginItemServiceAdapter {
    var status: LoginItemStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LoginItemStatus, registerError: Error? = nil, unregisterError: Error? = nil) {
        self.status = status
        self.registerError = registerError
        self.unregisterError = unregisterError
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .disabled
    }
}
