import Foundation
@testable import Injector
import XCTest

private final class AccountService: SessionScoped, @unchecked Sendable {
    private let lock = NSLock()
    private var endCount = 0

    var sessionDidEndCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return endCount
    }

    func sessionDidEnd() {
        lock.lock()
        endCount += 1
        lock.unlock()
    }
}

private final class PlainSessionService {}

private final class AppConfigService {}

private final class SessionConsumer {
    let account: AccountService

    init(account: AccountService) {
        self.account = account
    }
}

private final class LazySessionConsumer {
    @Injected(\.accountService) var account: AccountService

    init() {}

    init(container: Injector) {
        _account = Injected(\.accountService, container: container)
    }
}

private final class SessionOwner {
    @Injected(\.accountService) var account: AccountService
    @Injected(\.appConfigService) var appConfig: AppConfigService

    init(container: Injector) {
        _account = Injected(\.accountService, container: container)
        _appConfig = Injected(\.appConfigService, container: container)
    }
}

private extension Injector {
    var accountService: Dependency<AccountService> {
        .service(AccountService.self)
    }

    var secondAccountService: Dependency<AccountService> {
        .service(AccountService.self)
    }

    var plainSessionService: Dependency<PlainSessionService> {
        .service(PlainSessionService.self)
    }

    var appConfigService: Dependency<AppConfigService> {
        .service(AppConfigService.self)
    }

    var sessionConsumer: Dependency<SessionConsumer> {
        .service(SessionConsumer.self)
    }

    var lazySessionConsumer: Dependency<LazySessionConsumer> {
        .service(LazySessionConsumer.self)
    }
}

final class SessionScopeTests: XCTestCase {
    private var reports: UncheckedSendable<NSMutableArray>!

    override func setUp() {
        super.setUp()
        reports = UncheckedSendable(value: NSMutableArray())
    }

    private func makeInjector() -> Injector {
        let reports = reports!
        let injector = Injector(serviceBindingsTrigger: { _ in }, reportMisuse: { reports.value.add($0) })
        injector.bind(\.accountService, scope: .session) { _ in AccountService() }
        injector.bind(\.appConfigService, scope: .singleton) { _ in AppConfigService() }
        return injector
    }

    // MARK: - Lifetime

    func testSessionScopeReusesInstanceWithinASession() {
        let injector = makeInjector()

        XCTAssertTrue(injector.resolve(\.accountService) === injector.resolve(\.accountService))
    }

    func testEndSessionCreatesNewInstanceOnNextResolve() {
        let injector = makeInjector()
        let first = injector.resolve(\.accountService)

        injector.endSession()
        let second = injector.resolve(\.accountService)

        XCTAssertFalse(first === second)
        XCTAssertTrue(second === injector.resolve(\.accountService))
    }

    func testEndSessionKeepsSingletonsAndRegistrations() {
        let injector = makeInjector()
        let config = injector.resolve(\.appConfigService)

        injector.endSession()

        XCTAssertTrue(config === injector.resolve(\.appConfigService))
    }

    func testEndSessionBeforeAnyResolveIsHarmless() {
        let injector = makeInjector()

        injector.endSession()
        injector.endSession()

        XCTAssertNotNil(injector.resolve(\.accountService))
    }

    func testEndSessionIncrementsSessionGeneration() {
        let injector = makeInjector()

        injector.endSession()
        injector.endSession()

        XCTAssertEqual(injector.sessionGeneration, 2)
    }

    func testInjectedFunctionReturnsNewInstanceAfterEndSession() {
        Injector.withOverrides {
            $0.bind(\.accountService, scope: .session) { _ in AccountService() }
        } operation: {
            let first = injected(\.accountService)
            XCTAssertTrue(first === injected(\.accountService))

            Injector.current.endSession()

            XCTAssertFalse(first === injected(\.accountService))
        }
    }

    // MARK: - sessionDidEnd

    func testEndSessionNotifiesCreatedInstances() {
        let injector = makeInjector()
        let account = injector.resolve(\.accountService)

        injector.endSession()

        XCTAssertEqual(account.sessionDidEndCount, 1)
    }

    func testEndSessionNotifiesEachInstanceOnlyOnce() {
        let injector = makeInjector()
        let account = injector.resolve(\.accountService)

        injector.endSession()
        injector.endSession()

        XCTAssertEqual(account.sessionDidEndCount, 1)
    }

    func testInstanceBoundUnderTwoKeysIsNotifiedOnce() {
        let injector = makeInjector()
        let shared = AccountService()
        injector.bind(\.accountService, scope: .session) { _ in shared }
        injector.bind(\.secondAccountService, scope: .session) { _ in shared }
        _ = injector.resolve(\.accountService)
        _ = injector.resolve(\.secondAccountService)

        injector.endSession()

        XCTAssertEqual(shared.sessionDidEndCount, 1)
    }

    func testEndSessionIgnoresInstancesThatAreNotSessionScoped() {
        let injector = makeInjector()
        injector.bind(\.plainSessionService, scope: .session) { _ in PlainSessionService() }
        let plain = injector.resolve(\.plainSessionService)

        injector.endSession()

        XCTAssertFalse(plain === injector.resolve(\.plainSessionService))
    }

    func testResetDoesNotNotifySessionInstances() {
        let injector = makeInjector()
        let account = injector.resolve(\.accountService)

        injector.reset()

        XCTAssertEqual(account.sessionDidEndCount, 0)
    }

    func testEndSessionDoesNotNotifyNewScopedInstances() {
        let injector = makeInjector()
        injector.bind(\.accountService) { _ in AccountService() }
        let account = injector.resolve(\.accountService)

        injector.endSession()

        XCTAssertEqual(account.sessionDidEndCount, 0)
    }

    // MARK: - @Injected

    func testInjectedPropertyResolvesAgainAfterEndSession() {
        let injector = makeInjector()
        let owner = SessionOwner(container: injector)
        let first = owner.account
        XCTAssertTrue(first === owner.account)

        injector.endSession()

        XCTAssertFalse(first === owner.account)
        XCTAssertTrue(owner.account === injector.resolve(\.accountService))
    }

    func testInjectedPropertyKeepsSingletonAcrossSessions() {
        let injector = makeInjector()
        let owner = SessionOwner(container: injector)
        let config = owner.appConfig

        injector.endSession()

        XCTAssertTrue(config === owner.appConfig)
    }

    func testInjectedPropertyIsNotAffectedByOtherContainersSession() {
        let injector = makeInjector()
        let owner = SessionOwner(container: injector)
        let account = owner.account

        makeInjector().endSession()

        XCTAssertTrue(account === owner.account)
    }

    // MARK: - Captive dependency detection

    func testSingletonDependingOnSessionIsReported() {
        let injector = makeInjector()
        injector.bind(\.sessionConsumer, scope: .singleton) { resolver in
            SessionConsumer(account: resolver.resolve(\.accountService))
        }

        _ = injector.resolve(\.sessionConsumer)

        XCTAssertEqual(reports.value.count, 1)
        let report = reports.value.firstObject as? String ?? ""
        XCTAssertTrue(report.contains("AccountService"), report)
    }

    func testSingletonDependingOnSessionThroughNewScopeIsReported() {
        let injector = makeInjector()
        injector.bind(\.sessionConsumer) { resolver in
            SessionConsumer(account: resolver.resolve(\.accountService))
        }
        injector.bind(\.lazySessionConsumer, scope: .singleton) { resolver in
            _ = resolver.resolve(\.sessionConsumer)
            return LazySessionConsumer()
        }

        _ = injector.resolve(\.lazySessionConsumer)

        XCTAssertEqual(reports.value.count, 1)
    }

    func testSessionAndNewDependingOnSessionAreNotReported() {
        let injector = makeInjector()
        injector.bind(\.sessionConsumer, scope: .session) { resolver in
            SessionConsumer(account: resolver.resolve(\.accountService))
        }
        _ = injector.resolve(\.sessionConsumer)

        injector.bind(\.sessionConsumer) { resolver in
            SessionConsumer(account: resolver.resolve(\.accountService))
        }
        _ = injector.resolve(\.sessionConsumer)

        XCTAssertEqual(reports.value.count, 0)
    }

    func testSingletonAccessingSessionLazilyIsNotReported() {
        let injector = makeInjector()
        injector.bind(\.lazySessionConsumer, scope: .singleton) { _ in
            LazySessionConsumer(container: injector)
        }

        let consumer = injector.resolve(\.lazySessionConsumer)
        let first = consumer.account
        injector.endSession()

        XCTAssertEqual(reports.value.count, 0)
        XCTAssertFalse(first === consumer.account, "@Injected should follow the new session")
    }

    func testSingletonReadingInjectedSessionDuringConstructionIsNotReported() {
        let injector = makeInjector()
        injector.bind(\.lazySessionConsumer, scope: .singleton) { _ in
            let consumer = LazySessionConsumer(container: injector)
            _ = consumer.account
            return consumer
        }

        let consumer = injector.resolve(\.lazySessionConsumer)
        let first = consumer.account
        injector.endSession()

        XCTAssertEqual(reports.value.count, 0)
        XCTAssertFalse(first === consumer.account)
    }

    func testResolvingSessionAfterSingletonCreationIsNotReported() {
        let injector = makeInjector()
        _ = injector.resolve(\.appConfigService)

        _ = injector.resolve(\.accountService)

        XCTAssertEqual(reports.value.count, 0)
    }

    // MARK: - withOverrides

    func testOverridesContainerHasItsOwnSession() {
        Injector.withOverrides {
            $0.bind(\.accountService, scope: .session) { _ in AccountService() }
        } operation: {
            let outer = injected(\.accountService)

            let inner = Injector.withOverrides { _ in } operation: {
                injected(\.accountService)
            }

            XCTAssertFalse(outer === inner)
        }
    }

    func testEndSessionInOverridesDoesNotAffectParentContainer() {
        Injector.withOverrides {
            $0.bind(\.accountService, scope: .session) { _ in AccountService() }
        } operation: {
            let outer = injected(\.accountService)

            Injector.withOverrides { _ in } operation: {
                _ = injected(\.accountService)
                Injector.current.endSession()
            }

            XCTAssertEqual(outer.sessionDidEndCount, 0)
            XCTAssertTrue(outer === injected(\.accountService))
        }
    }

    func testEndSessionInParentDoesNotAffectExistingOverridesContainer() {
        Injector.withOverrides {
            $0.bind(\.accountService, scope: .session) { _ in AccountService() }
        } operation: {
            let parent = Injector.current

            Injector.withOverrides { _ in } operation: {
                let before = injected(\.accountService)
                parent.endSession()

                XCTAssertEqual(before.sessionDidEndCount, 0)
                XCTAssertTrue(before === injected(\.accountService))
            }
        }
    }

    // MARK: - Concurrency

    func testEndSessionWaitsForInFlightCreationWithoutDeadlock() {
        let injector = makeInjector()
        let started = DispatchSemaphore(value: 0)
        let resolved = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        injector.bind(\.accountService, scope: .session) { resolver in
            started.signal()
            Thread.sleep(forTimeInterval: 0.05)
            // Needs the container lock while endSession may be running.
            _ = resolver.resolve(\.appConfigService)
            return AccountService()
        }

        let box = UncheckedSendable(value: (injector, NSMutableArray()))
        DispatchQueue.global().async {
            box.value.1.add(box.value.0.resolve(\.accountService))
            resolved.signal()
        }
        started.wait()
        DispatchQueue.global().async {
            box.value.0.endSession()
            ended.signal()
        }

        XCTAssertEqual(resolved.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(ended.wait(timeout: .now() + 2), .success)
        let inFlight = box.value.1.firstObject as? AccountService
        XCTAssertEqual(inFlight?.sessionDidEndCount, 1, "an instance finished during endSession belongs to the ended session")
        XCTAssertFalse(inFlight === injector.resolve(\.accountService))
    }

    func testEndedStorageRefusesToCreate() {
        let storage = Injector.SingletonStorage()

        XCTAssertNil(storage.end())
        XCTAssertNil(storage.instance { AccountService() })
    }

    func testEndedStorageKeepsExistingInstance() {
        let storage = Injector.SingletonStorage()
        let created = storage.instance { AccountService() } as AnyObject?

        let ended = storage.end() as AnyObject?

        XCTAssertTrue(created === ended)
        XCTAssertTrue(storage.instance { AccountService() } as AnyObject? === created)
    }

    func testEveryEndedSessionInstanceIsNotifiedExactlyOnce() {
        let injector = makeInjector()
        let created = UncheckedSendable(value: NSMutableArray())
        let createdLock = NSLock()
        injector.bind(\.accountService, scope: .session) { _ in
            let account = AccountService()
            createdLock.lock()
            created.value.add(account)
            createdLock.unlock()
            return account
        }

        DispatchQueue.concurrentPerform(iterations: 2000) { index in
            if index % 7 == 0 {
                injector.endSession()
            } else {
                _ = injector.resolve(\.accountService)
            }
        }

        let current = injector.resolve(\.accountService)
        let accounts = created.value.compactMap { $0 as? AccountService }
        XCTAssertGreaterThan(accounts.count, 1)
        for account in accounts {
            XCTAssertEqual(account.sessionDidEndCount, account === current ? 0 : 1)
        }
    }

    func testConcurrentResolvesAndEndSessions() {
        let injector = makeInjector()
        let owner = SessionOwner(container: injector)
        let ownerBox = UncheckedSendable(value: owner)

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index % 10 == 0 {
                injector.endSession()
            } else if index % 2 == 0 {
                _ = ownerBox.value.account
            } else {
                _ = injector.resolve(\.accountService)
            }
        }

        XCTAssertTrue(owner.account === injector.resolve(\.accountService))
    }
}