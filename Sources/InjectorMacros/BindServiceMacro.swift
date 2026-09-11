import RheaTimeMacroExpansion
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct BindServiceMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let implementationType = try serviceImplementationTypeName(from: declaration)
        let arguments = try BindServiceArguments(from: node)

        let closure: ExprSyntax = """
        { _ in
            Injector.shared.bind(\(raw: arguments.target), scope: \(raw: arguments.scope)) { _ in
                \(raw: implementationType)()
            }
        }
        """

        return RheaMacroExpansion.makeRegisterInfoDecls(
            time: "injectorBindService",
            priority: "5",
            repeatable: "false",
            async: "false",
            closure: closure,
            isGlobal: false,
            uniqueName: "\(context.makeUniqueName("rhea"))"
        )
    }

    private static func serviceImplementationTypeName(from declaration: some DeclGroupSyntax) throws -> String {
        if let classDeclaration = declaration.as(ClassDeclSyntax.self) {
            try rejectGenericType(classDeclaration.genericParameterClause)
            return classDeclaration.name.trimmedDescription
        }

        if let structDeclaration = declaration.as(StructDeclSyntax.self) {
            try rejectGenericType(structDeclaration.genericParameterClause)
            return structDeclaration.name.trimmedDescription
        }

        if let actorDeclaration = declaration.as(ActorDeclSyntax.self) {
            try rejectGenericType(actorDeclaration.genericParameterClause)
            return actorDeclaration.name.trimmedDescription
        }

        throw MacroExpansionErrorMessage("@BindService can only be attached to a class, struct, or actor")
    }

    private static func rejectGenericType(_ genericParameterClause: GenericParameterClauseSyntax?) throws {
        if genericParameterClause != nil {
            throw MacroExpansionErrorMessage("@BindService does not support generic service implementation types")
        }
    }
}

private struct BindServiceArguments {
    let target: String
    let scope: String

    init(from node: AttributeSyntax) throws {
        guard case let .argumentList(arguments) = node.arguments,
              let targetArgument = arguments.first(where: { $0.label == nil })
        else {
            throw MacroExpansionErrorMessage("@BindService requires a service entry key path, for example @BindService(\\.paymentService)")
        }

        target = targetArgument.expression.trimmedDescription
        scope = arguments.first(where: { $0.label?.text == "scope" })?.expression.trimmedDescription ?? ".singleton"
    }
}

@main
struct InjectorPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        BindServiceMacro.self
    ]
}
