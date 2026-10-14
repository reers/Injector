import Foundation
@testable import Injector
import XCTest

private final class RegistrationService: Sendable {}

private final class RegistrationLeafService {}

private final class RegistrationParentService {
    let leaf: RegistrationLeafService

    init(leaf: RegistrationLeafService) {
        self.leaf = leaf
    }
}

private final class RegistrationResolverProbe {
    let resolver: Resolver

    init(resolver: Resolver) {
        self.resolver = resolver
    }
}

private struct RegistrationConfiguration: Equatable {
    var baseURL: String
    var timeout: Int
}

private extension Injector {
    var registrationService: Dependency<RegistrationService> {
        .service()
    }

    var registrationOtherService: Dependency<RegistrationService> {
        .service()
    }

    var registrationLeafService: Dependency<RegistrationLeafService> {
        .service()
    }

    var registrationParentService: Dependency<RegistrationParentService> {
        .service()
    }

    var registrationResolverProbe: Dependency<RegistrationResolverProbe> {
        .service()
    }

    var registrationConfiguration: Dependency<RegistrationConfiguration> {
        .service()
    }

    var registrationRetryCount: Dependency<Int> {
        .service()
    }

    var registrationIsVIP: Dependency<() -> Bool> {
        .service()
    }
}

private enum RegistrationServiceModule: Module {
    static func register(into injector: Injector) {
        injector.bind(\.registrationService, scope: .singleton) { _ in RegistrationService() }
    }
}

private enum RegistrationConfigurationModule: Module {
    static func register(into injector: Injector) {
        injector.bindInstance(\.registrationConfiguration, RegistrationConfiguration(baseURL: "https://example.com", timeout: 10))
    }
}

private final class RegistrationOwner {
    @Injected(\.registrationService, container: RegistrationOwner.container) var service: RegistrationService

    nonisolated(unsafe) static var container = Injector()
}

final class InjectorRegistrationTests: XCTestCase {
    // MARK: - Rebinding

    func testRebindingReplacesThePreviousFactory() {
        let first = RegistrationService()
        let second = RegistrationService()
        let container = Injector()
        container.bind(\.registrationService) { _ in first }
        XCTAssertTrue(container.resolve(\.registrationService) === first)

        container.bind(\.registrationService) { _ in second }

        XCTAssertTrue(container.resolve(\.registrationService) === second)
    }

    func testRebindingASingletonDropsTheCreatedInstance() {
        let container = Injector()
        container.bind(\.registrationService, scope: .singleton) { _ in RegistrationService() }
        let beforeRebinding = container.resolve(\.registrationService)

        container.bind(\.registrationService, scope: .singleton) { _ in RegistrationService() }

        XCTAssertFalse(container.resolve(\.registrationService) === beforeRebinding)
    }

    func testBindReplacesABoundInstance() {
        let instance = RegistrationService()
        let container = Injector()
        container.bindInstance(\.registrationService, instance)

        container.bind(\.registrationService) { _ in RegistrationService() }

        XCTAssertFalse(container.resolve(\.registrationService) === instance)
    }

    func testBindInstanceReplacesAFactory() {
        let instance = RegistrationService()
        let container = Injector()
        container.bind(\.registrationService) { _ in RegistrationService() }

        container.bindInstance(\.registrationService, instance)

        XCTAssertTrue(container.resolve(\.registrationService) === instance)
    }

    func testBindInstanceAlwaysReturnsTheSameInstance() {
        let instance = RegistrationService()
        let container = Injector()
        container.bindInstance(\.registrationService, instance)

        XCTAssertTrue(container.resolve(\.registrationService) === instance)
        XCTAssertTrue(container.resolve(\.registrationService) === instance)
    }

    // MARK: - Remove

    func testRemoveKeepsOtherDependencies() {
        let other = RegistrationService()
        let container = Injector()
        container.bind(\.registrationService) { _ in RegistrationService() }
        container.bindInstance(\.registrationOtherService, other)

        container.remove(\.registrationService)

        XCTAssertTrue(container.resolve(\.registrationOtherService) === other)
    }

    func testBindingAgainAfterRemoveCreatesAFreshSingleton() {
        let container = Injector()
        container.bind(\.registrationService, scope: .singleton) { _ in RegistrationService() }
        let beforeRemove = container.resolve(\.registrationService)

        container.remove(\.registrationService)
        container.bind(\.registrationService, scope: .singleton) { _ in RegistrationService() }

        XCTAssertFalse(container.resolve(\.registrationService) === beforeRemove)
    }

    func testRemovingAnUnregisteredDependencyIsANoOp() {
        let container = Injector()

        container.remove(\.registrationService)
        container.bindInstance(\.registrationOtherService, RegistrationService())

        XCTAssertNotNil(container.resolve(\.registrationOtherService))
    }

    // MARK: - Value and function dependencies

    func testValueTypeDependencies() {
        let configuration = RegistrationConfiguration(baseURL: "https://example.com", timeout: 30)
        let container = Injector()
        container.bindInstance(\.registrationConfiguration, configuration)
        container.bind(\.registrationRetryCount) { _ in 3 }

        XCTAssertEqual(container.resolve(\.registrationConfiguration), configuration)
        XCTAssertEqual(container.resolve(\.registrationRetryCount), 3)
    }

    func testNewScopedValueTypeFactoryRunsOnEveryResolve() {
        let calls = LockedCounter()
        let container = Injector()
        container.bind(\.registrationRetryCount) { _ in
            calls.increment()
            return calls.value
        }

        XCTAssertEqual(container.resolve(\.registrationRetryCount), 1)
        XCTAssertEqual(container.resolve(\.registrationRetryCount), 2)
    }

    func testFunctionDependencies() {
        let container = Injector()
        container.bindInstance(\.registrationIsVIP) { true }

        XCTAssertTrue(container.resolve(\.registrationIsVIP)())
    }

    // MARK: - Factories and resolvers

    func testFactoryReceivesTheResolvingContainer() {
        let container = Injector()
        container.bind(\.registrationResolverProbe) { RegistrationResolverProbe(resolver: $0) }

        XCTAssertTrue(container.resolve(\.registrationResolverProbe).resolver === container)
    }

    func testFactoryCanResolveItsOwnDependencies() {
        let leaf = RegistrationLeafService()
        let container = Injector()
        container.bindInstance(\.registrationLeafService, leaf)
        container.bind(\.registrationParentService) { resolver in
            RegistrationParentService(leaf: resolver.resolve(\.registrationLeafService))
        }

        XCTAssertTrue(container.resolve(\.registrationParentService).leaf === leaf)
    }

    func testSingletonKeepsTheNewScopedDependencyItWasCreatedWith() {
        let container = Injector()
        container.bind(\.registrationLeafService) { _ in RegistrationLeafService() }
        container.bind(\.registrationParentService, scope: .singleton) { resolver in
            RegistrationParentService(leaf: resolver.resolve(\.registrationLeafService))
        }

        let first = container.resolve(\.registrationParentService)
        let second = container.resolve(\.registrationParentService)

        XCTAssertTrue(first.leaf === second.leaf)
        XCTAssertFalse(container.resolve(\.registrationLeafService) === first.leaf)
    }

    // MARK: - Modules

    func testInstallingAModuleRegistersItsBindings() {
        let container = Injector()

        container.install(RegistrationServiceModule.self)

        XCTAssertTrue(container.resolve(\.registrationService) === container.resolve(\.registrationService))
    }

    func testInstallingMultipleModules() {
        let container = Injector()

        container.install(RegistrationServiceModule.self, RegistrationConfigurationModule.self)

        XCTAssertNotNil(container.resolve(\.registrationService))
        XCTAssertEqual(container.resolve(\.registrationConfiguration).timeout, 10)
    }

    // MARK: - Custom containers

    func testCustomContainersAreIsolatedFromEachOther() {
        let firstService = RegistrationService()
        let secondService = RegistrationService()
        let first = Injector()
        let second = Injector()

        first.bindInstance(\.registrationService, firstService)
        second.bindInstance(\.registrationService, secondService)

        XCTAssertTrue(first.resolve(\.registrationService) === firstService)
        XCTAssertTrue(second.resolve(\.registrationService) === secondService)
    }

    func testInjectedWithExplicitContainerResolvesLazily() {
        let creations = LockedCounter()
        let container = Injector()
        container.bind(\.registrationService) { _ in
            creations.increment()
            return RegistrationService()
        }
        RegistrationOwner.container = container

        let owner = RegistrationOwner()
        XCTAssertEqual(creations.value, 0)

        _ = owner.service
        _ = owner.service
        XCTAssertEqual(creations.value, 1)
    }

    // MARK: - Service bindings installation

    private func makeContainer(triggerCount: LockedCounter) -> Injector {
        Injector { injector in
            triggerCount.increment()
            injector.bind(\.registrationService, scope: .singleton) { _ in RegistrationService() }
        }
    }

    func testServiceBindingsAreInstalledLazilyOnFirstResolve() {
        let triggerCount = LockedCounter()
        let container = makeContainer(triggerCount: triggerCount)
        XCTAssertEqual(triggerCount.value, 0)

        _ = container.resolve(\.registrationService)
        _ = container.resolve(\.registrationService)

        XCTAssertEqual(triggerCount.value, 1)
    }

    func testInstallingServiceBindingsIsIdempotent() {
        let triggerCount = LockedCounter()
        let container = makeContainer(triggerCount: triggerCount)

        container.installRheaServiceBindingsIfNeeded()
        container.installRheaServiceBindingsIfNeeded()
        _ = container.resolve(\.registrationService)

        XCTAssertEqual(triggerCount.value, 1)
    }

    func testManualBindingAfterInstallOverridesTheServiceBinding() {
        let manual = RegistrationService()
        let container = makeContainer(triggerCount: LockedCounter())
        container.installRheaServiceBindingsIfNeeded()

        container.bindInstance(\.registrationService, manual)

        XCTAssertTrue(container.resolve(\.registrationService) === manual)
    }

    func testServiceBindingOverwritesAManualBindingMadeBeforeInstall() {
        let manual = RegistrationService()
        let container = makeContainer(triggerCount: LockedCounter())
        container.bindInstance(\.registrationService, manual)

        container.installRheaServiceBindingsIfNeeded()

        XCTAssertFalse(container.resolve(\.registrationService) === manual)
    }

    func testResetBeforeInstallStillInstallsOnNextResolve() {
        let triggerCount = LockedCounter()
        let container = makeContainer(triggerCount: triggerCount)

        container.reset()
        _ = container.resolve(\.registrationService)

        XCTAssertEqual(triggerCount.value, 1)
    }

    func testConcurrentFirstResolvesInstallServiceBindingsOnce() {
        let triggerCount = LockedCounter()
        let container = makeContainer(triggerCount: triggerCount)

        let instances = UncheckedSendable(value: NSMutableSet())
        let instancesLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            let service = container.resolve(\.registrationService)
            instancesLock.lock()
            instances.value.add(ObjectIdentifier(service))
            instancesLock.unlock()
        }

        XCTAssertEqual(triggerCount.value, 1)
        XCTAssertEqual(instances.value.count, 1)
    }

    // MARK: - Concurrency

    func testConcurrentNewScopedResolvesCreateDistinctInstances() {
        let container = Injector()
        container.bind(\.registrationService) { _ in RegistrationService() }

        let instances = UncheckedSendable(value: NSMutableArray())
        let instancesLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            let service = container.resolve(\.registrationService)
            instancesLock.lock()
            instances.value.add(service)
            instancesLock.unlock()
        }

        let identifiers = Set(instances.value.map { ObjectIdentifier($0 as AnyObject) })
        XCTAssertEqual(identifiers.count, 50)
    }

    func testConcurrentBindingAndResolvingIsSafe() {
        let stable = RegistrationService()
        let container = Injector()
        container.bindInstance(\.registrationOtherService, stable)
        container.bind(\.registrationService) { _ in RegistrationService() }

        let mismatches = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 2) {
                container.bind(\.registrationService, scope: index.isMultiple(of: 4) ? .singleton : .new) { _ in
                    RegistrationService()
                }
            } else {
                _ = container.resolve(\.registrationService)
            }
            if container.resolve(\.registrationOtherService) !== stable {
                mismatches.increment()
            }
        }

        XCTAssertEqual(mismatches.value, 0)
    }
}
