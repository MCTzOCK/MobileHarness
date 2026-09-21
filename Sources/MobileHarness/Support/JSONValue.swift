import Foundation

/// A dynamically typed JSON value.
///
/// `JSONValue` models the full JSON value space so agent tool arguments and
/// tool results can flow through the harness without each tool declaring its
/// own Codable types. Read arguments with the typed accessors — for example
/// `arguments["city"]?.stringValue` — and return structured output by wrapping
/// any `Codable` value with ``init(wrapping:)``.
///
/// ```swift
/// agent.registerTool("get_weather", description: "Current weather for a city.") { arguments in
///     let city = arguments["city"]?.stringValue ?? "unknown"
///     return "\(city): 22°C, sunny"
/// }
/// ```
public enum JSONValue: Sendable, Hashable {
    /// The JSON `null` value.
    case null
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON integer number.
    case int(Int64)
    /// A JSON floating-point number.
    case double(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([JSONValue])
    /// A JSON object.
    case object([String: JSONValue])
}

// MARK: - Convenience accessors

extension JSONValue {
    /// The string value, if this value is a string.
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The boolean value, if this value is a boolean.
    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// The integer value, if this value is an integer.
    public var intValue: Int64? {
        switch self {
        case let .int(value): value
        case let .double(value) where value.rounded() == value: Int64(value)
        default: nil
        }
    }

    /// The floating-point value, if this value is a number.
    public var doubleValue: Double? {
        switch self {
        case let .int(value): Double(value)
        case let .double(value): value
        default: nil
        }
    }

    /// The array elements, if this value is an array.
    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// The object members, if this value is an object.
    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// `true` if this value is `null`.
    public var isNull: Bool {
        self == .null
    }

    /// Accesses the member for the given key of an object value.
    ///
    /// Returns `nil` when this value is not an object or the key is absent.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Accesses the element at the given index of an array value.
    ///
    /// Returns `nil` when this value is not an array or the index is out of range.
    public subscript(index: Int) -> JSONValue? {
        guard let arrayValue, arrayValue.indices.contains(index) else { return nil }
        return arrayValue[index]
    }
}

// MARK: - Literal conveniences

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    /// Creates the JSON `null` value.
    public init(nilLiteral: ()) { self = .null }
    /// Creates a boolean from a boolean literal.
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    /// Creates an integer from an integer literal.
    public init(integerLiteral value: Int64) { self = .int(value) }
    /// Creates a number from a floating-point literal.
    public init(floatLiteral value: Double) { self = .double(value) }
    /// Creates a string from a string literal.
    public init(stringLiteral value: String) { self = .string(value) }
    /// Creates an array from an array literal.
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    /// Creates an object from a dictionary literal.
    public init(dictionaryLiteral pairs: (String, JSONValue)...) {
        self = .object(Dictionary(pairs, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    /// Decodes any JSON value from its single-value representation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "The value is not valid JSON."
            )
            throw DecodingError.dataCorrupted(context)
        }
    }

    /// Encodes the value back into its single-value representation.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// MARK: - Bridging

extension JSONValue {
    /// Wraps any encodable value as a JSON value.
    ///
    /// Use this to return structured results from tools that work with their
    /// own `Codable` types:
    ///
    /// ```swift
    /// struct Forecast: Codable { let temperatureCelsius: Double }
    /// return JSONValue(wrapping: Forecast(temperatureCelsius: 22))
    /// ```
    public init(wrapping value: some Encodable) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes an instance of the given type from this JSON value.
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The encoded JSON text for this value.
    ///
    /// When `sortedKeys` is true, object keys are sorted so the output is stable
    /// and comparable in tests.
    public func jsonText(sortedKeys: Bool = true) -> String {
        let encoder = JSONEncoder()
        if sortedKeys { encoder.outputFormatting = [.sortedKeys] }
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }
}
