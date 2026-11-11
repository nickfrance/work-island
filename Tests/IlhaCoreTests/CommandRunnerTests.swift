import Foundation
import Testing
@testable import IlhaCore

@Suite struct CommandRunnerTests {
  private let tmp = URL(fileURLWithPath: NSTemporaryDirectory())

  @Test func commandRunnerReportsExitAndOutput() async {
    let result = await CommandRunner.run(
      URL(fileURLWithPath: "/bin/sh"), ["-c", "echo oi; exit 3"], environment: [:], workingDirectory: tmp)
    #expect(result?.exitCode == 3)
    #expect(result?.stdout == "oi\n")
  }

  @Test func commandRunnerTimesOut() async {
    let result = await CommandRunner.run(
      URL(fileURLWithPath: "/bin/sleep"), ["5"], environment: [:], workingDirectory: tmp, timeout: 0.5)
    #expect(result == nil)
  }
}
