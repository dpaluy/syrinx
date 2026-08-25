import Darwin
import Foundation
import XCTest
@_spi(Testing) import SyrinxCore
@testable import SyrinxCore

final class NativeTranscriptionEngineTests: XCTestCase {
    func testReadinessProbeIsPrivateAndBoundedUnder022Umask() throws {
        let oldMask = umask(0o022)
        defer { _ = umask(oldMask) }

        let root = FileManager.default.temporaryDirectory
        let leaf = "syrinx-readiness-test-\(UUID().uuidString)"
        let probe = try SelfGeneratedReadinessProbe(root: root, leafName: leaf, fileName: "probe.wav")
        defer { probe.remove() }

        var directoryStatus = stat()
        XCTAssertEqual(lstat(probe.directoryURL.path, &directoryStatus), 0)
        XCTAssertEqual(directoryStatus.st_mode & S_IFMT, mode_t(S_IFDIR))
        XCTAssertEqual(directoryStatus.st_mode & 0o777, 0o700)

        var fileStatus = stat()
        XCTAssertEqual(lstat(probe.fileURL.path, &fileStatus), 0)
        XCTAssertEqual(fileStatus.st_mode & S_IFMT, mode_t(S_IFREG))
        XCTAssertEqual(fileStatus.st_mode & 0o777, 0o600)
        XCTAssertEqual(fileStatus.st_size, 3_244)
        XCTAssertLessThanOrEqual(fileStatus.st_size, 4_096)
    }

    func testReadinessProbeConstructionFailureRemovesItsLeaf() {
        let root = FileManager.default.temporaryDirectory
        let leaf = "syrinx-readiness-failure-\(UUID().uuidString)"
        let leafURL = root.appendingPathComponent(leaf, isDirectory: true)

        XCTAssertThrowsError(
            try SelfGeneratedReadinessProbe(
                root: root,
                leafName: leaf,
                fileName: "missing/probe.wav"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: leafURL.path))
    }

    func testAdmissionGateIsFIFOCancellationSafeAndExact() async throws {
        let gate = TranscriptionAdmissionGate()
        let first = try await gate.acquire(until: nil)
        let second = Task { try await gate.acquire(until: nil) }
        let third = Task { try await gate.acquire(until: nil) }

        second.cancel()
        do {
            _ = try await second.value
            XCTFail("expected waiter cancellation")
        } catch is CancellationError {
            XCTAssertTrue(true)
        }

        await gate.release(AdmissionPermit(id: first.id + 99))
        try await Task.sleep(for: .milliseconds(20))

        await gate.release(first)
        let thirdPermit = try await third.value
        XCTAssertGreaterThan(thirdPermit.id, first.id)
        await gate.release(thirdPermit)
        await gate.waitForZero()
    }

    func testAdmissionGateDeadlineAndDrainRejectQueuedWaiters() async throws {
        let gate = TranscriptionAdmissionGate()
        let first = try await gate.acquire(until: nil)
        let deadlineWaiter = Task {
            try await gate.acquire(until: ContinuousClock.now.advanced(by: .milliseconds(10)))
        }
        do {
            _ = try await deadlineWaiter.value
            XCTFail("expected waiter deadline")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTFail("gate should classify its marker at the engine boundary: \(diagnostic)")
        } catch is DeadlineMarker {
            XCTAssertTrue(true)
        }

        let drainingWaiter = Task { try await gate.acquire(until: nil) }
        await gate.beginDrain()
        do {
            _ = try await drainingWaiter.value
            XCTFail("expected drain rejection")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .draining)
        }
        await gate.release(first)
        await gate.waitForZero()
        let isDraining = await gate.isDraining
        XCTAssertTrue(isDraining)
        await gate.resetAfterDrain()
        let isReset = await gate.isDraining
        XCTAssertFalse(isReset)
        let resetPermit = try await gate.acquire(until: nil)
        await gate.release(resetPermit)
        await gate.waitForZero()
    }

    func testAdmissionGateReleasesPermitWhenCancelledImmediatelyAfterGrant() async throws {
        let target = CancellationTarget()
        let gate = TranscriptionAdmissionGate(afterPermitResume: {
            target.cancel()
        })
        let first = try await gate.acquire(until: nil)
        let cancelledWaiter = Task { try await gate.acquire(until: nil) }
        let nextWaiter = Task { try await gate.acquire(until: nil) }
        target.set(cancel: { cancelledWaiter.cancel() })
        try await Task.sleep(for: .milliseconds(10))

        await gate.release(first)

        do {
            _ = try await cancelledWaiter.value
            XCTFail("expected cancellation after grant")
        } catch is CancellationError {
            XCTAssertTrue(true)
        }
        let nextPermit = try await nextWaiter.value
        XCTAssertNotEqual(nextPermit, first)
        await gate.release(nextPermit)
        await gate.waitForZero()
    }

    func testAdmissionGateFastGrantReleaseStressHasNoLostWakeup() async throws {
        let gate = TranscriptionAdmissionGate()
        for _ in 0..<100 {
            let first = try await gate.acquire(until: nil)
            let waiter = Task { try await gate.acquire(until: nil) }
            try await Task.sleep(for: .milliseconds(1))
            await gate.release(first)
            let next = try await waiter.value
            await gate.release(next)
        }
        await gate.waitForZero()
    }

    func testEngineCancellationWhileQueuedDoesNotReachOpen() async throws {
        let fixture = try EngineFixture()
        let actualLatch = CleanupLatch()
        let recorder = PhaseRecorder()
        let engine = try fixture.engine(
            transcriber: EngineFakeTranscriber(blockActual: true, actualBlockSignal: actualLatch),
            hooks: TranscriptionPipelineHooks(
                afterAdmission: { recorder.append("admission") },
                beforeOpen: { recorder.append("open") }
            )
        )
        try await engine.start()
        recorder.reset()
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }

        let first = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 5)) }
        let firstStarted = await actualLatch.waitForStart(within: .seconds(1))
        XCTAssertTrue(firstStarted)
        let second = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 5)) }
        try await Task.sleep(for: .milliseconds(10))
        second.cancel()
        do {
            _ = try await second.value
            XCTFail("expected queued cancellation")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .cancelled)
        }
        XCTAssertEqual(recorder.values, ["admission", "open"])
        actualLatch.release()
        _ = try await first.value
        XCTAssertFalse(actualLatch.didTimeOut)
        let drain = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drain, .completed)
    }

    func testEngineDeadlineWhileQueuedDoesNotReachOpen() async throws {
        let fixture = try EngineFixture()
        let actualLatch = CleanupLatch()
        let recorder = PhaseRecorder()
        let engine = try fixture.engine(
            transcriber: EngineFakeTranscriber(blockActual: true, actualBlockSignal: actualLatch),
            hooks: TranscriptionPipelineHooks(
                afterAdmission: { recorder.append("admission") },
                beforeOpen: { recorder.append("open") }
            )
        )
        try await engine.start()
        recorder.reset()
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }

        let first = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 5)) }
        let firstStarted = await actualLatch.waitForStart(within: .seconds(1))
        XCTAssertTrue(firstStarted)
        let second = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 0.01)) }
        do {
            _ = try await second.value
            XCTFail("expected queued deadline")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .deadlineExceeded)
        }
        XCTAssertEqual(recorder.values, ["admission", "open"])
        actualLatch.release()
        _ = try await first.value
        XCTAssertFalse(actualLatch.didTimeOut)
        let drain = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drain, .completed)
    }

    func testEngineCancellationIsObservedAtEveryAdmittedPhaseAndCleanup() async throws {
        for phase in ["open", "riff", "metadata", "conversion", "inference", "cleanup"] {
            let iterations = phase == "cleanup" ? 20 : 1
            for _ in 0..<iterations {
                let fixture = try EngineFixture()
                let latch = CleanupLatch()
                let engine = try fixture.engine(hooks: cancellationPhaseHooks(phase: phase, latch: latch))
                try await engine.start()
                latch.arm()
                let source = try makeToneWAV(frameCount: 1_600)
                defer { try? FileManager.default.removeItem(at: source) }

                let task = Task {
                    try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 5))
                }
                let phaseStarted = await latch.waitForStart(within: .seconds(1))
                XCTAssertTrue(phaseStarted, "phase \(phase) did not start")
                task.cancel()
                latch.release()
                do {
                    _ = try await task.value
                    XCTFail("expected cancellation at phase \(phase)")
                } catch let diagnostic as TranscriptionDiagnostic {
                    XCTAssertEqual(diagnostic.code, .cancelled, "phase \(phase)")
                }
                XCTAssertFalse(latch.didTimeOut, "phase \(phase) barrier timed out")
                let drain = await engine.drain(timeout: .seconds(1))
                XCTAssertEqual(drain, .completed)
            }
        }
    }

    func testEngineUsesExactPipelineOrderAndSecondRequestWaitsBeforeOpen() async throws {
        let fixture = try EngineFixture()
        let recorder = PhaseRecorder()
        let actualLatch = CleanupLatch()
        let transcriber = EngineFakeTranscriber(blockActual: true, actualBlockSignal: actualLatch)
        let engine = try fixture.engine(
            transcriber: transcriber,
            hooks: TranscriptionPipelineHooks(
                afterAdmission: { recorder.append("admission") },
                beforeOpen: { recorder.append("beforeOpen") },
                afterOpen: { recorder.append("afterOpen") },
                beforeRIFF: { recorder.append("riff") },
                beforeMetadata: { recorder.append("metadata") },
                beforeConversion: { recorder.append("conversion") },
                beforeInference: { recorder.append("inference") },
                afterCleanup: { recorder.append("cleanup") }
            )
        )
        try await engine.start()
        recorder.reset()

        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }
        let first = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source)) }
        let started = await actualLatch.waitForStart(within: .seconds(1))
        XCTAssertTrue(started)
        let expected = ["admission", "beforeOpen", "afterOpen", "riff", "metadata", "conversion", "inference"]
        XCTAssertEqual(recorder.values, expected)

        let second = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source)) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(recorder.values, expected)

        actualLatch.release()
        _ = try await first.value
        _ = try await second.value
        XCTAssertFalse(actualLatch.didTimeOut)
        XCTAssertEqual(recorder.values, expected + ["cleanup", "admission", "beforeOpen", "afterOpen", "riff", "metadata", "conversion", "inference", "cleanup"])
        let drainResult = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drainResult, .completed)
    }

    func testEngineResultUsesPreparedDurationRevisionAndConfiguredModel() async throws {
        let fixture = try EngineFixture()
        let transcriber = EngineFakeTranscriber(backendDuration: 999)
        let engine = try fixture.engine(transcriber: transcriber)
        try await engine.start()
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }

        let result = try await engine.transcribe(TranscriptionRequest(audioFile: source))
        XCTAssertEqual(result.text, "backend")
        XCTAssertEqual(result.duration, 0.1, accuracy: 0.000_1)
        XCTAssertEqual(result.modelID, ServiceConfiguration.defaultModelID)
        XCTAssertEqual(result.canonicalModelID, ServiceConfiguration.defaultModelID)
        XCTAssertEqual(result.modelRevision, fixture.commit)
        let drainResult = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drainResult, .completed)
    }

    func testEngineCleanupHookRunsForBackendFailureAndDeadlineAfterBackendReturns() async throws {
        let fixture = try EngineFixture()
        let recorder = PhaseRecorder()
        let transcriber = EngineFakeTranscriber(backendError: true, sleepSeconds: 0.05)
        let engine = try fixture.engine(
            transcriber: transcriber,
            hooks: TranscriptionPipelineHooks(afterCleanup: { recorder.append("cleanup") })
        )
        try await engine.start()
        recorder.reset()
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            _ = try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 1))
            XCTFail("expected backend failure")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .runtimeUnavailable)
        }
        XCTAssertEqual(recorder.values, ["cleanup"])

        await transcriber.setMode(backendError: false, sleepSeconds: 0.05)
        recorder.reset()
        let started = ContinuousClock.now
        do {
            _ = try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 0.01))
            XCTFail("expected deadline")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .deadlineExceeded)
        }
        let elapsed = started.duration(to: .now)
        let elapsedMilliseconds = durationMilliseconds(elapsed)
        XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 40)
        XCTAssertEqual(recorder.values, ["cleanup"])
        let drainResult = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drainResult, .completed)
    }

    func testDeadlineWinnerWaitsForCleanupBeforeAdmissionReuse() async throws {
        let fixture = try EngineFixture()
        let recorder = PhaseRecorder()
        let backendSignal = BusyWaitSignal()
        let cleanupLatch = CleanupLatch()
        let transcriber = EngineFakeTranscriber(
            sleepSeconds: 0.06,
            busyWaitSignal: backendSignal
        )
        let engine = try fixture.engine(
            transcriber: transcriber,
            hooks: TranscriptionPipelineHooks(
                afterAdmission: { recorder.append("admission") },
                beforeOpen: { recorder.append("open") },
                beforeInference: { recorder.append("inference") },
                afterCleanup: {
                    recorder.append("cleanup")
                    if cleanupLatch.isArmed {
                        cleanupLatch.markStarted()
                        if !cleanupLatch.waitForRelease(within: .seconds(2)) {
                            cleanupLatch.markTimedOut()
                        }
                    }
                }
            )
        )
        try await engine.start()
        recorder.reset()
        cleanupLatch.arm()
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }

        let first = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 0.01)) }
        let started = await backendSignal.waitForStart(within: .seconds(1))
        XCTAssertTrue(started)
        let second = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 1)) }
        let cleanupStarted = await cleanupLatch.waitForStart(within: .seconds(1))
        XCTAssertTrue(cleanupStarted)
        XCTAssertEqual(recorder.values, ["admission", "open", "inference", "cleanup"])

        cleanupLatch.release()
        do {
            _ = try await first.value
            XCTFail("expected deadline")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .deadlineExceeded)
        }
        XCTAssertFalse(cleanupLatch.didTimeOut)
        _ = try await second.value
        XCTAssertEqual(recorder.values, [
            "admission", "open", "inference", "cleanup",
            "admission", "open", "inference", "cleanup"
        ])
        let drained = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drained, .completed)
    }

    func testDeadlinesAreObservedAtEachSynchronousPhaseBoundary() async throws {
        let phases = ["open", "riff", "metadata", "conversion", "inference"]
        for phase in phases {
            let fixture = try EngineFixture()
            let engine = try fixture.engine(
                hooks: TranscriptionPipelineHooks(
                    beforeOpen: blockingPhaseHook(phase, name: "open"),
                    beforeRIFF: blockingPhaseHook(phase, name: "riff"),
                    beforeMetadata: blockingPhaseHook(phase, name: "metadata"),
                    beforeConversion: blockingPhaseHook(phase, name: "conversion"),
                    beforeInference: blockingPhaseHook(phase, name: "inference")
                )
            )
            try await engine.start()
            let source = try makeToneWAV(frameCount: 1_600)
            defer { try? FileManager.default.removeItem(at: source) }
            do {
                _ = try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 0.01))
                XCTFail("expected deadline at \(phase)")
            } catch let diagnostic as TranscriptionDiagnostic {
                XCTAssertEqual(diagnostic.code, .deadlineExceeded, "phase \(phase)")
            }
            let drained = await engine.drain(timeout: .seconds(1))
            XCTAssertEqual(drained, .completed)
        }
    }

    func testReadinessFailureReleasesLeaseAndDoesNotBecomeReady() async throws {
        let fixture = try EngineFixture()
        let transcriber = EngineFakeTranscriber(failProbe: true)
        let engine = try fixture.engine(transcriber: transcriber)
        do {
            try await engine.start()
            XCTFail("expected readiness failure")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .readinessProbeFailed)
        }
        let readyAfterFailure = await engine.isReady
        XCTAssertFalse(readyAfterFailure)
        let leases = try ModelRevisionLeaseManager(store: fixture.store)
        switch try leases.tryAcquireExclusive(fixture.commit) {
        case .acquired(let lease):
            lease.close()
        case .busy:
            XCTFail("failed startup retained the model lease")
        }
        await transcriber.setMode(backendError: false, sleepSeconds: 0)
        try await engine.start()
        let readyAfterRestart = await engine.isReady
        XCTAssertTrue(readyAfterRestart)
        let drained = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drained, .completed)
    }

    func testDrainDuringNoncooperativeStartupKeepsLeaseUntilStartupReturns() async throws {
        let fixture = try EngineFixture()
        let signal = BusyWaitSignal()
        let transcriber = EngineFakeTranscriber(
            sleepSeconds: 0.08,
            sleepDuringProbe: true,
            busyWaitSignal: signal
        )
        let engine = try fixture.engine(transcriber: transcriber)
        let startup = Task { try await engine.start() }
        let started = await signal.waitForStart(within: .seconds(1))
        XCTAssertTrue(started)
        let timeout = await engine.drain(timeout: .milliseconds(1))
        XCTAssertEqual(timeout, .timedOut)
        let leases = try ModelRevisionLeaseManager(store: fixture.store)
        switch try leases.tryAcquireExclusive(fixture.commit) {
        case .acquired(let lease):
            lease.close()
            XCTFail("startup lease was released before noncooperative startup returned")
        case .busy:
            break
        }
        let finished = await signal.waitForFinish(within: .seconds(1))
        XCTAssertTrue(finished)
        do {
            try await startup.value
            XCTFail("startup should be rejected by drain")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .draining)
        }
        let completed = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(completed, .completed)
        switch try leases.tryAcquireExclusive(fixture.commit) {
        case .acquired(let lease):
            lease.close()
        case .busy:
            XCTFail("startup lease was not released after startup returned")
        }
    }

    func testCancelledStartupWaitsForNoncooperativeReadinessCleanupAndReleasesLease() async throws {
        let fixture = try EngineFixture()
        let signal = BusyWaitSignal()
        let readinessRelease = CleanupLatch()
        let startupReturned = CleanupLatch()
        let transcriber = EngineFakeTranscriber(
            sleepSeconds: 0.08,
            sleepDuringProbe: true,
            busyWaitSignal: signal,
            probeRelease: readinessRelease
        )
        let engine = try fixture.engine(transcriber: transcriber)
        let startup = Task {
            defer { startupReturned.markStarted() }
            try await engine.start()
        }
        defer { readinessRelease.release() }

        let started = await signal.waitForStart(within: .seconds(1))
        XCTAssertTrue(started)
        startup.cancel()
        let reachedReleaseBarrier = await signal.waitForFinish(within: .seconds(1))
        XCTAssertTrue(reachedReleaseBarrier)
        let returnedBeforeCleanup = await startupReturned.waitForStart(within: .milliseconds(20))
        XCTAssertFalse(returnedBeforeCleanup)

        let leases = try ModelRevisionLeaseManager(store: fixture.store)
        let busyBeforeRelease: Bool
        switch try leases.tryAcquireExclusive(fixture.commit) {
        case .acquired(let lease):
            lease.close()
            busyBeforeRelease = false
        case .busy:
            busyBeforeRelease = true
        }
        XCTAssertTrue(busyBeforeRelease)

        readinessRelease.release()
        do {
            try await startup.value
            XCTFail("expected startup cancellation")
        } catch is CancellationError {
            XCTAssertTrue(true)
        }
        let returnedAfterCleanup = await startupReturned.waitForStart(within: .seconds(1))
        XCTAssertTrue(returnedAfterCleanup)
        let ready = await engine.isReady
        XCTAssertFalse(ready)

        switch try leases.tryAcquireExclusive(fixture.commit) {
        case .acquired(let lease):
            lease.close()
        case .busy:
            XCTFail("startup cancellation retained the model lease")
        }
        let drained = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drained, .completed)
    }

    func testCancelledConcurrentStartupWaiterDoesNotCancelSharedStartup() async throws {
        let fixture = try EngineFixture()
        let signal = BusyWaitSignal()
        let readinessRelease = CleanupLatch()
        let waiterReturned = CleanupLatch()
        let transcriber = EngineFakeTranscriber(
            sleepSeconds: 0.08,
            sleepDuringProbe: true,
            busyWaitSignal: signal,
            probeRelease: readinessRelease
        )
        let engine = try fixture.engine(transcriber: transcriber)
        let owner = Task { try await engine.start() }
        defer { readinessRelease.release() }

        let started = await signal.waitForStart(within: .seconds(1))
        XCTAssertTrue(started)
        let waiter = Task {
            defer { waiterReturned.markStarted() }
            try await engine.start()
        }
        try await Task.sleep(for: .milliseconds(10))
        waiter.cancel()
        let returnedBeforeSharedStartup = await waiterReturned.waitForStart(within: .milliseconds(20))
        XCTAssertFalse(returnedBeforeSharedStartup)

        readinessRelease.release()
        try await owner.value
        do {
            try await waiter.value
            XCTFail("expected concurrent waiter cancellation")
        } catch is CancellationError {
            XCTAssertTrue(true)
        }
        let returnedAfterSharedStartup = await waiterReturned.waitForStart(within: .seconds(1))
        XCTAssertTrue(returnedAfterSharedStartup)
        let ready = await engine.isReady
        XCTAssertTrue(ready)
        let drained = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drained, .completed)
    }

    func testEngineExternalCancellationWaitsForNoncooperativeBackendCleanup() async throws {
        let fixture = try EngineFixture()
        let recorder = PhaseRecorder()
        let signal = BusyWaitSignal()
        let transcriber = EngineFakeTranscriber(sleepSeconds: 0.06, busyWaitSignal: signal)
        let engine = try fixture.engine(
            transcriber: transcriber,
            hooks: TranscriptionPipelineHooks(afterCleanup: { recorder.append("cleanup") })
        )
        try await engine.start()
        recorder.reset()
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }
        let task = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 5)) }
        let started = await signal.waitForStart(within: .seconds(1))
        XCTAssertTrue(started)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .cancelled)
        }
        let finished = await signal.waitForFinish(within: .seconds(1))
        XCTAssertTrue(finished)
        let elapsed = cancelledAt.duration(to: ContinuousClock.now)
        let elapsedMilliseconds = durationMilliseconds(elapsed)
        XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 40)
        XCTAssertEqual(recorder.values, ["cleanup"])
        let drainResult = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drainResult, .completed)
    }

    func testEngineOperationCancellationErrorMapsToCancelledAfterCleanup() async throws {
        let fixture = try EngineFixture()
        let recorder = PhaseRecorder()
        let engine = try fixture.engine(
            transcriber: EngineFakeTranscriber(cancelActual: true),
            hooks: TranscriptionPipelineHooks(afterCleanup: { recorder.append("cleanup") })
        )
        try await engine.start()
        recorder.reset()
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            _ = try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 5))
            XCTFail("expected backend cancellation")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .cancelled)
        }
        XCTAssertEqual(recorder.values, ["cleanup"])
        let drain = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drain, .completed)
    }

    func testEngineDrainFastCompletionAllowsRestart() async throws {
        let fixture = try EngineFixture()
        let loader = EngineRuntimeLoader(transcriber: EngineFakeTranscriber())
        let engine = try fixture.engine(loader: loader)
        try await engine.start()
        for _ in 0..<20 {
            let result = await engine.drain(timeout: .seconds(1))
            XCTAssertEqual(result, .completed)
            try await engine.start()
        }
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 21)
        let isDraining = await engine.testingIsDraining()
        XCTAssertFalse(isDraining)
        let drainResult = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drainResult, .completed)
    }

    func testUploadedFileUsesPinnedDescriptorAndCanonicalModelBoundary() async throws {
        let fixture = try EngineFixture()
        let engine = try fixture.engine()
        try await engine.start()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-upload-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var parser = try MultipartUploadParser(boundary: "Pinned", temporaryRoot: root)
        let audio = try makeToneWAV(frameCount: 1_600)
        let bytes = try Data(contentsOf: audio)
        let body = Data("--Pinned\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            + bytes
            + Data("\r\n--Pinned--\r\n".utf8)
        try parser.consume(body)
        let upload = try parser.finish()
        defer { upload.cleanup() }
        let outside = root.appendingPathComponent("outside.wav")
        try bytes.write(to: outside)
        try FileManager.default.removeItem(at: upload.file.url)
        try FileManager.default.createSymbolicLink(at: upload.file.url, withDestinationURL: outside)

        do {
            _ = try await engine.transcribe(uploadedFile: upload.file, modelID: "parakeet-tdt-0.6b-v3")
        } catch {
            XCTFail("pinned descriptor transcription failed: \(error)")
        }
        do {
            _ = try await engine.transcribe(uploadedFile: upload.file, modelID: "parakeet-tdt-0.6b")
            XCTFail("expected canonical model mismatch")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .inputRejected)
        }
        upload.cleanup()
        XCTAssertTrue(upload.file.isClosedForHandoff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: upload.file.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        let drainResult = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drainResult, .completed)
    }

    func testEngineRejectsBeforeReadyAndWhileDraining() async throws {
        let fixture = try EngineFixture()
        let actualLatch = CleanupLatch()
        let transcriber = EngineFakeTranscriber(blockActual: true, actualBlockSignal: actualLatch)
        let engine = try fixture.engine(transcriber: transcriber)
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            _ = try await engine.transcribe(TranscriptionRequest(audioFile: source))
            XCTFail("expected not-ready rejection")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .runtimeUnavailable)
        }

        try await engine.start()
        let work = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 5)) }
        let started = await actualLatch.waitForStart(within: .seconds(1))
        XCTAssertTrue(started)
        let timedOut = await engine.drain(timeout: .milliseconds(1))
        XCTAssertEqual(timedOut, .timedOut)
        do {
            _ = try await engine.transcribe(TranscriptionRequest(audioFile: source))
            XCTFail("expected draining rejection")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .draining)
        }
        actualLatch.release()
        _ = try await work.value
        XCTAssertFalse(actualLatch.didTimeOut)
        let completed = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(completed, .completed)
        try await engine.start()
        let isReady = await engine.isReady
        XCTAssertTrue(isReady)
        let restartedDrain = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(restartedDrain, .completed)
    }

    func testEngineDrainWaitersCompleteAfterTimeoutAndFastCompletion() async throws {
        let fixture = try EngineFixture()
        let actualLatch = CleanupLatch()
        let transcriber = EngineFakeTranscriber(blockActual: true, actualBlockSignal: actualLatch)
        let engine = try fixture.engine(transcriber: transcriber)
        try await engine.start()

        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }
        let work = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 5)) }
        let started = await actualLatch.waitForStart(within: .seconds(1))
        XCTAssertTrue(started)
        let first = Task { await engine.drain(timeout: .milliseconds(1)) }
        let second = Task { await engine.drain(timeout: .seconds(1)) }
        let third = Task { await engine.drain(timeout: .seconds(1)) }
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .timedOut)
        actualLatch.release()
        _ = try await work.value
        XCTAssertFalse(actualLatch.didTimeOut)
        let secondResult = await second.value
        let thirdResult = await third.value
        XCTAssertEqual(secondResult, .completed)
        XCTAssertEqual(thirdResult, .completed)
        let isDraining = await engine.testingIsDraining()
        XCTAssertFalse(isDraining)
    }

    func testCancelledDrainWaiterDoesNotLeakContinuationAndLeavesDrainActive() async throws {
        let fixture = try EngineFixture()
        let actualLatch = CleanupLatch()
        let engine = try fixture.engine(
            transcriber: EngineFakeTranscriber(blockActual: true, actualBlockSignal: actualLatch)
        )
        try await engine.start()
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }
        let work = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 5)) }
        let started = await actualLatch.waitForStart(within: .seconds(1))
        XCTAssertTrue(started)

        let cancelledDrain = Task { await engine.drain(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(10))
        cancelledDrain.cancel()
        let cancelledResult = await cancelledDrain.value
        XCTAssertEqual(cancelledResult, .timedOut)
        let stillDraining = await engine.testingIsDraining()
        XCTAssertTrue(stillDraining)

        actualLatch.release()
        _ = try await work.value
        XCTAssertFalse(actualLatch.didTimeOut)
        let completed = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(completed, .completed)
    }

    func testEngineDrainFastCompletionStressRemainsBounded() async throws {
        let fixture = try EngineFixture()
        let loader = EngineRuntimeLoader(transcriber: EngineFakeTranscriber())
        let engine = try fixture.engine(loader: loader)
        try await engine.start()
        for _ in 0..<20 {
            let result = await engine.drain(timeout: .seconds(1))
            XCTAssertEqual(result, .completed)
            try await engine.start()
        }
        let loadCount = await loader.loadCount
        XCTAssertEqual(loadCount, 21)
        let isDraining = await engine.testingIsDraining()
        XCTAssertFalse(isDraining)
        let finalDrain = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(finalDrain, .completed)
    }

    func testEngineLeaseBlocksCoordinatorGCWhileReadyAndActiveUntilDrain() async throws {
        let fixture = try EngineFixture()
        let actualLatch = CleanupLatch()
        let transcriber = EngineFakeTranscriber(blockActual: true, actualBlockSignal: actualLatch)
        let engine = try fixture.engine(transcriber: transcriber)
        try await engine.start()
        let coordinator = try fixture.coordinator()
        _ = try await coordinator.activate(immutableCommit: fixture.secondCommit)
        _ = try await coordinator.activate(immutableCommit: fixture.thirdCommit)

        let whileReady = try await coordinator.garbageCollect()
        XCTAssertTrue(whileReady.skipped.contains(.busy(fixture.commit)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.commit).path))

        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }
        let work = Task { try await engine.transcribe(TranscriptionRequest(audioFile: source, deadline: 5)) }
        let started = await actualLatch.waitForStart(within: .seconds(1))
        XCTAssertTrue(started)
        let whileActive = try await coordinator.garbageCollect()
        XCTAssertTrue(whileActive.skipped.contains(.busy(fixture.commit)))
        actualLatch.release()
        _ = try await work.value
        XCTAssertFalse(actualLatch.didTimeOut)
        let drained = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drained, .completed)
        let afterDrain = try await coordinator.garbageCollect()
        XCTAssertTrue(afterDrain.deleted.contains(fixture.commit))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.revisionURL(for: fixture.commit).path))
    }

    func testEngineStartupUsesPinnedRevisionWhenActivationWaitsOnLifecycleLock() async throws {
        let fixture = try EngineFixture()
        let gate = AsyncTestGate()
        let engine = try fixture.engine(lifecycleHook: { event in
            if event == .afterRuntimeValidation(fixture.commit) {
                await gate.open()
                let released = await gate.waitForRelease(within: .seconds(2))
                if !released { await gate.recordTimeout() }
            }
        })

        let start = Task { try await engine.start() }
        let opened = await gate.waitForOpen(within: .seconds(1))
        XCTAssertTrue(opened)
        let activation = Task {
            try await fixture.coordinator().activate(immutableCommit: fixture.secondCommit)
        }
        await gate.release()

        try await start.value
        let selection = try await activation.value
        let gateTimedOut = await gate.didTimeOut
        XCTAssertFalse(gateTimedOut)
        XCTAssertEqual(selection.currentRevision, fixture.secondCommit)
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }
        let result = try await engine.transcribe(TranscriptionRequest(audioFile: source))
        XCTAssertEqual(result.modelRevision, fixture.commit)
        XCTAssertEqual(result.modelID, ServiceConfiguration.defaultModelID)
        let drain = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drain, .completed)
    }

    func testEngineStartupUsesPinnedRevisionWhenRollbackWaitsOnLifecycleLock() async throws {
        let fixture = try EngineFixture()
        _ = try await fixture.coordinator().activate(immutableCommit: fixture.secondCommit)
        let gate = AsyncTestGate()
        let engine = try fixture.engine(lifecycleHook: { event in
            if event == .afterRuntimeValidation(fixture.secondCommit) {
                await gate.open()
                let released = await gate.waitForRelease(within: .seconds(2))
                if !released { await gate.recordTimeout() }
            }
        })

        let start = Task { try await engine.start() }
        let opened = await gate.waitForOpen(within: .seconds(1))
        XCTAssertTrue(opened)
        let rollback = Task { try await fixture.coordinator().rollback() }
        await gate.release()

        try await start.value
        let selection = try await rollback.value
        let gateTimedOut = await gate.didTimeOut
        XCTAssertFalse(gateTimedOut)
        XCTAssertEqual(selection.currentRevision, fixture.commit)
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }
        let result = try await engine.transcribe(TranscriptionRequest(audioFile: source))
        XCTAssertEqual(result.modelRevision, fixture.secondCommit)
        let drain = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drain, .completed)
    }

    func testEngineStartupSerializesWithGarbageCollectionAndKeepsSelectedRevision() async throws {
        let fixture = try EngineFixture()
        let gate = AsyncTestGate()
        let engine = try fixture.engine(lifecycleHook: { event in
            if event == .afterRuntimeValidation(fixture.commit) {
                await gate.open()
                let released = await gate.waitForRelease(within: .seconds(2))
                if !released { await gate.recordTimeout() }
            }
        })

        let start = Task { try await engine.start() }
        let opened = await gate.waitForOpen(within: .seconds(1))
        XCTAssertTrue(opened)
        let garbageCollection = Task { try await fixture.coordinator().garbageCollect() }
        await gate.release()

        try await start.value
        let collected = try await garbageCollection.value
        let gateTimedOut = await gate.didTimeOut
        XCTAssertFalse(gateTimedOut)
        XCTAssertTrue(collected.deleted.contains(fixture.secondCommit))
        XCTAssertTrue(collected.deleted.contains(fixture.thirdCommit))
        let source = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: source) }
        let result = try await engine.transcribe(TranscriptionRequest(audioFile: source))
        XCTAssertEqual(result.modelRevision, fixture.commit)
        let drain = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drain, .completed)
    }

    func testEngineRejectsMalformedAndOverDurationBeforeBackendForURLAndDescriptor() async throws {
        let fixture = try EngineFixture()
        let transcriber = EngineFakeTranscriber()
        let engine = try fixture.engine(transcriber: transcriber)
        try await engine.start()
        let callsAfterStart = await transcriber.callCount

        let malformed = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-malformed-\(UUID().uuidString).wav")
        try Data("not-wav".utf8).write(to: malformed)
        defer { try? FileManager.default.removeItem(at: malformed) }
        do {
            _ = try await engine.transcribe(TranscriptionRequest(audioFile: malformed))
            XCTFail("expected malformed input rejection")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .inputRejected)
        }
        let callsAfterMalformed = await transcriber.callCount
        XCTAssertEqual(callsAfterMalformed, callsAfterStart)

        let exact = try makeToneWAV(frameCount: 32_000)
        defer { try? FileManager.default.removeItem(at: exact) }
        _ = try await engine.transcribe(TranscriptionRequest(audioFile: exact))
        let callsAfterExact = await transcriber.callCount
        XCTAssertEqual(callsAfterExact, callsAfterStart + 1)

        let uploadRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-over-duration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: uploadRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: uploadRoot) }
        var parser = try MultipartUploadParser(boundary: "Limit", temporaryRoot: uploadRoot)
        let over = try makeToneWAV(frameCount: 32_001)
        defer { try? FileManager.default.removeItem(at: over) }
        let overBytes = try Data(contentsOf: over)
        let body = Data("--Limit\r\nContent-Disposition: form-data; name=\"file\"; filename=\"over.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
            + overBytes
            + Data("\r\n--Limit--\r\n".utf8)
        try parser.consume(body)
        let upload = try parser.finish()
        defer { upload.cleanup() }
        do {
            _ = try await engine.transcribe(uploadedFile: upload.file, modelID: ServiceConfiguration.defaultModelID)
            XCTFail("expected descriptor duration rejection")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .inputRejected)
        }
        let callsAfterOver = await transcriber.callCount
        XCTAssertEqual(callsAfterOver, callsAfterExact)
        let drained = await engine.drain(timeout: .seconds(1))
        XCTAssertEqual(drained, .completed)
    }

    func testEngineEnforcesExactAndOneOverByteAndDurationBoundariesBeforeBackend() async throws {
        let byteFixture = try EngineFixture()
        let byteTranscriber = EngineFakeTranscriber()
        let byteEngine = try byteFixture.engine(
            transcriber: byteTranscriber,
            maxUploadBytes: 3_244
        )
        try await byteEngine.start()
        let exactBytes = try makeToneWAV(frameCount: 1_600)
        defer { try? FileManager.default.removeItem(at: exactBytes) }
        _ = try await byteEngine.transcribe(TranscriptionRequest(audioFile: exactBytes))
        let callsAfterExact = await byteTranscriber.callCount
        XCTAssertEqual(callsAfterExact, 2)

        let oneOverBytes = FileManager.default.temporaryDirectory
            .appendingPathComponent("syrinx-one-over-bytes-\(UUID().uuidString).wav")
        var bytes = try Data(contentsOf: exactBytes)
        bytes.append(0)
        try bytes.write(to: oneOverBytes)
        defer { try? FileManager.default.removeItem(at: oneOverBytes) }
        do {
            _ = try await byteEngine.transcribe(TranscriptionRequest(audioFile: oneOverBytes))
            XCTFail("expected one-over byte rejection")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .inputRejected)
            XCTAssertFalse(diagnostic.description.contains(oneOverBytes.path))
        }
        let callsAfterOneOverBytes = await byteTranscriber.callCount
        XCTAssertEqual(callsAfterOneOverBytes, callsAfterExact)
        let byteDrain = await byteEngine.drain(timeout: .seconds(1))
        XCTAssertEqual(byteDrain, .completed)

        let durationFixture = try EngineFixture()
        let durationTranscriber = EngineFakeTranscriber()
        let durationEngine = try durationFixture.engine(
            transcriber: durationTranscriber,
            maxDurationSeconds: 1
        )
        try await durationEngine.start()
        let exactDuration = try makeToneWAV(frameCount: 16_000)
        defer { try? FileManager.default.removeItem(at: exactDuration) }
        _ = try await durationEngine.transcribe(TranscriptionRequest(audioFile: exactDuration))
        let durationCalls = await durationTranscriber.callCount
        XCTAssertEqual(durationCalls, 2)
        let oneOverDuration = try makeToneWAV(frameCount: 16_001)
        defer { try? FileManager.default.removeItem(at: oneOverDuration) }
        do {
            _ = try await durationEngine.transcribe(TranscriptionRequest(audioFile: oneOverDuration))
            XCTFail("expected one-over duration and estimated sample rejection")
        } catch let diagnostic as TranscriptionDiagnostic {
            XCTAssertEqual(diagnostic.code, .inputRejected)
        }
        let callsAfterOneOverDuration = await durationTranscriber.callCount
        XCTAssertEqual(callsAfterOneOverDuration, durationCalls)
        let durationDrain = await durationEngine.drain(timeout: .seconds(1))
        XCTAssertEqual(durationDrain, .completed)
    }
}

private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func reset() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
}

private final class CancellationTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func set(cancel action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let action = self.action
        lock.unlock()
        action?()
    }
}

private actor EngineFakeTranscriber: Transcriber {
    private var backendError: Bool
    private let failProbe: Bool
    private var sleepSeconds: TimeInterval
    private let sleepDuringProbe: Bool
    private let blockActual: Bool
    private let cancelActual: Bool
    private let backendDuration: TimeInterval
    private let busyWaitSignal: BusyWaitSignal?
    private let probeRelease: CleanupLatch?
    private var count = 0
    private var actualStarted = false
    private let actualBlockSignal: CleanupLatch?

    init(
        blockActual: Bool = false,
        cancelActual: Bool = false,
        backendError: Bool = false,
        failProbe: Bool = false,
        sleepSeconds: TimeInterval = 0,
        sleepDuringProbe: Bool = false,
        backendDuration: TimeInterval = 1,
        busyWaitSignal: BusyWaitSignal? = nil,
        probeRelease: CleanupLatch? = nil,
        actualBlockSignal: CleanupLatch? = nil
    ) {
        self.blockActual = blockActual
        self.cancelActual = cancelActual
        self.backendError = backendError
        self.failProbe = failProbe
        self.sleepSeconds = sleepSeconds
        self.sleepDuringProbe = sleepDuringProbe
        self.backendDuration = backendDuration
        self.busyWaitSignal = busyWaitSignal
        self.probeRelease = probeRelease
        self.actualBlockSignal = blockActual ? (actualBlockSignal ?? CleanupLatch()) : nil
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        count += 1
        if count > 1 {
            actualStarted = true
            if cancelActual {
                throw CancellationError()
            }
            if blockActual && count == 2 {
                actualBlockSignal?.markStarted()
                guard actualBlockSignal?.waitForRelease(within: .seconds(5)) ?? true else {
                    throw TestBackendError.barrierTimedOut
                }
            }
            if backendError { throw TestBackendError.failed }
        }
        if sleepSeconds > 0 && (count > 1 || sleepDuringProbe) {
            busyWaitSignal?.started()
            busyWait(seconds: sleepSeconds)
            busyWaitSignal?.finished()
        }
        if count == 1 && failProbe { throw TestBackendError.failed }
        if count == 1, let probeRelease {
            guard probeRelease.waitForRelease(within: .seconds(2)) else {
                throw TestBackendError.barrierTimedOut
            }
        }
        return TranscriptionResult(text: count == 1 ? "probe" : "backend", duration: backendDuration, processingTime: 0.1, modelID: ServiceConfiguration.defaultModelID)
    }

    var callCount: Int { count }

    func waitForActualStart(within timeout: Duration) async -> Bool {
        if let actualBlockSignal {
            return await actualBlockSignal.waitForStart(within: timeout)
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !actualStarted {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    func setMode(backendError: Bool, sleepSeconds: TimeInterval) {
        self.backendError = backendError
        self.sleepSeconds = sleepSeconds
    }
}

private enum TestBackendError: Error, Sendable {
    case failed
    case barrierTimedOut
}

private actor EngineRuntimeLoader: RuntimeLoader {
    let transcriber: any Transcriber
    private(set) var loadCount = 0

    init(transcriber: any Transcriber) {
        self.transcriber = transcriber
    }

    func load(configuration: RuntimeStartConfiguration) async throws -> any Transcriber {
        loadCount += 1
        return transcriber
    }
}

private final class EngineFixture: @unchecked Sendable {
    let root: URL
    let store: ModelStore
    let manifest: ModelManifest
    let commit = String(repeating: "a", count: 40)
    let secondCommit = String(repeating: "b", count: 40)
    let thirdCommit = String(repeating: "c", count: 40)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-engine-\(UUID().uuidString)", isDirectory: true)
        store = ModelStore(root: root)
        manifest = ModelManifest(
            testingFiles: [("Preprocessor.mlmodelc/metadata.json", Data("fixture".utf8))],
            baseURL: "https://fixture.invalid/model",
            immutableCommit: commit
        )
        try store.prepareDirectories()
        for revisionManifest in [
            manifest,
            ModelManifest(
                testingFiles: [("Preprocessor.mlmodelc/metadata.json", Data("fixture".utf8))],
                baseURL: "https://fixture.invalid/model",
                immutableCommit: secondCommit
            ),
            ModelManifest(
                testingFiles: [("Preprocessor.mlmodelc/metadata.json", Data("fixture".utf8))],
                baseURL: "https://fixture.invalid/model",
                immutableCommit: thirdCommit
            )
        ] {
            let file = store.revisionURL(for: revisionManifest.immutableCommit)
                .appendingPathComponent("Preprocessor.mlmodelc/metadata.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file)
            try ModelVerifier().verify(manifest: revisionManifest, at: store.revisionURL(for: revisionManifest.immutableCommit))
            _ = try store.recordVerifiedRevision(manifest: revisionManifest, verifiedAt: Date())
        }
        _ = try store.activate(manifest: manifest, verifiedAt: Date())
    }

    func coordinator() throws -> ModelLifecycleCoordinator {
        try ModelLifecycleCoordinator(testingManifest: manifest, store: store)
    }

    func engine(
        transcriber: EngineFakeTranscriber = EngineFakeTranscriber(),
        loader: EngineRuntimeLoader? = nil,
        hooks: TranscriptionPipelineHooks = TranscriptionPipelineHooks(),
        lifecycleHook: ModelLifecycleTestingHook? = nil,
        maxUploadBytes: Int = 1_000_000,
        maxDurationSeconds: Int = 2
    ) throws -> NativeTranscriptionEngine {
        let configuration = try ServiceConfiguration(
            maxUploadBytes: ByteLimit(maxUploadBytes, key: "test"),
            maxDurationSeconds: DurationLimit(maxDurationSeconds, key: "test"),
            httpRequestTimeoutMilliseconds: DurationLimit(5_000, key: "test")
        )
        let policy = try AudioPreparationPolicy(configuration: configuration)
        let runtimeLoader = loader ?? EngineRuntimeLoader(transcriber: transcriber)
        let coordinator = try ModelLifecycleCoordinator(testingManifest: manifest, store: store, hook: lifecycleHook)
        return NativeTranscriptionEngine(
            testingLifecycle: coordinator,
            configuration: configuration,
            runtimeLoader: runtimeLoader,
            policy: policy,
            hooks: hooks
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private actor AsyncTestGate {
    private var opened = false
    private var released = false
    private var timedOut = false

    func open() {
        opened = true
    }

    func release() {
        released = true
    }

    func recordTimeout() {
        timedOut = true
    }

    var didTimeOut: Bool {
        timedOut
    }

    func waitForOpen(within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !opened {
            guard ContinuousClock.now < deadline else {
                timedOut = true
                return false
            }
            await Task.yield()
        }
        return true
    }

    func waitForRelease(within timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !released {
            guard ContinuousClock.now < deadline else {
                timedOut = true
                return false
            }
            await Task.yield()
        }
        return true
    }
}

private func makeToneWAV(frameCount: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("syrinx-test-audio-\(UUID().uuidString).wav")
    let sampleRate = 16_000
    let dataSize = frameCount * 2
    var data = Data("RIFF".utf8)
    appendLE(UInt32(36 + dataSize), to: &data)
    data.append(contentsOf: Data("WAVEfmt ".utf8))
    appendLE(UInt32(16), to: &data)
    appendLE(UInt16(1), to: &data)
    appendLE(UInt16(1), to: &data)
    appendLE(UInt32(sampleRate), to: &data)
    appendLE(UInt32(sampleRate * 2), to: &data)
    appendLE(UInt16(2), to: &data)
    appendLE(UInt16(16), to: &data)
    data.append(contentsOf: Data("data".utf8))
    appendLE(UInt32(dataSize), to: &data)
    for index in 0..<frameCount {
        let phase = Double(index) * 2 * Double.pi * 440 / Double(sampleRate)
        appendLE(UInt16(bitPattern: Int16((sin(phase) * 2_000).rounded())), to: &data)
    }
    try data.write(to: url)
    return url
}

private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var value = value.littleEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

private func busyWait(seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        _ = 1 + 1
    }
}

private func blockingPhaseHook(
    _ phase: String,
    name: String
) -> (@Sendable () -> Void)? {
    guard phase == name else { return nil }
    return { busyWait(seconds: 0.03) }
}

private func cancellationPhaseHooks(
    phase: String,
    latch: CleanupLatch
) -> TranscriptionPipelineHooks {
    let block = { @Sendable in
        guard latch.isArmed else { return }
        latch.markStarted()
        let released = latch.waitForRelease(within: .seconds(2))
        if !released { latch.markTimedOut() }
    }
    switch phase {
    case "open":
        return TranscriptionPipelineHooks(beforeOpen: block)
    case "riff":
        return TranscriptionPipelineHooks(beforeRIFF: block)
    case "metadata":
        return TranscriptionPipelineHooks(beforeMetadata: block)
    case "conversion":
        return TranscriptionPipelineHooks(beforeConversion: block)
    case "inference":
        return TranscriptionPipelineHooks(beforeInference: block)
    case "cleanup":
        return TranscriptionPipelineHooks(afterCleanup: block)
    default:
        return TranscriptionPipelineHooks()
    }
}

private final class CleanupLatch: @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var started = false
    private var released = false
    private var timedOut = false

    var isArmed: Bool {
        condition.lock()
        let value = armed
        condition.unlock()
        return value
    }

    var didTimeOut: Bool {
        condition.lock()
        let value = timedOut
        condition.unlock()
        return value
    }

    func arm() {
        condition.lock()
        armed = true
        condition.unlock()
    }

    func markStarted() {
        condition.lock()
        started = true
        condition.broadcast()
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func markTimedOut() {
        condition.lock()
        timedOut = true
        condition.unlock()
    }

    func waitForStart(within timeout: Duration) async -> Bool {
        await wait(for: { self.startedValue() }, within: timeout)
    }

    func waitForRelease(within timeout: Duration) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        condition.lock()
        while !released && ContinuousClock.now < deadline {
            _ = condition.wait(until: Date().addingTimeInterval(0.01))
        }
        let didRelease = released
        if !didRelease {
            timedOut = true
        }
        condition.unlock()
        return didRelease
    }

    private func startedValue() -> Bool {
        condition.lock()
        let value = started
        condition.unlock()
        return value
    }

    private func wait(
        for predicate: @escaping @Sendable () -> Bool,
        within timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }
}

private final class BusyWaitSignal: @unchecked Sendable {
    private let condition = NSCondition()
    private var hasStarted = false
    private var hasFinished = false

    func started() {
        condition.lock()
        hasStarted = true
        condition.broadcast()
        condition.unlock()
    }

    func finished() {
        condition.lock()
        hasFinished = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForStart(within timeout: Duration) async -> Bool {
        await wait(for: { self.startedValue() }, within: timeout)
    }

    func waitForFinish(within timeout: Duration) async -> Bool {
        await wait(for: { self.finishedValue() }, within: timeout)
    }

    private func wait(
        for predicate: @escaping @Sendable () -> Bool,
        within timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate() {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    private func startedValue() -> Bool {
        condition.lock()
        let value = hasStarted
        condition.unlock()
        return value
    }

    private func finishedValue() -> Bool {
        condition.lock()
        let value = hasFinished
        condition.unlock()
        return value
    }
}

private func durationMilliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000.0
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
}
