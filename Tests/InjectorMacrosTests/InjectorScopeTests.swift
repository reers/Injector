import Injector
import XCTest

private final class TestScopedService {}
private protocol TestEntryService: AnyObject {}
private final class TestEntryServiceImpl: TestEntryService {}

private extension Injector {
    var testEntryService: Entry<TestEntryService> {
        .service(TestEntryService.self)
    }

    var testScopedService: Entry<TestScopedService> {
        .service(TestScopedService.self)
    }
}

private struct TestEntryConsumer {
    @Injected(\.testEntryService) var service: TestEntryService
}

final class InjectorScopeTests: XCTestCase {
    func testEntryAndScopeAreTopLevelPublicTypes() throws {
        let injectorSource = try String(contentsOfFile: injectorSourcePath)
        let entrySource = try String(contentsOfFile: entrySourcePath)

        XCTAssertTrue(injectorSource.contains("public final class Injector"))
        XCTAssertTrue(injectorSource.contains("scope: Scope = .new"))
        XCTAssertTrue(entrySource.contains("public struct Entry<Service>"))
        XCTAssertTrue(entrySource.contains("public enum Scope"))
        XCTAssertFalse(injectorSource.contains("public struct Entry<Service>"))
        XCTAssertFalse(injectorSource.contains("public enum Scope"))
        XCTAssertFalse(injectorSource.contains("DIContainer"))
        XCTAssertFalse(injectorSource.contains("DIEntry"))
        XCTAssertFalse(injectorSource.contains("DIEntries"))
        XCTAssertFalse(injectorSource.contains("DIScope"))
        XCTAssertFalse(entrySource.contains("DIEntry"))
        XCTAssertFalse(entrySource.contains("DIEntries"))
        XCTAssertFalse(entrySource.contains("DIScope"))
    }

    func testInjectorOnlyExposesServiceEntryKeyPathAPI() throws {
        let source = try String(contentsOfFile: injectorSourcePath)

        XCTAssertFalse(source.contains("func resolve<Service>(_ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public init(\n        _ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public func bind<Service>(\n        _ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public func bind<Service>(\n        _ entry: Entry<Service>"))
        XCTAssertFalse(source.contains("public func bindInstance<Service>(\n        _ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public func bindInstance<Service>(\n        _ entry: Entry<Service>"))
        XCTAssertFalse(source.contains("public func remove<Service>(_ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public func remove<Service>(_ entry: Entry<Service>"))
        XCTAssertFalse(source.contains("public func resolve<Service>(_ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public func resolve<Service>(_ entry: Entry<Service>"))
    }

    func testServiceEntryUsesThePropertyNameAsItsKey() {
        XCTAssertEqual(Injector().testEntryService.key, "testEntryService")
    }

    func testCanBindResolveAndInjectUsingServiceEntries() {
        Injector.shared.withTestOverrides {
            Injector.shared.bind(\.testEntryService, scope: .singleton) { _ in
                TestEntryServiceImpl()
            }

            let resolved = Injector.shared.resolve(\.testEntryService)
            let injected = TestEntryConsumer().service

            XCTAssertTrue(resolved is TestEntryServiceImpl)
            XCTAssertTrue(injected is TestEntryServiceImpl)
        }
    }

    func testCanBindInstanceUsingServiceEntries() {
        Injector.shared.withTestOverrides {
            let service = TestEntryServiceImpl()

            Injector.shared.bindInstance(\.testEntryService, service)

            let resolved = Injector.shared.resolve(\.testEntryService)
            XCTAssertTrue(resolved === service)
        }
    }

    func testBindDefaultsToNewScope() {
        Injector.shared.withTestOverrides {
            Injector.shared.bind(\.testScopedService) { _ in
                TestScopedService()
            }

            let first = Injector.shared.resolve(\.testScopedService)
            let second = Injector.shared.resolve(\.testScopedService)

            XCTAssertFalse(first === second)
        }
    }

    func testNewScopeCreatesANewInstanceEveryResolve() {
        Injector.shared.withTestOverrides {
            Injector.shared.bind(\.testScopedService, scope: .new) { _ in
                TestScopedService()
            }

            let first = Injector.shared.resolve(\.testScopedService)
            let second = Injector.shared.resolve(\.testScopedService)

            XCTAssertFalse(first === second)
        }
    }

    func testSingletonScopeReusesTheSameInstance() {
        Injector.shared.withTestOverrides {
            Injector.shared.bind(\.testScopedService, scope: .singleton) { _ in
                TestScopedService()
            }

            let first = Injector.shared.resolve(\.testScopedService)
            let second = Injector.shared.resolve(\.testScopedService)

            XCTAssertTrue(first === second)
        }
    }
}

private let injectorSourcePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Injector/Injector.swift")
    .path

private let entrySourcePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Injector/Entry.swift")
    .path
