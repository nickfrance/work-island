import Testing
import Foundation
import IlhaCore

@Test func jsonValueRoundTripsNestedObject() throws {
  let raw = #"{"a":[1,"dois",true,null,{"b":{"c":[]}}],"d":{},"e":"x"}"#
  let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
  #expect(value == .object([
    "a": .array([.number(1), .string("dois"), .bool(true), .null, .object(["b": .object(["c": .array([])])])]),
    "d": .object([:]),
    "e": .string("x"),
  ]))
  let again = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(value))
  #expect(again == value)
}

@Test func jsonValueKeepsIntegersAndFractions() throws {
  let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[0,42,-7,1.5,-0.25,1e3]"#.utf8))
  #expect(value == .array([.number(0), .number(42), .number(-7), .number(1.5), .number(-0.25), .number(1000)]))
  let again = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(value))
  #expect(again == value)
  // Inteiro continua inteiro na volta (sem `.0`), para o Claude Code receber o mesmo número.
  let text = String(decoding: try JSONEncoder().encode(JSONValue.number(42)), as: UTF8.self)
  #expect(text == "42")
}

@Test func jsonValueBoolsAreNotNumbers() throws {
  let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true,false,1,0]"#.utf8))
  #expect(value == .array([.bool(true), .bool(false), .number(1), .number(0)]))
}

@Test func jsonValueKeyOrderDoesNotMatter() throws {
  let a = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"x":1,"y":{"p":"a","q":"b"}}"#.utf8))
  let b = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"y":{"q":"b","p":"a"},"x":1}"#.utf8))
  #expect(a == b)
}
