import Foundation
import CryptoKit

/// Conferências do download de uma atualização: resumo do zip e identidade do .app extraído.
public enum UpdateCheck {
  /// SHA-256 do arquivo em hexadecimal minúsculo, lido em blocos (zips têm dezenas de MB).
  public static func sha256Hex(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
      if chunk.isEmpty { break }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// O resumo do arquivo bate com o esperado? Maiúsculas e minúsculas valem igual.
  public static func verify(file: URL, expected: String) throws -> Bool {
    try sha256Hex(of: file) == expected.lowercased()
  }

  /// O .app extraído tem o bundle id e a versão esperados (lidos do Info.plist)?
  public static func bundleMatches(app: URL, bundleID: String, version: SemVer) -> Bool {
    let plist = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dict = obj as? [String: Any],
          dict["CFBundleIdentifier"] as? String == bundleID,
          let v = dict["CFBundleShortVersionString"] as? String,
          SemVer(v) == version
    else { return false }
    return true
  }
}
