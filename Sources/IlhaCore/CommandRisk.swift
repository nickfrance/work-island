import Foundation

/// Reconhece comandos de shell que mexem fora deste Mac (publicar, fazer deploy, escrever na rede)
/// ou apagam em massa. Heurística conservadora: comandos só de leitura nunca são marcados.
public enum CommandRisk {
  public static func touchesOutsideMac(_ command: String) -> Bool {
    isRisky(command, depth: 0)
  }

  // MARK: - Segmentos e palavras

  private static func isRisky(_ command: String, depth: Int) -> Bool {
    guard depth < 4 else { return false }
    return segments(of: command).contains { segmentIsRisky($0, depth: depth) }
  }

  /// Divide em comandos simples (`|`, `||`, `&&`, `&`, `;`, quebra de linha, parênteses, crase) e cada um em
  /// palavras, respeitando aspas e barra invertida. Aspas somem; o conteúdo vira uma palavra só.
  private static func segments(of command: String) -> [[String]] {
    var result: [[String]] = []
    var words: [String] = []
    var word = ""
    var inWord = false
    var quote: Character?
    var escaped = false

    func endWord() { if inWord { words.append(word); word = ""; inWord = false } }
    func endSegment() { endWord(); if !words.isEmpty { result.append(words); words = [] } }

    for ch in command {
      if escaped {
        escaped = false
        // Barra + quebra de linha é continuação: some, sem separar nem sujar a palavra.
        if ch != "\n" { word.append(ch); inWord = true }
        continue
      }
      if let q = quote {
        if ch == q { quote = nil }
        else if ch == "\\" && q == "\"" { escaped = true }
        else { word.append(ch) }
        continue
      }
      switch ch {
      case "\\": escaped = true
      case "'", "\"": quote = ch; inWord = true
      case " ", "\t": endWord()
      case "|", "&", ";", "\n", "(", ")", "`": endSegment()
      default: word.append(ch); inWord = true
      }
    }
    endSegment()
    return result
  }

  private static let keywords: Set<String> = [
    "!", "if", "then", "else", "elif", "do", "while", "until", "time", "nohup", "exec", "command", "builtin",
  ]
  private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
  private static let sudoFlagsWithValue: Set<String> = ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U", "-r", "-t"]
  private static let xargsFlagsWithValue: Set<String> = ["-n", "-I", "-P", "-L", "-d", "-s", "-E", "-a"]

  private static func isAssignment(_ w: String) -> Bool {
    guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return false }
    let name = w[..<eq]
    return name.first.map { $0.isLetter || $0 == "_" } == true && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
  }

  private static func segmentIsRisky(_ raw: [String], depth: Int) -> Bool {
    var t = raw[...]
    // Tira o que vem antes do comando de verdade.
    while let first = t.first {
      let name = basename(first)
      if isAssignment(first) || keywords.contains(first) {
        t = t.dropFirst()
      } else if name == "sudo" || name == "doas" {
        t = t.dropFirst()
        while let f = t.first, f.hasPrefix("-") {
          t = t.dropFirst()
          if sudoFlagsWithValue.contains(f), !t.isEmpty { t = t.dropFirst() }
        }
      } else if name == "env" {
        t = t.dropFirst()
        while let f = t.first, f.hasPrefix("-") {
          t = t.dropFirst()
          if f == "-u", !t.isEmpty { t = t.dropFirst() }
        }
      } else if name == "nice" || name == "ionice" {
        t = t.dropFirst()
        while let f = t.first, f.hasPrefix("-") {
          t = t.dropFirst()
          if f == "-n", !t.isEmpty { t = t.dropFirst() }
        }
      } else if name == "xargs" {
        t = t.dropFirst()
        while let f = t.first, f.hasPrefix("-") {
          t = t.dropFirst()
          if xargsFlagsWithValue.contains(f), !t.isEmpty { t = t.dropFirst() }
        }
      } else {
        break
      }
    }
    guard let head = t.first else { return false }
    let cmd = basename(head)
    let args = Array(t.dropFirst())
    // Argumentos que não são opção (depois de `--` tudo conta como alvo).
    let positional = args.filter { !$0.hasPrefix("-") }

    switch cmd {
    case "sh", "bash", "zsh", "dash", "ksh":
      // `bash -c "git push"`: olha dentro.
      if let i = args.firstIndex(where: { $0 == "-c" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c")) }),
         i + 1 < args.count {
        return isRisky(args[i + 1], depth: depth + 1)
      }
      return false
    case "eval":
      return isRisky(args.joined(separator: " "), depth: depth + 1)
    case "git":
      return gitSubcommand(args) == "push"
    case "npm", "pnpm", "yarn", "bun":
      // Opções globais (`-w a`, `workspace foo`) vêm antes do subcomando: procura em qualquer posição.
      return args.contains("publish")
    case "vercel":
      return vercelIsRisky(args, positional: positional)
    case "fly", "flyctl":
      // `fly -a app deploy`: o subcomando não é o primeiro argumento.
      return args.contains("deploy")
    case "kubectl":
      return positional.contains { $0 == "apply" || $0 == "delete" }
    case "terraform", "tofu":
      return positional.contains { $0 == "apply" || $0 == "destroy" }
    case "gh":
      // `gh -R o/r pr merge 1`, `gh pr --repo x merge`: opções entre as palavras.
      return containsInOrder(args, ["pr", "merge"]) || containsInOrder(args, ["release", "create"])
    case "rm":
      return rmIsRisky(args)
    case "curl":
      return curlIsRisky(args)
    case "wget":
      return wgetIsRisky(args)
    case "ssh", "scp":
      return true
    case "rsync":
      return positional.contains(where: isRemotePath)
    case "docker", "podman":
      return positional.prefix(2).contains("push") || args.contains("--push")
    default:
      return false
    }
  }

  /// As palavras de `sequence` aparecem em `args` nessa ordem (não necessariamente coladas).
  private static func containsInOrder(_ args: [String], _ sequence: [String]) -> Bool {
    var next = 0
    for a in args where next < sequence.count && a == sequence[next] { next += 1 }
    return next == sequence.count
  }

  /// `vercel` sem subcomando já faz deploy. Só leitura ou trabalho local passa.
  private static func vercelIsRisky(_ args: [String], positional: [String]) -> Bool {
    if args.contains(where: { $0 == "--version" || $0 == "-v" || $0 == "--help" || $0 == "-h" }) { return false }
    guard let sub = positional.first else { return true }
    let readOnly: Set<String> = ["whoami", "ls", "list", "inspect", "logs", "help", "version", "login", "logout", "build", "dev", "pull"]
    if readOnly.contains(sub) { return false }
    // Grupos que misturam leitura e escrita (`env add|rm`, `projects rm`…): só `ls|list|inspect|pull` é leitura.
    let groups: Set<String> = ["env", "domains", "dns", "certs", "teams", "projects"]
    if groups.contains(sub) {
      guard positional.count > 1 else { return false }
      return !["ls", "list", "inspect", "pull", "help"].contains(positional[1])
    }
    return true
  }

  private static func basename(_ w: String) -> String {
    w.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? w
  }

  // MARK: - Regras por comando

  private static func gitSubcommand(_ args: [String]) -> String? {
    let withValue: Set<String> = ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix"]
    var i = 0
    while i < args.count {
      let a = args[i]
      if a.hasPrefix("-") {
        i += withValue.contains(a) ? 2 : 1
      } else {
        return a
      }
    }
    return nil
  }

  private static let safeToDelete: Set<String> = ["node_modules", "build", ".build", "dist"]

  private static func rmIsRisky(_ args: [String]) -> Bool {
    var recursive = false
    var targets: [String] = []
    var afterDashDash = false
    for a in args {
      if afterDashDash { targets.append(a); continue }
      if a == "--" { afterDashDash = true; continue }
      if a == "--recursive" { recursive = true; continue }
      if a.hasPrefix("--") { continue }
      if a.hasPrefix("-"), a.count > 1 {
        if a.dropFirst().contains(where: { $0 == "r" || $0 == "R" }) { recursive = true }
        continue
      }
      targets.append(a)
    }
    guard recursive else { return false }
    // Sem alvo na linha (`… | xargs rm -rf`): os alvos vêm de fora, não dá para garantir que são seguros.
    if targets.isEmpty { return true }
    return targets.contains { target in
      let name = target.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? target
      return !safeToDelete.contains(name)
    }
  }

  private static let writeMethods: Set<String> = ["POST", "PUT", "DELETE", "PATCH"]

  private static func curlIsRisky(_ args: [String]) -> Bool {
    var i = 0
    while i < args.count {
      let a = args[i]
      switch a {
      case "-X", "--request":
        if i + 1 < args.count, writeMethods.contains(args[i + 1].uppercased()) { return true }
      case "-d", "-F", "-T", "--json", "--form", "--upload-file": return true
      default:
        if a.hasPrefix("--request="), writeMethods.contains(a.dropFirst("--request=".count).uppercased()) { return true }
        if a.hasPrefix("--data") || a.hasPrefix("--form") || a.hasPrefix("--json") { return true }
        // `-XPOST`, `-dfoo`
        if a.hasPrefix("-X"), a.count > 2, writeMethods.contains(a.dropFirst(2).uppercased()) { return true }
        if a.hasPrefix("-d"), !a.hasPrefix("--"), a.count > 2 { return true }
      }
      i += 1
    }
    return false
  }

  private static func wgetIsRisky(_ args: [String]) -> Bool {
    var i = 0
    while i < args.count {
      let a = args[i]
      if a.hasPrefix("--post-data") || a.hasPrefix("--post-file") || a.hasPrefix("--body-") { return true }
      if a == "--method", i + 1 < args.count, writeMethods.contains(args[i + 1].uppercased()) { return true }
      if a.hasPrefix("--method="), writeMethods.contains(a.dropFirst("--method=".count).uppercased()) { return true }
      i += 1
    }
    return false
  }

  /// `host:caminho`, `user@host:caminho` ou `rsync://…`; caminho local (`/x`, `./x`, `~/x`) não conta.
  private static func isRemotePath(_ arg: String) -> Bool {
    if arg.hasPrefix("rsync://") || arg.hasPrefix("ssh://") { return true }
    if arg.hasPrefix("/") || arg.hasPrefix(".") || arg.hasPrefix("~") { return false }
    guard let colon = arg.firstIndex(of: ":") else { return false }
    let host = arg[..<colon]
    return !host.isEmpty && !host.contains("/")
  }
}
