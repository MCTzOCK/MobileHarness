import Foundation

/// Declares one argument of a tool in the JSON Schema sent to the model.
///
/// Build parameter lists with the type factories, which read naturally at the
/// call site:
///
/// ```swift
/// agent.registerTool(
///     "get_weather",
///     description: "Returns the current weather for a city.",
///     parameters: [
///         .string("city", description: "The city name, e.g. \"Berlin\"."),
///         .enumeration("unit", values: ["celsius", "fahrenheit"], required: false),
///     ]
/// ) { arguments in
///     "22°C, sunny"
/// }
/// ```
public struct ToolParameter: Sendable, Hashable {
    /// The JSON Schema types a tool argument can have.
    public enum ValueType: String, Sendable, Hashable {
        /// A JSON string.
        case string
        /// A JSON integer.
        case integer
        /// A JSON number.
        case number
        /// A JSON boolean.
        case boolean
    }

    /// The argument name as the model will use it.
    public let name: String
    /// The argument's JSON Schema type.
    public let type: ValueType
    /// A description that helps the model supply a correct value.
    public let description: String?
    /// Whether the model must supply the argument.
    public let isRequired: Bool
    /// When set, restricts a string argument to a fixed set of values.
    public let allowedValues: [String]?
    /// The element type of an array argument.
    public let elementType: ValueType?

    private init(
        name: String,
        type: ValueType,
        description: String?,
        isRequired: Bool,
        allowedValues: [String]? = nil,
        elementType: ValueType? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
        self.allowedValues = allowedValues
        self.elementType = elementType
    }

    /// Declares a string argument.
    public static func string(_ name: String, description: String? = nil, required: Bool = true) -> ToolParameter {
        ToolParameter(name: name, type: .string, description: description, isRequired: required)
    }

    /// Declares an integer argument.
    public static func integer(_ name: String, description: String? = nil, required: Bool = true) -> ToolParameter {
        ToolParameter(name: name, type: .integer, description: description, isRequired: required)
    }

    /// Declares a numeric argument.
    public static func number(_ name: String, description: String? = nil, required: Bool = true) -> ToolParameter {
        ToolParameter(name: name, type: .number, description: description, isRequired: required)
    }

    /// Declares a boolean argument.
    public static func boolean(_ name: String, description: String? = nil, required: Bool = true) -> ToolParameter {
        ToolParameter(name: name, type: .boolean, description: description, isRequired: required)
    }

    /// Declares a string argument restricted to the given values.
    public static func enumeration(
        _ name: String,
        values: [String],
        description: String? = nil,
        required: Bool = true
    ) -> ToolParameter {
        ToolParameter(
            name: name,
            type: .string,
            description: description,
            isRequired: required,
            allowedValues: values
        )
    }

    /// Declares an array argument with the given element type.
    public static func array(
        _ name: String,
        of elementType: ValueType,
        description: String? = nil,
        required: Bool = true
    ) -> ToolParameter {
        ToolParameter(
            name: name,
            type: .string,
            description: description,
            isRequired: required,
            elementType: elementType
        )
    }

    /// The JSON Schema property describing this argument.
    var schemaProperty: JSONValue {
        var property: [String: JSONValue] = [:]
        if let elementType {
            property["type"] = "array"
            property["items"] = .object(["type": .string(elementType.rawValue)])
        } else {
            property["type"] = .string(type.rawValue)
        }
        if let description {
            property["description"] = .string(description)
        }
        if let allowedValues {
            property["enum"] = .array(allowedValues.map { .string($0) })
        }
        return .object(property)
    }
}

/// The outcome of a tool execution, fed back to the model.
public struct ToolResult: Sendable, Hashable {
    /// The content shown to the model; typically plain text or JSON text.
    public let content: String
    /// Whether the execution failed; the model sees the failure and can react,
    /// for example by correcting its arguments.
    public let isError: Bool

    /// Creates a tool result.
    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// A successful result carrying the given content.
    public static func success(_ content: String) -> ToolResult {
        ToolResult(content: content, isError: false)
    }

    /// A failed result explaining the failure to the model.
    public static func failure(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: true)
    }
}

/// A tool registered with an ``Agent``.
struct RegisteredTool: Sendable {
    let name: String
    let description: String
    let parameters: [ToolParameter]
    let execute: @Sendable ([String: JSONValue]) async throws -> ToolResult

    /// The JSON Schema object describing all arguments.
    var argumentsSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for parameter in parameters {
            properties[parameter.name] = parameter.schemaProperty
            if parameter.isRequired {
                required.append(.string(parameter.name))
            }
        }
        return .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required),
        ])
    }

    /// The wire definition sent to OpenRouter.
    var definition: ChatCompletionRequestDTO.ToolDefinition {
        .function(name: name, description: description, parameters: argumentsSchema)
    }
}
