import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(InjectorMacros)
@testable import InjectorMacros

private let testMacros: [String: Macro.Type] = [
    "BindService": BindServiceMacro.self
]
#endif

final class BindServiceMacroTests: XCTestCase {
    func testBindServiceMacroOnlyExposesDependencyAPI() throws {
        let source = try String(contentsOfFile: bindServiceSourcePath)

        XCTAssertFalse(source.contains("_ serviceType: Service.Type"))
        XCTAssertTrue(source.contains("_ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>"))
    }

    func testBindServiceMacroCanRegisterADependency() throws {
        #if canImport(InjectorMacros)
        assertMacroExpansion(
            """
            @BindService(\\.paymentService, scope: .singleton)
            public final class PaymentService {
                public init() {}
            }
            """,
            expandedSource: """
            public final class PaymentService {
                public init() {}

                @used
                @section("__DATA,__rheatime")
                static let __macro_local_4rheafMu_: RheaRegisterInfo = (
                    0xb3957a4da5484cc9, 5, false, false,
                    { _ in
                        Injector.shared.bind(\\.paymentService, scope: .singleton) { _ in
                            PaymentService()
                        }
                    }
                )
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("InjectorMacros is only available when running tests for the host platform")
        #endif
    }

    func testBindServiceMacroDefaultsToSingletonScope() throws {
        #if canImport(InjectorMacros)
        assertMacroExpansion(
            """
            @BindService(\\.userService)
            final class UserService {
                init() {}
            }
            """,
            expandedSource: """
            final class UserService {
                init() {}

                @used
                @section("__DATA,__rheatime")
                static let __macro_local_4rheafMu_: RheaRegisterInfo = (
                    0xb3957a4da5484cc9, 5, false, false,
                    { _ in
                        Injector.shared.bind(\\.userService, scope: .singleton) { _ in
                            UserService()
                        }
                    }
                )
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("InjectorMacros is only available when running tests for the host platform")
        #endif
    }

    func testBindServiceMacroCanUseNewScope() throws {
        #if canImport(InjectorMacros)
        assertMacroExpansion(
            """
            @BindService(\\.userService, scope: .new)
            final class UserService {
                init() {}
            }
            """,
            expandedSource: """
            final class UserService {
                init() {}

                @used
                @section("__DATA,__rheatime")
                static let __macro_local_4rheafMu_: RheaRegisterInfo = (
                    0xb3957a4da5484cc9, 5, false, false,
                    { _ in
                        Injector.shared.bind(\\.userService, scope: .new) { _ in
                            UserService()
                        }
                    }
                )
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("InjectorMacros is only available when running tests for the host platform")
        #endif
    }

    func testBindServiceMacroSupportsStructs() throws {
        #if canImport(InjectorMacros)
        assertMacroExpansion(
            """
            @BindService(\\.configService)
            struct ConfigService {
            }
            """,
            expandedSource: """
            struct ConfigService {

                @used
                @section("__DATA,__rheatime")
                static let __macro_local_4rheafMu_: RheaRegisterInfo = (
                    0xb3957a4da5484cc9, 5, false, false,
                    { _ in
                        Injector.shared.bind(\\.configService, scope: .singleton) { _ in
                            ConfigService()
                        }
                    }
                )
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("InjectorMacros is only available when running tests for the host platform")
        #endif
    }

    func testBindServiceMacroSupportsActors() throws {
        #if canImport(InjectorMacros)
        assertMacroExpansion(
            """
            @BindService(\\.cacheService, scope: .new)
            actor CacheService {
            }
            """,
            expandedSource: """
            actor CacheService {

                @used
                @section("__DATA,__rheatime")
                static let __macro_local_4rheafMu_: RheaRegisterInfo = (
                    0xb3957a4da5484cc9, 5, false, false,
                    { _ in
                        Injector.shared.bind(\\.cacheService, scope: .new) { _ in
                            CacheService()
                        }
                    }
                )
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("InjectorMacros is only available when running tests for the host platform")
        #endif
    }

    func testBindServiceMacroAcceptsScopeBeforeTheKeyPath() throws {
        #if canImport(InjectorMacros)
        assertMacroExpansion(
            """
            @BindService(scope: .new, \\.userService)
            final class UserService {
            }
            """,
            expandedSource: """
            final class UserService {

                @used
                @section("__DATA,__rheatime")
                static let __macro_local_4rheafMu_: RheaRegisterInfo = (
                    0xb3957a4da5484cc9, 5, false, false,
                    { _ in
                        Injector.shared.bind(\\.userService, scope: .new) { _ in
                            UserService()
                        }
                    }
                )
            }
            """,
            macros: testMacros
        )
        #else
        throw XCTSkip("InjectorMacros is only available when running tests for the host platform")
        #endif
    }

    func testBindServiceMacroRejectsEnums() throws {
        #if canImport(InjectorMacros)
        assertMacroExpansion(
            """
            @BindService(\\.userService)
            enum UserService {
            }
            """,
            expandedSource: """
            enum UserService {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@BindService can only be attached to a class, struct, or actor", line: 1, column: 1)
            ],
            macros: testMacros
        )
        #else
        throw XCTSkip("InjectorMacros is only available when running tests for the host platform")
        #endif
    }

    func testBindServiceMacroRejectsGenericTypes() throws {
        #if canImport(InjectorMacros)
        assertMacroExpansion(
            """
            @BindService(\\.userService)
            final class UserService<Value> {
            }
            """,
            expandedSource: """
            final class UserService<Value> {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@BindService does not support generic service implementation types", line: 1, column: 1)
            ],
            macros: testMacros
        )
        #else
        throw XCTSkip("InjectorMacros is only available when running tests for the host platform")
        #endif
    }

    func testBindServiceMacroRequiresAKeyPath() throws {
        #if canImport(InjectorMacros)
        assertMacroExpansion(
            """
            @BindService(scope: .new)
            final class UserService {
            }
            """,
            expandedSource: """
            final class UserService {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@BindService requires a dependency key path, for example @BindService(\\.paymentService)",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
        #else
        throw XCTSkip("InjectorMacros is only available when running tests for the host platform")
        #endif
    }

    func testBindServiceMacroRequiresArguments() throws {
        #if canImport(InjectorMacros)
        assertMacroExpansion(
            """
            @BindService
            final class UserService {
            }
            """,
            expandedSource: """
            final class UserService {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@BindService requires a dependency key path, for example @BindService(\\.paymentService)",
                    line: 1,
                    column: 1
                )
            ],
            macros: testMacros
        )
        #else
        throw XCTSkip("InjectorMacros is only available when running tests for the host platform")
        #endif
    }
}

private let bindServiceSourcePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Injector/BindService.swift")
    .path
