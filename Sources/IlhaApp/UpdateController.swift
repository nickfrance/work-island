import AppKit
import Combine
import IlhaCore

/// Atualização pela própria ilha: procura a última release no GitHub (10 s depois de abrir e a cada
/// 6 h), baixa o zip, confere o resumo e o .app de dentro, e troca o app por um script que espera
/// este processo sair e reabre a versão nova. Nunca reinicia com um pedido segurado na ilha.
/// Versão compilada do código (sem `WorkIslandRelease` no Info.plist): procura e avisa, mas não se
/// instala sozinha; o "Atualizar" mostra a linha de instalação, que traz a versão publicada.
@MainActor
final class UpdateController: ObservableObject {
  /// Versão mais nova que a atual; `nil` sem novidade (ou antes da primeira procura).
  @Published private(set) var available: ReleaseInfo? {
    didSet { refreshAnnounces() }
  }
  /// A seta na ilha e o ponto na engrenagem: versão nova que não foi dispensada no ×. O rodapé das
  /// configurações continua oferecendo a versão dispensada.
  @Published private(set) var announces = false
  @Published private(set) var phase: UpdatePhase = .idle
  /// Versão para a qual o app acabou de ser atualizado (o aviso verde, até o ×).
  @Published private(set) var justUpdatedTo: String?
  /// `CFBundleShortVersionString`; `nil` em `swift run` → nunca procura.
  let currentVersion: SemVer?
  /// De, para: chamado uma vez, na primeira abertura depois de atualizar (usado pelas métricas).
  var onUpdated: ((String, String) -> Void)?

  /// A linha de instalação do README: o caminho quando a pasta do app não é gravável.
  static let installCommand = "curl -fsSL https://raw.githubusercontent.com/nickfrance/work-island/main/install.sh | bash"
  static let releaseAPI = URL(string: "https://api.github.com/repos/nickfrance/work-island/releases/latest")!
  static let assetName = "WorkIsland.zip"
  private static let bundleID = "io.github.nickfrance.workisland"
  private static let appName = "Work Island.app"
  private static let checkInterval: Duration = .seconds(6 * 3600)

  private let settings: SettingsStore
  private let model: AppModel
  /// `WORK_ISLAND_RELEASE_API` (testes à mão, aceita `file://`) ou a API do GitHub.
  private let apiURL: URL
  private let debug: Bool
  /// `ILHA_DEBUG=1` + `WORK_ISLAND_AUTO_UPDATE=1`: instala sozinho ao achar versão nova (teste à mão;
  /// o app precisa ser montado como publicado: `RELEASE=1 scripts/bundle-app.sh`).
  private let autoInstall: Bool
  private let firstCheckDelay: Duration
  /// Versão do `release.sh` (`ReleaseBuild`): só ela se troca sozinha, com ou sem métricas. A
  /// compilada do código atualiza pela linha de instalação (que traz a publicada).
  private let selfInstalls: Bool
  private var checking: Task<Void, Never>?
  private var installing: Task<Void, Never>?
  /// Esperando a fila de pedidos esvaziar para seguir.
  private var waitSink: AnyCancellable?
  /// O app novo já conferido, pronto para a troca (quando um pedido chegou no meio do download).
  private var readyApp: URL?

  init(settings: SettingsStore, model: AppModel) {
    self.settings = settings
    self.model = model
    let info = Bundle.main.infoDictionary
    currentVersion = (info?["CFBundleShortVersionString"] as? String).flatMap(SemVer.init)
    selfInstalls = ReleaseBuild.isRelease(info)
    let environment = ProcessInfo.processInfo.environment
    apiURL = environment["WORK_ISLAND_RELEASE_API"].flatMap(URL.init(string:)) ?? Self.releaseAPI
    debug = environment["ILHA_DEBUG"] == "1"
    autoInstall = debug && environment["WORK_ISLAND_AUTO_UPDATE"] == "1"
    // Em modo de teste a primeira procura sai mais cedo: 2 s, ou `ILHA_DEBUG_UPDATE_DELAY` segundos.
    if debug {
      firstCheckDelay = .seconds(environment["ILHA_DEBUG_UPDATE_DELAY"].flatMap(Double.init) ?? 2)
    } else {
      firstCheckDelay = .seconds(10)
    }
  }

  /// Registra a abertura (`lastRunVersion`; "Atualizada" se veio de uma versão mais velha) e agenda
  /// as procuras. Em `main.swift`, depois da checagem de primeira abertura e de ligar `onUpdated`.
  func start() {
    guard let currentVersion, checking == nil else { return }
    let current = currentVersion.description
    if let previous = settings.settings.lastRunVersion, previous != current {
      // Só conta como atualização subindo de versão: reinstalar uma mais velha não diz "Atualizada".
      if SemVer(previous).map({ $0 < currentVersion }) ?? true {
        justUpdatedTo = current
        log("atualizada de \(previous) para \(current)")
        onUpdated?(previous, current)
      }
    }
    settings.update { $0.lastRunVersion = current }
    log("versão \(current); procura em \(firstCheckDelay) em \(apiURL.absoluteString)")
    checking = Task { [weak self, firstCheckDelay] in
      try? await Task.sleep(for: firstCheckDelay)
      while !Task.isCancelled {
        await self?.check()
        try? await Task.sleep(for: Self.checkInterval)
      }
    }
  }

  /// "Atualizar" (no aviso ou no rodapé das configurações).
  func install() {
    guard currentVersion != nil, let info = available else { return }
    switch phase {
    case .downloading, .restarting, .waitingForAnswer: return
    case .idle, .needsTerminal, .failed: break
    }
    guard selfInstalls else {
      log("versão compilada do código: atualização pelo Terminal")
      phase = .needsTerminal
      return
    }
    if !model.requests.pending.isEmpty {
      waitForAnswers { [weak self] in self?.install() }
      return
    }
    let parent = Bundle.main.bundleURL.deletingLastPathComponent().path
    guard FileManager.default.isWritableFile(atPath: parent) else {
      log("\(parent) não é gravável: atualização pelo Terminal")
      phase = .needsTerminal
      return
    }
    phase = .downloading(0)
    installing = Task { [weak self] in await self?.download(info) }
  }

  /// O × do aviso: tira o aviso que está na frente (a ordem é a de `TopNotices`).
  func dismiss() {
    switch phase {
    case .failed, .needsTerminal:
      phase = .idle
      // Sem o aviso da versão nova logo atrás: a seta e o rodapé continuam para tentar de novo.
      dismissAvailable()
    case .idle where justUpdatedTo != nil:
      justUpdatedTo = nil
    case .idle:
      dismissAvailable()
    case .downloading, .restarting, .waitingForAnswer:
      break
    }
  }

  /// O "Atualizada" sai: no × dele, ou quando o painel volta à ilha depois de mostrá-lo.
  func clearJustUpdated() {
    justUpdatedTo = nil
  }

  /// "O que mudou ↗": as notas da versão do aviso que está na frente.
  func openNotes() {
    if let version = justUpdatedTo,
       let url = URL(string: "https://github.com/nickfrance/work-island/releases/tag/v\(version)") {
      NSWorkspace.shared.open(url)
    } else if let available {
      NSWorkspace.shared.open(available.notesURL)
    }
  }

  // MARK: - Procura

  /// Lê a última release. Erro, resposta não-200 ou JSON que não serve → nada muda.
  private func check() async {
    var request = URLRequest(url: apiURL, timeoutInterval: 15)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    guard let (data, response) = try? await URLSession.shared.data(for: request) else {
      log("procura falhou (rede)")
      return
    }
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      log("procura falhou (HTTP \(http.statusCode))")
      return
    }
    guard let latest = ReleaseInfo.parseLatest(data, assetName: Self.assetName), let currentVersion else {
      log("procura: resposta sem release que sirva")
      return
    }
    // No meio de uma atualização, a versão em andamento não muda.
    guard phase == .idle || phase == .failed || phase == .needsTerminal else { return }
    let newer = latest.version > currentVersion ? latest : nil
    if available != newer { available = newer }
    log("última \(latest.version), atual \(currentVersion): \(newer == nil ? "nada novo" : "versão nova")")
    if autoInstall, newer != nil, phase == .idle { install() }
  }

  // MARK: - Instalação

  /// Baixa, confere e extrai; depois troca (ou espera a fila esvaziar).
  private func download(_ info: ReleaseInfo) async {
    let fm = FileManager.default
    let appURL = Bundle.main.bundleURL
    var staging: URL?
    do {
      // Pasta temporária no mesmo volume do app: a troca é um `mv`, sem cópia.
      let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
      staging = folder
      let zip = folder.appendingPathComponent(Self.assetName)
      log("baixando \(info.assetURL.absoluteString)")
      try await Downloader.fetch(info.assetURL, to: zip) { [weak self] fraction in
        Task { @MainActor in self?.progress(fraction) }
      }
      progress(1)
      let expected = info.sha256
      let ok = try await Task.detached { try UpdateCheck.verify(file: zip, expected: expected) }.value
      guard ok else { return fail("o resumo do zip não bate com o da release", cleaning: folder) }
      let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
      try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
      try await Self.unzip(zip, into: unpacked)
      try? fm.removeItem(at: zip)
      // O zip da release sempre traz "Work Island.app"; o script o põe no caminho atual (mesmo renomeado).
      let newApp = unpacked.appendingPathComponent(Self.appName)
      guard UpdateCheck.bundleMatches(app: newApp, bundleID: Self.bundleID, version: info.version) else {
        return fail("o .app do zip não é o \(Self.bundleID) \(info.version)", cleaning: folder)
      }
      log("conferido: \(newApp.path)")
      readyApp = newApp
      restartWhenFree()
    } catch {
      fail(error.localizedDescription, cleaning: staging)
    }
  }

  /// Progresso do download, de 1% em 1% (a ilha não redesenha a cada pacote).
  private func progress(_ fraction: Double) {
    guard case .downloading(let shown) = phase else { return }
    let next = min(1, max(0, fraction))
    guard next > shown, next >= 1 || next - shown >= 0.01 else { return }
    phase = .downloading(next)
    if debug, Int(next * 100) % 25 == 0 { log("baixando \(Int(next * 100))%") }
  }

  /// Troca agora, ou espera os pedidos segurados: nunca reinicia com alguém esperando resposta.
  private func restartWhenFree() {
    guard let newApp = readyApp else { return }
    if !model.requests.pending.isEmpty {
      waitForAnswers { [weak self] in self?.restartWhenFree() }
      return
    }
    phase = .restarting
    log("reiniciando para trocar por \(newApp.path)")
    // Um instante para o "Reiniciando a ilha…" aparecer antes de o app sair.
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(800))
      self?.swap(to: newApp)
    }
  }

  /// `.waitingForAnswer` até `requests.pending` esvaziar; aí segue com `then`.
  private func waitForAnswers(then: @escaping @MainActor () -> Void) {
    phase = .waitingForAnswer
    log("esperando \(model.requests.pending.count) pedido(s) na ilha")
    // `@Published` avisa antes de gravar, com a fila nova.
    waitSink = model.$requests.sink { [weak self] queue in
      guard queue.pending.isEmpty else { return }
      MainActor.assumeIsolated {
        guard let self, self.waitSink != nil else { return }
        self.waitSink = nil
        self.log("fila vazia: seguindo")
        // No giro seguinte, com a fila já gravada.
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard self.phase == .waitingForAnswer else { return }
            self.phase = .idle
            then()
          }
        }
      }
    }
  }

  /// Grava o script de troca, inicia sem esperar e sai. O script espera este PID morrer, põe o app
  /// novo no lugar (voltando o velho se der errado) e abre o app.
  private func swap(to newApp: URL) {
    guard model.requests.pending.isEmpty else {
      waitForAnswers { [weak self] in self?.restartWhenFree() }
      return
    }
    let script = """
      #!/bin/sh
      while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
      rm -rf "$2.old"
      if mv "$2" "$2.old" && mv "$3" "$2"; then rm -rf "$2.old"; else [ -e "$2" ] || mv "$2.old" "$2"; fi
      open "$2"

      """
    do {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("work-island-swap-\(UUID().uuidString).sh")
      try script.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
      let process = Process()
      process.executableURL = url
      process.arguments = [
        String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path, newApp.path,
      ]
      try process.run()
      log("script de troca iniciado (\(url.path)); saindo")
      NSApp.terminate(nil)
    } catch {
      fail("não consegui iniciar a troca: \(error.localizedDescription)")
    }
  }

  /// `.failed`, apagando o que já foi baixado.
  private func fail(_ reason: String, cleaning folder: URL? = nil) {
    if let folder { try? FileManager.default.removeItem(at: folder) }
    readyApp = nil
    phase = .failed
    FileHandle.standardError.write(Data("ilha: atualização falhou: \(reason)\n".utf8))
  }

  private func dismissAvailable() {
    guard let available else { return }
    settings.update { $0.dismissedUpdate = available.version.description }
    refreshAnnounces()
  }

  private func refreshAnnounces() {
    let shown = available.map { $0.version.description != settings.settings.dismissedUpdate } ?? false
    if announces != shown { announces = shown }
  }

  /// `ILHA_DEBUG=1`: o caminho da atualização no stderr.
  private func log(_ message: String) {
    guard debug else { return }
    FileHandle.standardError.write(Data("ilha: atualização: \(message)\n".utf8))
  }

  /// `/usr/bin/ditto -x -k`: o zip montado com `ditto -c -k --keepParent`.
  private nonisolated static func unzip(_ zip: URL, into folder: URL) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      process.arguments = ["-x", "-k", zip.path, folder.path]
      process.terminationHandler = { finished in
        if finished.terminationStatus == 0 {
          continuation.resume()
        } else {
          continuation.resume(throwing: CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedDescriptionKey: "ditto saiu com \(finished.terminationStatus)",
          ]))
        }
      }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
  }
}

/// Um download com progresso: `URLSessionDownloadTask` numa sessão própria, que move o arquivo para
/// o destino antes de o temporário do sistema sumir. Aceita `file://` (testes à mão).
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let onProgress: @Sendable (Double) -> Void
  private var continuation: CheckedContinuation<Void, Error>?
  private var moveError: Error?

  private init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
    self.destination = destination
    self.onProgress = onProgress
  }

  static func fetch(_ url: URL, to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
    let delegate = Downloader(destination: destination, onProgress: onProgress)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      delegate.continuation = continuation
      session.downloadTask(with: url).resume()
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else { return }
    onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
      moveError = URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
      return
    }
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: location, to: destination)
    } catch {
      moveError = error
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let continuation = self.continuation
    self.continuation = nil
    if let error = error ?? moveError {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
  }
}
