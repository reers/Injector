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
    func testBindServiceMacroOnlyExposesServiceEntryAPI() throws {
        let source = try String(contentsOfFile: bindServiceSourcePath)

        XCTAssertFalse(source.contains("_ serviceType: Service.Type"))
        XCTAssertTrue(source.contains("_ entryKeyPath: KeyPath<Injector, Entry<Service>>"))
    }

    func testBindServiceMacroCanRegisterAServiceEntry() throws {
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
}

private let bindServiceSourcePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/Injector/BindService.swift")
    .path
