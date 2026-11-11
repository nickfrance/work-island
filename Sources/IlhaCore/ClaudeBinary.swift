import Foundation

/// Onde está o `claude` instalado. O app abre pelo Finder, sem o PATH do terminal; por isso a
/// busca é por lugares fixos, nunca por `which`.
public enum ClaudeBinary {
  /// Primeiro executável na ordem: ~/.local/bin/claude, ~/.claude/local/claude, /opt/homebrew/bin/claude,
  /// /usr/local/bin/claude, e por fim o embutido no app desktop:
  /// ~/Library/Application Support/Claude/claude-code/<maior versão>/<qualquer>/claude.app/Contents/MacOS/claude
  public static func locate(
    home: URL,
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> URL? {
    let fixed = [
      home.appendingPathComponent(".local/bin/claude").path,
      home.appendingPathComponent(".claude/local/claude").path,
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
    ]
    if let path = fixed.first(where: isExecutable) { return URL(fileURLWithPath: path) }
    return desktopBundled(home: home, isExecutable: isExecutable)
  }

  /// O `claude` que o app desktop baixa por versão. Vale a maior versão, comparada como número
  /// (2.1.10 vem depois de 2.1.9); a pasta de hash dentro dela pode ter qualquer nome.
  private static func desktopBundled(home: URL, isExecutable: (String) -> Bool) -> URL? {
    let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
    let versions = subfolders(of: root).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    for version in versions {
      let versionDir = root.appendingPathComponent(version)
      for hash in subfolders(of: versionDir).sorted() {
        let candidate = versionDir.appendingPathComponent(hash)
          .appendingPathComponent("claude.app/Contents/MacOS/claude")
        if isExecutable(candidate.path) { return candidate }
      }
    }
    return nil
  }

  /// Nomes das subpastas; os caminhos são remontados a partir de `url` para não herdar a
  /// resolução de links (/var → /private/var) que a listagem faz.
  private static func subfolders(of url: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
  }
}
