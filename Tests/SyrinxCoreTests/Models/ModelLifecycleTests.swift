import Darwin
import Foundation
import XCTest
@_spi(Testing) import SyrinxCore
@testable import SyrinxCore

final class ModelLifecycleTests: XCTestCase {
    func testActivationVerifiesCandidateAndKeepsPreviousCurrentAsPrior() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let coordinator = try fixture.coordinator()

        let result = try await coordinator.activate(immutableCommit: fixture.second, verifiedAt: fixture.date)

        XCTAssertEqual(result.currentRevision, fixture.second)
        XCTAssertEqual(result.priorRevision, fixture.first)
        XCTAssertEqual(try fixture.store.readSelection(), result)
    }

    func testIdempotentActivationPreservesExistingPriorAndSelectionBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: fixture.second)
        let before = try Data(contentsOf: fixture.store.selectionURL)

        let result = try await fixture.coordinator().activate(immutableCommit: fixture.first, verifiedAt: fixture.date)

        XCTAssertEqual(result.currentRevision, fixture.first)
        XCTAssertEqual(result.priorRevision, fixture.second)
        XCTAssertEqual(try Data(contentsOf: fixture.store.selectionURL), before)
    }

    func testRollbackSwapsCurrentAndPriorForRepeatedRollback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.second, prior: fixture.first)
        let coordinator = try fixture.coordinator()

        let first = try await coordinator.rollback(verifiedAt: fixture.date)
        let second = try await coordinator.rollback(verifiedAt: fixture.date)

        XCTAssertEqual(first.currentRevision, fixture.first)
        XCTAssertEqual(first.priorRevision, fixture.second)
        XCTAssertEqual(second.currentRevision, fixture.second)
        XCTAssertEqual(second.priorRevision, fixture.first)
    }

    func testRollbackVerificationFailurePreservesSelectionBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.second, prior: fixture.first)
        try Data("changed".utf8).write(
            to: fixture.store.revisionURL(for: fixture.first)
                .appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        )
        let before = try Data(contentsOf: fixture.store.selectionURL)

        do {
            _ = try await fixture.coordinator().rollback(verifiedAt: fixture.date)
            XCTFail("expected rollback verification failure")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .rollbackVerificationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.store.selectionURL), before)
    }

    func testRuntimeResolutionReturnsOnlyASharedLeasedRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let coordinator = try fixture.coordinator()

        let runtime = try await coordinator.resolveRuntime()
        defer { runtime.close() }

        XCTAssertEqual(runtime.immutableCommit, fixture.first)
        XCTAssertEqual(runtime.repositoryURL, fixture.store.revisionURL(for: fixture.first))
        switch try fixture.leases.tryAcquireExclusive(fixture.first) {
        case .acquired:
            XCTFail("active runtime lease must block exclusive garbage collection")
        case .busy:
            break
        }
    }

    func testRuntimeResolutionRaceWithGCAcquiresLeaseBeforeGCCanDelete() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.second, prior: nil)
        let gate = LifecycleRaceHook()
        let first = fixture.first
        let gcCoordinator = try fixture.coordinator(hook: { event in
            if event == .afterExclusiveLease(first) {
                await gate.signal()
                try await gate.waitForRelease()
            }
        })

        let gcTask = Task { try await gcCoordinator.garbageCollect() }
        try await gate.waitForSignal()
        let runtime = try await fixture.coordinator().resolveRuntime()
        defer { runtime.close() }
        XCTAssertEqual(runtime.immutableCommit, fixture.second)
        await gate.release()
        let gc = try await gcTask.value
        XCTAssertEqual(gc.deleted, [first])
    }

    func testRuntimeResolutionWaitsForActivationAtTheGlobalTransactionBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let gate = LifecycleRaceHook()
        let runtimeCoordinator = try fixture.coordinator(hook: { event in
            if event == .afterRuntimeValidation(fixture.first) {
                await gate.signal()
                try await gate.waitForRelease()
            }
        })

        let runtimeTask = Task { try await runtimeCoordinator.resolveRuntime() }
        try await gate.waitForSignal()
        let activationTask = Task {
            try await fixture.coordinator().activate(immutableCommit: fixture.second, verifiedAt: fixture.date)
        }
        await gate.release()
        let runtime = try await runtimeTask.value
        let activation = try await activationTask.value
        defer { runtime.close() }

        XCTAssertEqual(runtime.immutableCommit, fixture.first)
        XCTAssertEqual(activation.currentRevision, fixture.second)
        XCTAssertEqual(try fixture.store.readSelection()?.currentRevision, fixture.second)
    }

    func testRuntimeResolutionWaitsForRollbackAtTheGlobalTransactionBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.second, prior: fixture.first)
        let gate = LifecycleRaceHook()
        let runtimeCoordinator = try fixture.coordinator(hook: { event in
            if event == .afterRuntimeValidation(fixture.second) {
                await gate.signal()
                try await gate.waitForRelease()
            }
        })

        let runtimeTask = Task { try await runtimeCoordinator.resolveRuntime() }
        try await gate.waitForSignal()
        let rollbackTask = Task { try await fixture.coordinator().rollback(verifiedAt: fixture.date) }
        await gate.release()
        let runtime = try await runtimeTask.value
        let rollback = try await rollbackTask.value
        defer { runtime.close() }

        XCTAssertEqual(runtime.immutableCommit, fixture.second)
        XCTAssertEqual(rollback.currentRevision, fixture.first)
        XCTAssertEqual(try fixture.store.readSelection()?.currentRevision, fixture.first)
    }

    func testCandidateVerificationFailureLeavesSelectionBytesUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        try Data("tampered".utf8).write(to: fixture.store.revisionURL(for: fixture.second).appendingPathComponent("Preprocessor.mlmodelc/metadata.json"))
        let before = try Data(contentsOf: fixture.store.selectionURL)

        do {
            _ = try await fixture.coordinator().activate(immutableCommit: fixture.second, verifiedAt: fixture.date)
            XCTFail("expected verification failure")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .candidateVerificationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.store.selectionURL), before)
    }

    func testRuntimeRejectsUnsafeTreeWithoutReturningALease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        let file = fixture.store.revisionURL(for: fixture.first).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)

        do {
            _ = try await fixture.coordinator().resolveRuntime()
            XCTFail("expected unsafe tree rejection")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .runtimeUnavailable)
        }
        switch try fixture.leases.tryAcquireExclusive(fixture.first) {
        case .acquired(let lease):
            lease.close()
        case .busy:
            XCTFail("runtime failure must not retain a lease")
        }
    }

    func testGarbageCollectionDeletesOnlyStaleInstalledRevisions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([
            fixture.revision(fixture.first),
            fixture.revision(fixture.second),
            fixture.revision(fixture.third)
        ])
        try fixture.writeSelection(current: fixture.first, prior: fixture.second)
        let result = try await fixture.coordinator().garbageCollect()

        XCTAssertEqual(result.deleted, [fixture.third])
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.second).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.third).path))
        XCTAssertEqual(try fixture.store.readInstalled()?.revisions.map(\.immutableCommit), [fixture.first, fixture.second])
    }

    func testGarbageCollectionRequiresSelectionAndLeavesInstalledTreeUnchanged() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        let installedBefore = try Data(contentsOf: fixture.store.installedURL)

        do {
            _ = try await fixture.coordinator().garbageCollect()
            XCTFail("expected missing selection to fail closed")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .selectionUnavailable)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.store.installedURL), installedBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.second).path))
    }

    func testGarbageCollectionJournalWriteFaultPreservesInstalledBytesAndTree() async throws {
        let fixture = try Fixture(writer: AtomicStateWriter(failureInjector: { $0 == .rename }))
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let before = try Data(contentsOf: fixture.store.installedURL)

        do {
            _ = try await fixture.coordinator().garbageCollect()
            XCTFail("expected GC journal write failure")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .journalWriteFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.store.installedURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.second).path))
        XCTAssertNil(try fixture.store.lifecycleJournalData())
    }

    func testSelectionMutationFailsClosedWhileGarbageCollectionJournalIsPending() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let injected = LockedFlag()
        let failing = try fixture.coordinator(hook: { event in
            if event == .beforeRevisionDelete(fixture.second), injected.take() {
                throw ModelLifecycleError.deletionFailed
            }
        })
        do {
            _ = try await failing.garbageCollect()
            XCTFail("expected pending GC journal")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .deletionFailed)
        }

        do {
            _ = try await fixture.coordinator().activate(immutableCommit: fixture.second, verifiedAt: fixture.date)
            XCTFail("activation must not overwrite a pending GC journal")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .journalWriteFailed)
        }
        XCTAssertTrue(try fixture.store.readInstalled()!.revisions.contains { $0.immutableCommit == fixture.first })
        XCTAssertFalse(try fixture.store.readInstalled()!.revisions.contains { $0.immutableCommit == fixture.second })
    }

    func testBusyLeaseIsSkippedWithoutDeletingTheRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        guard case .acquired(let lease) = try fixture.leases.tryAcquireShared(fixture.second) else {
            return XCTFail("expected shared fixture lease")
        }
        defer { lease.close() }

        let result = try await fixture.coordinator().garbageCollect()

        XCTAssertEqual(result.deleted, [])
        XCTAssertEqual(result.skipped, [.busy(fixture.second)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.second).path))
    }

    func testLiveSetChangeBetweenScanAndFinalRecheckSkipsNewCurrentRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([
            fixture.revision(fixture.first),
            fixture.revision(fixture.second),
            fixture.revision(fixture.third)
        ])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let hook = LifecycleRaceHook()
        let second = fixture.second
        let coordinator = try fixture.coordinator(hook: { event in
            if event == .afterExclusiveLease(second) {
                await hook.signal()
                try await hook.waitForRelease()
            }
        })

        let gc = Task { try await coordinator.garbageCollect() }
        try await hook.waitForSignal()
        _ = try await coordinator.activate(immutableCommit: fixture.second, verifiedAt: fixture.date)
        await hook.release()
        let result = try await gc.value

        XCTAssertTrue(result.skipped.contains(.becameLive(fixture.second)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.second).path))
    }

    func testDeletionFailureLeavesJournalAndReopenRecoversConservatively() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let injected = LockedFlag()
        let second = fixture.second
        let failing = try fixture.coordinator(hook: { event in
            if event == .beforeRevisionDelete(second), injected.take() {
                throw ModelLifecycleError.deletionFailed
            }
        })

        do {
            _ = try await failing.garbageCollect()
            XCTFail("expected injected deletion failure")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .deletionFailed)
        }
        XCTAssertFalse(try fixture.store.readInstalled()!.revisions.contains { $0.immutableCommit == fixture.second })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.second).path))

        _ = try await fixture.coordinator().garbageCollect()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.second).path))
        XCTAssertNil(try fixture.store.lifecycleJournalData())
    }

    func testCrashAfterDeletionBeforeJournalClearRecoversWithoutDeletingOutsideData() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("sentinel".utf8).write(to: outside)
        let injected = LockedFlag()
        let failing = try fixture.coordinator(hook: { event in
            if event == .afterRevisionDelete(fixture.second), injected.take() {
                throw ModelLifecycleError.journalWriteFailed
            }
        })

        do {
            _ = try await failing.garbageCollect()
            XCTFail("expected post-delete crash injection")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .journalWriteFailed)
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
        XCTAssertNotNil(try fixture.store.lifecycleJournalData())

        _ = try await fixture.coordinator().garbageCollect()
        XCTAssertNil(try fixture.store.lifecycleJournalData())
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
    }

    func testSelectionWriteFaultRecoversOldBytesBeforeRetryingActivation() async throws {
        let failures = OperationFailure(failAt: 2)
        let fixture = try Fixture(writer: AtomicStateWriter(failureInjector: { operation in
            operation == .rename && failures.shouldFail()
        }))
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let before = try Data(contentsOf: fixture.store.selectionURL)

        do {
            _ = try await fixture.coordinator().activate(immutableCommit: fixture.second, verifiedAt: fixture.date)
            XCTFail("expected selection state write fault")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .selectionWriteFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.store.selectionURL), before)
        XCTAssertNotNil(try fixture.store.lifecycleJournalData())

        let result = try await fixture.coordinator().activate(immutableCommit: fixture.second, verifiedAt: fixture.date)
        XCTAssertEqual(result.currentRevision, fixture.second)
        XCTAssertNil(try fixture.store.lifecycleJournalData())
    }

    func testInstalledWriteFaultKeepsInstalledBytesAndTreeForRecovery() async throws {
        let failures = OperationFailure(failAt: 2)
        let fixture = try Fixture(writer: AtomicStateWriter(failureInjector: { operation in
            operation == .rename && failures.shouldFail()
        }))
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let before = try Data(contentsOf: fixture.store.installedURL)

        do {
            _ = try await fixture.coordinator().garbageCollect()
            XCTFail("expected installed state write fault")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .installedStateWriteFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.store.installedURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.second).path))
        XCTAssertNotNil(try fixture.store.lifecycleJournalData())

        let result = try await fixture.coordinator().garbageCollect()
        XCTAssertEqual(result.deleted, [fixture.second])
        XCTAssertNil(try fixture.store.lifecycleJournalData())
    }

    func testUnsafeCandidateIsSkippedAndLaterCandidatesStillDelete() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeInstalled([
            fixture.revision(fixture.first),
            fixture.revision(fixture.second),
            fixture.revision(fixture.third)
        ])
        try fixture.writeSelection(current: fixture.first, prior: nil)
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("sentinel".utf8).write(to: outside)
        let replaced = LockedFlag()
        let coordinator = try fixture.coordinator(hook: { event in
            guard event == .afterExclusiveLease(fixture.second), replaced.take() else { return }
            let candidate = fixture.store.revisionsDirectory.appendingPathComponent(fixture.second)
            let backup = fixture.root.appendingPathComponent("replaced-candidate")
            try FileManager.default.moveItem(at: candidate, to: backup)
            try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: outside)
        })

        let result: ModelGarbageCollectionResult
        do {
            result = try await coordinator.garbageCollect()
        } catch {
            XCTFail("GC failed: \(String(reflecting: error))")
            return
        }

        XCTAssertTrue(
            result.skipped.contains(.unsafe(fixture.second)),
            "unexpected GC result: \(String(reflecting: result))"
        )
        XCTAssertEqual(result.deleted, [fixture.third])
        XCTAssertEqual(try Data(contentsOf: outside), Data("sentinel".utf8))
        var candidateInfo = stat()
        XCTAssertEqual(lstat(fixture.store.revisionsDirectory.appendingPathComponent(fixture.second).path, &candidateInfo), 0)
        XCTAssertEqual(candidateInfo.st_mode & S_IFMT, S_IFLNK)
        guard case .acquired(let lease) = try fixture.leases.tryAcquireExclusive(fixture.second) else {
            return XCTFail("unsafe candidate lease was not released")
        }
        lease.close()
    }

    func testGarbageCollectionReplacementAttacksFailClosed() async throws {
        for target in ReplacementTarget.allCases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.writeInstalled([
                fixture.revision(fixture.first),
                fixture.revision(fixture.second),
                fixture.revision(fixture.third)
            ])
            try fixture.writeSelection(current: fixture.first, prior: nil)
            let outside = fixture.root.deletingLastPathComponent()
                .appendingPathComponent("syrinx-lifecycle-outside-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try Data("sentinel".utf8).write(to: outside.appendingPathComponent("sentinel"))
            let replaced = LockedFlag()
            let targetURL = target.url(
                root: fixture.store.root,
                models: fixture.store.modelsDirectory,
                revisions: fixture.store.revisionsDirectory,
                candidate: fixture.second
            )
            let backup = targetURL.deletingLastPathComponent()
                .appendingPathComponent("syrinx-lifecycle-backup-\(UUID().uuidString)", isDirectory: true)
            let coordinator = try fixture.coordinator(hook: { event in
                guard event == .afterExclusiveLease(fixture.second), replaced.take() else { return }
                try FileManager.default.moveItem(at: targetURL, to: backup)
                try FileManager.default.createSymbolicLink(at: targetURL, withDestinationURL: outside)
            })

            do {
                let result = try await coordinator.garbageCollect()
                if target == .root || target == .models {
                    XCTFail("expected ancestor replacement to fail closed: \(String(reflecting: result))")
                } else {
                    XCTAssertTrue(result.skipped.contains(ModelGarbageCollectionSkip.unsafe(fixture.second)))
                }
            } catch let error as ModelLifecycleError {
                XCTAssertEqual(error, .installedStateUnavailable)
            }
            XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("sentinel")), Data("sentinel".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
            try FileManager.default.removeItem(at: targetURL)
            try FileManager.default.moveItem(at: backup, to: targetURL)
        }
    }

    func testCrossProcessGarbageCollectionTransactionExclusion() async throws {
        let fixture = try ProcessFixture()
        try fixture.prepareLifecycleFixture()
        let holder = try fixture.startHelper(
            "lifecycle-gc-hold",
            fixture.ready.path,
            fixture.release.path
        )
        defer {
            if holder.isRunning { fixture.terminate(holder) }
            fixture.remove()
        }
        try await fixture.waitForMarker(fixture.ready, process: holder)

        let second = try fixture.startHelper("lifecycle-gc")
        try await Task.sleep(for: .milliseconds(100))
        fixture.touch(fixture.release)
        try await fixture.waitForExit(holder)
        XCTAssertEqual(holder.terminationStatus, 0)
        try await fixture.waitForExit(second)
        XCTAssertEqual(second.terminationStatus, 0)
        let store = ModelStore(root: fixture.root)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.revisionURL(for: fixture.second).deletingLastPathComponent().path
            )
        )
    }

    func testConcurrentGarbageCollectionProcessesSerializeOnTheGlobalLock() async throws {
        let fixture = try ProcessFixture()
        let firstReady = fixture.root.appendingPathComponent("first-ready")
        let firstRelease = fixture.root.appendingPathComponent("first-release")
        try fixture.prepareLifecycleFixture()
        let first = try fixture.startHelper(
            "lifecycle-gc-hold",
            firstReady.path,
            firstRelease.path,
            fixture.second
        )
        try await fixture.waitForMarker(firstReady, process: first)
        let second = try fixture.startHelper("lifecycle-gc")
        defer {
            if first.isRunning { fixture.terminate(first) }
            if second.isRunning { fixture.terminate(second) }
            fixture.remove()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(second.isRunning)

        fixture.touch(firstRelease)
        try await fixture.waitForExit(first)
        XCTAssertEqual(first.terminationStatus, 0)
        try await fixture.waitForExit(second)
        XCTAssertEqual(second.terminationStatus, 0)

        let store = ModelStore(root: fixture.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.revisionURL(for: fixture.second).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.revisionURL(for: fixture.third).path))
        XCTAssertEqual(try store.readInstalled()?.revisions.map(\.immutableCommit), [fixture.first])
    }

    func testSIGKILLReleasesRuntimeSharedLeaseForLaterGarbageCollection() async throws {
        let fixture = try ProcessFixture()
        try fixture.prepareLifecycleFixture()
        let holder = try fixture.startHelper(
            "lifecycle-runtime-hold",
            fixture.ready.path,
            fixture.release.path
        )
        defer {
            if holder.isRunning { fixture.terminate(holder) }
            fixture.remove()
        }
        try await fixture.waitForMarker(fixture.ready, process: holder)

        XCTAssertEqual(kill(holder.processIdentifier, SIGKILL), 0)
        try await fixture.waitForExit(holder)
        XCTAssertEqual(holder.terminationStatus, SIGKILL)
        let coordinator = try ModelLifecycleCoordinator(
            testingManifest: fixture.manifest(for: fixture.first),
            store: ModelStore(root: fixture.root)
        )
        _ = try await coordinator.activate(immutableCommit: fixture.second, verifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try await coordinator.activate(immutableCommit: fixture.third, verifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let result = try await coordinator.garbageCollect()
        XCTAssertTrue(result.deleted.contains(fixture.first))
    }

    func testActivationWriterFailurePreservesSelectionBytes() async throws {
        let fixture = try Fixture(writer: AtomicStateWriter(failureInjector: { $0 == .rename }))
        defer { fixture.remove() }
        try fixture.writeInstalled([fixture.revision(fixture.first), fixture.revision(fixture.second)])
        try fixture.writeSelection(current: fixture.first, prior: nil, writer: AtomicStateWriter())
        let before = try Data(contentsOf: fixture.store.selectionURL)

        do {
            _ = try await fixture.coordinator().activate(immutableCommit: fixture.second, verifiedAt: fixture.date)
            XCTFail("expected selection writer failure")
        } catch let error as ModelLifecycleError {
            XCTAssertEqual(error, .selectionWriteFailed)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.store.selectionURL), before)
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let store: ModelStore
        let leases: ModelRevisionLeaseManager
        let lifecycleLock: InProcessModelStoreLock
        let manifest: ModelManifest
        let first = String(repeating: "a", count: 40)
        let second = String(repeating: "b", count: 40)
        let third = String(repeating: "c", count: 40)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        init(writer: AtomicStateWriter = AtomicStateWriter()) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-lifecycle-\(UUID().uuidString)", isDirectory: true)
            store = ModelStore(root: root, writer: writer)
            manifest = ModelManifest(
                testFiles: [("Preprocessor.mlmodelc/metadata.json", Data("fixture".utf8))],
                baseURL: "https://fixture.invalid/model",
                immutableCommit: first
            )
            try store.prepareDirectories()
            leases = try ModelRevisionLeaseManager(store: store)
            lifecycleLock = InProcessModelStoreLock()
            for commit in [first, second, third] {
                let file = store.revisionURL(for: commit).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: file)
            }
        }

        func revision(_ commit: String) -> InstalledRevision {
            InstalledRevision(immutableCommit: commit, modelId: manifest.modelId, variantId: manifest.variantId, verifiedAt: date)
        }

        func writeInstalled(_ revisions: [InstalledRevision], writer: AtomicStateWriter = AtomicStateWriter()) throws {
            try writer.write(InstalledState(modelId: manifest.modelId, variantId: manifest.variantId, revisions: revisions), to: store.installedURL)
        }

        func writeSelection(current: String, prior: String?, writer: AtomicStateWriter = AtomicStateWriter()) throws {
            try writer.write(SelectionState(modelId: manifest.modelId, variantId: manifest.variantId, currentRevision: current, priorRevision: prior, verifiedAt: date), to: store.selectionURL)
        }

        func coordinator(hook: ModelLifecycleHook? = nil) throws -> ModelLifecycleCoordinator {
            try ModelLifecycleCoordinator(
                unvalidatedManifestForTesting: manifest,
                store: store,
                lock: lifecycleLock,
                hook: hook
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private enum ReplacementTarget: CaseIterable {
    case root
    case models
    case revisions
    case candidate

    func url(root: URL, models: URL, revisions: URL, candidate: String) -> URL {
        switch self {
        case .root:
            return root
        case .models:
            return models
        case .revisions:
            return revisions
        case .candidate:
            return revisions.appendingPathComponent(candidate)
        }
    }
}

private final class ProcessFixture: @unchecked Sendable {
    let root: URL
    let ready: URL
    let release: URL
    let first = String(repeating: "a", count: 40)
    let second = String(repeating: "b", count: 40)
    let third = String(repeating: "c", count: 40)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let manifestData = Data("fixture".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-lifecycle-process-\(UUID().uuidString)", isDirectory: true)
        ready = root.appendingPathComponent("ready")
        release = root.appendingPathComponent("release")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func manifest(for commit: String) -> ModelManifest {
        ModelManifest(
            testingFiles: [("Preprocessor.mlmodelc/metadata.json", manifestData)],
            baseURL: "https://fixture.invalid/model",
            immutableCommit: commit
        )
    }

    func prepareLifecycleFixture() throws {
        let store = ModelStore(root: root)
        try store.prepareDirectories()
        for commit in [first, second, third] {
            let file = store.revisionURL(for: commit).appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manifestData.write(to: file)
        }
        _ = try store.recordVerifiedRevision(manifest: manifest(for: first), verifiedAt: date)
        _ = try store.recordVerifiedRevision(manifest: manifest(for: second), verifiedAt: date)
        _ = try store.recordVerifiedRevision(manifest: manifest(for: third), verifiedAt: date)
        _ = try store.activate(manifest: manifest(for: first), verifiedAt: date)
    }

    func startHelper(_ mode: String, _ arguments: String...) throws -> Process {
        try startHelper(mode, arguments: arguments)
    }

    private func startHelper(_ mode: String, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = try helperURL()
        process.arguments = [mode, root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    func runHelper(_ mode: String, _ arguments: String...) async throws -> Int32 {
        let process = try startHelper(mode, arguments: arguments)
        try await waitForExit(process)
        return process.terminationStatus
    }

    func waitForMarker(_ marker: URL, process: Process) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard process.isRunning else { throw TestSynchronizationError.timeout }
            guard ContinuousClock.now < deadline else {
                terminate(process)
                throw TestSynchronizationError.timeout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func waitForExit(_ process: Process) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                terminate(process)
                throw TestSynchronizationError.timeout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func terminate(_ process: Process) {
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }

    func touch(_ url: URL) {
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    func helperURL() throws -> URL {
        let bundle = Bundle(for: ModelLifecycleTests.self).bundleURL
        var directory = bundle.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("LockHelper")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        throw TestSynchronizationError.timeout
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private enum TestSynchronizationError: Error, Equatable {
    case timeout
}

private actor LifecycleRaceHook {
    private var signaled = false
    private var released = false

    func signal() {
        signaled = true
    }

    func waitForSignal() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !signaled {
            guard ContinuousClock.now < deadline else { throw TestSynchronizationError.timeout }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func waitForRelease() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !released {
            guard ContinuousClock.now < deadline else { throw TestSynchronizationError.timeout }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() {
        released = true
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard value else { return false }
        value = false
        return true
    }
}

private final class OperationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let failAt: Int
    private var count = 0

    init(failAt: Int) {
        self.failAt = failAt
    }

    func shouldFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count == failAt
    }
}
