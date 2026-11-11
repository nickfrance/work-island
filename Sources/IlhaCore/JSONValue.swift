import Foundation

/// Qualquer valor JSON, para guardar e ecoar sem perder nada (`tool_input`, `permission_suggestions`).
/// Objetos comparam sem olhar a ordem das chaves.
public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    // `Bool` antes de `Double`: `true` não pode virar `1`.
    if let b = try? c.decode(Bool.self) { self = .bool(b); return }
    if let n = try? c.decode(Double.self) { self = .number(n); return }
    if let s = try? c.decode(String.self) { self = .string(s); return }
    if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
    if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
    throw DecodingError.dataCorruptedError(in: c, debugDescription: "valor JSON desconhecido")
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n):
      // Inteiro sai sem `.0`, como chegou (dentro da faixa exata do `Double`).
      if n.rounded() == n, abs(n) < 9_007_199_254_740_992 { try c.encode(Int64(n)) } else { try c.encode(n) }
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }
}
