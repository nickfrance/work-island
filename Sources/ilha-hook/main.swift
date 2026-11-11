import Foundation
import IlhaCore

// Lê o evento do Claude Code no stdin e o repassa ao app. Sai sempre com 0; só escreve no stdout
// a decisão da ilha para um pedido de permissão ou pergunta.
signal(SIGPIPE, SIG_IGN)  // stdout fechado não pode derrubar o hook
let input = FileHandle.standardInput.readDataToEndOfFile()
let result = runHook(
  stdin: input, environment: ProcessInfo.processInfo.environment,
  parentPID: getppid(), socketPath: IlhaPaths.socketPath)
if !result.stdout.isEmpty { try? FileHandle.standardOutput.write(contentsOf: result.stdout) }
exit(result.code)
