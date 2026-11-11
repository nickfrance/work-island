import Foundation
import Testing
import IlhaCore

@Test func supportDirIsWorkIsland() {
  let support = IlhaPaths.supportDir
  #expect(support.lastPathComponent == "Work Island")
  #expect(IlhaPaths.settingsPath.deletingLastPathComponent() == support)
  #expect(IlhaPaths.metricsQueuePath.deletingLastPathComponent() == support)
  #expect(IlhaPaths.activityPath.deletingLastPathComponent() == support)
  #expect(IlhaPaths.pluginDir.deletingLastPathComponent() == support)
  #expect(IlhaPaths.settingsPath.lastPathComponent == "settings.json")
  #expect(IlhaPaths.metricsQueuePath.lastPathComponent == "metrics-queue.json")
  #expect(IlhaPaths.activityPath.lastPathComponent == "activity.json")
  #expect(IlhaPaths.pluginDir.lastPathComponent == "plugin")
}

/// O espaço no nome da pasta não pode estourar o limite do socket Unix (104 bytes) num home de 40 caracteres.
@Test func socketPathFitsWithLongHome() {
  let realHome = FileManager.default.homeDirectoryForCurrentUser.path
  var tail = IlhaPaths.socketPath
  if tail.hasPrefix(realHome) { tail.removeFirst(realHome.count) }
  let home = "/Users/" + String(repeating: "x", count: 33)
  #expect(home.utf8.count == 40)
  #expect((home + tail).utf8.count < 104)
}
