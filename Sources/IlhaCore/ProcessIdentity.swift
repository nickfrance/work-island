import Foundation
import Darwin

/// Confere se um pid vivo ainda é o processo que escreveu uma entrada do registro do Claude Code:
/// pids são reaproveitados, e um arquivo velho de uma sessão que travou viraria uma etiqueta fantasma.
public enum ProcessIdentity {
  /// Hora de início do processo (`sysctl` `KERN_PROC_PID` → `p_starttime`); `nil` se não existe.
  public static func startTime(pid: Int32) -> Date? {
    guard pid > 0 else { return nil }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let tv = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
  }

  /// Caminho do executável do processo (`proc_pidpath`); `nil` se não existe ou não dá para ler.
  public static func executablePath(pid: Int32) -> String? {
    guard pid > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }

  /// Os argumentos do processo, `argv[0]` incluído (`sysctl` `KERN_PROCARGS2`); `nil` se não existe
  /// ou não é do usuário.
  public static func arguments(pid: Int32) -> [String]? {
    guard pid > 0 else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    // Layout: argc (Int32), o caminho do executável, zeros de alinhamento, e então os argc argumentos.
    let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 { index += 1 }
    while index < size, buffer[index] == 0 { index += 1 }
    var args: [String] = []
    while args.count < argc, index < size {
      let start = index
      while index < size, buffer[index] != 0 { index += 1 }
      args.append(String(decoding: buffer[start..<index], as: UTF8.self))
      index += 1
    }
    return args.count == argc ? args : nil
  }

  /// O processo `pid`, como está agora, é a sessão de `entry`?
  public static func isSession(pid: Int32, entry: RegistryEntry) -> Bool {
    matches(entry, startTime: startTime(pid: pid), executablePath: executablePath(pid: pid))
  }

  /// Com `procStart` legível, a hora de início do processo tem de bater com ela (precisão de
  /// segundos). Sem ele, algum componente do caminho do executável tem de ser do Claude (`isClaudeComponent`).
  public static func matches(_ entry: RegistryEntry, startTime: Date?, executablePath: String?) -> Bool {
    let candidates = entry.procStart.map(procStartCandidates) ?? []
    if !candidates.isEmpty {
      guard let startTime else { return false }
      // `procStart` trunca os segundos: o início real fica em [candidato, candidato + 1 s).
      return candidates.contains { abs(startTime.timeIntervalSince($0) - 0.5) <= 1 }
    }
    guard let executablePath else { return false }
    // O caminho inteiro, não só o nome: na instalação nativa o executável resolve para
    // `.../claude/versions/2.1.309`.
    return executablePath.split(separator: "/").contains { isClaudeComponent($0) }
  }

  /// Um componente do Claude, sem diferença de maiúsculas: "claude", ou "claude" seguido de "." ou
  /// "-code" (`Claude.app`, `claude-code`). "claude" no meio ou no começo de outro nome
  /// (`claude-menubar`, `myclaude`) não conta.
  static func isClaudeComponent(_ component: Substring) -> Bool {
    let name = component.lowercased()
    guard name.hasPrefix("claude") else { return false }
    let rest = name.dropFirst("claude".count)
    return rest.isEmpty || rest.hasPrefix(".") || rest.hasPrefix("-code")
  }

  /// `procStart` vem no formato do `ctime` ("Fri Oct 23 16:14:09 2026"). Nas versões vistas ele
  /// está em UTC; como o formato não diz o fuso, vale também a leitura no fuso local.
  static func procStartCandidates(_ text: String) -> [Date] {
    let normalized = text.split(separator: " ").joined(separator: " ")
    guard !normalized.isEmpty else { return [] }
    var dates: [Date] = []
    for zone in [TimeZone(identifier: "UTC"), TimeZone.current].compactMap({ $0 }) {
      let f = DateFormatter()
      f.locale = Locale(identifier: "en_US_POSIX")
      f.timeZone = zone
      f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
      f.isLenient = false
      if let date = f.date(from: normalized) { dates.append(date) }
    }
    return dates
  }
}
