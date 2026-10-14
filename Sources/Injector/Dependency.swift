public struct Dependency<Service> {
    public let serviceType: Service.Type
    public let key: String

    public init(
        _ serviceType: Service.Type = Service.self,
        key: StaticString = #function
    ) {
        self.serviceType = serviceType
        self.key = "\(key)"
    }

    public static func service(
        _ serviceType: Service.Type = Service.self,
        key: StaticString = #function
    ) -> Self {
        Self(serviceType, key: key)
    }
}

public enum Scope {
    /// Creates a new instance on every resolve.
    case new
    /// Creates one instance for the lifetime of the container.
    case singleton
    /// Creates one instance per user session. `Injector.endSession()` drops it,
    /// and the next resolve creates a new one.
    case session
}

/// Adopted by `.session` scoped services that need to stop work when the session ends,
/// such as invalidating timers or removing observers.
///
/// `sessionDidEnd()` is called once per instance, outside the container lock,
/// on the thread that calls `Injector.endSession()`.
public protocol SessionScoped: AnyObject {
    func sessionDidEnd()
}
