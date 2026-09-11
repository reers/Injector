# Injector

Injector is a lightweight dependency injection framework for Swift.

It is built around a small container, strongly typed entries, key-path based resolution, and a `@BindService` macro that can register services automatically through [Rhea](https://github.com/reers/Rhea).

## Features

- Strongly typed dependency entries declared as `extension Injector` properties.
- Key-path based `bind`, `resolve`, `remove`, and `@Injected` APIs.
- `@BindService` macro for colocating protocol bindings with service implementations.
- Lazy Rhea registration: macro-generated bindings are installed before the first resolve.
- Manual module registration for app-level or infrastructure bindings.
- Instance binding for objects such as `UserDefaults`, configuration, clients, and environment values.
- Test override scopes that restore the previous registration table automatically.

## Installation

Add Injector to your Swift package dependencies:

```swift
.package(url: "https://github.com/reers/Injector.git", branch: "main")
```

Then add the product to your target:

```swift
.target(
    name: "YourFeature",
    dependencies: [
        "Injector"
    ]
)
```

Injector currently targets macOS 13 or later and uses Swift macros.

## Quick Start

Declare your service protocol:

```swift
public protocol PaymentFeatureAPI {
    func pay(amount: Decimal) -> String
}
```

Expose the dependency as an entry. Entries are regular properties on `Injector`, and `Entry` is a top-level public type from the `Injector` module:

```swift
import Injector

public extension Injector {
    var paymentService: Entry<PaymentFeatureAPI> {
        .service(PaymentFeatureAPI.self)
    }
}
```

Bind an implementation with the macro:

```swift
import Injector

@BindService(\.paymentService)
public final class PaymentService: PaymentFeatureAPI {
    public init() {}

    public func pay(amount: Decimal) -> String {
        "Paid \(amount)"
    }
}
```

Resolve it directly:

```swift
let paymentService = Injector.shared.resolve(\.paymentService)
```

Or inject it into another type:

```swift
public final class CheckoutViewModel {
    @Injected(\.paymentService) private var paymentService

    public func submit() -> String {
        paymentService.pay(amount: 99)
    }
}
```

## Entries

Injector intentionally uses named entries instead of type-only lookups:

```swift
public extension Injector {
    var primaryPaymentService: Entry<PaymentFeatureAPI> {
        .service(PaymentFeatureAPI.self)
    }

    var fallbackPaymentService: Entry<PaymentFeatureAPI> {
        .service(PaymentFeatureAPI.self)
    }
}
```

This keeps call sites readable and allows multiple bindings for the same protocol or concrete type.

Public APIs accept entry key paths:

```swift
Injector.shared.bind(\.primaryPaymentService) { _ in PrimaryPaymentService() }
Injector.shared.resolve(\.primaryPaymentService)
Injector.shared.remove(\.primaryPaymentService)
```

There is no public `resolve(PaymentFeatureAPI.self)` style API.

## Scopes

Injector has two scopes:

```swift
public enum Scope {
    case new
    case singleton
}
```

Manual `bind` defaults to `.new`, which creates a new instance for every resolve:

```swift
Injector.shared.bind(\.paymentService) { _ in
    PaymentService()
}
```

Use `.singleton` when the same instance should be reused:

```swift
Injector.shared.bind(\.paymentService, scope: .singleton) { _ in
    PaymentService()
}
```

`@BindService` defaults to `.singleton`, because feature API services are commonly module-level facade objects:

```swift
@BindService(\.paymentService)
public final class PaymentService: PaymentFeatureAPI {}
```

Use `.new` with the macro when you want a fresh service on every resolve:

```swift
@BindService(\.temporaryService, scope: .new)
public final class TemporaryService: TemporaryFeatureAPI {}
```

## Binding Instances

Some dependencies are not service types. They may be created from environment, process arguments, configuration files, suite names, or app lifecycle state.

For those cases, declare an entry and bind the already-created instance:

```swift
import Foundation
import Injector

public extension Injector {
    var appDefaults: Entry<UserDefaults> {
        .service(UserDefaults.self)
    }
}

#premain {
    let defaults = UserDefaults(suiteName: "com.example.app") ?? .standard
    Injector.shared.bindInstance(\.appDefaults, defaults)
}
```

Consumers use it the same way as service dependencies:

```swift
public final class SettingsStore {
    @Injected(\.appDefaults) private var defaults
}
```

## Rhea Registration Timing

`@BindService` generates a Rhea registration callback inside the annotated type. Injector exposes a dedicated Rhea event:

```swift
public extension RheaEvent {
    static let injectorBindService: RheaEvent = "injectorBindService"
}
```

You may trigger all service bindings eagerly during startup:

```swift
#premain {
    Injector.shared.installRheaServiceBindingsIfNeeded()
}
```

You can also skip the startup hook. `Injector.resolve` lazily installs Rhea service bindings before the first resolve.

Rhea registrations generated by `@BindService` are not repeatable. Once services are bound, the same callback does not need to run again.

## Manual Modules

For app-level bindings, infrastructure setup, or cases where a macro is not appropriate, define a module:

```swift
import Injector

public enum AppModule: Module {
    public static func register(into injector: Injector) {
        injector.bind(\.paymentService, scope: .singleton) { _ in
            PaymentService()
        }
    }
}

Injector.shared.install(AppModule.self)
```

## Test Overrides

Use `withTestOverrides` to replace dependencies during a test without leaking registrations into other tests:

```swift
try Injector.shared.withTestOverrides {
    Injector.shared.bind(\.paymentService, scope: .singleton) { _ in
        MockPaymentService()
    }

    let service = Injector.shared.resolve(\.paymentService)
    // Assert against the mock-backed behavior.
}
```

During a test override scope, lazy Rhea service installation is skipped so explicit test bindings are not replaced by real service bindings.

## API Shape

The recommended public surface is:

```swift
public extension Injector {
    var paymentService: Entry<PaymentFeatureAPI> {
        .service(PaymentFeatureAPI.self)
    }
}

@BindService(\.paymentService)
public final class PaymentService: PaymentFeatureAPI {}

@Injected(\.paymentService) private var paymentService

Injector.shared.bind(\.paymentService) { _ in PaymentService() }
Injector.shared.bindInstance(\.appDefaults, defaults)
Injector.shared.resolve(\.paymentService)
```

`Entry` and `Scope` are top-level public types. After `import Injector`, use them directly as `Entry<Service>` and `Scope`.

## License

This package does not currently include a license file.
