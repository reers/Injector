@_exported import RheaTime
import Foundation

public protocol Resolver: AnyObject {
    func resolve<Service>(_ entryKeyPath: KeyPath<Injector, Entry<Service>>) -> Service
}

public protocol Module {
    static func register(into injector: Injector)
}

@propertyWrapper
public struct Injected<Service> {
    private let resolveValue: () -> Service

    public init(
        _ entryKeyPath: KeyPath<Injector, Entry<Service>>,
        container: Injector = .shared
    ) {
        self.resolveValue = {
            container.resolve(entryKeyPath)
        }
    }

    public var wrappedValue: Service {
        resolveValue()
    }
}

public final class Injector: Resolver, @unchecked Sendable {
    public static let shared = Injector()

    private struct Registration {
        let scope: Scope
        let factory: (Resolver) -> Any
        var instance: Any?
    }

    private struct RegistrationKey: Hashable {
        let serviceType: ObjectIdentifier
        let entryKey: String?

        init<Service>(_ serviceType: Service.Type, entryKey: String? = nil) {
            self.serviceType = ObjectIdentifier(serviceType)
            self.entryKey = entryKey
        }

        init<Service>(_ entry: Entry<Service>) {
            self.init(entry.serviceType, entryKey: entry.key)
        }
    }

    private let lock = NSRecursiveLock()
    private var registrations: [RegistrationKey: Registration] = [:]
    private var didInstallRheaServiceBindings = false
    private var isUsingTestOverrides = false

    public init() {}

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
        _ entryKeyPath: KeyPath<Injector, Entry<Service>>,
        scope: Scope = .new,
        factory: @escaping (Resolver) -> Service
    ) {
        bind(self[keyPath: entryKeyPath], scope: scope, factory: factory)
    }

    private func bind<Service>(
        _ entry: Entry<Service>,
        scope: Scope = .new,
        factory: @escaping (Resolver) -> Service
    ) {
        lock.lock()
        defer { lock.unlock() }

        let key = RegistrationKey(entry)
        registrations[key] = Registration(
            scope: scope,
            factory: { resolver in factory(resolver) },
            instance: nil
        )
    }

    public func bindInstance<Service>(
        _ entryKeyPath: KeyPath<Injector, Entry<Service>>,
        _ instance: Service
    ) {
        bindInstance(self[keyPath: entryKeyPath], instance)
    }

    private func bindInstance<Service>(
        _ entry: Entry<Service>,
        _ instance: Service
    ) {
        lock.lock()
        defer { lock.unlock() }

        let key = RegistrationKey(entry)
        registrations[key] = Registration(
            scope: .singleton,
            factory: { _ in instance },
            instance: instance
        )
    }

    public func remove<Service>(_ entryKeyPath: KeyPath<Injector, Entry<Service>>) {
        remove(self[keyPath: entryKeyPath])
    }

    private func remove<Service>(_ entry: Entry<Service>) {
        lock.lock()
        defer { lock.unlock() }

        let key = RegistrationKey(entry)
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

    public func resolve<Service>(_ entryKeyPath: KeyPath<Injector, Entry<Service>>) -> Service {
        resolve(self[keyPath: entryKeyPath])
    }

    private func resolve<Service>(_ entry: Entry<Service>) -> Service {
        resolve(serviceType: entry.serviceType, key: RegistrationKey(entry))
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
}

public extension RheaEvent {
    static let injectorBindService: RheaEvent = "injectorBindService"
}
