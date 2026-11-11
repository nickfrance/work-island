import Foundation

/// O que pode pedir uma leitura do uso.
public enum UsageTrigger: Sendable { case launch, turnEnded, surfaceOpened, timer }

/// O que a ilha mostra do uso.
public enum UsageStatus: Equatable, Sendable {
  /// Nenhuma leitura terminou ainda.
  case loading
  /// `resetsAt` (sessão) e `weekResetsAt` (semana) são nil se a renovação já passou ou é desconhecida.
  case fresh(session: Int, week: Int?, resetsAt: Date?, weekResetsAt: Date?)
  /// Leitura velha: números da última leitura boa e há quantos minutos ela foi feita.
  case stale(session: Int, week: Int?, minutesAgo: Int)
  case unreadable
  case unlimited
  /// Só o app produz este (o comando `claude` não existe na máquina).
  case noClaude
}

/// Idade da leitura velha na unidade que cabe numa linha: minutos até 1 h, horas até 1 dia, depois
/// dias (sempre arredondando para baixo). "atualizado há 480 min" vira "atualizado há 8 h".
public enum UsageAge: Equatable, Sendable {
  case minutes(Int)
  case hours(Int)
  case days(Int)

  public init(minutes: Int) {
    let minutes = max(0, minutes)
    if minutes < 60 {
      self = .minutes(minutes)
    } else if minutes < 24 * 60 {
      self = .hours(minutes / 60)
    } else {
      self = .days(minutes / (24 * 60))
    }
  }
}

/// Política de leitura do uso: quando rodar o comando e o que mostrar. Pura: não roda nada, só decide.
public struct UsageSchedule: Equatable, Sendable {
  public static let turnInterval: TimeInterval = 120
  public static let surfaceInterval: TimeInterval = 60
  public static let idleInterval: TimeInterval = 900
  /// Sem nenhum resultado ainda, uma leitura que falhou tenta de novo depois disto.
  public static let firstResultRetry: TimeInterval = 120
  public static let staleAfter: TimeInterval = 1200
  /// Folga depois da hora de renovação da janela antes de reler.
  private static let resetSlack: TimeInterval = 5

  public private(set) var result: UsageResult?
  public private(set) var lastAttempt: Date?
  public private(set) var inFlight: Bool

  public init() {
    result = nil
    lastAttempt = nil
    inFlight = false
  }

  /// `paused` = tela apagada ou bloqueada: nada lê. `lowPower` só suspende a releitura ociosa de 15 min.
  public func shouldRead(_ trigger: UsageTrigger, now: Date, paused: Bool, lowPower: Bool = false) -> Bool {
    if paused || inFlight { return false }
    switch trigger {
    case .launch:
      return true
    case .turnEnded:
      return sinceLastAttempt(now).map { $0 >= Self.turnInterval } ?? true
    case .surfaceOpened:
      return sinceLastAttempt(now).map { $0 > Self.surfaceInterval } ?? true
    case .timer:
      guard let elapsed = sinceLastAttempt(now) else { return true }
      if resetIsDue(now) { return true }
      if result == nil { return elapsed >= Self.firstResultRetry }
      return !lowPower && elapsed >= Self.idleInterval
    }
  }

  public mutating func begin(at now: Date) {
    inFlight = true
    lastAttempt = now
  }

  /// `nil` ou `.commandFailed` = o comando falhou: mantém o resultado anterior (que pode ser nenhum).
  public mutating func finish(_ result: UsageResult?, at now: Date) {
    inFlight = false
    if let result, result != .commandFailed { self.result = result }
  }

  /// Quando o timer deve acordar de novo: o que vier primeiro entre a próxima leitura ociosa
  /// e a renovação da janela de 5 h (+5 s). Sem tentativa ainda, agora; sem resultado ainda,
  /// 120 s depois da última tentativa. Com `lowPower` não há leitura ociosa: só a renovação
  /// (ou `distantFuture`, e os outros gatilhos leem).
  public func nextWake(now: Date, lowPower: Bool = false) -> Date {
    guard let lastAttempt else { return now }
    if resetIsDue(now) { return now }
    if result == nil { return lastAttempt.addingTimeInterval(Self.firstResultRetry) }
    let idle = lowPower ? Date.distantFuture : lastAttempt.addingTimeInterval(Self.idleInterval)
    if case .reading(let reading)? = result, let reset = reading.session.resetsAt, reset > now {
      return min(idle, reset.addingTimeInterval(Self.resetSlack))
    }
    return idle
  }

  public func status(now: Date) -> UsageStatus {
    switch result {
    // `.commandFailed` nunca fica guardado (o `finish` o descarta).
    case nil, .commandFailed?: return .loading
    case .unreadable?: return .unreadable
    case .unlimited?: return .unlimited
    case .reading(let reading)?:
      // Janela que já renovou conta 0%: o número da leitura é da janela anterior.
      let session = Self.percent(reading.session, now: now)
      let week = reading.week.map { Self.percent($0, now: now) }
      let age = now.timeIntervalSince(reading.readAt)
      if age > Self.staleAfter {
        return .stale(session: session, week: week, minutesAgo: Int(age / 60))
      }
      let resetsAt = reading.session.resetsAt.flatMap { $0 > now ? $0 : nil }
      let weekResetsAt = reading.week?.resetsAt.flatMap { $0 > now ? $0 : nil }
      return .fresh(session: session, week: week, resetsAt: resetsAt, weekResetsAt: weekResetsAt)
    }
  }

  /// A renovação da sessão passou depois da leitura atual (o número mostrado já é de outra janela)
  /// e ainda não houve tentativa desde então: dispara uma vez por renovação, mesmo se a tentativa falhar.
  private func resetIsDue(_ now: Date) -> Bool {
    guard case .reading(let reading)? = result, let reset = reading.session.resetsAt,
          reading.readAt < reset, reset <= now
    else { return false }
    return lastAttempt.map { $0 < reset } ?? true
  }

  private func sinceLastAttempt(_ now: Date) -> TimeInterval? {
    lastAttempt.map { now.timeIntervalSince($0) }
  }

  private static func percent(_ window: UsageWindow, now: Date) -> Int {
    if let reset = window.resetsAt, reset <= now { return 0 }
    return window.percent
  }
}
