import Foundation
import Darwin

/// Acha o app onde uma sessão roda subindo pela árvore de processos: o `claude` do terminal é
/// neto do iTerm/Ghostty/Terminal, o do VS Code é filho do VS Code (ou do Cursor), o do app desktop
/// é filho do Claude. O primeiro ancestral que é um app de verdade é quem vai para a frente.
public enum HostApp {
  /// Primeiro processo, a partir de `pid` e subindo pelos pais, que `isApp` reconhece. O `launchd`
  /// (pid 1) nunca conta, e a subida para em 64 níveis ou num laço.
  public static func ancestor(
    of pid: Int32, parent: (Int32) -> Int32?, isApp: (Int32) -> Bool
  ) -> Int32? {
    var current = pid
    var seen: Set<Int32> = []
    while current > 1, seen.count < 64, seen.insert(current).inserted {
      if isApp(current) { return current }
      guard let next = parent(current) else { return nil }
      current = next
    }
    return nil
  }

  /// Pai do processo (`sysctl` `KERN_PROC_PID` → `e_ppid`); `nil` se não existe.
  public static func parentPID(of pid: Int32) -> Int32? {
    guard pid > 0 else { return nil }
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
  }
}
