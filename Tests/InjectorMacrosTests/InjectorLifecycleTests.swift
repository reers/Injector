import Foundation
@testable import Injector
import XCTest

private protocol ResetMacroService: AnyObject {}

private final class DefaultResetMacroService: ResetMacroService {}

private final class LifecycleService {}

private final class SlowSingletonService {
    let otherResolveFinished: Bool

    init(otherResolveFinished: Bool) {
        self.otherResolveFinished = otherResolveFinished
    }
}

private extension Injector {
    var resetMacroService: Dependency<ResetMacroService> {
        .service(ResetMacroService.self)
    }

    var lifecycleService: Dependency<LifecycleService> {
        .service(LifecycleService.self)
    }

    var slowSingletonService: Dependency<SlowSingletonService> {
        .service(SlowSingletonService.self)
    }
}

final class InjectorLifecycleTests: XCTestCase {
    // MARK: - reset

    /// Stands in for Rhea: `@BindService` callbacks are non-repeatable, so the trigger must fire only once.
    private func makeContainerWithServiceBindings(triggerCount: LockedCounter) -> Injector {
        Injector { injector in
            triggerCount.increment()
            injector.bind(\.resetMacroService, scope: .singleton) { _ in
                DefaultResetMacroService()
            }
        }
    }

    func testResetReplaysServiceBindingsWithoutTriggeringAgain() {
        let triggerCount = LockedCounter()
        let injector = makeContainerWithServiceBindings(triggerCount: triggerCount)
        let beforeReset = injector.resolve(\.resetMacroService)

        injector.reset()
        let afterFirstReset = injector.resolve(\.resetMacroService)

        injector.reset()
        let afterSecondReset = injector.resolve(\.resetMacroService)

        XCTAssertEqual(triggerCount.value, 1)
        XCTAssertTrue(afterFirstReset is DefaultResetMacroService)
        XCTAssertTrue(afterSecondReset is DefaultResetMacroService)
        XCTAssertFalse(beforeReset === afterFirstReset, "reset should drop created singletons")
    }

    func testResetRestoresServiceBindingsReplacedManually() {
        let injector = makeContainerWithServiceBindings(triggerCount: LockedCounter())
        injector.installRheaServiceBindingsIfNeeded()
        let manual = DefaultResetMacroService()
        injector.bindInstance(\.resetMacroService, manual)

        injector.reset()
        let restored = injector.resolve(\.resetMacroService)

        XCTAssertFalse(restored === manual)
    }

    // MARK: - Duplicate service bindings

    func testDuplicateServiceBindingIsReported() {
        let reports = UncheckedSendable(value: NSMutableArray())
        let injector = Injector(
            serviceBindingsTrigger: { injector in
                injector.bind(\.resetMacroService, scope: .singleton) { _ in DefaultResetMacroService() }
                injector.bind(\.resetMacroService, scope: .singleton) { _ in DefaultResetMacroService() }
            },
            reportMisuse: { reports.value.add($0) }
        )

        injector.installRheaServiceBindingsIfNeeded()

        XCTAssertEqual(reports.value.count, 1)
        let report = reports.value.firstObject as? String ?? ""
        XCTAssertTrue(report.contains("\\.resetMacroService"), report)
        XCTAssertTrue(report.contains("ResetMacroService"), report)
    }

    func testDistinctServiceBindingsAreNotReported() {
        let reports = UncheckedSendable(value: NSMutableArray())
        let injector = Injector(
            serviceBindingsTrigger: { injector in
                injector.bind(\.resetMacroService, scope: .singleton) { _ in DefaultResetMacroService() }
                injector.bind(\.lifecycleService) { _ in LifecycleService() }
            },
            reportMisuse: { reports.value.add($0) }
        )

        injector.installRheaServiceBindingsIfNeeded()

        XCTAssertEqual(reports.value.count, 0)
    }

    func testManualRebindingIsNotReported() {
        let reports = UncheckedSendable(value: NSMutableArray())
        let injector = Injector(
            serviceBindingsTrigger: { injector in
                injector.bind(\.resetMacroService, scope: .singleton) { _ in DefaultResetMacroService() }
            },
            reportMisuse: { reports.value.add($0) }
        )

        injector.installRheaServiceBindingsIfNeeded()
        injector.bindInstance(\.resetMacroService, DefaultResetMacroService())
        injector.bind(\.resetMacroService) { _ in DefaultResetMacroService() }
        injector.reset()
        _ = injector.resolve(\.resetMacroService)

        XCTAssertEqual(reports.value.count, 0)
    }

    // MARK: - Factories run outside the container lock

    func testSingletonFactoryDoesNotBlockResolvesFromOtherThreads() {
        let service = Injector.withOverrides {
            $0.bind(\.lifecycleService) { _ in
                LifecycleService()
            }
            $0.bind(\.slowSingletonService, scope: .singleton) { resolver in
                let finished = DispatchSemaphore(value: 0)
                let box = UncheckedSendable(value: resolver)
                DispatchQueue.global().async {
                    _ = box.value.resolve(\.lifecycleService)
                    finished.signal()
                }
                let result = finished.wait(timeout: .now() + 2)
                return SlowSingletonService(otherResolveFinished: result == .success)
            }
        } operation: {
            Injector.current.resolve(\.slowSingletonService)
        }

        XCTAssertTrue(service.otherResolveFinished)
    }

    func testWithOverridesDuringInFlightSingletonCreationDoesNotDeadlock() {
        let started = DispatchSemaphore(value: 0)
        let resolved = DispatchSemaphore(value: 0)
        let copied = DispatchSemaphore(value: 0)
        let parent = Injector.withOverrides {
            $0.bind(\.lifecycleService) { _ in LifecycleService() }
            $0.bind(\.slowSingletonService, scope: .singleton) { resolver in
                started.signal()
                Thread.sleep(forTimeInterval: 0.05)
                // Needs the container lock while withOverrides may be copying the container.
                _ = resolver.resolve(\.lifecycleService)
                return SlowSingletonService(otherResolveFinished: true)
            }
        } operation: {
            Injector.current
        }

        let box = UncheckedSendable(value: parent)
        DispatchQueue.global().async {
            _ = box.value.resolve(\.slowSingletonService)
            resolved.signal()
        }
        started.wait()
        DispatchQueue.global().async {
            _ = box.value.copyForOverrides()
            copied.signal()
        }

        XCTAssertEqual(resolved.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(copied.wait(timeout: .now() + 2), .success)
    }

    func testSingletonIsCreatedOnceUnderConcurrentResolves() {
        let creations = LockedCounter()
        let injector = Injector()
        injector.bind(\.lifecycleService, scope: .singleton) { _ in
            creations.increment()
            Thread.sleep(forTimeInterval: 0.01)
            return LifecycleService()
        }

        let instances = UncheckedSendable(value: NSMutableSet())
        let instancesLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            let service = injector.resolve(\.lifecycleService)
            instancesLock.lock()
            instances.value.add(ObjectIdentifier(service))
            instancesLock.unlock()
        }

        XCTAssertEqual(creations.value, 1)
        XCTAssertEqual(instances.value.count, 1)
    }

    func testSingletonCreatedInsideOverrideScopeDoesNotLeakToParentScope() {
        let (inner, outer) = Injector.withOverrides {
            $0.bind(\.lifecycleService, scope: .singleton) { _ in
                LifecycleService()
            }
        } operation: {
            let inner = Injector.withOverrides { _ in } operation: {
                Injector.current.resolve(\.lifecycleService)
            }
            return (inner, Injector.current.resolve(\.lifecycleService))
        }

        XCTAssertFalse(inner === outer)
    }

    func testOverrideScopeReusesSingletonsAlreadyCreatedInParentScope() {
        let (outer, inner) = Injector.withOverrides {
            $0.bind(\.lifecycleService, scope: .singleton) { _ in
                LifecycleService()
            }
        } operation: {
            let outer = Injector.current.resolve(\.lifecycleService)
            let inner = Injector.withOverrides { _ in } operation: {
                Injector.current.resolve(\.lifecycleService)
            }
            return (outer, inner)
        }

        XCTAssertTrue(outer === inner)
    }
}
