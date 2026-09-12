// swift-tools-version: 6.3
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Injector",
    platforms: [
        .iOS(.v13),
        .macOS(.v13)
    ],
    products: [
        .library(name: "Injector", targets: ["Injector"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "601.0.1"..<"606.0.0"),
        .package(url: "https://github.com/reers/Rhea.git", from: "2.5.0")
    ],
    targets: [
        .macro(
            name: "InjectorMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "RheaTimeMacroExpansion", package: "Rhea")
            ]
        ),
        .target(
            name: "Injector",
            dependencies: [
                "InjectorMacros",
                .product(name: "RheaTime", package: "Rhea")
            ]
        ),
        .testTarget(
            name: "InjectorMacrosTests",
            dependencies: [
                "Injector",
                "InjectorMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ]
        )
    ]
)
