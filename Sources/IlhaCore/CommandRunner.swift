import Foundation

public struct CommandResult: Sendable, Equatable {
  public let exitCode: Int32
  public let stdout: String
  public let stderr: String

  public init(exitCode: Int32, stdout: String, stderr: String) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
  }
}

/// Roda um comando como processo filho e devolve saída e código. Mesmo desenho do `UsageProbe`:
/// o processo vive numa fila de fundo e, estourado o prazo, leva SIGTERM e depois SIGKILL.
public enum CommandRunner {
  /// `nil`: o processo não abriu, estourou o prazo ou foi morto por sinal.
  public static func run(
    _ executable: URL, _ arguments: [String], environment: [String: String],
    workingDirectory: URL, timeout: TimeInterval = 60
  ) async -> CommandResult? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: runBlocking(
          executable, arguments, environment: environment, workingDirectory: workingDirectory, timeout: timeout))
      }
    }
  }

  private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
  }

  private static func runBlocking(
    _ executable: URL, _ arguments: [String], environment: [String: String],
    workingDirectory: URL, timeout: TimeInterval
  ) -> CommandResult? {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = workingDirectory
    process.qualityOfService = .utility
    process.standardInput = FileHandle.nullDevice
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return nil }

    // Leitura em outras threads: uma saída maior que o buffer do pipe não trava o filho.
    let out = Collector()
    let err = Collector()
    let drained = DispatchGroup()
    for (pipe, collector) in [(outPipe, out), (errPipe, err)] {
      let reader = pipe.fileHandleForReading
      drained.enter()
      DispatchQueue.global(qos: .utility).async {
        while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty { collector.append(chunk) }
        drained.leave()
      }
    }

    let finishedInTime = exited.wait(timeout: .now() + timeout) == .success
    if !finishedInTime, process.isRunning {
      process.terminate()
      if exited.wait(timeout: .now() + 1) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 2)
      }
    }
    // Um neto que herdou o pipe pode mantê-lo aberto: não esperar o EOF para sempre.
    if drained.wait(timeout: .now() + 1) == .timedOut {
      try? outPipe.fileHandleForReading.close()
      try? errPipe.fileHandleForReading.close()
    }

    guard finishedInTime, process.terminationReason == .exit else { return nil }
    return CommandResult(
      exitCode: process.terminationStatus,
      stdout: String(decoding: out.data, as: UTF8.self),
      stderr: String(decoding: err.data, as: UTF8.self))
  }
}
