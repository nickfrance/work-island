import Foundation

/// Versão publicada (montada pelo `scripts/release.sh`) ou compilada do código. Só a publicada se
/// troca sozinha pela ilha; a compilada avisa e manda para a linha de instalação. Independe das
/// métricas: uma versão publicada sem receptor também se atualiza.
public enum ReleaseBuild {
  /// Chave do Info.plist gravada pelo `scripts/bundle-app.sh` (`RELEASE=1`).
  public static let infoKey = "WorkIslandRelease"

  /// Só um `true` booleano conta; ausente, falso ou outro tipo → compilada do código.
  public static func isRelease(_ info: [String: Any]?) -> Bool {
    (info?[infoKey] as? Bool) == true
  }
}
