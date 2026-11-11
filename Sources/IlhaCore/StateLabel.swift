import Foundation

/// Qual texto de estado uma sessão mostra na espiada e no painel. O texto em si sai do app,
/// no idioma do macOS (`L10n.state`).
public enum StateLabel {
  public enum Kind: Equatable, Sendable {
    case working, needsYou, done, doneMinutesAgo(Int), idle
  }

  public static func kind(for session: Session, now: Date) -> Kind {
    switch session.state {
    case .working: return .working
    case .needsYou: return .needsYou
    case .done: return .done
    case .idle: return .idle
    case .doneStale:
      guard let since = session.doneSince else { return .done }
      return .doneMinutesAgo(minutesSince(since, now: now))
    }
  }

  /// Minutos inteiros (arredondados para baixo) desde `date`, no mínimo 1.
  static func minutesSince(_ date: Date, now: Date) -> Int {
    let elapsed = now.timeIntervalSince(date)
    guard elapsed.isFinite, elapsed > 0 else { return 1 }
    return max(1, Int(elapsed / 60))
  }
}
