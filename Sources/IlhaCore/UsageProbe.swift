import Foundation

/// Roda `claude -p /usage …` como processo filho e devolve o que ele imprime. Não autentica nada:
/// quem decide como ler o resultado é o `UsageParser`.
public enum UsageProbe {
  /// Argumentos do comando, sem o binário. O JSON de `--settings` é um argumento só.
  /// `--strict-mcp-config` sem `--mcp-config`: nenhum servidor MCP sobe só para ler o uso
  /// (medido: ~6,3 s → ~4,1 s, mesma leitura).
  public static let arguments: [String] = [
    "-p", "/usage", "--no-session-persistence", "--output-format", "json",
    "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config",
  ]

  /// Formas do comando de versões anteriores da ilha (sem `--strict-mcp-config`), para achar órfãs delas.
  static let legacyArguments: [[String]] = [Array(arguments.dropLast())]

  /// Uma leitura da ilha que ficou sem dono: filha do `launchd` (o app que a lançou morreu) com os
  /// argumentos exatos de uma leitura de uso (`argv` sem o executável).
  public static func isOrphanedProbe(parentPID: Int32, arguments args: [String]) -> Bool {
    parentPID == 1 && ([arguments] + legacyArguments).contains(args)
  }

  /// Leituras órfãs deste usuário, para o app encerrar ao abrir (um app morto à força não teve como).
  public static func orphanedProbePIDs() -> [Int32] {
    let capacity = proc_listallpids(nil, 0)
    guard capacity > 0 else { return [] }
    var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard count > 0 else { return [] }
    return pids.prefix(Int(count)).filter { pid in
      guard pid > 1, let parent = HostApp.parentPID(of: pid), parent == 1,
            let argv = ProcessIdentity.arguments(pid: pid), argv.count > 1 else { return false }
      return isOrphanedProbe(parentPID: parent, arguments: Array(argv.dropFirst()))
    }
  }

  /// Interrompe uma leitura em andamento (o app saindo). `cancel()` manda SIGKILL ao filho na hora,
  /// na própria thread de quem chama: quem sai logo depois com `exit` não deixa o processo para trás
  /// (o CLI às vezes ignora SIGTERM, e depois do `exit` ninguém mais escalaria).
  /// Cancelar antes de o processo existir faz o `run` nem lançá-lo. Um uso por leitura.
  public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var action: (@Sendable () -> Void)?

    public init() {}

    public var isCancelled: Bool {
      lock.lock(); defer { lock.unlock() }
      return cancelled
    }

    public func cancel() {
      lock.lock(); defer { lock.unlock() }
      guard !cancelled else { return }
      cancelled = true
      // Sob a trava, que o `clear()` (logo depois de o processo sair) também pega: o sinal não vai a
      // um pid já reaproveitado, a não ser na janela de microssegundos entre a saída e o `clear()`.
      action?()
      action = nil
    }

    /// Guarda o que `cancel()` faz; `false` se já foi cancelado (e nada fica guardado).
    fileprivate func register(_ action: @escaping @Sendable () -> Void) -> Bool {
      lock.lock(); defer { lock.unlock() }
      guard !cancelled else { return false }
      self.action = action
      return true
    }

    fileprivate func clear() {
      lock.lock(); defer { lock.unlock() }
      action = nil
    }
  }

  /// stdout se o processo sai com 0 dentro do prazo; senão nil (e o processo é morto: SIGTERM, 1 s, SIGKILL).
  /// 60 s: com a máquina estrangulada (bateria baixa) a leitura já passou de 30 s.
  /// `cancellation` cancelado = nil, com o processo morto do mesmo jeito.
  public static func run(
    binary: URL, workingDirectory: URL, environment: [String: String], timeout: TimeInterval = 60,
    cancellation: Cancellation? = nil
  ) async -> Data? {
    var env = environment
    env["ILHA_INTERNAL"] = "1"
    let environment = env
    // O processo vive inteiro numa fila de fundo: bloqueia só essa thread, não o pool do Swift.
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: runBlocking(
          binary: binary, workingDirectory: workingDirectory, environment: environment, timeout: timeout,
          cancellation: cancellation))
      }
    }
  }

  /// Acumula o stdout enquanto o processo roda (leitura em outra thread, senão uma saída maior
  /// que o buffer do pipe travaria o filho).
  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
  }

  private static func runBlocking(
    binary: URL, workingDirectory: URL, environment: [String: String], timeout: TimeInterval,
    cancellation: Cancellation?
  ) -> Data? {
    if cancellation?.isCancelled == true { return nil }
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = workingDirectory
    process.qualityOfService = .utility
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return nil }

    // Cancelar manda SIGKILL e acorda a espera abaixo, que segue como num estouro de prazo.
    let pid = process.processIdentifier
    let wasCancelled = cancellation.map { cancellation in
      !cancellation.register {
        kill(pid, SIGKILL)
        exited.signal()
      }
    } ?? false

    let collector = Collector()
    let drained = DispatchGroup()
    let reader = pipe.fileHandleForReading
    drained.enter()
    DispatchQueue.global(qos: .utility).async {
      while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
        collector.append(chunk)
      }
      drained.leave()
    }

    var finishedInTime = !wasCancelled && exited.wait(timeout: .now() + timeout) == .success
    if cancellation?.isCancelled == true { finishedInTime = false }
    if !finishedInTime, process.isRunning {
      process.terminate()
      if exited.wait(timeout: .now() + 1) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 2)
      }
    }
    cancellation?.clear()
    // Um neto que herdou o pipe pode mantê-lo aberto: não esperar o EOF para sempre.
    if drained.wait(timeout: .now() + 1) == .timedOut { try? reader.close() }

    guard finishedInTime, process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
    return collector.data
  }
}
