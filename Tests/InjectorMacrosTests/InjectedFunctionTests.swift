import Injector
import XCTest

private protocol MembershipService: AnyObject {
    var isVIP: Bool { get }
}

private final class DefaultMembershipService: MembershipService {
    let isVIP: Bool

    init(isVIP: Bool) {
        self.isVIP = isVIP
    }
}

private final class InjectedFunctionCounterService {}

private extension Injector {
    var membershipService: Dependency<MembershipService> {
        .service(MembershipService.self)
    }

    var injectedFunctionCounterService: Dependency<InjectedFunctionCounterService> {
        .service(InjectedFunctionCounterService.self)
    }
}

private struct InjectedPropertyConsumer {
    @Injected(\.membershipService) var membershipService: MembershipService
}

/// A type that declares its own `resolve` / `resolved` members.
/// A global function named `resolve` would be shadowed here; `injected` must stay callable.
private struct MemberNamedResolveConsumer {
    let resolved = false

    static func resolve(rawText: String) -> Int {
        rawText.count
    }

    func resolve(rawText: String) -> Int {
        rawText.count
    }

    func isVIP() -> Bool {
        injected(\.membershipService).isVIP
    }

    static func isVIP() -> Bool {
        injected(\.membershipService).isVIP
    }
}

final class InjectedFunctionTests: XCTestCase {
    func testInjectedResolvesBoundDependency() {
        let isVIP = Injector.withOverrides {
            $0.bind(\.membershipService) { _ in
                DefaultMembershipService(isVIP: true)
            }
        } operation: {
            injected(\.membershipService).isVIP
        }

        XCTAssertTrue(isVIP)
    }

    func testInjectedReturnsTheBoundInstance() {
        let service = DefaultMembershipService(isVIP: false)

        let resolved = Injector.withOverrides {
            $0.bindInstance(\.membershipService, service)
        } operation: {
            injected(\.membershipService)
        }

        XCTAssertTrue(resolved === service)
    }

    func testInjectedHonorsSingletonScope() {
        let (first, second) = Injector.withOverrides {
            $0.bind(\.injectedFunctionCounterService, scope: .singleton) { _ in
                InjectedFunctionCounterService()
            }
        } operation: {
            (injected(\.injectedFunctionCounterService), injected(\.injectedFunctionCounterService))
        }

        XCTAssertTrue(first === second)
    }

    func testInjectedHonorsNewScope() {
        let (first, second) = Injector.withOverrides {
            $0.bind(\.injectedFunctionCounterService, scope: .new) { _ in
                InjectedFunctionCounterService()
            }
        } operation: {
            (injected(\.injectedFunctionCounterService), injected(\.injectedFunctionCounterService))
        }

        XCTAssertFalse(first === second)
    }

    func testInjectedMatchesInjectedPropertyWrapper() {
        let (fromFunction, fromProperty) = Injector.withOverrides {
            $0.bind(\.membershipService, scope: .singleton) { _ in
                DefaultMembershipService(isVIP: true)
            }
        } operation: {
            (injected(\.membershipService), InjectedPropertyConsumer().membershipService)
        }

        XCTAssertTrue(fromFunction === fromProperty)
    }

    func testInjectedMatchesInjectorResolve() {
        let (fromFunction, fromResolve) = Injector.withOverrides {
            $0.bind(\.membershipService, scope: .singleton) { _ in
                DefaultMembershipService(isVIP: true)
            }
        } operation: {
            (
                injected(\.membershipService),
                Injector.current.resolve(\.membershipService)
            )
        }

        XCTAssertTrue(fromFunction === fromResolve)
    }

    func testInjectedUsesScopedBindingsInsideWithOverrides() {
        let outerService = DefaultMembershipService(isVIP: false)
        let scopedService = DefaultMembershipService(isVIP: true)

        let (resolved, outerAfterScope) = Injector.withOverrides {
            $0.bindInstance(\.membershipService, outerService)
        } operation: {
            let resolved = Injector.withOverrides {
                $0.bindInstance(\.membershipService, scopedService)
            } operation: {
                injected(\.membershipService)
            }
            return (resolved, injected(\.membershipService))
        }

        XCTAssertTrue(resolved === scopedService)
        XCTAssertTrue(outerAfterScope === outerService)
    }

    func testInjectedUsesInnermostScopeForNestedOverrides() {
        let outerService = DefaultMembershipService(isVIP: false)
        let innerService = DefaultMembershipService(isVIP: true)

        let (inner, outerAfterInner) = Injector.withOverrides {
            $0.bindInstance(\.membershipService, outerService)
        } operation: {
            let inner = Injector.withOverrides {
                $0.bindInstance(\.membershipService, innerService)
            } operation: {
                injected(\.membershipService)
            }
            return (inner, injected(\.membershipService))
        }

        XCTAssertTrue(inner === innerService)
        XCTAssertTrue(outerAfterInner === outerService)
    }

    func testInjectedKeepsScopedBindingsAcrossAsyncOperations() async {
        let scopedService = DefaultMembershipService(isVIP: true)

        let resolved = await Injector.withOverrides {
            $0.bindInstance(\.membershipService, scopedService)
        } operation: {
            await Task.yield()
            return injected(\.membershipService)
        }

        XCTAssertTrue(resolved === scopedService)
    }

    func testInjectedIsNotShadowedByMembersNamedResolve() {
        let isVIP = Injector.withOverrides {
            $0.bindInstance(\.membershipService, DefaultMembershipService(isVIP: true))
        } operation: {
            (MemberNamedResolveConsumer().isVIP(), MemberNamedResolveConsumer.isVIP())
        }

        XCTAssertTrue(isVIP.0)
        XCTAssertTrue(isVIP.1)
    }
}
