import Testing
import Foundation
import IlhaCore

private func tempDir() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ilha-probe-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func script(in dir: URL, _ body: String) throws -> URL {
  let url = dir.appendingPathComponent("claude")
  try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  return url
}

@Test func probeSendsTheExactCommand() async throws {
  let dir = try tempDir()
  let bin = try script(in: dir, #"""
  printf 'ARG:%s\n' "$@"
  printf 'ENV:%s\n' "$ILHA_INTERNAL"
  printf 'KEEP:%s\n' "$ILHA_TEST_KEEP"
  printf 'PWD:%s\n' "$(pwd -P)"
  if read -r line; then echo "STDIN:data"; else echo "STDIN:eof"; fi
  """#)
  let cwd = try tempDir()
  let data = await UsageProbe.run(
    binary: bin, workingDirectory: cwd, environment: ["PATH": "/usr/bin:/bin", "ILHA_TEST_KEEP": "yes"])
  let lines = String(decoding: try #require(data), as: UTF8.self).split(separator: "\n").map(String.init)
  #expect(lines.filter { $0.hasPrefix("ARG:") } == UsageProbe.arguments.map { "ARG:\($0)" })
  #expect(UsageProbe.arguments == [
    "-p", "/usage", "--no-session-persistence", "--output-format", "json",
    "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config",
  ])
  #expect(lines.contains("ENV:1"))
  #expect(lines.contains("KEEP:yes"))
  // /var é link para /private/var: compara o último componente, único por teste.
  #expect(lines.contains { $0.hasPrefix("PWD:") && $0.hasSuffix(cwd.lastPathComponent) })
  #expect(lines.contains("STDIN:eof"))
}

@Test func largeOutputDoesNotDeadlock() async throws {
  let dir = try tempDir()
  // ~2 MB no stdout: bem acima do buffer do pipe.
  let bin = try script(in: dir, "yes 0123456789abcdef | head -c 2000000")
  let data = await UsageProbe.run(binary: bin, workingDirectory: dir, environment: [:], timeout: 10)
  #expect(data?.count == 2_000_000)
}

@Test func failingProbeGivesNil() async throws {
  let dir = try tempDir()
  let bin = try script(in: dir, "echo partial; exit 3")
  #expect(await UsageProbe.run(binary: bin, workingDirectory: dir, environment: [:]) == nil)
}

@Test func missingBinaryGivesNil() async throws {
  let dir = try tempDir()
  let bin = dir.appendingPathComponent("nao-existe")
  #expect(await UsageProbe.run(binary: bin, workingDirectory: dir, environment: [:]) == nil)
}

@Test func hangingProbeIsKilledAtTimeout() async throws {
  let dir = try tempDir()
  let pidFile = dir.appendingPathComponent("pid")
  let bin = try script(in: dir, """
  [ -n "$ILHA_TEST_WARMUP" ] && exit 0
  echo $$ > '\(pidFile.path)'
  exec sleep 30
  """)
  // A primeira execução de um script recém-criado pode demorar mais que o prazo do teste
  // (verificação do sistema); aquece antes para medir só o timeout.
  _ = await UsageProbe.run(binary: bin, workingDirectory: dir, environment: ["ILHA_TEST_WARMUP": "1"], timeout: 20)
  let start = Date()
  let data = await UsageProbe.run(binary: bin, workingDirectory: dir, environment: [:], timeout: 1.0)
  let elapsed = Date().timeIntervalSince(start)
  let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
  // Processo morto (e recolhido): kill com sinal 0 falha com ESRCH. Lidos antes de qualquer #expect,
  // que pode mexer no errno.
  let killResult = kill(pid, 0)
  let killErrno = errno
  #expect(data == nil)
  #expect(elapsed < 3.0)
  #expect(killResult == -1)
  #expect(killErrno == ESRCH)
}

/// Lê o pid que o script gravou, esperando o arquivo aparecer (até `limit` segundos).
private func waitForPid(_ file: URL, limit: TimeInterval = 10) async throws -> Int32? {
  let deadline = Date().addingTimeInterval(limit)
  while Date() < deadline {
    if let text = try? String(contentsOf: file, encoding: .utf8),
       let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
      return pid
    }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
  return nil
}

@Test func cancelKillsARunningProbe() async throws {
  let dir = try tempDir()
  let pidFile = dir.appendingPathComponent("pid")
  let bin = try script(in: dir, """
  [ -n "$ILHA_TEST_WARMUP" ] && exit 0
  echo $$ > '\(pidFile.path)'
  exec sleep 30
  """)
  _ = await UsageProbe.run(binary: bin, workingDirectory: dir, environment: ["ILHA_TEST_WARMUP": "1"], timeout: 20)
  let cancellation = UsageProbe.Cancellation()
  let task = Task {
    await UsageProbe.run(binary: bin, workingDirectory: dir, environment: [:], timeout: 20, cancellation: cancellation)
  }
  let pid = try #require(try await waitForPid(pidFile))
  // `exec`: o pid do script já é o `sleep`.
  try await Task.sleep(nanoseconds: 100_000_000)
  let start = Date()
  cancellation.cancel()
  let data = await task.value
  let elapsed = Date().timeIntervalSince(start)
  let killResult = kill(pid, 0)
  let killErrno = errno
  #expect(data == nil)
  #expect(elapsed < 2.0)
  #expect(killResult == -1)
  #expect(killErrno == ESRCH)
  #expect(cancellation.isCancelled)
}

@Test func cancelledBeforeStartNeverLaunches() async throws {
  let dir = try tempDir()
  let marker = dir.appendingPathComponent("ran")
  let bin = try script(in: dir, "touch '\(marker.path)'; echo ok")
  let cancellation = UsageProbe.Cancellation()
  cancellation.cancel()
  let data = await UsageProbe.run(binary: bin, workingDirectory: dir, environment: [:], cancellation: cancellation)
  #expect(data == nil)
  #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func orphanedProbeNeedsLaunchdParentAndExactArguments() {
  #expect(UsageProbe.isOrphanedProbe(parentPID: 1, arguments: UsageProbe.arguments))
  // Versões anteriores da ilha rodavam sem `--strict-mcp-config`: também são nossas.
  #expect(UsageProbe.isOrphanedProbe(parentPID: 1, arguments: Array(UsageProbe.arguments.dropLast())))
  // Com dono vivo não é órfã; argumentos diferentes não são da ilha.
  #expect(!UsageProbe.isOrphanedProbe(parentPID: 4242, arguments: UsageProbe.arguments))
  #expect(!UsageProbe.isOrphanedProbe(parentPID: 1, arguments: ["-p", "/usage"]))
  #expect(!UsageProbe.isOrphanedProbe(parentPID: 1, arguments: UsageProbe.arguments + ["--verbose"]))
}

@Test func argumentsOfThisProcessAreReadable() {
  let args = ProcessIdentity.arguments(pid: getpid())
  #expect(args?.isEmpty == false)
  #expect(args?.count == CommandLine.arguments.count)
  #expect(ProcessIdentity.arguments(pid: -1) == nil)
}

@Test func cancelKillsAProbeThatIgnoresSIGTERM() async throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ilha-probe-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let pidFile = dir.appendingPathComponent("pid")
  let script = dir.appendingPathComponent("claude")
  try "#!/bin/sh\ntrap '' TERM\necho $$ > \"\(pidFile.path)\"\nexec sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  _ = await UsageProbe.run(binary: script, workingDirectory: dir, environment: [:], timeout: 0.01)  // aquece o exec
  let cancellation = UsageProbe.Cancellation()
  let started = Date()
  let task = Task { await UsageProbe.run(binary: script, workingDirectory: dir, environment: [:], timeout: 30, cancellation: cancellation) }
  var pid: Int32?
  for _ in 0..<100 where pid == nil {
    try await Task.sleep(nanoseconds: 50_000_000)
    pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }
  let probe = try #require(pid)
  cancellation.cancel()
  // Sem espera nenhuma: o SIGKILL sai na própria chamada, antes de o app sair.
  try await Task.sleep(nanoseconds: 100_000_000)
  let alive = kill(probe, 0) == 0
  #expect(!alive)
  #expect(await task.value == nil)
  #expect(Date().timeIntervalSince(started) < 8)
}
