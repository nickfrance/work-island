import Foundation
import Testing
@testable import IlhaCore

@Suite struct PluginInstallTests {
  private let dir = URL(fileURLWithPath: "/tmp/wi/plugin")
  private let claude = URL(fileURLWithPath: "/usr/local/bin/claude")

  @Test func planWithoutClaudeIsClaudeMissing() {
    #expect(PluginInstall.plan(bundledVersion: "0.3.0", installedVersion: nil, claude: nil) == .claudeMissing)
  }

  @Test func planFirstRunInstallsAndRemovesLegacy() {
    #expect(PluginInstall.plan(bundledVersion: "0.3.0", installedVersion: nil, claude: claude)
      == .install(removeLegacy: true))
  }

  @Test func planSameVersionIsUpToDate() {
    #expect(PluginInstall.plan(bundledVersion: "0.3.0", installedVersion: "0.3.0", claude: claude) == .upToDate)
  }

  @Test func planOtherVersionReinstalls() {
    #expect(PluginInstall.plan(bundledVersion: "0.3.0", installedVersion: "0.2.1", claude: claude) == .reinstall)
  }

  @Test func installStepsOrder() {
    #expect(PluginInstall.steps(for: .install(removeLegacy: true), pluginDir: dir) == [
      PluginStep(arguments: ["plugin", "uninstall", "ilha"], mayFail: true),
      PluginStep(arguments: ["plugin", "marketplace", "remove", "ilha-local"], mayFail: true),
      PluginStep(arguments: ["plugin", "marketplace", "add", dir.path], mayFail: false),
      PluginStep(arguments: ["plugin", "install", "work-island@work-island"], mayFail: false),
    ])
  }

  @Test func reinstallStepsRemoveThenAdd() {
    #expect(PluginInstall.steps(for: .reinstall, pluginDir: dir) == [
      PluginStep(arguments: ["plugin", "marketplace", "update", "work-island"], mayFail: false),
      PluginStep(arguments: ["plugin", "update", "work-island@work-island"], mayFail: false),
    ])
  }

  @Test func repairStepsRemoveThenAdd() {
    #expect(PluginInstall.steps(for: .repair, pluginDir: dir) == [
      PluginStep(arguments: ["plugin", "uninstall", "work-island"], mayFail: true),
      PluginStep(arguments: ["plugin", "marketplace", "remove", "work-island"], mayFail: true),
      PluginStep(arguments: ["plugin", "marketplace", "add", dir.path], mayFail: false),
      PluginStep(arguments: ["plugin", "install", "work-island@work-island"], mayFail: false),
    ])
  }

  @Test func uninstallStepsOnlyOurs() {
    #expect(PluginInstall.uninstallSteps() == [
      PluginStep(arguments: ["plugin", "uninstall", "work-island"], mayFail: true),
      PluginStep(arguments: ["plugin", "marketplace", "remove", "work-island"], mayFail: true),
    ])
  }

  @Test func upToDateAndMissingHaveNoSteps() {
    #expect(PluginInstall.steps(for: .upToDate, pluginDir: dir).isEmpty)
    #expect(PluginInstall.steps(for: .claudeMissing, pluginDir: dir).isEmpty)
  }

  // MARK: execute

  private actor Calls {
    var seen: [[String]] = []
    func add(_ step: PluginStep) { seen.append(step.arguments) }
  }

  @Test func executeStopsAtFirstHardFailure() async {
    let steps = [
      PluginStep(arguments: ["a"], mayFail: true),
      PluginStep(arguments: ["b"], mayFail: false),
      PluginStep(arguments: ["c"], mayFail: false),
    ]
    let calls = Calls()
    let outcome = await PluginInstall.execute(steps) { step in
      await calls.add(step)
      switch step.arguments[0] {
      case "a": return CommandResult(exitCode: 1, stdout: "", stderr: "ignorado")
      case "b": return CommandResult(exitCode: 2, stdout: "", stderr: "deu ruim\nmais")
      default: return CommandResult(exitCode: 0, stdout: "", stderr: "")
      }
    }
    #expect(outcome == .failed("deu ruim"))
    #expect(await calls.seen == [["a"], ["b"]])
  }

  @Test func executeTimeoutOnHardStepFails() async {
    let outcome = await PluginInstall.execute([PluginStep(arguments: ["x"], mayFail: false)]) { _ in nil }
    #expect(outcome == .failed("timeout"))
  }

  @Test func executeAllOkIsInstalled() async {
    let steps = [PluginStep(arguments: ["a"], mayFail: true), PluginStep(arguments: ["b"], mayFail: false)]
    let outcome = await PluginInstall.execute(steps) { step in
      step.mayFail ? nil : CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
    #expect(outcome == .installed)
  }

  @Test func failedInstallDoesNotRecordVersion() {
    var before = AppSettings()
    before.installedPluginVersion = "0.2.1"
    #expect(before.recordingPluginInstall(.failed("x"), version: "0.3.0").installedPluginVersion == "0.2.1")
    #expect(before.recordingPluginInstall(.installed, version: "0.3.0").installedPluginVersion == "0.3.0")
  }
}
