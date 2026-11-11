import Foundation

/// Uma janela de limite do plano (a de 5 h ou a semanal): quanto já foi usado e quando renova.
public struct UsageWindow: Codable, Equatable, Sendable {
  public let percent: Int
  public let resetsAt: Date?

  public init(percent: Int, resetsAt: Date?) {
    self.percent = percent
    self.resetsAt = resetsAt
  }
}

/// Uma leitura boa do `/usage`: janela da sessão, janela semanal (quando a saída traz) e a hora da leitura.
public struct UsageReading: Codable, Equatable, Sendable {
  public let session: UsageWindow
  public let week: UsageWindow?
  public let readAt: Date

  public init(session: UsageWindow, week: UsageWindow?, readAt: Date) {
    self.session = session
    self.week = week
    self.readAt = readAt
  }
}

public enum UsageResult: Equatable, Sendable {
  case reading(UsageReading)
  /// Conta sem limite de plano (chave de API): o anel some da ilha.
  case unlimited
  /// O comando rodou, mas o texto é de um formato que não conhecemos: "não consegui ler o uso".
  case unreadable
  /// O comando falhou (`is_error`, JSON inválido, resultado vazio, "Failed to load usage data"):
  /// passageiro, mantém o resultado anterior; nunca chega ao que a ilha mostra.
  case commandFailed
}

/// Lê a saída de `claude -p "/usage" --output-format json`. Função pura: não roda comando nenhum.
public enum UsageParser {
  /// `output` = stdout inteiro do comando (JSON com `is_error` e `result`). Do `calendar` só vale o fuso.
  public static func parse(_ output: Data, now: Date, calendar: Calendar = .current) -> UsageResult {
    guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
          (object["is_error"] as? Bool) != true,
          let text = object["result"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !text.localizedCaseInsensitiveContains("Failed to load usage data")
    else { return .commandFailed }

    var session: UsageWindow?
    var week: UsageWindow?
    for line in text.split(whereSeparator: \.isNewline) {
      guard let match = matchLimitLine(String(line)) else { continue }
      let window = UsageWindow(
        percent: match.percent,
        resetsAt: match.reset.flatMap { parseReset($0, now: now, calendar: calendar) }
      )
      switch (match.kind, match.qualifier) {
      // `Current session` ou `Current session (all models)`; as de um modelo só ficam de fora.
      case ("session", nil), ("session", "all models"):
        if session == nil { session = window }
      // `Current week (all models)` ou o antigo `Current week`; as semanais por modelo ficam de fora.
      case ("week", nil), ("week", "all models"):
        if week == nil { week = window }
      default:
        break
      }
    }

    if let session {
      return .reading(UsageReading(session: session, week: week, readAt: now))
    }
    // Conta sem limite de plano só com o texto dizendo de onde vem a cobrança, e sem porcentagem
    // nenhuma; o resto é formato que não conhecemos: melhor "não consegui ler" do que um número errado.
    let lowered = text.lowercased()
    let billedElsewhere = ["api key", "api usage", "bedrock", "vertex"].contains { lowered.contains($0) }
    return billedElsewhere && !lowered.contains("%") ? .unlimited : .unreadable
  }

  /// "Oct 23 at 6:30pm (America/Sao_Paulo)", "Oct 29 at 4am (…)", "1:29pm" → próxima ocorrência.
  /// O fuso entre parênteses vale sobre o do `calendar`. Sem data, é a próxima vez que o relógio
  /// marca aquele horário; com data sem ano, o ano que deixa a data mais próxima no futuro
  /// (até 1 dia no passado ainda conta como este ano). As datas da saída são sempre gregorianas:
  /// do `calendar` só vale o fuso.
  public static func parseReset(_ text: String, now: Date, calendar: Calendar) -> Date? {
    guard let groups = groups(of: resetPattern, in: text.trimmingCharacters(in: .whitespaces)),
          var hour = groups[3].flatMap({ Int($0) }), (1...12).contains(hour)
    else { return nil }
    let minute = groups[4].flatMap { Int($0) } ?? 0
    guard (0..<60).contains(minute) else { return nil }
    if hour == 12 { hour = 0 }
    if groups[5]?.lowercased() == "pm" { hour += 12 }

    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    var calendar = gregorian
    if let name = groups[6] {
      guard let zone = TimeZone(identifier: name) else { return nil }
      calendar.timeZone = zone
    }

    guard let monthName = groups[1], let day = groups[2].flatMap({ Int($0) }) else {
      // Só a hora: hoje, ou amanhã se já passou.
      var parts = calendar.dateComponents([.year, .month, .day], from: now)
      parts.hour = hour
      parts.minute = minute
      guard let today = calendar.date(from: parts) else { return nil }
      return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    guard let month = months[monthName.lowercased()] else { return nil }
    let year = calendar.component(.year, from: now)
    let earliest = now.addingTimeInterval(-24 * 60 * 60)
    let candidates = (year - 1...year + 1).compactMap { y -> Date? in
      let parts = DateComponents(year: y, month: month, day: day, hour: hour, minute: minute)
      // 30 de fevereiro (ou 29 em ano comum) não existe; o calendário rolaria para março.
      guard let date = calendar.date(from: parts),
            calendar.component(.month, from: date) == month,
            calendar.component(.day, from: date) == day
      else { return nil }
      return date
    }
    return candidates.filter { $0 >= earliest }.min()
  }

  // MARK: - Texto

  private struct LimitLine {
    let kind: String          // "session" ou "week"
    let qualifier: String?    // o que vem entre parênteses, em minúsculas
    let percent: Int
    let reset: String?
  }

  private static let limitPattern =
    #"^\s*Current\s+(session|week)(?:\s*\(([^)]*)\))?\s*:\s*(\d{1,3})%\s*used(?:\s*·\s*resets\s+(.*?))?\s*$"#

  /// Hora com dia opcional: `[Mon D at ]H[:MM](am|pm)[ (Fuso)]`.
  private static let resetPattern =
    #"^(?:([A-Za-z]{3,9})\.?\s+(\d{1,2})\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\s*(?:\(([^)]+)\))?$"#

  private static let months: [String: Int] = {
    let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    var result: [String: Int] = [:]
    for (index, name) in names.enumerated() { result[name] = index + 1 }
    let full = ["january", "february", "march", "april", "may", "june", "july", "august",
                "september", "october", "november", "december"]
    for (index, name) in full.enumerated() { result[name] = index + 1 }
    result["sept"] = 9
    return result
  }()

  private static func matchLimitLine(_ line: String) -> LimitLine? {
    guard let g = groups(of: limitPattern, in: line), let kind = g[1]?.lowercased(),
          let percent = g[3].flatMap({ Int($0) })
    else { return nil }
    return LimitLine(kind: kind, qualifier: g[2]?.trimmingCharacters(in: .whitespaces).lowercased(),
                     percent: percent, reset: g[4])
  }

  /// Grupos de captura do padrão (índice 0 = o trecho inteiro); `nil` nos grupos que não participaram.
  private static func groups(of pattern: String, in text: String) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let whole = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: whole) else { return nil }
    return (0..<match.numberOfRanges).map { index in
      Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
  }
}
