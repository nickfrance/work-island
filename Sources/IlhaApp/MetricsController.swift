import Foundation
import IlhaCore

/// Métricas anônimas de uso: grava os eventos (só os construtores de `MetricsEvents`, nunca título,
/// pasta, texto, comando ou conta) numa fila em disco, soma a atividade do dia a cada 30 s (gravada
/// na virada do dia, a cada 5 min e ao sair) e envia a fila em lote a cada 15 min, só depois de o
/// aviso "Métricas anônimas ligadas" ter sido visto. Sem endereço no Info.plist (versão compilada do
/// código), nada é gravado nem enviado, e nenhum arquivo é criado.
@MainActor
final class MetricsController {
  /// `WorkIslandMetricsURL` do Info.plist; vazio, ausente, sem https (http só em 127.0.0.1,
  /// localhost ou ::1) → `nil`.
  let endpoint: URL?

  private let settings: SettingsStore
  private let queueURL: URL
  private let activityURL: URL
  private var queue: MetricsQueue
  private var activity: DailyActivity
  /// Último passo da atividade: o próximo soma o tempo desde ele (o core corta passos longos).
  private var lastActivityTick: Date?
  /// Última gravação de `activity.json`: entre uma e outra, a atividade fica só na memória.
  private var lastActivitySave: Date?
  private var activityTimer: Timer?
  private var sendTimer: Timer?
  /// Um envio por vez.
  private var sending = false
  /// Muda a cada `clear`: um envio que voltou depois de a fila ser apagada não tira eventos novos.
  private var queueGeneration = 0
  private let sendInterval: TimeInterval
  /// `ILHA_DEBUG=1`: envio a cada 30 s e o caminho do envio no stderr.
  private let debug: Bool
  /// Sessão própria, sem cookies nem cache.
  private let session: URLSession

  private static let activityInterval: TimeInterval = 30
  private static let activitySaveInterval: TimeInterval = 5 * 60
  private static let batchSize = 200

  /// Aviso "Métricas anônimas ligadas": só com receptor, chave ligada e ainda não visto.
  var noticeDue: Bool {
    endpoint != nil && !settings.settings.metricsNoticeSeen && settings.settings.metricsEnabled
  }

  /// Grava e envia só com endereço e a chave ligada.
  private var enabled: Bool { endpoint != nil && settings.settings.metricsEnabled }

  init(
    settings: SettingsStore, info: [String: Any]? = Bundle.main.infoDictionary,
    queueURL: URL = IlhaPaths.metricsQueuePath, activityURL: URL = IlhaPaths.activityPath
  ) {
    self.settings = settings
    self.queueURL = queueURL
    self.activityURL = activityURL
    endpoint = Self.endpoint(from: info)
    debug = ProcessInfo.processInfo.environment["ILHA_DEBUG"] == "1"
    sendInterval = debug ? 30 : 15 * 60
    // Sem endereço, nem lê: nada em disco é tocado.
    queue = endpoint != nil ? MetricsQueue.load(from: queueURL) : MetricsQueue()
    activity = endpoint != nil ? Self.loadActivity(from: activityURL) : DailyActivity()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 15
    session = URLSession(configuration: configuration)
  }

  nonisolated static func endpoint(from info: [String: Any]?) -> URL? {
    guard let raw = (info?["WorkIslandMetricsURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty, let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty
    else { return nil }
    // http só para um receptor na própria máquina (testes à mão); fora dela, sempre https.
    let loopback: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]
    guard scheme == "https" || (scheme == "http" && loopback.contains(host)) else { return nil }
    return url
  }

  /// Grava o evento na fila (e no disco) só com endereço e a chave ligada.
  func record(_ e: MetricsEvent) {
    guard enabled else { return }
    ensureAnonymousID()
    queue.append(e, enabled: true)
    saveQueue()
    log("gravado \(e.name) (\(queue.events.count) na fila)")
  }

  /// Timer de 30 s (atividade) e de 15 min (envio). Sem endereço, não faz nada.
  func start() {
    guard endpoint != nil, activityTimer == nil else { return }
    log("receptor \(endpoint?.absoluteString ?? "-"); envio a cada \(Int(sendInterval)) s")
    // Chave desligada com eventos de antes na fila: nada sobra para sair.
    if !settings.settings.metricsEnabled, !queue.events.isEmpty { discard() }
    // Primeiro passo já na abertura: um dia novo desde a última vez sai agora.
    tickActivity()
    let activityTimer = Timer(timeInterval: Self.activityInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tickActivity() }
    }
    activityTimer.tolerance = 5
    RunLoop.main.add(activityTimer, forMode: .common)
    self.activityTimer = activityTimer
    let sendTimer = Timer(timeInterval: sendInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.send() }
    }
    sendTimer.tolerance = debug ? 2 : 60
    RunLoop.main.add(sendTimer, forMode: .common)
    self.sendTimer = sendTimer
  }

  /// Uma das escolhas visíveis mudou. Desligar as métricas apaga a fila e a atividade; a própria
  /// mudança "métricas desligadas" não é gravada (com a chave desligada nada é).
  func settingChanged(_ key: SettingKey, value: String) {
    if key == .metrics, !settings.settings.metricsEnabled {
      discard()
      log("métricas desligadas: fila apagada")
    }
    record(MetricsEvents.settingChanged(key, value: value, at: Date()))
  }

  /// Pedido respondido na ilha (ou devolvido ao app): só o tipo do pedido e o resultado.
  func answered(_ request: PendingRequest, _ outcome: AnsweredOutcome) {
    let isPermission = if case .permission = request.kind { true } else { false }
    record(MetricsEvents.answered(isPermission: isPermission, outcome, at: Date()))
  }

  /// O app subiu de versão (de, para).
  func updated(from: String, to: String) {
    record(MetricsEvents.updated(from: from, to: to, at: Date()))
  }

  // MARK: - Atividade

  /// `forceSave`: grava `activity.json` mesmo fora da hora (ao sair).
  private func tickActivity(forceSave: Bool = false) {
    guard enabled else {
      lastActivityTick = nil
      return
    }
    let now = Date()
    let elapsed = lastActivityTick.map { now.timeIntervalSince($0) } ?? 0
    lastActivityTick = now
    let minutes = activity.advance(now: now, elapsed: elapsed, calendar: .current)
    // Grava na virada do dia e a cada 5 min (não a cada passo de 30 s); o resto, ao sair (`flush`).
    let saveDue = lastActivitySave.map { now.timeIntervalSince($0) >= Self.activitySaveInterval } ?? true
    if forceSave || minutes != nil || saveDue {
      saveActivity()
      lastActivitySave = now
    }
    // Um dia de 0 minuto (primeira abertura, chave religada) não conta como dia ativo.
    if let minutes, minutes > 0 { record(MetricsEvents.active(minutes: minutes, at: now)) }
  }

  /// Ao sair: grava a atividade que ainda está só na memória.
  func flush() {
    guard enabled, lastActivityTick != nil else { return }
    tickActivity(forceSave: true)
  }

  // MARK: - Envio

  /// POST do próximo lote. 2xx → tira da fila os enviados; qualquer outra coisa → mantém, sem aviso.
  /// Antes de o aviso das métricas ser visto, a fila só cresce: nada sai sem que você saiba.
  private func send() {
    guard let endpoint, enabled, settings.settings.metricsNoticeSeen, !sending else { return }
    let events = queue.nextBatch(max: Self.batchSize)
    guard !events.isEmpty else { return }
    let batch = MetricsBatch(id: ensureAnonymousID(), app: Self.appVersion, os: Self.osVersion, events: events)
    guard let body = try? batch.encoded() else { return }
    var request = URLRequest(url: endpoint, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    sending = true
    let generation = queueGeneration
    let count = events.count
    log("enviando \(count) evento(s)")
    Task { [weak self, session] in
      var status: Int?
      do {
        let (_, response) = try await session.data(for: request)
        status = (response as? HTTPURLResponse)?.statusCode
      } catch {
        status = nil
      }
      self?.finishSend(count: count, status: status, generation: generation)
    }
  }

  private func finishSend(count: Int, status: Int?, generation: Int) {
    sending = false
    guard let status, (200..<300).contains(status) else {
      log("envio falhou (\(status.map { "HTTP \($0)" } ?? "rede")); fica na fila")
      return
    }
    // Fila apagada no meio (chave desligada): os eventos enviados já não estão lá.
    guard generation == queueGeneration else { return }
    queue.removeFirst(count)
    saveQueue()
    log("enviado (HTTP \(status)); \(queue.events.count) na fila")
  }

  // MARK: - Disco e identidade

  /// O código anônimo persistente: criado na primeira gravação e guardado nas preferências.
  @discardableResult
  private func ensureAnonymousID() -> UUID {
    if let id = settings.settings.anonymousID { return id }
    let id = UUID()
    settings.update { $0.anonymousID = id }
    return id
  }

  /// Apaga a fila e a atividade (em memória e no disco).
  private func discard() {
    queueGeneration += 1
    queue.clear()
    saveQueue()
    activity = DailyActivity()
    lastActivityTick = nil
    lastActivitySave = nil
    try? FileManager.default.removeItem(at: activityURL)
  }

  private func saveQueue() {
    guard endpoint != nil else { return }
    try? queue.save(to: queueURL)
  }

  private func saveActivity() {
    guard endpoint != nil else { return }
    do {
      try FileManager.default.createDirectory(
        at: activityURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(activity).write(to: activityURL, options: .atomic)
    } catch {
      log("não consegui gravar a atividade: \(error.localizedDescription)")
    }
  }

  private static func loadActivity(from url: URL) -> DailyActivity {
    guard let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode(DailyActivity.self, from: data) else { return DailyActivity() }
    return decoded
  }

  /// `CFBundleShortVersionString`; sem bundle (`swift run`), "dev".
  private static var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
  }

  /// Versão do macOS, ex. "15.6.1".
  private static var osVersion: String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
  }

  /// `ILHA_DEBUG=1`: o caminho das métricas no stderr (nunca o conteúdo dos eventos além do nome).
  private func log(_ message: String) {
    guard debug else { return }
    FileHandle.standardError.write(Data("ilha: métricas: \(message)\n".utf8))
  }
}

extension SphereMood {
  /// O humor da esfera levado ao estado das métricas.
  var sessionState: SessionState {
    switch self {
    case .needsYou: .needsYou
    case .result: .done
    case .working: .working
    case .idle: .idle
    }
  }
}
