import Foundation
import Injector
import XCTest

private final class InjectedPropertyService {}

private extension Injector {
    var injectedPropertyService: Dependency<InjectedPropertyService> {
        .service(InjectedPropertyService.self)
    }
}

private final class InjectedPropertyOwner: @unchecked Sendable {
    @Injected(\.injectedPropertyService) var service: InjectedPropertyService
}

final class InjectedPropertyTests: XCTestCase {
    func testNewScopedDependencyStaysTheSameInstanceForOneOwner() {
        let (first, second, otherOwner) = Injector.withOverrides {
            $0.bind(\.injectedPropertyService, scope: .new) { _ in
                InjectedPropertyService()
            }
        } operation: {
            let owner = InjectedPropertyOwner()
            return (owner.service, owner.service, InjectedPropertyOwner().service)
        }

        XCTAssertTrue(first === second)
        XCTAssertFalse(first === otherOwner)
    }

    func testDependencyIsResolvedOnFirstAccessOnly() {
        let creations = LockedCounter()

        let (beforeAccess, afterAccesses) = Injector.withOverrides {
            $0.bind(\.injectedPropertyService, scope: .new) { _ in
                creations.increment()
                return InjectedPropertyService()
            }
        } operation: {
            let owner = InjectedPropertyOwner()
            let beforeAccess = creations.value
            _ = owner.service
            _ = owner.service
            return (beforeAccess, creations.value)
        }

        XCTAssertEqual(beforeAccess, 0)
        XCTAssertEqual(afterAccesses, 1)
    }

    func testOwnerCreatedInsideOverrideScopeKeepsScopedBindingsAfterTheScope() {
        let scopedService = InjectedPropertyService()

        let owner = Injector.withOverrides {
            $0.bindInstance(\.injectedPropertyService, scopedService)
        } operation: {
            InjectedPropertyOwner()
        }

        XCTAssertTrue(owner.service === scopedService)
    }

    func testOwnerCreatedInsideOverrideScopeKeepsScopedBindingsOnOtherThreads() {
        let scopedService = InjectedPropertyService()
        let owner = Injector.withOverrides {
            $0.bindInstance(\.injectedPropertyService, scopedService)
        } operation: {
            InjectedPropertyOwner()
        }

        let resolvedOnOtherThread = expectation(description: "resolved on another thread")
        let resolved = UncheckedSendable(value: NSMutableArray())
        DispatchQueue.global().async {
            resolved.value.add(owner.service)
            resolvedOnOtherThread.fulfill()
        }
        wait(for: [resolvedOnOtherThread], timeout: 2)

        XCTAssertTrue(resolved.value.firstObject as AnyObject === scopedService)
    }

    func testOwnerCreatedOutsideOverrideScopeIgnoresLaterScopes() {
        let outerService = InjectedPropertyService()
        let laterService = InjectedPropertyService()

        let resolved = Injector.withOverrides {
            $0.bindInstance(\.injectedPropertyService, outerService)
        } operation: {
            let owner = InjectedPropertyOwner()
            return Injector.withOverrides {
                $0.bindInstance(\.injectedPropertyService, laterService)
            } operation: {
                owner.service
            }
        }

        XCTAssertTrue(resolved === outerService)
    }

    func testExplicitContainerIsUsedInsteadOfCurrent() {
        let containerService = InjectedPropertyService()
        let container = Injector()
        container.bindInstance(\.injectedPropertyService, containerService)

        let resolved = Injector.withOverrides {
            $0.bindInstance(\.injectedPropertyService, InjectedPropertyService())
        } operation: {
            Injected(\.injectedPropertyService, container: container).wrappedValue
        }

        XCTAssertTrue(resolved === containerService)
    }

    func testConcurrentFirstAccessResolvesOnce() {
        let creations = LockedCounter()
        let owner = Injector.withOverrides {
            $0.bind(\.injectedPropertyService, scope: .new) { _ in
                creations.increment()
                Thread.sleep(forTimeInterval: 0.01)
                return InjectedPropertyService()
            }
        } operation: {
            InjectedPropertyOwner()
        }

        let instances = UncheckedSendable(value: NSMutableSet())
        let instancesLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            let service = owner.service
            instancesLock.lock()
            instances.value.add(ObjectIdentifier(service))
            instancesLock.unlock()
        }

        XCTAssertEqual(creations.value, 1)
        XCTAssertEqual(instances.value.count, 1)
    }

    func testInjectedFunctionStillResolvesOnEveryCall() {
        let (first, second) = Injector.withOverrides {
            $0.bind(\.injectedPropertyService, scope: .new) { _ in
                InjectedPropertyService()
            }
        } operation: {
            (injected(\.injectedPropertyService), injected(\.injectedPropertyService))
        }

        XCTAssertFalse(first === second)
    }
}
