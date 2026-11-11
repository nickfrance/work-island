import Foundation

public enum ShortName {
  /// Último componente do caminho, em minúsculas; acima de `maxLength` corta e termina em "…".
  public static func make(cwd: String, maxLength: Int = 10) -> String {
    let last = cwd.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
    guard maxLength > 0, last.count > maxLength else { return maxLength > 0 ? last : "" }
    return String(last.prefix(maxLength - 1)) + "…"
  }
}
