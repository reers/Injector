@attached(member, names: arbitrary)
public macro BindService<Service>(
    _ dependencyKeyPath: KeyPath<Injector, Dependency<Service>>,
    scope: Scope = .singleton
) = #externalMacro(module: "InjectorMacros", type: "BindServiceMacro")
