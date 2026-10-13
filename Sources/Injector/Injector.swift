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

/// Expression form of `@Injected`, for call sites that do not want to declare a property.
///
/// Resolves from `Injector.current`, so it honors `Injector.withOverrides` scopes.
public func injected<Service>(_ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>) -> Service {
    Injector.current.resolve(dependencyKeyPath)
}

public final class Injector: Resolver, @unchecked Sendable {
    public static let shared = Injector { _ in
        Rhea.trigger(event: .injectorBindService)
    }

    @TaskLocal private static var scopedInjector: Injector?

    public static var current: Injector {
        scopedInjector ?? shared
    }

    /// Holds a singleton instance with its own lock, so factories never run under the container lock.
    private final class SingletonStorage {
        private let lock = NSRecursiveLock()
        private var instance: Any?

        init(instance: Any? = nil) {
            self.instance = instance
        }

        var existingInstance: Any? {
            lock.lock()
            defer { lock.unlock() }
            return instance
        }

        func instance(orMake make: () -> Any) -> Any {
            lock.lock()
            defer { lock.unlock() }

            if let instance {
                return instance
            }
            let created = make()
            instance = created
            return created
        }
    }

    private struct Registration {
        let scope: Scope
        let factory: (Resolver) -> Any
        let singletonStorage: SingletonStorage

        init(scope: Scope, factory: @escaping (Resolver) -> Any, instance: Any? = nil) {
            self.scope = scope
            self.factory = factory
            self.singletonStorage = SingletonStorage(instance: instance)
        }

        /// Keeps already created singletons, but creates new ones in its own storage.
        func detachedCopy() -> Registration {
            Registration(scope: scope, factory: factory, instance: singletonStorage.existingInstance)
        }

        /// Drops any created singleton.
        func freshCopy() -> Registration {
            Registration(scope: scope, factory: factory)
        }
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
    /// `@BindService` registrations recorded on the first Rhea trigger.
    /// Rhea runs non-repeatable callbacks only once, so later installs replay this snapshot.
    private var rheaServiceRegistrations: [RegistrationKey: Registration]?
    private var recordingRheaServiceRegistrations: [RegistrationKey: Registration]?
    /// Fires the `@BindService` registrations. Only the container that owns it records and replays them;
    /// other containers delegate to `shared`, which `@BindService` always binds into.
    private let serviceBindingsTrigger: ((Injector) -> Void)?

    public convenience init() {
        self.init(serviceBindingsTrigger: nil)
    }

    init(serviceBindingsTrigger: ((Injector) -> Void)?) {
        self.serviceBindingsTrigger = serviceBindingsTrigger
    }

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
        guard let serviceBindingsTrigger else {
            Injector.shared.installRheaServiceBindingsIfNeeded()
            lock.lock()
            didInstallRheaServiceBindings = true
            lock.unlock()
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard !didInstallRheaServiceBindings else {
            return
        }
        didInstallRheaServiceBindings = true

        if let rheaServiceRegistrations {
            for (key, registration) in rheaServiceRegistrations {
                registrations[key] = registration.freshCopy()
            }
            return
        }

        recordingRheaServiceRegistrations = [:]
        serviceBindingsTrigger(self)
        rheaServiceRegistrations = recordingRheaServiceRegistrations
        recordingRheaServiceRegistrations = nil
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
        let registration = Registration(scope: scope, factory: { resolver in factory(resolver) })
        registrations[key] = registration
        recordingRheaServiceRegistrations?[key] = registration
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

    /// Removes all registrations and created singletons.
    ///
    /// `@BindService` registrations are installed again before the next resolve.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        didInstallRheaServiceBindings = false
        registrations.removeAll()
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
        let registration = registrations[key]
        lock.unlock()

        guard let registration else {
            fatalError("No Injector registration found for \(serviceType)")
        }

        let created: Any
        switch registration.scope {
        case .new:
            created = registration.factory(self)
        case .singleton:
            created = registration.singletonStorage.instance { registration.factory(self) }
        }

        guard let service = created as? Service else {
            fatalError("Injector registration for \(serviceType) returned \(type(of: created))")
        }
        return service
    }

    private func installRheaServiceBindingsBeforeResolvingIfNeeded() {
        lock.lock()
        let shouldInstall = !didInstallRheaServiceBindings
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
        injector.registrations = registrations.mapValues { $0.detachedCopy() }
        injector.didInstallRheaServiceBindings = didInstallRheaServiceBindings
        return injector
    }
}

public extension RheaEvent {
    static let injectorBindService: RheaEvent = "injectorBindService"
}
