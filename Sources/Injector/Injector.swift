@_exported import RheaTime
import Foundation

public protocol Resolver: AnyObject {
    func resolve<Service>(_ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>) -> Service
}

public protocol Module {
    static func register(into injector: Injector)
}

/// Injects a dependency into a property.
///
/// The container is captured when the owner is created, so an owner created inside
/// `Injector.withOverrides` keeps using the scoped bindings even when accessed later from
/// another thread or callback. The dependency is resolved on first access and then reused,
/// so `.new` scoped dependencies stay the same instance for the lifetime of the owner,
/// and later `reset` / rebinding is not observed by an owner that already resolved it.
/// `.session` scoped dependencies are resolved again after `Injector.endSession()`,
/// so long-lived owners never keep the previous session's instance.
@propertyWrapper
public struct Injected<Service> {
    private let storage: Storage

    public init(_ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>) {
        self.init(dependencyKeyPath, container: Injector.current)
    }

    public init(
        _ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>,
        container: Injector
    ) {
        self.storage = Storage(container: container, dependencyKeyPath: dependencyKeyPath)
    }

    public var wrappedValue: Service {
        storage.value
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSRecursiveLock()
        private let container: Injector
        private let dependencyKeyPath: KeyPath<Injector, Dependency<Service>>
        private var resolved: Service?
        /// Session generation the cached service belongs to; `nil` when it is not `.session` scoped.
        private var resolvedSessionGeneration: Int?

        init(container: Injector, dependencyKeyPath: KeyPath<Injector, Dependency<Service>>) {
            self.container = container
            self.dependencyKeyPath = dependencyKeyPath
        }

        var value: Service {
            lock.lock()
            defer { lock.unlock() }

            if let resolved, isCurrent {
                return resolved
            }
            let resolution = container.resolveTrackingSession(dependencyKeyPath, followsSession: true)
            resolved = resolution.service
            resolvedSessionGeneration = resolution.sessionGeneration
            return resolution.service
        }

        private var isCurrent: Bool {
            guard let resolvedSessionGeneration else {
                return true
            }
            return resolvedSessionGeneration == container.sessionGeneration
        }
    }
}

/// Expression form of `@Injected`, for call sites that do not want to declare a property.
///
/// Resolves from `Injector.current` on every call, so it honors `Injector.withOverrides` scopes
/// and returns a new instance per call for `.new` scoped dependencies.
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

    /// Holds a singleton or session instance with its own lock, so factories never run under the container lock.
    final class SingletonStorage {
        private let lock = NSRecursiveLock()
        private var instance: Any?
        private var isEnded = false

        init(instance: Any? = nil) {
            self.instance = instance
        }

        var existingInstance: Any? {
            lock.lock()
            defer { lock.unlock() }
            return instance
        }

        /// Returns `nil` when the storage was ended before an instance was created,
        /// so the caller can resolve again from the current registration.
        func instance(orMake make: () -> Any) -> Any? {
            lock.lock()
            defer { lock.unlock() }

            if let instance {
                return instance
            }
            guard !isEnded else {
                return nil
            }
            let created = make()
            instance = created
            return created
        }

        /// Prevents further creation and returns the instance, waiting for an in-flight creation to finish.
        func end() -> Any? {
            lock.lock()
            defer { lock.unlock() }

            isEnded = true
            return instance
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
        /// Session instances are not kept, so the copy has its own session.
        func detachedCopy() -> Registration {
            guard scope == .singleton else {
                return freshCopy()
            }
            return Registration(scope: scope, factory: factory, instance: singletonStorage.existingInstance)
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
    /// Reports programming errors such as duplicate `@BindService` or a singleton capturing a session dependency.
    private let reportMisuse: (String) -> Void
    private var currentSessionGeneration = 0

    public convenience init() {
        self.init(serviceBindingsTrigger: nil)
    }

    init(
        serviceBindingsTrigger: ((Injector) -> Void)?,
        reportMisuse: @escaping (String) -> Void = { assertionFailure($0) }
    ) {
        self.serviceBindingsTrigger = serviceBindingsTrigger
        self.reportMisuse = reportMisuse
    }

    /// Incremented by every `endSession()`.
    var sessionGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentSessionGeneration
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

        guard recordingRheaServiceRegistrations != nil else {
            return
        }
        // Rebinding manually is a legitimate override; only a second `@BindService` for the same key is a mistake.
        if recordingRheaServiceRegistrations?[key] != nil {
            reportMisuse(
                "Duplicate @BindService for \\.\(dependency.key) (\(dependency.serviceType)). "
                    + "The registration order is undefined, so only one implementation takes effect."
            )
        }
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

    /// Removes all registrations and created singletons and session instances.
    ///
    /// `@BindService` registrations are installed again before the next resolve.
    /// Unlike `endSession()`, it does not call `SessionScoped.sessionDidEnd()`.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        didInstallRheaServiceBindings = false
        registrations.removeAll()
    }

    /// Ends the current user session, typically on logout or account switch.
    ///
    /// Drops every `.session` scoped instance while keeping the registrations, so the next resolve
    /// creates a new instance, and `@Injected` properties resolve again on their next access.
    /// Created instances that adopt `SessionScoped` receive `sessionDidEnd()` before this method returns.
    /// Overrides containers created by `withOverrides` keep their own sessions and are not affected.
    public func endSession() {
        lock.lock()
        var endedStorages: [SingletonStorage] = []
        for (key, registration) in registrations where registration.scope == .session {
            endedStorages.append(registration.singletonStorage)
            registrations[key] = registration.freshCopy()
        }
        currentSessionGeneration += 1
        lock.unlock()

        // End outside the container lock: an in-flight creation holds the storage lock
        // and may need the container lock to resolve its own dependencies.
        var notified = Set<ObjectIdentifier>()
        for storage in endedStorages {
            guard let instance = storage.end() as? SessionScoped,
                  notified.insert(ObjectIdentifier(instance)).inserted
            else {
                continue
            }
            instance.sessionDidEnd()
        }
    }

    public func resolve<Service>(_ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>) -> Service {
        resolveTrackingSession(dependencyKeyPath).service
    }

    /// Resolves the service and, for `.session` scoped registrations, the session generation it belongs to.
    ///
    /// - Parameter followsSession: `true` when the caller resolves again after `endSession()`, like `@Injected`,
    ///   so resolving a `.session` dependency while constructing a singleton is not a captive dependency.
    func resolveTrackingSession<Service>(
        _ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>,
        followsSession: Bool = false
    ) -> (service: Service, sessionGeneration: Int?) {
        let dependency = self[keyPath: dependencyKeyPath]
        return resolve(serviceType: dependency.serviceType, key: RegistrationKey(dependency), followsSession: followsSession)
    }

    private func resolve<Service>(
        serviceType: Service.Type,
        key: RegistrationKey,
        followsSession: Bool
    ) -> (service: Service, sessionGeneration: Int?) {
        installRheaServiceBindingsBeforeResolvingIfNeeded()

        lock.lock()
        let registration = registrations[key]
        let generation = currentSessionGeneration
        lock.unlock()

        guard let registration else {
            fatalError("No Injector registration found for \(serviceType)")
        }

        let created: Any?
        var sessionGeneration: Int?
        switch registration.scope {
        case .new:
            created = registration.factory(self)
        case .singleton:
            created = registration.singletonStorage.instance {
                SingletonConstruction.run { registration.factory(self) }
            }
        case .session:
            if !followsSession, SingletonConstruction.isActive {
                reportMisuse(
                    "A singleton depends on the .session scoped \(serviceType). "
                        + "It would keep the first session's instance after endSession(). "
                        + "Make the dependent .session scoped, access it through @Injected, "
                        + "or call injected() where it is used instead of during construction."
                )
            }
            created = registration.singletonStorage.instance { registration.factory(self) }
            sessionGeneration = generation
        }

        guard let created else {
            // The session ended between reading the registration and creating the instance.
            return resolve(serviceType: serviceType, key: key, followsSession: followsSession)
        }
        guard let service = created as? Service else {
            fatalError("Injector registration for \(serviceType) returned \(type(of: created))")
        }
        return (service, sessionGeneration)
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

    func copyForOverrides() -> Injector {
        lock.lock()
        let registrationsSnapshot = registrations
        let didInstallSnapshot = didInstallRheaServiceBindings
        lock.unlock()

        // Detach outside the container lock: an in-flight singleton creation holds the storage lock
        // and may need the container lock to resolve its own dependencies.
        let injector = Injector(serviceBindingsTrigger: nil, reportMisuse: reportMisuse)
        injector.registrations = registrationsSnapshot.mapValues { $0.detachedCopy() }
        injector.didInstallRheaServiceBindings = didInstallSnapshot
        return injector
    }
}

/// Tracks whether the current thread is running a singleton factory, to detect singletons
/// capturing `.session` scoped dependencies. Only active in debug builds.
private enum SingletonConstruction {
    private static let depthKey = "com.reers.Injector.singletonConstructionDepth"

    static var isActive: Bool {
        #if DEBUG
        return depth > 0
        #else
        return false
        #endif
    }

    static func run<Result>(_ body: () -> Result) -> Result {
        #if DEBUG
        depth += 1
        defer { depth -= 1 }
        #endif
        return body()
    }

    private static var depth: Int {
        get { Thread.current.threadDictionary[depthKey] as? Int ?? 0 }
        set { Thread.current.threadDictionary[depthKey] = newValue }
    }
}

public extension RheaEvent {
    static let injectorBindService: RheaEvent = "injectorBindService"
}
