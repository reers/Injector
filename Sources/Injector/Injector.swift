@_exported import RheaTime
import Foundation

public protocol Resolver: AnyObject {
    func resolve<Service>(_ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>) -> Service
}

public protocol Module {
    static func register(into injector: Injector)
}

@propertyWrapper
public struct Injected<Service> {
    private let resolveValue: () -> Service

    public init(_ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>) {
        self.resolveValue = {
            Injector.current.resolve(dependencyKeyPath)
        }
    }

    public init(
        _ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>,
        container: Injector
    ) {
        self.resolveValue = {
            container.resolve(dependencyKeyPath)
        }
    }

    public var wrappedValue: Service {
        resolveValue()
    }
}

public final class Injector: Resolver, @unchecked Sendable {
    public static let shared = Injector()

    @TaskLocal private static var scopedInjector: Injector?

    public static var current: Injector {
        scopedInjector ?? shared
    }

    private struct Registration {
        let scope: Scope
        let factory: (Resolver) -> Any
        var instance: Any?
    }

    private struct RegistrationKey: Hashable {
        let serviceType: ObjectIdentifier
        let dependencyKey: String?

        init<Service>(_ serviceType: Service.Type, dependencyKey: String? = nil) {
            self.serviceType = ObjectIdentifier(serviceType)
            self.dependencyKey = dependencyKey
        }

        init<Service>(_ dependency: Dependency<Service>) {
            self.init(dependency.serviceType, dependencyKey: dependency.key)
        }
    }

    private let lock = NSRecursiveLock()
    private var registrations: [RegistrationKey: Registration] = [:]
    private var didInstallRheaServiceBindings = false
    private var isUsingTestOverrides = false

    public init() {}

    public static func withOverrides<Result>(
        _ update: (Injector) throws -> Void,
        operation: () throws -> Result
    ) rethrows -> Result {
        let injector = makeOverrideInjector()
        try update(injector)
        return try $scopedInjector.withValue(injector) {
            try operation()
        }
    }

    public static func withOverrides<Result>(
        _ update: (Injector) throws -> Void,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        let injector = makeOverrideInjector()
        try update(injector)
        return try await $scopedInjector.withValue(injector) {
            try await operation()
        }
    }

    public func installRheaServiceBindingsIfNeeded() {
        lock.lock()
        defer { lock.unlock() }

        guard !didInstallRheaServiceBindings else {
            return
        }

        didInstallRheaServiceBindings = true
        Rhea.trigger(event: .injectorBindService)
    }

    public func install(_ module: Module.Type) {
        module.register(into: self)
    }

    public func install(_ modules: Module.Type...) {
        modules.forEach { install($0) }
    }

    public func bind<Service>(
        _ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>,
        scope: Scope = .new,
        factory: @escaping (Resolver) -> Service
    ) {
        bind(self[keyPath: dependencyKeyPath], scope: scope, factory: factory)
    }

    private func bind<Service>(
        _ dependency: Dependency<Service>,
        scope: Scope = .new,
        factory: @escaping (Resolver) -> Service
    ) {
        lock.lock()
        defer { lock.unlock() }

        let key = RegistrationKey(dependency)
        registrations[key] = Registration(
            scope: scope,
            factory: { resolver in factory(resolver) },
            instance: nil
        )
    }

    public func bindInstance<Service>(
        _ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>,
        _ instance: Service
    ) {
        bindInstance(self[keyPath: dependencyKeyPath], instance)
    }

    private func bindInstance<Service>(
        _ dependency: Dependency<Service>,
        _ instance: Service
    ) {
        lock.lock()
        defer { lock.unlock() }

        let key = RegistrationKey(dependency)
        registrations[key] = Registration(
            scope: .singleton,
            factory: { _ in instance },
            instance: instance
        )
    }

    public func remove<Service>(_ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>) {
        remove(self[keyPath: dependencyKeyPath])
    }

    private func remove<Service>(_ dependency: Dependency<Service>) {
        lock.lock()
        defer { lock.unlock() }

        let key = RegistrationKey(dependency)
        registrations.removeValue(forKey: key)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        didInstallRheaServiceBindings = false
        registrations.removeAll()
    }

    /// Temporarily overrides the container registration table, then restores it.
    ///
    /// This is intended for tests that need to replace dependencies with mocks while
    /// preserving existing registrations and avoiding lazy installation of
    /// `@BindService` registrations during the override scope.
    public func withTestOverrides<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        let savedRegistrations = registrations
        let savedDidInstallRheaServiceBindings = didInstallRheaServiceBindings
        let savedIsUsingTestOverrides = isUsingTestOverrides
        isUsingTestOverrides = true
        defer {
            registrations = savedRegistrations
            didInstallRheaServiceBindings = savedDidInstallRheaServiceBindings
            isUsingTestOverrides = savedIsUsingTestOverrides
            lock.unlock()
        }

        return try body()
    }

    public func resolve<Service>(_ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>) -> Service {
        resolve(self[keyPath: dependencyKeyPath])
    }

    private func resolve<Service>(_ dependency: Dependency<Service>) -> Service {
        resolve(serviceType: dependency.serviceType, key: RegistrationKey(dependency))
    }

    private func resolve<Service>(
        serviceType: Service.Type,
        key: RegistrationKey
    ) -> Service {
        installRheaServiceBindingsBeforeResolvingIfNeeded()

        lock.lock()
        defer { lock.unlock() }

        guard var registration = registrations[key] else {
            fatalError("No Injector registration found for \(serviceType)")
        }

        switch registration.scope {
        case .new:
            return makeService(from: registration, as: serviceType)

        case .singleton:
            if let existing = registration.instance as? Service {
                return existing
            }

            let created = registration.factory(self)
            registration.instance = created
            registrations[key] = registration

            guard let service = created as? Service else {
                fatalError("Injector registration for \(serviceType) returned \(type(of: created))")
            }
            return service
        }
    }

    private func makeService<Service>(
        from registration: Registration,
        as serviceType: Service.Type
    ) -> Service {
        let created = registration.factory(self)
        guard let service = created as? Service else {
            fatalError("Injector registration for \(serviceType) returned \(type(of: created))")
        }
        return service
    }

    private func installRheaServiceBindingsBeforeResolvingIfNeeded() {
        lock.lock()
        let shouldInstall = !isUsingTestOverrides && !didInstallRheaServiceBindings
        lock.unlock()

        if shouldInstall {
            installRheaServiceBindingsIfNeeded()
        }
    }

    private static func makeOverrideInjector() -> Injector {
        if scopedInjector == nil {
            shared.installRheaServiceBindingsIfNeeded()
        }

        return current.copyForOverrides()
    }

    private func copyForOverrides() -> Injector {
        lock.lock()
        defer { lock.unlock() }

        let injector = Injector()
        injector.registrations = registrations
        injector.didInstallRheaServiceBindings = didInstallRheaServiceBindings
        return injector
    }
}

public extension RheaEvent {
    static let injectorBindService: RheaEvent = "injectorBindService"
}
