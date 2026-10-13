import Injector
import XCTest

private final class OverrideTestService: Sendable {
    let id: Int

    init(id: Int = 0) {
        self.id = id
    }
}

private final class OverrideTestConsumer {
    let service: OverrideTestService

    init(service: OverrideTestService) {
        self.service = service
    }
}

private enum OverrideTestError: Error {
    case update
    case operation
}

private extension Injector {
    var overrideTestService: Dependency<OverrideTestService> {
        .service()
    }

    var overrideTestConsumer: Dependency<OverrideTestConsumer> {
        .service()
    }
}

final class WithOverridesTests: XCTestCase {
    // MARK: - Scope boundaries

    func testCurrentIsSharedOutsideAnyScope() {
        XCTAssertTrue(Injector.current === Injector.shared)
    }

    func testCurrentIsAScopedContainerInsideAndSharedAfterwards() {
        let isScopedInside = Injector.withOverrides { _ in } operation: {
            Injector.current !== Injector.shared
        }

        XCTAssertTrue(isScopedInside)
        XCTAssertTrue(Injector.current === Injector.shared)
    }

    func testEachScopeGetsItsOwnContainer() {
        let first = Injector.withOverrides { _ in } operation: { Injector.current }
        let second = Injector.withOverrides { _ in } operation: { Injector.current }

        XCTAssertFalse(first === second)
    }

    func testUpdateReceivesTheScopedContainer() {
        let (updated, current) = Injector.withOverrides { injector in
            injector.bindInstance(\.overrideTestService, OverrideTestService())
        } operation: {
            (Injector.current.resolve(\.overrideTestService), Injector.current.resolve(\.overrideTestService))
        }

        XCTAssertTrue(updated === current)
    }

    func testBindingsMadeOnCurrentInsideTheOperationDoNotLeakToTheParentScope() {
        let outerService = OverrideTestService()

        let afterInnerScope = Injector.withOverrides {
            $0.bindInstance(\.overrideTestService, outerService)
        } operation: {
            Injector.withOverrides { _ in } operation: {
                Injector.current.bindInstance(\.overrideTestService, OverrideTestService())
            }
            return Injector.current.resolve(\.overrideTestService)
        }

        XCTAssertTrue(afterInnerScope === outerService)
    }

    func testRemovingInsideAScopeDoesNotAffectTheParentScope() {
        let outerService = OverrideTestService()

        let afterInnerScope = Injector.withOverrides {
            $0.bindInstance(\.overrideTestService, outerService)
        } operation: {
            Injector.withOverrides {
                $0.remove(\.overrideTestService)
            } operation: {}
            return Injector.current.resolve(\.overrideTestService)
        }

        XCTAssertTrue(afterInnerScope === outerService)
    }

    func testInnerScopeInheritsParentBindings() {
        let outerService = OverrideTestService()

        let resolved = Injector.withOverrides {
            $0.bindInstance(\.overrideTestService, outerService)
        } operation: {
            Injector.withOverrides { _ in } operation: {
                Injector.current.resolve(\.overrideTestService)
            }
        }

        XCTAssertTrue(resolved === outerService)
    }

    // MARK: - Factories resolve through the scope they are resolved from

    func testParentFactoryUsesTheInnerScopeOverride() {
        let outerService = OverrideTestService(id: 1)
        let innerService = OverrideTestService(id: 2)

        let (fromInner, fromOuter) = Injector.withOverrides {
            $0.bindInstance(\.overrideTestService, outerService)
            $0.bind(\.overrideTestConsumer) { resolver in
                OverrideTestConsumer(service: resolver.resolve(\.overrideTestService))
            }
        } operation: {
            let fromInner = Injector.withOverrides {
                $0.bindInstance(\.overrideTestService, innerService)
            } operation: {
                Injector.current.resolve(\.overrideTestConsumer).service
            }
            return (fromInner, Injector.current.resolve(\.overrideTestConsumer).service)
        }

        XCTAssertTrue(fromInner === innerService)
        XCTAssertTrue(fromOuter === outerService)
    }

    // MARK: - Errors

    func testUpdateErrorsAreRethrownAndSkipTheOperation() {
        var didRunOperation = false

        XCTAssertThrowsError(
            try Injector.withOverrides { _ in
                throw OverrideTestError.update
            } operation: {
                didRunOperation = true
            }
        ) { error in
            XCTAssertEqual(error as? OverrideTestError, .update)
        }
        XCTAssertFalse(didRunOperation)
    }

    func testCurrentIsRestoredAfterTheOperationThrows() {
        XCTAssertThrowsError(
            try Injector.withOverrides { _ in } operation: {
                throw OverrideTestError.operation
            }
        )

        XCTAssertTrue(Injector.current === Injector.shared)
    }

    func testAsyncOperationErrorsAreRethrown() async {
        do {
            try await Injector.withOverrides { _ in } operation: { () async throws -> Void in
                await Task.yield()
                throw OverrideTestError.operation
            }
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? OverrideTestError, .operation)
        }
    }

    func testAsyncUpdateErrorsAreRethrownAndSkipTheOperation() async {
        let didRunOperation = LockedCounter()

        do {
            try await Injector.withOverrides { _ in
                throw OverrideTestError.update
            } operation: { () async throws -> Void in
                didRunOperation.increment()
            }
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? OverrideTestError, .update)
        }
        XCTAssertEqual(didRunOperation.value, 0)
    }

    // MARK: - Tasks

    func testChildTasksInheritTheScope() async {
        let scopedService = OverrideTestService()

        let resolved = await Injector.withOverrides {
            $0.bindInstance(\.overrideTestService, scopedService)
        } operation: {
            await Task {
                injected(\.overrideTestService)
            }.value
        }

        XCTAssertTrue(resolved === scopedService)
    }

    func testTaskGroupChildrenInheritTheScope() async {
        let scopedService = OverrideTestService()

        let allScoped = await Injector.withOverrides {
            $0.bindInstance(\.overrideTestService, scopedService)
        } operation: {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        injected(\.overrideTestService) === scopedService
                    }
                }
                var results: [Bool] = []
                for await result in group {
                    results.append(result)
                }
                return results.allSatisfy { $0 }
            }
        }

        XCTAssertTrue(allScoped)
    }

    func testDetachedTasksDoNotInheritTheScope() async {
        let detachedSeesShared = await Injector.withOverrides { _ in } operation: {
            await Task.detached {
                Injector.current === Injector.shared
            }.value
        }

        XCTAssertTrue(detachedSeesShared)
    }

    func testConcurrentScopesAreIsolated() async {
        let allIsolated = await withTaskGroup(of: Bool.self) { group in
            for id in 0..<20 {
                group.addTask {
                    let service = OverrideTestService(id: id)
                    let resolved = await Injector.withOverrides {
                        $0.bindInstance(\.overrideTestService, service)
                    } operation: {
                        await Task.yield()
                        return injected(\.overrideTestService)
                    }
                    return resolved === service
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results.allSatisfy { $0 }
        }

        XCTAssertTrue(allIsolated)
    }
}
