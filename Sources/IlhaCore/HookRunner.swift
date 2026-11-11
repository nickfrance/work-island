import Foundation

/// Quanto o hook espera o ack de um pedido segurado antes de concluir que o app é antigo.
public let holdAckTimeout: TimeInterval = 0.5

/// Corpo do binário `ilha-hook`: embrulha o evento do Claude Code e o manda ao app pelo socket.
/// Devolve sempre o código 0 e nunca deixa um erro escapar — o hook não pode atrapalhar a sessão
/// do usuário. Com `ILHA_INTERNAL=1` no ambiente não envia nada; conexão e envio têm prazo de 0,2 s.
///
/// Só os eventos segurados (`HookEvent.holdsForReply`: pedido de permissão e pergunta) esperam,
/// na mesma conexão: primeiro o ack do app (`ack`) por até `holdAckTimeout` — sem ele o app é
/// antigo, não responde pedidos, e o hook sai na hora com `stdout` vazio —, depois uma linha de
/// resposta por até `holdTimeout` + 5 s. Se a linha é um
/// objeto JSON, ela volta em `stdout` (é a decisão do hook); linha vazia, conexão fechada, tempo
/// esgotado ou app fechado deixam `stdout` vazio e o Claude Code segue o fluxo normal. Todo o resto
/// nunca escreve no stdout.
///
/// O pid da sessão vem de `CLAUDE_PID` (o processo do Claude Code); sem ele, ou se não for um
/// número positivo, vale o processo pai do hook.
public func runHook(
  stdin: Data, environment: [String: String], parentPID: Int32, socketPath: String,
  holdTimeout: TimeInterval = 300
) -> (code: Int32, stdout: Data) {
  if environment["ILHA_INTERNAL"] == "1" { return (0, Data()) }
  let claudePID = environment["CLAUDE_PID"].flatMap { Int32($0) }.flatMap { $0 > 0 ? $0 : nil }
  let projectDir = environment["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
  let attended: Bool? = switch environment["CLAUDE_CODE_SESSION_ATTENDED"] {
  case "0": false
  case "1": true
  default: nil
  }
  guard let line = try? Envelope.wrap(
    rawEvent: stdin, entrypoint: environment["CLAUDE_CODE_ENTRYPOINT"], pid: claudePID ?? parentPID,
    projectDir: projectDir, attended: attended)
  else { return (0, Data()) }

  let holds = (try? JSONDecoder().decode(HookEvent.self, from: stdin))?.holdsForReply ?? false
  guard holds else {
    _ = sendEnvelope(line, socketPath: socketPath, timeout: 0.2)
    return (0, Data())
  }
  // O app responde vazio ao fim de `holdTimeout`; os 5 s a mais cobrem o atraso dessa resposta.
  guard let reply = exchangeEnvelope(
    line, socketPath: socketPath, connectTimeout: 0.2, ackTimeout: holdAckTimeout, replyTimeout: holdTimeout + 5),
    !reply.isEmpty,
    (try? JSONSerialization.jsonObject(with: reply)) is [String: Any]
  else { return (0, Data()) }
  return (0, reply)
}
