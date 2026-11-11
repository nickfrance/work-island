import AppKit
import Combine
import IlhaCore

/// Decide quando ler o uso do plano, roda a leitura fora da thread principal e publica o `status`.
/// A política (quando ler, o que mostrar) é do `UsageSchedule`; aqui ficam timers, pausas e o processo.
@MainActor
final class UsageController: ObservableObject {
  @Published private(set) var status: UsageStatus = .loading

  private let home: URL
  /// A última busca pelo `claude` não achou nada. O caminho nunca fica guardado: cada leitura procura
  /// de novo (o Claude Code pode ser instalado, removido ou mudar de lugar com o app aberto).
  private var claudeMissing = false
  private var schedule = UsageSchedule()
  private var started = false
  /// A leitura em andamento: o `stop()` (app saindo) mata o processo por ela.
  private var probeCancellation: UsageProbe.Cancellation?

  /// Timer de um disparo na próxima hora em que a política pode querer ler.
  private var wakeTimer: Timer?
  /// Só recalcula o `status` ("atualizado há N min", janela que renovou).
  private var refreshTimer: Timer?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  // Pausa: tela apagada ou bloqueada. O modo de pouca energia só suspende a releitura ociosa.
  private var screensAsleep = false
  private var screenLocked = false
  private var lowPower = false
  private var paused: Bool { screensAsleep || screenLocked }

  /// Intervalo mínimo até o timer de despertar: uma data no passado nunca vira laço apertado.
  private static let minimumWakeDelay: TimeInterval = 1

  init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.home = home
  }

  func start() {
    guard !started else { return }
    started = true

    // Leituras de uma ilha anterior que morreu no meio (SIGKILL, queda) ficam paradas para sempre.
    DispatchQueue.global(qos: .utility).async {
      for pid in UsageProbe.orphanedProbePIDs() { kill(pid, SIGKILL) }
    }

    lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) {
      $0.setPause { $0.screensAsleep = true }
    }
    observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) {
      $0.setPause { $0.screensAsleep = false }
    }
    observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) {
      $0.setPause { $0.screenLocked = true }
    }
    observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) {
      $0.setPause { $0.screenLocked = false }
    }
    observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) {
      $0.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    // Modo `.common`: continua contando enquanto a espiada ou o painel acompanham o mouse.
    let refresh = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateStatus() }
    }
    refresh.tolerance = 5
    RunLoop.main.add(refresh, forMode: .common)
    refreshTimer = refresh

    trigger(.launch)
  }

  /// Chamado ao sair (terminate, SIGTERM, SIGINT) logo antes do `exit`: o filho recebe SIGKILL aqui.
  func stop() {
    started = false
    probeCancellation?.cancel()
    probeCancellation = nil
    wakeTimer?.invalidate()
    wakeTimer = nil
    refreshTimer?.invalidate()
    refreshTimer = nil
    for (center, token) in observers { center.removeObserver(token) }
    observers.removeAll()
  }

  func trigger(_ trigger: UsageTrigger) {
    guard started else { return }
    let now = Date()
    if claudeMissing {
      // Sem `claude`: só a espiada aberta e o timer de 15 min procuram de novo; achou, lê na hora
      // e volta à política normal.
      guard trigger != .turnEnded, !paused else { return }
      guard let binary = ClaudeBinary.locate(home: home) else {
        armWake()
        return
      }
      claudeMissing = false
      updateStatus()
      if schedule.shouldRead(.launch, now: now, paused: paused, lowPower: lowPower) {
        read(binary: binary, at: now)
      } else {
        armWake()
      }
      return
    }
    if schedule.shouldRead(trigger, now: now, paused: paused, lowPower: lowPower) {
      guard let binary = ClaudeBinary.locate(home: home) else {
        markClaudeMissing()
        return
      }
      read(binary: binary, at: now)
    } else if trigger == .timer {
      // O timer acordou (ou a pausa acabou) sem nada a ler: agenda a próxima.
      armWake()
    }
  }

  // MARK: - Leitura

  /// O `claude` sumiu da máquina: mostra "Claude Code não encontrado" e só acorda a cada 15 min.
  private func markClaudeMissing() {
    claudeMissing = true
    if status != .noClaude { status = .noClaude }
    persist()
    armWake()
  }

  private func read(binary: URL, at now: Date) {
    schedule.begin(at: now)
    armWake()

    let workingDirectory: URL
    do {
      workingDirectory = try Self.prepareProbeDirectory()
    } catch {
      FileHandle.standardError.write(Data("ilha: não consegui criar a pasta do uso: \(error)\n".utf8))
      finish(nil, at: now)
      return
    }
    let environment = ProcessInfo.processInfo.environment
    let cancellation = UsageProbe.Cancellation()
    probeCancellation = cancellation
    // O processo espera numa fila de fundo; só o resultado volta para a main.
    Task.detached(priority: .utility) { [weak self] in
      let output = await UsageProbe.run(
        binary: binary, workingDirectory: workingDirectory, environment: environment, cancellation: cancellation)
      let finishedAt = Date()
      let result = output.map { UsageParser.parse($0, now: finishedAt) }
      await self?.finish(result, at: finishedAt)
    }
  }

  private func finish(_ result: UsageResult?, at now: Date) {
    probeCancellation = nil
    schedule.finish(result, at: now)
    updateStatus()
    persist()
    armWake()
  }

  /// Rearma o timer de despertar. Nunca enquanto pausado (a saída da pausa reavalia) nem com
  /// uma leitura em andamento (o `finish` rearma). Sem `claude`, só a nova busca em 15 min.
  private func armWake() {
    wakeTimer?.invalidate()
    wakeTimer = nil
    guard started, !paused, !schedule.inFlight else { return }
    let now = Date()
    let wake = claudeMissing
      ? now.addingTimeInterval(UsageSchedule.idleInterval)
      : schedule.nextWake(now: now, lowPower: lowPower)
    // Pouca energia sem renovação à vista: nada a esperar; os outros gatilhos continuam lendo.
    guard wake != .distantFuture else { return }
    let fire = max(wake, now.addingTimeInterval(Self.minimumWakeDelay))
    let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.trigger(.timer) }
    }
    timer.tolerance = 1
    RunLoop.main.add(timer, forMode: .common)
    wakeTimer = timer
  }

  private func setPause(_ change: (UsageController) -> Void) {
    let wasPaused = paused
    change(self)
    guard paused != wasPaused else { return }
    if paused {
      wakeTimer?.invalidate()
      wakeTimer = nil
    } else {
      trigger(.timer)
    }
  }

  /// Entrar ou sair do modo de pouca energia muda o que o timer espera: reavalia como uma saída da pausa.
  private func setLowPower(_ enabled: Bool) {
    guard enabled != lowPower else { return }
    lowPower = enabled
    trigger(.timer)
  }

  private func observe(
    _ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (UsageController) -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        handler(self)
      }
    }
    observers.append((center, token))
  }

  private func updateStatus() {
    guard !claudeMissing else { return }
    let next = schedule.status(now: Date())
    if next != status { status = next }
  }

  // MARK: - Disco

  /// `~/Library/Application Support/Work Island/probe` (0700), pasta de trabalho do comando.
  private static func prepareProbeDirectory() throws -> URL {
    let fm = FileManager.default
    let support = IlhaPaths.supportDir
    try ensureDirectory(support, fm: fm)
    let probe = IlhaPaths.probeDir
    try ensureDirectory(probe, fm: fm)
    return probe
  }

  private static func ensureDirectory(_ dir: URL, fm: FileManager) throws {
    if fm.fileExists(atPath: dir.path) {
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    } else {
      try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }

  /// O que vai para `usage.json`; `reading` e `lastAttempt` saem como `null` quando faltam.
  private struct Snapshot: Encodable {
    let status: String
    let reading: UsageReading?
    let lastAttempt: Date?

    enum CodingKeys: String, CodingKey { case status, reading, lastAttempt }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(status, forKey: .status)
      try container.encode(reading, forKey: .reading)
      try container.encode(lastAttempt, forKey: .lastAttempt)
    }
  }

  /// Grava `usage.json` (datas ISO-8601, chaves ordenadas), de forma atômica, para verificação e depuração.
  private func persist() {
    var reading: UsageReading?
    if case .reading(let value)? = schedule.result { reading = value }
    let snapshot = Snapshot(status: Self.caseName(status), reading: reading, lastAttempt: schedule.lastAttempt)
    do {
      let support = IlhaPaths.supportDir
      try Self.ensureDirectory(support, fm: FileManager.default)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      let data = try encoder.encode(snapshot)
      try data.write(to: support.appendingPathComponent("usage.json"), options: .atomic)
    } catch {
      FileHandle.standardError.write(Data("ilha: não consegui gravar usage.json: \(error)\n".utf8))
    }
  }

  private static func caseName(_ status: UsageStatus) -> String {
    switch status {
    case .loading: "loading"
    case .fresh: "fresh"
    case .stale: "stale"
    case .unreadable: "unreadable"
    case .unlimited: "unlimited"
    case .noClaude: "noClaude"
    }
  }
}
