import Foundation
import Testing
@testable import MobileHarness

@Suite("JSONValue")
struct JSONValueTests {
    @Test("Decodes every JSON kind and round-trips")
    func roundTrip() throws {
        let source = """
        {"null": null, "bool": true, "int": 42, "double": 2.5, "string": "hi",
         "array": [1, "two", false], "nested": {"deep": {"x": 7}}}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        #expect(value["null"]?.isNull == true)
        #expect(value["bool"]?.boolValue == true)
        #expect(value["int"]?.intValue == 42)
        #expect(value["double"]?.doubleValue == 2.5)
        #expect(value["string"]?.stringValue == "hi")
        #expect(value["array"]?[1]?.stringValue == "two")
        #expect(value["nested"]?["deep"]?["x"]?.intValue == 7)
        #expect(value["array"]?[99] == nil)

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(decoded == value)
    }

    @Test("Integer-valued doubles read as integers and doubles")
    func numericAccessors() {
        #expect(JSONValue.double(3).intValue == 3)
        #expect(JSONValue.double(3.5).intValue == nil)
        #expect(JSONValue.int(7).doubleValue == 7)
        #expect(JSONValue.string("7").intValue == nil)
    }

    @Test("Literals construct values ergonomically")
    func literals() {
        let value: JSONValue = ["name": "MobileHarness", "count": 3, "tags": ["a", "b"], "ok": true]
        #expect(value["count"]?.intValue == 3)
        #expect(value["tags"]?.arrayValue?.count == 2)
        #expect(value["ok"]?.boolValue == true)
        let null: JSONValue = nil
        #expect(null.isNull)
    }

    @Test("Wrapping and decoding Codable values")
    func codableBridge() throws {
        struct Forecast: Codable, Equatable {
            let city: String
            let temperature: Double
        }
        let wrapped = try JSONValue(wrapping: Forecast(city: "Berlin", temperature: 22))
        let unwrapped = try wrapped.decoded(as: Forecast.self)
        #expect(unwrapped == Forecast(city: "Berlin", temperature: 22))
    }

    @Test("jsonText produces stable, sorted output")
    func stableText() {
        let value: JSONValue = ["b": 2, "a": 1]
        #expect(value.jsonText() == #"{"a":1,"b":2}"#)
    }

    @Test("Accessors tolerate mismatched kinds")
    func tolerantAccessors() {
        #expect(JSONValue.string("x").arrayValue == nil)
        #expect(JSONValue.array([.int(1)]).objectValue == nil)
        #expect(JSONValue.bool(true)["key"] == nil)
        #expect(JSONValue.null.boolValue == nil)
    }
}

@Suite("Decimal money conversion")
struct DecimalTests {
    @Test("Plain decimal strings parse exactly")
    func plainStrings() {
        #expect(Decimal(usdString: "0.00000015") == Decimal(string: "0.00000015"))
        #expect(Decimal(usdString: "0.00006") == Decimal(string: "0.00006"))
        #expect(Decimal(usdString: "0") == 0)
        #expect(Decimal(usdString: "-2.5") == Decimal(string: "-2.5"))
    }

    @Test("Scientific-notation strings parse exactly")
    func scientificStrings() {
        #expect(Decimal(usdString: "1e-07") == Decimal(string: "0.0000001"))
        #expect(Decimal(usdString: "1.5E-6") == Decimal(string: "0.0000015"))
        #expect(Decimal(usdString: "4.2e-05") == Decimal(string: "0.000042"))
        #expect(Decimal(usdString: "2E3") == 2000)
    }

    @Test("Doubles round-trip through their shortest representation")
    func doubleConversion() {
        #expect(Decimal(usdDouble: 0.0012) == Decimal(string: "0.0012"))
        #expect(Decimal(usdDouble: 25.5) == Decimal(string: "25.5"))
        #expect(Decimal(usdDouble: 74.5) == Decimal(string: "74.5"))
        #expect(Decimal(usdDouble: 0.0001) == Decimal(string: "0.0001"))
    }

    @Test("Unparseable input falls back to zero")
    func fallback() {
        #expect(Decimal(usdString: "free") == 0)
        #expect(Decimal(usdDouble: .nan) == 0)
        #expect(Decimal(usdDouble: .infinity) == 0)
    }

    @Test("Cost arithmetic stays exact in aggregation")
    func exactAggregation() {
        let a = Decimal(usdDouble: 0.0001)
        let b = Decimal(usdDouble: 0.0002)
        #expect(a + b == Decimal(string: "0.0003"))
        #expect(Decimal(usdString: "0.00000015") * 1000 == Decimal(string: "0.00015"))
    }
}
