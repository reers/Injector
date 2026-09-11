public struct Entry<Service> {
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
    case new
    case singleton
}
