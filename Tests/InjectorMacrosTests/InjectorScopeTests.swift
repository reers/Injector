import Injector
import XCTest

private final class TestScopedService {}
private protocol TestDependencyService: AnyObject {}
private final class TestDependencyServiceImpl: TestDependencyService {}
private final class TestOverrideService {}

private enum TestOverrideError: Error {
    case expected
}

private extension Injector {
    var testDependencyService: Dependency<TestDependencyService> {
        .service(TestDependencyService.self)
    }

    var testScopedService: Dependency<TestScopedService> {
        .service(TestScopedService.self)
    }

    var testOverrideService: Dependency<TestOverrideService> {
        .service(TestOverrideService.self)
    }
}

private struct TestDependencyConsumer {
    @Injected(\.testDependencyService) var service: TestDependencyService
}

private struct TestOverrideConsumer {
    @Injected(\.testOverrideService) var service: TestOverrideService
}

final class InjectorScopeTests: XCTestCase {
    func testPackageSupportsIOS13() throws {
        let packageSource = try String(contentsOfFile: packageSourcePath)

        XCTAssertTrue(packageSource.contains(".iOS(.v13)"))
    }

    func testDependencyAndScopeAreTopLevelPublicTypes() throws {
        let injectorSource = try String(contentsOfFile: injectorSourcePath)
        let dependencySource = try String(contentsOfFile: dependencySourcePath)

        XCTAssertTrue(injectorSource.contains("public final class Injector"))
        XCTAssertTrue(injectorSource.contains("scope: Scope = .new"))
        XCTAssertTrue(dependencySource.contains("public struct Dependency<Service>"))
        XCTAssertTrue(dependencySource.contains("public enum Scope"))
        XCTAssertFalse(injectorSource.contains("public struct Dependency<Service>"))
        XCTAssertFalse(injectorSource.contains("public struct Entry<Service>"))
        XCTAssertFalse(injectorSource.contains("public enum Scope"))
        XCTAssertFalse(injectorSource.contains("DIContainer"))
        XCTAssertFalse(injectorSource.contains("DIEntry"))
        XCTAssertFalse(injectorSource.contains("DIEntries"))
        XCTAssertFalse(injectorSource.contains("DIScope"))
        XCTAssertFalse(dependencySource.contains("public struct Entry<Service>"))
        XCTAssertFalse(dependencySource.contains("DIEntry"))
        XCTAssertFalse(dependencySource.contains("DIEntries"))
        XCTAssertFalse(dependencySource.contains("DIScope"))
    }

    func testInjectorOnlyExposesDependencyKeyPathAPI() throws {
        let source = try String(contentsOfFile: injectorSourcePath)

        XCTAssertFalse(source.contains("func resolve<Service>(_ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public init(\n        _ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public func bind<Service>(\n        _ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public func bind<Service>(\n        _ dependency: Dependency<Service>"))
        XCTAssertFalse(source.contains("public func bindInstance<Service>(\n        _ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public func bindInstance<Service>(\n        _ dependency: Dependency<Service>"))
        XCTAssertFalse(source.contains("public func remove<Service>(_ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public func remove<Service>(_ dependency: Dependency<Service>"))
        XCTAssertFalse(source.contains("public func resolve<Service>(_ serviceType: Service.Type"))
        XCTAssertFalse(source.contains("public func resolve<Service>(_ dependency: Dependency<Service>"))
    }

    func testDependencyUsesThePropertyNameAsItsKey() {
        XCTAssertEqual(Injector().testDependencyService.key, "testDependencyService")
    }

    func testCanBindResolveAndInjectUsingDependencies() {
        let (resolved, injected) = Injector.withOverrides {
            $0.bind(\.testDependencyService, scope: .singleton) { _ in
                TestDependencyServiceImpl()
            }
        } operation: {
            (Injector.current.resolve(\.testDependencyService), TestDependencyConsumer().service)
        }

        XCTAssertTrue(resolved is TestDependencyServiceImpl)
        XCTAssertTrue(injected is TestDependencyServiceImpl)
    }

    func testCanBindInstanceUsingDependencies() {
        let service = TestDependencyServiceImpl()

        let resolved = Injector.withOverrides {
            $0.bindInstance(\.testDependencyService, service)
        } operation: {
            Injector.current.resolve(\.testDependencyService)
        }

        XCTAssertTrue(resolved === service)
    }

    func testBindDefaultsToNewScope() {
        let (first, second) = Injector.withOverrides {
            $0.bind(\.testScopedService) { _ in
                TestScopedService()
            }
        } operation: {
            (Injector.current.resolve(\.testScopedService), Injector.current.resolve(\.testScopedService))
        }

        XCTAssertFalse(first === second)
    }

    func testNewScopeCreatesANewInstanceEveryResolve() {
        let (first, second) = Injector.withOverrides {
            $0.bind(\.testScopedService, scope: .new) { _ in
                TestScopedService()
            }
        } operation: {
            (Injector.current.resolve(\.testScopedService), Injector.current.resolve(\.testScopedService))
        }

        XCTAssertFalse(first === second)
    }

    func testSingletonScopeReusesTheSameInstance() {
        let (first, second) = Injector.withOverrides {
            $0.bind(\.testScopedService, scope: .singleton) { _ in
                TestScopedService()
            }
        } operation: {
            (Injector.current.resolve(\.testScopedService), Injector.current.resolve(\.testScopedService))
        }

        XCTAssertTrue(first === second)
    }

    func testWithOverridesUsesScopedBindingsForInjectedProperties() throws {
        let outerService = TestOverrideService()
        let scopedService = TestOverrideService()

        let (resolved, outerAfterScope) = Injector.withOverrides {
            $0.bindInstance(\.testOverrideService, outerService)
        } operation: {
            let resolved = Injector.withOverrides {
                $0.bindInstance(\.testOverrideService, scopedService)
            } operation: {
                TestOverrideConsumer().service
            }
            return (resolved, Injector.current.resolve(\.testOverrideService))
        }

        XCTAssertTrue(resolved === scopedService)
        XCTAssertTrue(outerAfterScope === outerService)
    }

    func testWithOverridesProvidesCurrentInjectorInsideOperation() throws {
        let scopedService = TestOverrideService()

        let resolved = Injector.withOverrides {
            $0.bindInstance(\.testOverrideService, scopedService)
        } operation: {
            Injector.current.resolve(\.testOverrideService)
        }

        XCTAssertTrue(resolved === scopedService)
    }

    func testWithOverridesRethrowsOperationErrors() {
        XCTAssertThrowsError(
            try Injector.withOverrides { _ in
            } operation: {
                throw TestOverrideError.expected
            }
        ) { error in
            XCTAssertEqual(error as? TestOverrideError, .expected)
        }
    }

    func testWithOverridesKeepsScopedBindingsAcrossAsyncOperations() async throws {
        let scopedService = TestOverrideService()

        let resolved = await Injector.withOverrides {
            $0.bindInstance(\.testOverrideService, scopedService)
        } operation: {
            await Task.yield()
            return TestOverrideConsumer().service
        }

        XCTAssertTrue(resolved === scopedService)
    }
}

private let packageSourcePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Package.swift")
    .path

private let injectorSourcePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Injector/Injector.swift")
    .path

private let dependencySourcePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Injector/Dependency.swift")
    .path
