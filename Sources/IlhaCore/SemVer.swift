import Foundation

/// Versão no formato major.minor.patch. Aceita "v" no começo; qualquer outra coisa é nil.
public struct SemVer: Comparable, Sendable, CustomStringConvertible {
  public let major, minor, patch: Int

  public init?(_ s: String) {
    var t = Substring(s)
    if t.hasPrefix("v") { t = t.dropFirst() }
    let parts = t.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var n: [Int] = []
    for p in parts {
      guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(p) else { return nil }
      n.append(v)
    }
    major = n[0]; minor = n[1]; patch = n[2]
  }

  public static func < (a: SemVer, b: SemVer) -> Bool {
    (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
  }

  public var description: String { "\(major).\(minor).\(patch)" }
}
