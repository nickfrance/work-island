import Foundation
import IlhaCore

/// Textos da interface no idioma do macOS (pt-BR por padrão, en), lidos da tabela "Localizable"
/// (`Resources/<idioma>.lproj`, copiada para o `.app` pelo `scripts/bundle-app.sh`).
enum L10n {
  /// De onde vêm as tabelas. O harness de renders aponta para `build/Work Island.app`; o app nunca muda.
  /// Num bundle que não é o principal, o idioma segue o do app que roda: o harness precisa rodar
  /// dentro de um `.app` com os mesmos `.lproj`, senão sai sempre em inglês.
  nonisolated(unsafe) static var bundle: Bundle = .main

  /// O texto da chave, com os argumentos aplicados no formato do idioma (plurais pelo `.stringsdict`).
  static func string(_ key: String, _ args: CVarArg...) -> String {
    let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    guard !args.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: args)
  }

  static func state(_ kind: StateLabel.Kind) -> String {
    switch kind {
    case .working: return string("state.working")
    case .needsYou: return string("state.needsYou")
    case .done: return string("state.done")
    case .doneMinutesAgo(let minutes): return string("state.doneMinutesAgo", minutes)
    case .idle: return string("state.idle")
    }
  }

  /// "atualizado há 25 min" / "há 8 h" / "há 2 d": a idade da leitura velha numa linha curta.
  static func updatedAgo(minutes: Int) -> String {
    switch UsageAge(minutes: minutes) {
    case .minutes(let n): return string("usage.updatedMinutesAgo", n)
    case .hours(let n): return string("usage.updatedHoursAgo", n)
    case .days(let n): return string("usage.updatedDaysAgo", n)
    }
  }

  /// Hora no formato do sistema ("17:30", "5:30 PM"), no fuso local.
  static func time(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute())
  }

  /// Dia da semana abreviado e hora ("qui 04:00", "Thu 4:00 AM"). O ponto da abreviação
  /// ("qui.") sai, como na copy do uso.
  static func weekdayTime(_ date: Date) -> String {
    var weekday = date.formatted(.dateTime.weekday(.abbreviated))
    if weekday.hasSuffix(".") { weekday.removeLast() }
    return "\(weekday) \(time(date))"
  }
}
