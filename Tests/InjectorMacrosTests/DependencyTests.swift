import Injector
import XCTest

private protocol DependencyTestPaymentService: AnyObject {}
private final class DependencyTestPaymentServiceImpl: DependencyTestPaymentService {}
private final class DependencyTestConcreteService {}

private extension Injector {
    var primaryPaymentService: Dependency<DependencyTestPaymentService> {
        .service(DependencyTestPaymentService.self)
    }

    var fallbackPaymentService: Dependency<DependencyTestPaymentService> {
        .service(DependencyTestPaymentService.self)
    }

    var concreteService: Dependency<DependencyTestConcreteService> {
        .service()
    }
}

final class DependencyTests: XCTestCase {
    func testServiceFactoryInfersTheServiceType() {
        let dependency = Injector().concreteService

        XCTAssertTrue(dependency.serviceType == DependencyTestConcreteService.self)
        XCTAssertEqual(dependency.key, "concreteService")
    }

    func testExplicitKeyIsUsedAsIs() {
        let dependency = Dependency(DependencyTestConcreteService.self, key: "customKey")

        XCTAssertEqual(dependency.key, "customKey")
        XCTAssertTrue(dependency.serviceType == DependencyTestConcreteService.self)
    }

    func testServiceFactoryWithExplicitKey() {
        let dependency = Dependency<DependencyTestConcreteService>.service(key: "customKey")

        XCTAssertEqual(dependency.key, "customKey")
    }

    func testDefaultKeyIsTheEnclosingDeclarationName() {
        let dependency = Dependency<DependencyTestConcreteService>.service()

        XCTAssertEqual(dependency.key, "testDefaultKeyIsTheEnclosingDeclarationName()")
    }

    func testNamedDependenciesOfTheSameTypeAreIndependent() {
        let primary = DependencyTestPaymentServiceImpl()
        let fallback = DependencyTestPaymentServiceImpl()
        let container = Injector()
        container.bindInstance(\.primaryPaymentService, primary)
        container.bindInstance(\.fallbackPaymentService, fallback)

        XCTAssertTrue(container.resolve(\.primaryPaymentService) === primary)
        XCTAssertTrue(container.resolve(\.fallbackPaymentService) === fallback)
    }

    func testRemovingOneNamedDependencyKeepsTheOther() {
        let fallback = DependencyTestPaymentServiceImpl()
        let container = Injector()
        container.bindInstance(\.primaryPaymentService, DependencyTestPaymentServiceImpl())
        container.bindInstance(\.fallbackPaymentService, fallback)

        container.remove(\.primaryPaymentService)

        XCTAssertTrue(container.resolve(\.fallbackPaymentService) === fallback)
    }

    func testSingletonsAreTrackedPerNamedDependency() {
        let container = Injector()
        container.bind(\.primaryPaymentService, scope: .singleton) { _ in DependencyTestPaymentServiceImpl() }
        container.bind(\.fallbackPaymentService, scope: .singleton) { _ in DependencyTestPaymentServiceImpl() }

        XCTAssertFalse(container.resolve(\.primaryPaymentService) === container.resolve(\.fallbackPaymentService))
    }
}
