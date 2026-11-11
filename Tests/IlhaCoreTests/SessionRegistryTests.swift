import Testing
import Foundation
import IlhaCore

private let now = Date(timeIntervalSince1970: 2_000_000)

private func makeDir() throws -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ilha-registry-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func write(_ text: String, to name: String, in dir: URL) throws {
  try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

private func entry(pid: Int, id: String, cwd: String, entrypoint: String, status: String) -> String {
  """
  {"pid":\(pid),"sessionId":"\(id)","cwd":"\(cwd)","startedAt":1792700000000,"procStart":"x",\
  "version":"2.1.308","peerProtocol":1,"peerFeatures":[],"kind":"interactive",\
  "entrypoint":"\(entrypoint)","hostSessionId":"local_1","name":"n","status":"\(status)",\
  "updatedAt":1792700000000,"statusUpdatedAt":0}
  """
}

@Test func loadsLiveSessions() throws {
  let dir = try makeDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  try write(entry(pid: 101, id: "a", cwd: "/x/a", entrypoint: "claude-vscode", status: "busy"), to: "101.json", in: dir)
  try write(entry(pid: 102, id: "b", cwd: "/x/b", entrypoint: "cli", status: "idle"), to: "102.json", in: dir)

  let sessions = SessionRegistry.load(directory: dir, processMatches: { _, _ in true }, now: now)
    .sorted { $0.id < $1.id }

  #expect(sessions.count == 2)
  let started = Date(timeIntervalSince1970: 1_792_700_000)
  #expect(sessions[0] == Session(
    id: "a", cwd: "/x/a", host: .vscode, pid: 101, state: .working, updatedAt: now, createdAt: started))
  #expect(sessions[1] == Session(
    id: "b", cwd: "/x/b", host: .terminal, pid: 102, state: .idle, updatedAt: now, createdAt: started))
  #expect(sessions[0].projectDir == "/x/a")
  #expect(sessions[0].stateSince == now)
}

@Test func waitingSeedsAsNeedsYou() throws {
  let dir = try makeDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  try write(entry(pid: 111, id: "w", cwd: "/x", entrypoint: "claude-desktop", status: "waiting"), to: "111.json", in: dir)
  let sessions = SessionRegistry.load(directory: dir, processMatches: { _, _ in true }, now: now)
  #expect(sessions.map(\.state) == [.needsYou])
  #expect(sessions.first?.hooked == false)
}

@Test func skipsDeadAndBroken() throws {
  let dir = try makeDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  try write(entry(pid: 201, id: "dead", cwd: "/x", entrypoint: "cli", status: "busy"), to: "201.json", in: dir)
  try write("{ not json", to: "202.json", in: dir)
  try write(#"{"pid":203,"cwd":"/x"}"#, to: "203.json", in: dir)
  // JSON de registro válido, de um processo que bate, mas com extensão .key: fica de fora.
  try write(entry(pid: 204, id: "key", cwd: "/x", entrypoint: "cli", status: "busy"), to: "204.abc123.key", in: dir)
  try write(entry(pid: 205, id: "live", cwd: "/x", entrypoint: "cli", status: "idle"), to: "205.json", in: dir)

  let sessions = SessionRegistry.load(directory: dir, processMatches: { pid, _ in pid == 204 || pid == 205 }, now: now)
  #expect(sessions.map(\.id) == ["live"])
}

@Test func processMatchesReceivesTheEntry() throws {
  let dir = try makeDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  try write(entry(pid: 401, id: "a", cwd: "/x/a", entrypoint: "cli", status: "busy"), to: "401.json", in: dir)
  var seen: [(Int32, RegistryEntry)] = []
  _ = SessionRegistry.load(directory: dir, processMatches: { pid, e in seen.append((pid, e)); return false }, now: now)
  #expect(seen.count == 1)
  #expect(seen.first?.0 == 401)
  #expect(seen.first?.1.sessionId == "a")
  #expect(seen.first?.1.procStart == "x")
}

@Test func missingDirectoryIsEmpty() {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ilha-does-not-exist-\(UUID().uuidString)")
  #expect(SessionRegistry.load(directory: dir, processMatches: { _, _ in true }, now: now).isEmpty)
}

@Test func statusesReadsActivityAndStatusUpdatedAt() throws {
  let dir = try makeDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  try write(#"{"pid":301,"sessionId":"a","cwd":"/x","status":"busy","statusUpdatedAt":1792700001000}"#, to: "301.json", in: dir)
  try write(#"{"pid":302,"sessionId":"b","cwd":"/x","status":"idle","statusUpdatedAt":1792700002500}"#, to: "302.json", in: dir)
  try write(#"{"pid":303,"sessionId":"c","cwd":"/x"}"#, to: "303.json", in: dir)
  try write(#"{"pid":306,"sessionId":"f","cwd":"/x","status":"waiting","statusUpdatedAt":1792700003000}"#, to: "306.json", in: dir)
  try write(#"{"pid":307,"sessionId":"g","cwd":"/x","status":"sleeping","statusUpdatedAt":1792700003000}"#, to: "307.json", in: dir)
  try write("{ not json", to: "304.json", in: dir)
  try write(#"{"pid":305,"sessionId":"e","cwd":"/x","status":"idle","statusUpdatedAt":1}"#, to: "305.abc.key", in: dir)

  let statuses = SessionRegistry.statuses(directory: dir)
  #expect(statuses.keys.sorted() == [301, 302, 306])
  #expect(statuses[301] == RegistryStatus(.busy, updatedAt: Date(timeIntervalSince1970: 1_792_700_001)))
  #expect(statuses[302] == RegistryStatus(.idle, updatedAt: Date(timeIntervalSince1970: 1_792_700_002.5)))
  #expect(statuses[306] == RegistryStatus(.waiting, updatedAt: Date(timeIntervalSince1970: 1_792_700_003)))
}

@Test func statusesOfMissingDirectoryIsEmpty() {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ilha-nope-\(UUID().uuidString)")
  #expect(SessionRegistry.statuses(directory: dir).isEmpty)
}

// MARK: - O processo é mesmo aquela sessão?

private func ctime(_ date: Date, _ zone: TimeZone) -> String {
  let f = DateFormatter()
  f.locale = Locale(identifier: "en_US_POSIX")
  f.timeZone = zone
  f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
  let s = f.string(from: date)
  // ctime alinha o dia com espaço: "Fri Oct  3 …"
  let parts = s.split(separator: " ", omittingEmptySubsequences: false)
  return parts.count == 5 && parts[2].count == 1 ? "\(parts[0]) \(parts[1])  \(parts[2]) \(parts[3]) \(parts[4])" : s
}

private func regEntry(pid: Int32 = 1, procStart: String?) -> RegistryEntry {
  RegistryEntry(pid: pid, sessionId: "s", cwd: "/x", entrypoint: "cli", status: "idle", startedAt: nil, procStart: procStart)
}

@Test func procStartMatchesInUTCOrLocalTime() {
  let start = Date(timeIntervalSince1970: 1_792_772_049.6)  // 23/10/2026 16:14:09.6 UTC
  #expect(ctime(start, TimeZone(identifier: "UTC")!) == "Fri Oct 23 16:14:09 2026")
  let utc = regEntry(procStart: ctime(start, TimeZone(identifier: "UTC")!))
  let local = regEntry(procStart: ctime(start, .current))
  #expect(ProcessIdentity.matches(utc, startTime: start, executablePath: nil))
  #expect(ProcessIdentity.matches(local, startTime: start, executablePath: nil))
  // Outro processo com o mesmo pid, iniciado uma hora depois: não é a sessão.
  #expect(!ProcessIdentity.matches(utc, startTime: start.addingTimeInterval(3600), executablePath: "/x/claude"))
  #expect(!ProcessIdentity.matches(utc, startTime: start.addingTimeInterval(5), executablePath: "/x/claude"))
  #expect(!ProcessIdentity.matches(utc, startTime: nil, executablePath: "/x/claude"))
}

@Test func procStartWithPaddedDayParses() {
  let start = Date(timeIntervalSince1970: 1_791_028_800)  // 03/10/2026 12:00:00 UTC
  let text = ctime(start, TimeZone(identifier: "UTC")!)
  #expect(text == "Sat Oct  3 12:00:00 2026")
  #expect(ProcessIdentity.matches(regEntry(procStart: text), startTime: start.addingTimeInterval(0.4), executablePath: nil))
}

@Test func withoutProcStartTheExecutableMustBeClaude() {
  for procStart in [nil, "x", ""] as [String?] {
    let e = regEntry(procStart: procStart)
    #expect(ProcessIdentity.matches(e, startTime: Date(), executablePath: "/Users/a/.vscode/ext/native-binary/claude"))
    #expect(ProcessIdentity.matches(e, startTime: nil, executablePath: "/Applications/Claude.app/Contents/MacOS/Claude"))
    // Instalação nativa: o executável resolve para um arquivo cujo nome é a versão.
    #expect(ProcessIdentity.matches(e, startTime: Date(), executablePath: "/Users/x/.local/share/claude/versions/2.1.309"))
    // O claude embutido no app desktop.
    #expect(ProcessIdentity.matches(e, startTime: nil, executablePath:
      "/Users/x/Library/Application Support/Claude/claude-code/2.1.309/abc/claude.app/Contents/MacOS/claude"))
    #expect(ProcessIdentity.matches(e, startTime: nil, executablePath: "/opt/claude-code/bin/node"))
    #expect(!ProcessIdentity.matches(e, startTime: Date(), executablePath: "/usr/bin/vim"))
    // "claude" no meio de outro nome não conta: a própria ilha, compilada numa pasta claude-menubar.
    #expect(!ProcessIdentity.matches(e, startTime: Date(), executablePath:
      "/Users/x/Dev/claude-menubar/build/Ilha.app/Contents/MacOS/IlhaApp"))
    #expect(!ProcessIdentity.matches(e, startTime: Date(), executablePath: "/usr/local/bin/myclaude"))
    #expect(!ProcessIdentity.matches(e, startTime: Date(), executablePath: nil))
  }
}

@Test func probesTheCurrentProcess() throws {
  let pid = getpid()
  let start = try #require(ProcessIdentity.startTime(pid: pid))
  #expect(start <= Date())
  #expect(start > Date().addingTimeInterval(-24 * 3600))
  let path = try #require(ProcessIdentity.executablePath(pid: pid))
  #expect(FileManager.default.isExecutableFile(atPath: path))
  #expect(ProcessIdentity.startTime(pid: -1) == nil)
  #expect(ProcessIdentity.executablePath(pid: -1) == nil)
  // Com o procStart certo, o próprio processo de teste "é" a sessão, mesmo sem chamar-se claude.
  let entry = regEntry(pid: pid, procStart: ctime(start, TimeZone(identifier: "UTC")!))
  #expect(ProcessIdentity.isSession(pid: pid, entry: entry))
  #expect(!ProcessIdentity.isSession(pid: pid, entry: regEntry(pid: pid, procStart: ctime(start.addingTimeInterval(-60), TimeZone(identifier: "UTC")!))))
}

@Test func seededStateSinceComesFromStatusUpdatedAt() throws {
  // Sessão parada há dias continua parada há dias depois de reabrir a ilha (e pode adormecer já).
  let dir = try makeDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  try write(#"{"pid":401,"sessionId":"a","cwd":"/x","status":"idle","statusUpdatedAt":1500000000}"#, to: "401.json", in: dir)
  // Data no futuro não vale: fica a hora da leitura.
  let future = (now.timeIntervalSince1970 + 3600) * 1000
  try write(#"{"pid":402,"sessionId":"b","cwd":"/x","status":"idle","statusUpdatedAt":\#(Int(future))}"#, to: "402.json", in: dir)

  let sessions = SessionRegistry.load(directory: dir, processMatches: { _, _ in true }, now: now)
    .sorted { $0.id < $1.id }
  #expect(sessions[0].stateSince == Date(timeIntervalSince1970: 1_500_000))
  #expect(sessions[1].stateSince == now)
}
