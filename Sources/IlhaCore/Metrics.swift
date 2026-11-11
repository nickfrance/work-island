import Foundation

/// Valor de uma propriedade de métrica: codifica como texto ou número JSON puro.
public enum MetricValue: Codable, Equatable, Sendable {
  case string(String)
  case int(Int)

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let i = try? c.decode(Int.self) { self = .int(i); return }
    self = .string(try c.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let s): try c.encode(s)
    case .int(let i): try c.encode(i)
    }
  }
}

public struct MetricsEvent: Codable, Equatable, Sendable {
  public let name: String
  public let at: Date
  public let props: [String: MetricValue]

  public init(name: String, at: Date, props: [String: MetricValue]) {
    self.name = name
    self.at = at
    self.props = props
  }
}

public enum CardStage: String, Sendable { case espiada, painel }
public enum AnsweredOutcome: String, Sendable { case permitiu, negou, respondeu, devolveu }

/// Construtores dos sete eventos. Só chaves da lista fixa; nunca título, pasta, texto, comando ou conta.
public enum MetricsEvents {
  public static let allowedKeys: Set<String> = [
    "minutos", "tipo", "estado", "segundos", "origem", "pedido", "resultado", "de", "para", "linha", "valor",
  ]

  public static func active(minutes: Int, at: Date) -> MetricsEvent {
    MetricsEvent(name: "ilha_ativa", at: at, props: ["minutos": .int(minutes)])
  }

  public static func cardOpened(_ stage: CardStage, mood: SessionState, at: Date) -> MetricsEvent {
    MetricsEvent(name: "cartao_aberto", at: at, props: ["tipo": .string(stage.rawValue), "estado": .string(mood.rawValue)])
  }

  public static func cardClosed(seconds: Int, at: Date) -> MetricsEvent {
    MetricsEvent(name: "cartao_fechado", at: at, props: ["segundos": .int(seconds)])
  }

  public static func sessionClicked(state: SessionState, host: Host, at: Date) -> MetricsEvent {
    MetricsEvent(name: "sessao_clicada", at: at, props: ["estado": .string(state.rawValue), "origem": .string(host.rawValue)])
  }

  public static func answered(isPermission: Bool, _ outcome: AnsweredOutcome, at: Date) -> MetricsEvent {
    MetricsEvent(name: "respondeu_na_ilha", at: at, props: [
      "pedido": .string(isPermission ? "permissao" : "pergunta"), "resultado": .string(outcome.rawValue),
    ])
  }

  public static func updated(from: String, to: String, at: Date) -> MetricsEvent {
    MetricsEvent(name: "atualizou", at: at, props: ["de": .string(from), "para": .string(to)])
  }

  public static func settingChanged(_ key: SettingKey, value: String, at: Date) -> MetricsEvent {
    MetricsEvent(name: "configuracao_mudada", at: at, props: ["linha": .string(key.rawValue), "valor": .string(value)])
  }
}

/// Envelope enviado ao receptor: `{"v":1,"id":…,"app":…,"os":…,"events":[…]}`.
public struct MetricsBatch: Encodable {
  public let v = 1
  /// Código anônimo PERSISTENTE (`AppSettings.anonymousID`): o receptor conta usuários por ele.
  /// Obrigatório de propósito: um id novo a cada lote inflaria os números.
  public let id: UUID
  public let app: String
  public let os: String
  public let events: [MetricsEvent]

  public init(id: UUID, app: String, os: String, events: [MetricsEvent]) {
    self.id = id
    self.app = app
    self.os = os
    self.events = events
  }

  /// Codificador único do formato de rede (datas ISO-8601); o envio deve usar este.
  public static func jsonEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }

  public func encoded() throws -> Data { try Self.jsonEncoder().encode(self) }
}

/// Fila em disco dos eventos ainda não enviados; passa de 1000, descarta os mais antigos.
public struct MetricsQueue: Codable, Equatable {
  public private(set) var events: [MetricsEvent] = []
  public static let cap = 1000

  public init() {}

  /// Desligado: não guarda nada.
  public mutating func append(_ e: MetricsEvent, enabled: Bool) {
    guard enabled else { return }
    events.append(e)
    if events.count > Self.cap { events.removeFirst(events.count - Self.cap) }
  }

  public func nextBatch(max: Int = 200) -> [MetricsEvent] {
    Array(events.prefix(Swift.max(0, max)))
  }

  public mutating func removeFirst(_ n: Int) {
    events.removeFirst(Swift.min(Swift.max(0, n), events.count))
  }

  public mutating func clear() { events.removeAll() }

  private static func coders() -> (JSONEncoder, JSONDecoder) {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return (e, d)
  }

  /// Arquivo ausente ou ilegível → fila vazia.
  public static func load(from url: URL) -> MetricsQueue {
    guard let data = try? Data(contentsOf: url),
      let q = try? coders().1.decode(MetricsQueue.self, from: data)
    else { return MetricsQueue() }
    return q
  }

  /// Grava de forma atômica, criando a pasta se preciso.
  public func save(to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Self.coders().0.encode(self).write(to: url, options: .atomic)
  }
}

/// Soma o tempo de atividade do dia local e avisa quando o dia vira.
public struct DailyActivity: Codable, Equatable {
  public var day: String
  public var seconds: Double

  public init(day: String = "", seconds: Double = 0) {
    self.day = day
    self.seconds = seconds
  }

  /// Tempo dormindo não conta: cada passo vale no máximo isto.
  public static let maxStep: TimeInterval = 60

  /// Dia novo (inclusive a primeira chamada) → minutos do dia que acabou (0 na primeira), zera e troca o dia.
  /// A fatia que cruza a meia-noite é descartada. Mesmo dia → soma e devolve `nil`.
  public mutating func advance(now: Date, elapsed: TimeInterval, calendar: Calendar) -> Int? {
    let key = Self.dayKey(now, calendar)
    if key == day {
      seconds += Swift.min(Swift.max(0, elapsed), Self.maxStep)
      return nil
    }
    let minutes = day.isEmpty ? 0 : Swift.min(Int(seconds / 60), 1440)
    day = key
    seconds = 0
    return minutes
  }

  private static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }
}
