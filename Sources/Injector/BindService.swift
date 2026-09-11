@attached(member, names: arbitrary)
public macro BindService<Service>(
    _ entryKeyPath: KeyPath<Injector, Entry<Service>>,
    scope: Scope = .singleton
) = #externalMacro(module: "InjectorMacros", type: "BindServiceMacro")
