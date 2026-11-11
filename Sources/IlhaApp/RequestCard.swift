import AppKit
import SwiftUI
import IlhaCore

// MARK: - Baralho de pedidos

/// Tecla que o cartão entende com o painel aberto (a janela repassa; ver `IslandPanel`).
enum CardKey: Equatable {
  /// ↩ (também dentro do campo de texto).
  case confirm
  /// Esc sem campo de texto em foco.
  case escape
  /// 1–9 sem campo de texto em foco.
  case digit(Int)
}

/// O que a janela faz com uma tecla enquanto o painel é a janela chave.
enum PanelKeyAction: Equatable {
  /// Segue para o conteúdo (campo de texto, botões).
  case pass
  /// Usada e descartada (tecla segurada).
  case swallow
  /// Esc num campo de texto: só tira o foco.
  case unfocus
  case card(CardKey)
}

extension CardKey {
  /// ↩ confirma mesmo dentro do campo de texto (⇧↩ e a composição de acentos seguem para o campo);
  /// Esc com campo em foco só tira o foco; números só fora do campo. Repetição de tecla segurada
  /// nunca responde nada: ↩, Esc e números repetidos são descartados.
  static func action(
    keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
    isRepeat: Bool, typing: Bool, composing: Bool
  ) -> PanelKeyAction {
    let modifiers = modifiers.intersection([.shift, .control, .option, .command])
    switch keyCode {
    case 36, 76:
      guard modifiers.isEmpty, !composing else { return .pass }
      return isRepeat ? .swallow : .card(.confirm)
    case 53:
      guard !composing else { return .pass }
      if isRepeat { return .swallow }
      return typing ? .unfocus : .card(.escape)
    default:
      guard !typing, modifiers.isEmpty, let digit = characters.flatMap(Int.init), (1...9).contains(digit) else {
        return .pass
      }
      return isRepeat ? .swallow : .card(.digit(digit))
    }
  }
}

/// O que o painel mostra quando há pedidos: qual cartão está na frente, o rascunho de cada um
/// (opções marcadas, "Outra…", explicação do "Negar"), a fase do cartão (esperando, respondido aqui,
/// resolvido em outro lugar) e a troca deslizando entre um cartão e outro. A fila vem do `AppModel`
/// por `sync`; responder volta por `respond`/`handBack`.
@MainActor
final class RequestDeck: ObservableObject {
  enum Phase: Equatable {
    /// Esperando a resposta.
    case asking
    /// Respondido aqui: check verde e a frase do resultado por 1,05 s, depois o próximo.
    case answered(String)
    /// Saiu da fila por outro caminho (respondido no app de origem, devolvido, prazo): a frase
    /// enquanto o resultado vive em `recentlyResolved` (3 s).
    case resolved(RequestQueue.Outcome)
  }

  /// O que já foi escolhido num pedido, por pergunta.
  struct Draft: Equatable {
    /// Pergunta na tela (várias perguntas vêm uma por vez).
    var question = 0
    var picked: [Set<Int>] = []
    var otherPicked: [Bool] = []
    var other: [String] = []
    /// "Negar e explicar…" abriu o campo.
    var explaining = false
    var why = ""
    /// "Ler tudo" no contexto do Claude (vale para todas as perguntas do pedido).
    var contextOpen = false
    /// "ver pergunta inteira" na pergunta na tela.
    var questionOpen = false

    init(_ request: PendingRequest) {
      guard case .questions(let ask) = request.kind else { return }
      // Escolha única já vem com a recomendada marcada, como no protótipo.
      picked = ask.questions.map { q in
        guard !q.multiSelect, let i = q.options.firstIndex(where: \.recommended) else { return [] }
        return [i]
      }
      otherPicked = Array(repeating: false, count: ask.questions.count)
      other = Array(repeating: "", count: ask.questions.count)
    }
  }

  /// Campo de texto que deve ganhar o foco.
  enum Focus: Hashable {
    case why
    case other(Int)
  }

  /// `target` nil: nenhum campo com o foco (troca de pergunta ou de cartão, resposta enviada).
  struct FocusRequest: Equatable {
    let target: Focus?
    let serial: Int
  }

  /// Deslocamento e opacidade do conteúdo durante a troca de cartão.
  struct Slide: Equatable {
    var offset: CGFloat = 0
    var opacity: Double = 1
  }

  enum KeyResult { case handled, close, ignored }

  @Published private(set) var queue = RequestQueue()
  /// O pedido no cartão; continua aqui enquanto o resultado dele aparece, já fora da fila.
  @Published private(set) var shown: PendingRequest?
  @Published private(set) var phase: Phase = .asking
  @Published private(set) var drafts: [UUID: Draft] = [:]
  /// Os pedidos desta leva, em ordem de chegada: um tracinho para cada.
  @Published private(set) var batch: [UUID] = []
  @Published private(set) var slide = Slide()
  @Published private(set) var focus: FocusRequest?
  /// O que o Claude escreveu antes de cada pergunta, lido da transcrição e já dividido em blocos de
  /// Markdown; sem texto, sem entrada.
  @Published private(set) var contexts: [UUID: [QuestionContext.Block]] = [:]

  /// O painel está na tela: só então as trocas deslizam. Abrir conta como o cartão aparecendo.
  var visible = false {
    didSet { if visible, !oldValue { markAppeared() } }
  }
  var respond: (UUID, Decision) -> Void = { _, _ in }
  var handBack: (UUID) -> Void = { _ in }
  /// Tira o foco do campo de texto na janela (o AppKit, além do `@FocusState` da SwiftUI).
  var resignTextFocus: () -> Void = {}
  /// A transcrição da sessão (`Session.transcriptPath`), de onde vem o contexto da pergunta.
  var transcript: (String) -> URL? = { _ in nil }

  /// Leitura do contexto nas transcrições, fora da thread principal.
  private static let contextQueue = DispatchQueue(label: "dev.nick.ilha.context", qos: .utility)
  /// A pergunta pode chegar antes de a linha dela ser gravada: tenta de novo algumas vezes.
  static let contextAttempts = 4
  static let contextRetry: TimeInterval = 0.5
  /// `ILHA_DEBUG=1`: o resultado de cada leitura do contexto vai para o stderr.
  private let debug = ProcessInfo.processInfo.environment["ILHA_DEBUG"] == "1"

  /// Quanto tempo um cartão (ou pergunta) novo precisa estar na tela antes de aceitar resposta:
  /// um ↩ dado antes (ou segurado) não responde o que você ainda não viu.
  static let settleTime: TimeInterval = 0.3
  private var readyAt = Date.distantPast

  private var swapping = false
  private var focusSerial = 0
  /// Pedido escolhido de fora (chegou com o app de origem na frente) enquanto o cartão não podia trocar.
  private var preferred: UUID?
  private var advanceWork: DispatchWorkItem?

  var pending: [PendingRequest] { queue.pending }

  /// Os outros pedidos esperando ("Na fila").
  var waiting: [PendingRequest] { queue.pending.filter { $0.id != shown?.id } }

  var draft: Draft? { shown.flatMap { drafts[$0.id] } }

  /// A forma do objeto do topo: check ao responder, pensando enquanto algo espera, esfera no resto.
  var shape: ParticleShape {
    if case .answered = phase { return .check }
    return queue.pending.isEmpty ? .sphere : .thinking
  }

  /// A cor do painel: verde no check, âmbar com cartão esperando, a das sessões no resto.
  func accent(sessions: [Session]) -> SphereMood {
    if case .answered = phase { return .result }
    if shown != nil, !queue.pending.isEmpty { return .needsYou }
    return SphereMood(sessions: sessions, hasPendingRequest: !queue.pending.isEmpty)
  }

  enum Dash { case current, done, waiting }

  func dash(_ id: UUID) -> Dash {
    if id == shown?.id { return .current }
    return queue.pending.contains { $0.id == id } ? .waiting : .done
  }

  // MARK: Fila

  /// A fila mudou no `AppModel`.
  func sync(_ next: RequestQueue) {
    queue = next
    let ids = Set(next.pending.map(\.id))
    for request in next.pending where drafts[request.id] == nil {
      drafts[request.id] = Draft(request)
      if !batch.contains(request.id) { batch.append(request.id) }
      loadContext(request, attempt: 1)
    }
    let keep = drafts.keys.filter { !ids.contains($0) && $0 != shown?.id }
    for id in keep {
      drafts[id] = nil
      contexts[id] = nil
    }
    // No meio da troca, quem decide é o fim dela (relê a fila).
    guard !swapping else { return }

    if let current = shown {
      switch phase {
      case .asking where !ids.contains(current.id):
        // Saiu da fila sem resposta daqui: a frase do que houve, até o resultado apagar.
        if let outcome = next.recentlyResolved[current.id] {
          withAnimation(.easeOut(duration: 0.2)) { phase = .resolved(outcome) }
        } else {
          advance(preferring: nil)
        }
      case .resolved where next.recentlyResolved[current.id] == nil:
        advance(preferring: nil)
      default:
        break
      }
    } else if let first = next.pending.first {
      transition { self.shown = first; self.phase = .asking }
    } else if !batch.isEmpty {
      batch = []
    }
  }

  /// Abre o cartão deste pedido (chegou agora com o app de origem na frente). No meio de uma
  /// resposta, ele vem logo depois.
  func bringForward(_ id: UUID) {
    guard let request = queue.pending.first(where: { $0.id == id }), request.id != shown?.id else { return }
    if phase == .asking, !swapping {
      transition { self.shown = request }
    } else {
      preferred = id
    }
  }

  /// Clique numa linha de "Na fila".
  func select(_ id: UUID) {
    guard phase == .asking, !swapping, id != shown?.id,
          let request = queue.pending.first(where: { $0.id == id }) else { return }
    transition { self.shown = request }
  }

  // MARK: Texto longo

  /// "Ler tudo" / "Recolher" no contexto do pedido na tela.
  func toggleContext() {
    guard let id = shown?.id, drafts[id] != nil else { return }
    withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.45)) { drafts[id]?.contextOpen.toggle() }
  }

  /// "ver pergunta inteira" / "mostrar menos" na pergunta na tela.
  func toggleQuestion() {
    guard let id = shown?.id, drafts[id] != nil else { return }
    withAnimation(.easeOut(duration: 0.25)) { drafts[id]?.questionOpen.toggle() }
  }

  /// Com contexto, ou com pergunta média ou longa, o cartão inteiro alinha à esquerda.
  func leading(_ request: PendingRequest) -> Bool {
    guard case .questions(let ask) = request.kind else { return false }
    if contexts[request.id] != nil { return true }
    let index = min(drafts[request.id]?.question ?? 0, ask.questions.count - 1)
    return ask.questions.indices.contains(index) && QuestionSize(ask.questions[index].text) != .short
  }

  /// Lê, fora da thread principal, o que o Claude escreveu antes da pergunta. Se a linha da pergunta
  /// ainda não está na transcrição (ou a sessão ainda não tem o caminho), tenta de novo em 0,5 s.
  private func loadContext(_ request: PendingRequest, attempt: Int) {
    guard case .questions = request.kind, let toolUseID = request.toolUseID, !toolUseID.isEmpty else { return }
    guard let url = transcript(request.sessionID) else {
      retryContext(request, attempt: attempt)
      return
    }
    Self.contextQueue.async { [weak self] in
      let lookup = QuestionContext.lookup(transcript: url, toolUseID: toolUseID)
      let blocks: [QuestionContext.Block]? = if case .found(let text?) = lookup { QuestionContext.blocks(text) } else { nil }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.drafts[request.id] != nil else { return }
          self.log(lookup, toolUseID: toolUseID, attempt: attempt)
          switch lookup {
          case .found where blocks?.isEmpty == false:
            let onScreen = self.visible && self.shown?.id == request.id
            withAnimation(onScreen ? .easeOut(duration: 0.25) : nil) {
              self.contexts[request.id] = blocks
            }
            // As opções desceram: 300 ms antes de aceitar clique ou ↩ de novo.
            if onScreen { self.markAppeared() }
          case .found:
            break
          case .missing:
            self.retryContext(request, attempt: attempt)
          }
        }
      }
    }
  }

  private func log(_ lookup: QuestionContext.Lookup, toolUseID: String, attempt: Int) {
    guard debug else { return }
    let what: String
    switch lookup {
    case .found(let text?): what = "\(text.count) caracteres"
    case .found(nil): what = "sem texto"
    case .missing: what = "pergunta ainda não está na transcrição"
    }
    FileHandle.standardError.write(Data("ilha: contexto de \(toolUseID) (tentativa \(attempt)): \(what)\n".utf8))
  }

  private func retryContext(_ request: PendingRequest, attempt: Int) {
    guard attempt < Self.contextAttempts else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.contextRetry) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.drafts[request.id] != nil else { return }
        self.loadContext(request, attempt: attempt + 1)
      }
    }
  }

  // MARK: Respostas

  func allow() { finish(.allow, phrase: L10n.string("result.allowed")) }

  func allowAlways() { finish(.allowAlways, phrase: L10n.string("result.alwaysAllowed")) }

  /// Negar (botão ou ↩ com o campo aberto); com o campo aberto e algum texto, o texto vai junto.
  func deny() {
    let why = (draft?.explaining ?? false) ? draft?.why.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
    finish(.deny(message: why.isEmpty ? nil : why),
           phrase: L10n.string(why.isEmpty ? "result.denied" : "result.deniedExplained"))
  }

  /// Esc: nega sem o texto, mesmo com o campo da explicação aberto (sem foco).
  func denyPlain() {
    finish(.deny(message: nil), phrase: L10n.string("result.denied"))
  }

  func explain() {
    guard phase == .asking, !swapping, let id = shown?.id else { return }
    withAnimation(.easeOut(duration: 0.25)) { drafts[id]?.explaining = true }
    requestFocus(.why)
  }

  /// Texto da explicação do pedido `id` (o do campo que escreveu, não o que estiver na tela).
  func setWhy(_ text: String, for id: UUID) {
    drafts[id]?.why = text
  }

  /// "ou abrir no <app>": o pedido volta para lá (resposta vazia) e o app vem para a frente.
  func openInOrigin() {
    guard phase == .asking, !swapping, isSettled, let id = shown?.id else { return }
    handBack(id)
  }

  /// Marca (ou desmarca, na múltipla) a opção `index` da pergunta na tela. Nos 300 ms depois de o
  /// cartão aparecer (ou mudar de lugar), o clique não vale.
  func pick(_ index: Int) {
    guard phase == .asking, !swapping, isSettled, let id = shown?.id, let question = currentQuestion, var d = drafts[id] else { return }
    let q = d.question
    if question.multiSelect {
      if d.picked[q].contains(index) { d.picked[q].remove(index) } else { d.picked[q].insert(index) }
    } else {
      d.picked[q] = [index]
      d.otherPicked[q] = false
    }
    drafts[id] = d
  }

  /// A linha "Outra…" (clique ou número): como `pick`, espera o cartão assentar.
  func pickOther() {
    guard isSettled else { return }
    toggleOther()
  }

  /// Marca (alterna na múltipla) a linha "Outra…" e põe o foco no campo quando fica marcada.
  private func toggleOther() {
    guard phase == .asking, !swapping, let id = shown?.id, let question = currentQuestion, var d = drafts[id] else { return }
    let q = d.question
    if question.multiSelect {
      d.otherPicked[q].toggle()
    } else {
      d.picked[q] = []
      d.otherPicked[q] = true
    }
    drafts[id] = d
    if d.otherPicked[q] { requestFocus(.other(q)) }
  }

  /// Texto do "Outra…" da pergunta `question` do pedido `id` (os do campo que escreveu); escrever
  /// também marca a linha, se ela é a que está na tela.
  func setOther(_ text: String, for id: UUID, question: Int) {
    guard var d = drafts[id], d.other.indices.contains(question) else { return }
    d.other[question] = text
    drafts[id] = d
    if !text.isEmpty { ensureOther(for: id, question: question) }
  }

  /// O campo do "Outra…" ganhou o foco ou texto: a linha fica marcada (só no cartão e na pergunta na tela).
  func ensureOther(for id: UUID, question: Int) {
    guard phase == .asking, shown?.id == id, let d = drafts[id], d.question == question,
          d.otherPicked.indices.contains(question), !d.otherPicked[question] else { return }
    // Escrever no campo sempre marca: o texto nunca fica fora da resposta.
    toggleOther()
  }

  var currentQuestion: QuestionAsk.Question? {
    guard case .questions(let ask)? = shown?.kind, let d = draft, ask.questions.indices.contains(d.question) else { return nil }
    return ask.questions[d.question]
  }

  /// Quantas escolhas a pergunta na tela tem ("Enviar (N)").
  var choiceCount: Int {
    guard let d = draft, d.picked.indices.contains(d.question) else { return 0 }
    return d.picked[d.question].count + (d.otherPicked[d.question] ? 1 : 0)
  }

  /// Dá para seguir: alguma escolha, e "Outra…" marcada só com texto.
  var canConfirmQuestion: Bool {
    guard let d = draft, d.picked.indices.contains(d.question) else { return false }
    let q = d.question
    if d.otherPicked[q], d.other[q].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
    return choiceCount > 0
  }

  var isLastQuestion: Bool {
    guard case .questions(let ask)? = shown?.kind, let d = draft else { return true }
    return d.question >= ask.questions.count - 1
  }

  /// ↩ ou o botão principal: permitir (ou negar com a explicação aberta); na pergunta, a próxima ou responder.
  func confirm() {
    guard phase == .asking, !swapping, isSettled, let request = shown else { return }
    switch request.kind {
    case .permission:
      if draft?.explaining == true { deny() } else { allow() }
    case .questions(let ask):
      guard canConfirmQuestion, let id = shown?.id else { return }
      if !isLastQuestion {
        transition {
          self.drafts[id]?.question += 1
          self.drafts[id]?.questionOpen = false
        }
        return
      }
      submit(ask)
    }
  }

  func key(_ key: CardKey) -> KeyResult {
    guard let request = shown else { return key == .escape ? .close : .ignored }
    // No meio do resultado ou da troca: Esc ainda fecha, o resto espera.
    guard phase == .asking, !swapping else { return key == .escape ? .close : .handled }
    switch (key, request.kind) {
    case (.confirm, _):
      confirm()
      return .handled
    case (.escape, .permission):
      denyPlain()
      return .handled
    case (.escape, .questions):
      return .close
    case (.digit(let n), .questions):
      guard let question = currentQuestion else { return .ignored }
      if n - 1 < question.options.count {
        pick(n - 1)
      } else if n - 1 == question.options.count {
        pickOther()
      } else {
        return .ignored
      }
      return .handled
    case (.digit, .permission):
      return .ignored
    }
  }

  private func submit(_ ask: QuestionAsk) {
    guard let d = draft else { return }
    var answers: [String: String] = [:]
    var shownLabels: [String] = []
    for (q, question) in ask.questions.enumerated() where d.picked.indices.contains(q) {
      let indices = d.picked[q].sorted().filter { question.options.indices.contains($0) }
      let other = d.otherPicked[q] ? d.other[q].trimmingCharacters(in: .whitespacesAndNewlines) : nil
      answers[question.text] = QuestionAsk.answerValue(
        forSelected: indices.map { question.options[$0].answerLabel }, other: other)
      shownLabels += indices.map { question.options[$0].label }
      if let other, !other.isEmpty { shownLabels.append(other) }
    }
    finish(.answer(answers), phrase: L10n.string("result.answered", shownLabels.joined(separator: ", ")))
  }

  /// Responde o pedido na tela: check verde e a frase, a resposta sai na hora e, 1,05 s depois,
  /// o próximo entra da direita (ou as sessões, se não há mais).
  private func finish(_ decision: Decision, phrase: String) {
    guard phase == .asking, !swapping, isSettled, let request = shown,
          queue.pending.contains(where: { $0.id == request.id }) else { return }
    // Antes de responder: depois o id já não está na fila.
    let next = queue.next(after: request.id).flatMap { $0.id == request.id ? nil : $0.id }
    clearFocus()
    withAnimation(.easeOut(duration: 0.2)) { phase = .answered(phrase) }
    respond(request.id, decision)
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.advance(preferring: next) }
    }
    advanceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: work)
  }

  /// O próximo cartão: o escolhido de fora, o que vinha depois, o primeiro da fila — ou as sessões.
  private func advance(preferring id: UUID?) {
    advanceWork?.cancel()
    advanceWork = nil
    let wanted = [preferred, id].compactMap { $0 }
    preferred = nil
    let target = wanted.lazy.compactMap { w in self.queue.pending.first { $0.id == w } }.first ?? queue.pending.first
    transition {
      self.shown = target
      self.phase = .asking
      if target == nil { self.batch = [] }
    }
  }

  private func requestFocus(_ target: Focus?) {
    focusSerial += 1
    focus = FocusRequest(target: target, serial: focusSerial)
  }

  /// Nenhum campo com o foco, nem na SwiftUI nem no AppKit: o que você digitou numa pergunta nunca
  /// segue para a próxima.
  private func clearFocus() {
    requestFocus(nil)
    resignTextFocus()
  }

  /// Já passou o tempo mínimo desde que o cartão (ou a pergunta) apareceu.
  var isSettled: Bool { Date() >= readyAt }

  private func markAppeared() {
    readyAt = Date().addingTimeInterval(Self.settleTime)
  }

  /// A troca do protótipo: o conteúdo sai para a esquerda (260 ms), muda, e entra da direita (420 ms).
  /// Com o painel fechado ou Reduzir movimento, muda direto.
  private func transition(_ change: @escaping @MainActor () -> Void) {
    // Cartão ou pergunta nova: sem foco em campo nenhum e, na tela, 300 ms antes de aceitar resposta.
    let change: @MainActor () -> Void = { [unowned self] in
      change()
      self.clearFocus()
      if self.visible { self.markAppeared() }
    }
    guard visible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      change()
      slide = Slide()
      return
    }
    swapping = true
    withAnimation(.easeIn(duration: 0.26)) { slide = Slide(offset: -18, opacity: 0) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
          change()
          self.slide = Slide(offset: 18, opacity: 0)
        }
        self.swapping = false
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            withAnimation(.timingCurve(0.2, 0.9, 0.25, 1.05, duration: 0.42)) { self.slide = Slide() }
          }
        }
        // A fila pode ter mudado durante a saída.
        self.sync(self.queue)
      }
    }
  }
}

// MARK: - Textos

/// Tamanho da pergunta pelo número de caracteres: até 60 curta (19 pt, centralizada), até 140
/// média (15,5 pt, à esquerda), acima longa (14 pt, à esquerda, cortada em 4 linhas).
enum QuestionSize: Equatable {
  case short, medium, long

  init(_ text: String) {
    let count = text.count
    self = count <= 60 ? .short : count <= 140 ? .medium : .long
  }
}

/// Os textos do cartão a partir do pedido (título por ferramenta, conteúdo, horário, resultado).
enum CardText {
  static func title(_ ask: PermissionAsk) -> String {
    switch ask.toolName {
    case "Bash":
      return L10n.string("card.title.run", leadingWords(ask.command ?? ""))
    case "Edit", "Write", "MultiEdit":
      let name = string(ask.toolInput, "file_path").map { URL(fileURLWithPath: $0).lastPathComponent }
      return L10n.string(ask.toolName == "Write" ? "card.title.write" : "card.title.edit", name ?? ask.toolName)
    case "WebFetch":
      return L10n.string("card.title.open", domain(string(ask.toolInput, "url")) ?? ask.toolName)
    default:
      return L10n.string("card.title.use", toolDisplayName(ask.toolName))
    }
  }

  /// Os dois primeiros termos do comando (da primeira linha), cada um com no máximo 24 caracteres.
  static func leadingWords(_ command: String) -> String {
    let words = commandWords(command)
    guard !words.isEmpty else { return "…" }
    return words.map { $0.count > 24 ? String($0.prefix(23)) + "…" : $0 }.joined(separator: " ")
  }

  /// Os dois primeiros termos; um segundo termo que é só operador do shell (`>`, `|`, `&&`) fica de fora.
  private static func commandWords(_ command: String) -> [String] {
    let line = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).prefix(2).map(String.init)
    if words.count == 2, words[1].allSatisfy({ "<>|&;".contains($0) }) { words.removeLast() }
    return words
  }

  /// Comando inteiro com os dois primeiros termos em destaque (`.cmd .k` do protótipo).
  static func command(_ command: String) -> AttributedString {
    var text = AttributedString(command)
    let lead = commandWords(command).joined(separator: " ")
    let trimmed = command.drop { $0 == " " || $0 == "\t" }
    if !lead.isEmpty, trimmed.hasPrefix(lead), let range = text.range(of: lead) {
      text[range].foregroundColor = Color(red: 1, green: 0xB3 / 255, blue: 0x47 / 255)
    }
    return text
  }

  /// O caminho do arquivo com `~` no lugar da pasta do usuário.
  static func shortPath(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  /// A mudança no arquivo, inteira: o conteúdo novo (Write), ou cada trecho com as linhas que saem
  /// (`−`, vermelho) e as que entram (`+`, verde); trechos separados por `⋯`.
  static func change(_ change: FileChange) -> AttributedString {
    switch change.kind {
    case .write(let content):
      return AttributedString(lines(content).joined(separator: "\n"))
    case .edits(let edits):
      var text = AttributedString()
      let removed = Color(red: 1, green: 0x7A / 255, blue: 0x7A / 255)
      let added = Color(red: 0x5F / 255, green: 0xD3 / 255, blue: 0x8A / 255)
      let note = Color.white.opacity(0.45)
      func append(_ line: String, _ color: Color) {
        if !text.characters.isEmpty { text.append(AttributedString("\n")) }
        var piece = AttributedString(line)
        piece.foregroundColor = color
        text.append(piece)
      }
      for (index, edit) in edits.enumerated() {
        if index > 0 { append("⋯", note) }
        if edit.replaceAll { append("(\(L10n.string("card.edit.replaceAll")))", note) }
        for line in lines(edit.old) { append("− " + line, removed) }
        for line in lines(edit.new) { append("+ " + line, added) }
      }
      return text
    }
  }

  /// As linhas do trecho, sem a vazia que o `\n` final deixaria na caixa; trecho vazio não tem linha.
  private static func lines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.components(separatedBy: "\n")
    if lines.count > 1, lines.last == "" { lines.removeLast() }
    return lines
  }

  /// O que vai em mono embaixo do título: o comando, o arquivo, o endereço, ou os campos de texto.
  static func content(_ ask: PermissionAsk) -> String? {
    switch ask.toolName {
    case "Bash":
      return ask.command
    case "Edit", "Write", "MultiEdit":
      return string(ask.toolInput, "file_path").map { ($0 as NSString).abbreviatingWithTildeInPath }
    case "WebFetch":
      return string(ask.toolInput, "url")
    default:
      guard case .object(let input) = ask.toolInput else { return nil }
      // Tudo o que vai ser aprovado, inteiro: nenhuma chave escondida, nenhum valor cortado (a caixa rola).
      // A `description` em texto já é o subtítulo do cartão.
      let lines = input.keys.sorted().compactMap { key -> String? in
        if key == "description", case .string = input[key] { return nil }
        return input[key].map { "\(key): \(fieldValue($0))" }
      }
      return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
  }

  /// Texto e número como estão; listas e objetos em JSON compacto, com as chaves em ordem.
  private static func fieldValue(_ value: JSONValue) -> String {
    switch value {
    case .string(let s): return s
    case .number(let n): return n.rounded() == n && abs(n) < 9_007_199_254_740_992 ? String(Int64(n)) : String(n)
    case .bool(let b): return String(b)
    case .null: return "null"
    case .array, .object:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
  }

  /// `mcp__servidor__ferramenta` → `ferramenta`.
  static func toolDisplayName(_ name: String) -> String {
    guard name.hasPrefix("mcp__") else { return name }
    return name.components(separatedBy: "__").last.flatMap { $0.isEmpty ? nil : $0 } ?? name
  }

  static func domain(_ url: String?) -> String? {
    guard let url, let host = URL(string: url)?.host(), !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  private static func string(_ value: JSONValue, _ key: String) -> String? {
    guard case .object(let o) = value, case .string(let s)? = o[key], !s.isEmpty else { return nil }
    return s
  }

  /// "agora", "há 2 min", "há 3 h".
  static func ago(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return L10n.string("card.when.now") }
    let minutes = Int(seconds / 60)
    if minutes < 60 { return L10n.string("card.when.minutes", minutes) }
    return L10n.string("card.when.hours", minutes / 60)
  }

  static func kind(_ request: PendingRequest) -> String {
    switch request.kind {
    case .permission: return L10n.string("card.kind.permission")
    case .questions: return L10n.string("card.kind.question")
    }
  }

  /// "abrir no VS Code" (ou "no app de origem" sem saber qual).
  static func openIn(_ host: IlhaCore.Host?) -> String {
    guard let label = host?.label, !label.isEmpty else { return L10n.string("card.openIn.unknown") }
    return L10n.string("card.openIn", label)
  }

  /// A frase de um pedido que saiu da fila sem resposta daqui. `request`: as respostas saem na ordem das perguntas.
  static func outcome(_ outcome: RequestQueue.Outcome, sessionHost: IlhaCore.Host?, request: PendingRequest? = nil) -> String {
    switch outcome {
    case .resolvedElsewhere(let host):
      let label = host == .unknown ? sessionHost?.label ?? "" : host.label
      return label.isEmpty ? L10n.string("result.elsewhere.unknown") : L10n.string("result.elsewhere", label)
    case .expired, .answered(.passThrough):
      guard let label = sessionHost?.label, !label.isEmpty else { return L10n.string("result.handedBack.unknown") }
      return L10n.string("result.handedBack", label)
    case .answered(.allow):
      return L10n.string("result.allowed")
    case .answered(.allowAlways):
      return L10n.string("result.alwaysAllowed")
    case .answered(.deny(let message)):
      return L10n.string(message?.isEmpty == false ? "result.deniedExplained" : "result.denied")
    case .answered(.answer(let answers)):
      var order: [String] = []
      if case .questions(let ask)? = request?.kind { order = ask.questions.map(\.text).filter { answers[$0] != nil } }
      // Chave que não casa com nenhuma pergunta (não deveria haver) vai no fim, em ordem alfabética.
      order += answers.keys.filter { !order.contains($0) }.sorted()
      return L10n.string("result.answered", order.compactMap { answers[$0] }.joined(separator: ", "))
    }
  }
}

// MARK: - Cartão

/// O cabeçalho do cartão (projeto, "há 2 min · VS Code", "1 de 2"): fica no topo fixo do painel,
/// embaixo do objeto, e não rola com o resto.
struct RequestCardHeader: View {
  @ObservedObject var deck: RequestDeck
  let request: PendingRequest
  let store: SessionStore
  let now: Date
  let accent: Color

  var body: some View {
    let name = store.displayName(for: request.sessionID)
    var meta = [CardText.ago(request.receivedAt, now: now)]
    if let label = store.sessions[request.sessionID]?.host.label, !label.isEmpty { meta.append(label) }
    if case .questions(let ask) = request.kind, ask.questions.count > 1, let d = deck.drafts[request.id] {
      meta.append(L10n.string("card.question.step", d.question + 1, ask.questions.count))
    }
    return HStack(spacing: 6) {
      Text(verbatim: name.isEmpty ? "Claude" : name)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.black)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(accent))
      Text(verbatim: meta.joined(separator: " · "))
        .font(.system(size: 11))
        .foregroundStyle(Color.white.opacity(0.45))
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: deck.leading(request) ? .leading : .center)
    .padding(.horizontal, 18)
  }
}

/// O miolo do cartão, a parte que rola: título e texto, aviso, conteúdo e explicação (permissão), ou
/// o contexto do Claude, a pergunta e as opções. Com o resultado, a frase toma o lugar do texto.
struct RequestCardView: View {
  @ObservedObject var deck: RequestDeck
  let request: PendingRequest
  let store: SessionStore
  let accent: Color

  @FocusState private var focused: RequestDeck.Focus?

  private var session: Session? { store.sessions[request.sessionID] }

  private var answering: Bool { deck.phase == .asking }

  /// Tudo à esquerda: com contexto, ou pergunta média ou longa.
  private var leading: Bool { deck.leading(request) }

  /// A frase do resultado, quando há.
  private var phrase: String? {
    switch deck.phase {
    case .asking: return nil
    case .answered(let text): return text
    case .resolved(let outcome): return CardText.outcome(outcome, sessionHost: session?.host, request: request)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      switch request.kind {
      case .permission(let ask): permission(ask)
      case .questions(let ask): questions(ask)
      }
    }
    .padding(.bottom, 4)
    .frame(maxWidth: .infinity)
    .allowsHitTesting(answering)
    .onChange(of: deck.focus) { _, request in
      guard let request else { return }
      if request.target == nil {
        focused = nil
        return
      }
      // No giro seguinte: o campo pode ter acabado de aparecer.
      DispatchQueue.main.async { focused = request.target }
    }
    .onChange(of: focused) { _, target in
      // Entrar no campo do "Outra…" já marca a linha.
      if case .other(let question)? = target { deck.ensureOther(for: request.id, question: question) }
    }
  }

  private func title(_ text: String) -> some View {
    Text(verbatim: text)
      .font(.system(size: 19, weight: .bold))
      .kerning(-0.2)
      .foregroundStyle(Color(white: 0.96))
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 8)
      .padding(.bottom, 4)
      .padding(.horizontal, 18)
  }

  /// O texto embaixo do título; com o resultado, a frase dele.
  @ViewBuilder
  private func subtitle(_ text: String?) -> some View {
    if let line = phrase ?? text {
      Text(verbatim: line)
        .font(.system(size: 12.5))
        .foregroundStyle(Color.white.opacity(0.55))
        .multilineTextAlignment(leading ? .leading : .center)
        .lineSpacing(2.5)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
        .padding(.horizontal, leading ? 18 : 22)
        .id(phrase == nil ? "text" : "phrase")
        .transition(.opacity)
    }
  }

  // MARK: Permissão

  private func permission(_ ask: PermissionAsk) -> some View {
    let explaining = deck.drafts[request.id]?.explaining ?? false
    return VStack(spacing: 0) {
      let fileChange = FileChange(toolName: ask.toolName, toolInput: ask.toolInput)
      title(CardText.title(ask))
      subtitle(ask.summary ?? fileChange.map { CardText.shortPath($0.path) })
      if ask.risky {
        HStack(spacing: 5) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .semibold))
          Text(verbatim: L10n.string("card.risky"))
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Palette.needsYou)
        .padding(.top, 8)
      }
      if let fileChange {
        // O que vai mudar no arquivo, inteiro: acima de 180 pt rola dentro da caixa.
        CommandBox(text: Text(CardText.change(fileChange)), maxHeight: 180)
          .padding(.top, 10)
          .padding(.horizontal, 14)
      } else if let content = CardText.content(ask) {
        // Inteiro, nunca cortado: acima de 120 pt rola dentro da caixa.
        CommandBox(text: ask.toolName == "Bash" ? Text(CardText.command(content)) : Text(verbatim: content))
          .padding(.top, 10)
          .padding(.horizontal, 14)
      }
      if explaining {
        CardTextField(
          placeholder: L10n.string("card.why.placeholder"),
          text: Binding(get: { deck.drafts[request.id]?.why ?? "" }, set: { [id = request.id] in deck.setWhy($0, for: id) }),
          multiline: true,
          focused: focused == .why,
          accent: accent)
          .focused($focused, equals: .why)
          .padding(.top, 10)
          .padding(.horizontal, 14)
          .transition(.opacity)
      }
    }
  }

  // MARK: Pergunta

  @ViewBuilder
  private func questions(_ ask: QuestionAsk) -> some View {
    let draft = deck.drafts[request.id]
    let index = min(draft?.question ?? 0, ask.questions.count - 1)
    let question = ask.questions[index]
    let picked = draft?.picked[safe: index] ?? []
    let otherPicked = draft?.otherPicked[safe: index] ?? false
    VStack(spacing: 0) {
      if let context = deck.contexts[request.id] {
        ContextBox(blocks: context, open: draft?.contextOpen ?? false, accent: accent) { deck.toggleContext() }
          .padding(.top, 10)
          .padding(.horizontal, 14)
          .transition(.opacity)
      }
      questionTitle(question.text, open: draft?.questionOpen ?? false)
      subtitle(Self.subtitle(question))
      VStack(spacing: 5) {
        ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in
          Button { deck.pick(i) } label: {
            OptionLabel(option: option, multi: question.multiSelect, selected: picked.contains(i), accent: accent)
          }
          .buttonStyle(OptionStyle(selected: picked.contains(i), accent: accent))
        }
        otherRow(index: index, multi: question.multiSelect, selected: otherPicked)
      }
      .padding(.top, 12)
      .padding(.horizontal, 14)
    }
    // Cada pergunta é outra view: campo e foco de uma nunca passam para a seguinte.
    .id(index)
  }

  /// A pergunta no tamanho do texto: curta 19 pt (centralizada sem contexto), média 15,5 pt, longa
  /// 14 pt cortada em 4 linhas com "ver pergunta inteira".
  @ViewBuilder
  private func questionTitle(_ text: String, open: Bool) -> some View {
    switch QuestionSize(text) {
    case .short:
      Text(verbatim: text)
        .font(.system(size: 19, weight: .bold))
        .kerning(-0.2)
        .lineSpacing(1)
        .foregroundStyle(Color(white: 0.96))
        .multilineTextAlignment(leading ? .leading : .center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.horizontal, 18)
    case .medium:
      questionText(text, size: 15.5, spacing: 2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .padding(.horizontal, 18)
    case .long:
      LineClamp(open: open) {
        questionText(text, size: 14, spacing: 2.6)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityHidden(!open)
        questionText(text, size: 14, spacing: 2.6)
          .lineLimit(4)
          .accessibilityHidden(open)
        Button { deck.toggleQuestion() } label: {
          Text(verbatim: L10n.string(open ? "card.question.less" : "card.question.more"))
        }
        .buttonStyle(AccentLinkStyle(accent: accent))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 8)
      .padding(.bottom, 4)
      .padding(.horizontal, 18)
    }
  }

  private func questionText(_ text: String, size: CGFloat, spacing: CGFloat) -> some View {
    Text(verbatim: text)
      .font(.system(size: size, weight: .semibold))
      .kerning(-0.2)
      .lineSpacing(spacing)
      .foregroundStyle(Color(white: 0.96))
      .multilineTextAlignment(.leading)
  }

  /// O cabeçalho curto da pergunta e, na múltipla, "Escolha quantas quiser."
  private static func subtitle(_ question: QuestionAsk.Question) -> String? {
    var parts: [String] = []
    if let header = question.header, !header.isEmpty { parts.append(header) }
    if question.multiSelect { parts.append(L10n.string("card.question.many")) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// "Outra resposta…": a última linha, com o campo de texto no lugar do nome.
  private func otherRow(index: Int, multi: Bool, selected: Bool) -> some View {
    OtherRow(multi: multi, selected: selected, accent: accent, onPick: { deck.pickOther() }) {
      CardTextField(
        placeholder: L10n.string("card.question.other"),
        text: Binding(get: { deck.drafts[request.id]?.other[safe: index] ?? "" }, set: { [id = request.id] in deck.setOther($0, for: id, question: index) }),
        multiline: false,
        focused: focused == .other(index),
        accent: accent,
        bare: true)
        .focused($focused, equals: .other(index))
    }
  }
}

/// O pé do cartão, fixo embaixo do painel enquanto o miolo rola: as ações (Negar/Permitir e os
/// links, ou o botão principal da pergunta) e "ou abrir no <app>". Com o resultado, somem.
struct RequestCardFooter: View {
  @ObservedObject var deck: RequestDeck
  let request: PendingRequest
  let store: SessionStore
  let accent: Color

  private var answering: Bool { deck.phase == .asking }

  var body: some View {
    VStack(spacing: 0) {
      switch request.kind {
      case .permission(let ask): permission(ask)
      case .questions(let ask): question(ask)
      }
      openInOrigin
    }
    .padding(.top, 12)
    .padding(.bottom, 14)
    .frame(maxWidth: .infinity)
    .allowsHitTesting(answering)
  }

  private func permission(_ ask: PermissionAsk) -> some View {
    let explaining = deck.drafts[request.id]?.explaining ?? false
    return VStack(spacing: 0) {
      HStack(spacing: 8) {
        Button { deck.deny() } label: {
          Text(verbatim: L10n.string(explaining ? "card.denySend" : "card.deny"))
        }
        .buttonStyle(CapsuleButtonStyle(primary: false, accent: accent))
        Button { deck.allow() } label: {
          Text(verbatim: L10n.string("card.allow"))
        }
        .buttonStyle(CapsuleButtonStyle(primary: true, accent: accent))
      }
      .padding(.horizontal, 14)
      HStack {
        Button { deck.explain() } label: { Text(verbatim: L10n.string("card.denyExplain")) }
          .buttonStyle(LinkStyle(rest: 0.5))
        Spacer(minLength: 8)
        if ask.alwaysAllow != nil {
          Button { deck.allowAlways() } label: { Text(verbatim: L10n.string("card.alwaysAllow")) }
            .buttonStyle(LinkStyle(rest: 0.5))
        }
      }
      .font(.system(size: 11.5))
      .padding(.top, 11)
      .padding(.horizontal, 22)
    }
    .opacity(answering ? 1 : 0)
  }

  private func question(_ ask: QuestionAsk) -> some View {
    let index = min(deck.drafts[request.id]?.question ?? 0, ask.questions.count - 1)
    return Button { deck.confirm() } label: { Text(verbatim: primaryLabel(ask.questions[index])) }
      .buttonStyle(CapsuleButtonStyle(primary: true, accent: accent))
      .disabled(!deck.canConfirmQuestion)
      .padding(.horizontal, 14)
      .opacity(answering ? 1 : 0)
  }

  private func primaryLabel(_ question: QuestionAsk.Question) -> String {
    if !deck.isLastQuestion { return L10n.string("card.question.next") }
    guard question.multiSelect else { return L10n.string("card.question.answer") }
    let count = deck.choiceCount
    return count > 0 ? L10n.string("card.question.sendCount", count) : L10n.string("card.question.send")
  }

  private var openInOrigin: some View {
    HStack(spacing: 0) {
      Text(verbatim: L10n.string("card.openIn.prefix") + " ")
        .foregroundStyle(Color.white.opacity(0.4))
      Button { deck.openInOrigin() } label: { Text(verbatim: CardText.openIn(store.sessions[request.sessionID]?.host)) }
        .buttonStyle(LinkStyle(rest: 0.6))
    }
    .font(.system(size: 11))
    .frame(maxWidth: .infinity, alignment: deck.leading(request) ? .leading : .center)
    .padding(.horizontal, 18)
    .padding(.top, 10)
    .opacity(answering ? 1 : 0)
  }
}

// MARK: - Texto longo

/// "◆ Claude, antes de perguntar": a última mensagem do Claude antes da pergunta, em 12,5 pt,
/// recolhida em 4 linhas com degradê e "Ler tudo ↓" (`.ctx` do protótipo).
private struct ContextBox: View {
  let blocks: [QuestionContext.Block]
  let open: Bool
  let accent: Color
  let toggle: () -> Void

  /// 12,5 pt com 1,5 de entrelinha; recolhido mostra 4 linhas.
  nonisolated static let lineHeight: CGFloat = 12.5 * 1.5
  nonisolated static let collapsed = lineHeight * 4

  /// Mais de um bloco, ou um parágrafo com mais de ~3 linhas de 46 caracteres.
  private var mayOverflow: Bool {
    guard blocks.count == 1, case .paragraph(let text) = blocks[0] else { return true }
    return text.count > 140 || text.contains("\n")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 5) {
        Text(verbatim: "◆").font(.system(size: 8))
        Text(verbatim: L10n.string("card.context.who"))
      }
      .font(.system(size: 10.5))
      .foregroundStyle(Color.white.opacity(0.4))
      .padding(.bottom, 4)
      .accessibilityElement(children: .combine)
      FadeClamp(open: open, collapsed: Self.collapsed) {
        ContextText(blocks: blocks)
          .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
          .clipped()
        // `mask: linear-gradient(#000 55%, transparent)`: apaga o fim do texto recolhido.
        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
          .blendMode(.destinationOut)
          .allowsHitTesting(false)
        // Um parágrafo curto nunca passa de 4 linhas: sem link escondido (nem para o VoiceOver).
        if mayOverflow {
          Button(action: toggle) {
            Text(verbatim: L10n.string(open ? "card.context.less" : "card.context.more"))
          }
          .buttonStyle(AccentLinkStyle(accent: accent))
        }
      }
      .compositingGroup()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    .background {
      let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
      shape.fill(Color.white.opacity(0.035))
        .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
    }
  }
}

/// O texto do Claude em Markdown básico: parágrafos, títulos, listas (com recuo) e código em mono.
private struct ContextText: View {
  let blocks: [QuestionContext.Block]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(Self.groups(blocks).enumerated()), id: \.offset) { _, group in
        if group.count == 1, !Self.isItem(group[0]) {
          block(group[0])
        } else {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(group.enumerated()), id: \.offset) { _, item in block(item) }
          }
        }
      }
    }
    .font(.system(size: 12.5))
    .foregroundStyle(Color.white.opacity(0.72))
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Itens de lista seguidos ficam juntos (2 pt entre eles); o resto, um por grupo (6 pt).
  private static func groups(_ blocks: [QuestionContext.Block]) -> [[QuestionContext.Block]] {
    var groups: [[QuestionContext.Block]] = []
    for block in blocks {
      if isItem(block), let last = groups.last?.last, isItem(last) {
        groups[groups.count - 1].append(block)
      } else {
        groups.append([block])
      }
    }
    return groups
  }

  private static func isItem(_ block: QuestionContext.Block) -> Bool {
    switch block {
    case .bullet, .numbered: return true
    default: return false
    }
  }

  @ViewBuilder
  private func block(_ block: QuestionContext.Block) -> some View {
    switch block {
    case .paragraph(let text):
      line(Self.inline(text))
    case .heading(let text):
      line(Self.inline(text, bold: true))
    case .bullet(let level, let text):
      item("•", text, level: level)
    case .numbered(let level, let marker, let text):
      item(marker, text, level: level)
    case .code(let code):
      Text(verbatim: code)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color(white: 0.92))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
    }
  }

  private func line(_ text: AttributedString) -> some View {
    Text(text)
      .lineSpacing(ContextBox.lineHeight - 14.9)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// `ul { padding-left: 16px }`: o marcador no recuo, o texto alinhado depois dele.
  private func item(_ marker: String, _ text: String, level: Int) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Text(verbatim: marker)
        .monospacedDigit()
        .foregroundStyle(Color.white.opacity(0.45))
      line(Self.inline(text))
    }
    .padding(.leading, 4 + CGFloat(level) * 14)
  }

  /// Markdown de linha: negrito em branco, código em mono com fundo, itálico. Links ficam só como
  /// texto sublinhado: nada abre sozinho.
  static func inline(_ text: String, bold: Bool = false) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    var string = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    if bold {
      string.swiftUI.font = .system(size: 12.5, weight: .semibold)
      string.swiftUI.foregroundColor = Color.white
    }
    let runs = string.runs.map { ($0.range, $0.inlinePresentationIntent ?? [], $0.link != nil) }
    for (range, intent, link) in runs {
      if intent.contains(.code) {
        string[range].swiftUI.font = .system(size: 11.5, design: .monospaced)
        string[range].swiftUI.foregroundColor = Color.white
        string[range].swiftUI.backgroundColor = Color.white.opacity(0.08)
      } else if intent.contains(.stronglyEmphasized) {
        string[range].swiftUI.font = .system(size: 12.5, weight: .semibold)
        string[range].swiftUI.foregroundColor = Color.white
      } else if intent.contains(.emphasized) {
        string[range].swiftUI.font = .system(size: 12.5).italic()
      }
      if link {
        string[range].link = nil
        string[range].swiftUI.underlineStyle = .single
      }
    }
    return string
  }
}

/// O contexto recolhido: mede o texto inteiro e, se passa de `collapsed`, mostra só `collapsed` com
/// o degradê no fim e o link embaixo; aberto, o texto inteiro e o link. Texto curto: só o texto.
/// Subviews: o texto (que se corta na altura dada), o degradê e o link (ausente num texto que nunca
/// passa de 4 linhas). Numa passada só, sem estado: funciona igual na tela e nos renders.
private struct FadeClamp: Layout {
  let open: Bool
  let collapsed: CGFloat
  /// O degradê cobre os últimos 45% do texto recolhido.
  private static let fadeShare: CGFloat = 0.45
  private static let gap: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count >= 2 else { return .zero }
    let m = measure(proposal.width, subviews)
    return CGSize(width: m.width, height: m.visible + (m.overflows ? Self.gap + m.toggle.height : 0))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count >= 2 else { return }
    let m = measure(bounds.width, subviews)
    subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: m.visible))
    let fade = m.overflows && !open ? collapsed * Self.fadeShare : 0
    subviews[1].place(
      at: CGPoint(x: bounds.minX, y: bounds.minY + m.visible - fade),
      proposal: ProposedViewSize(width: bounds.width, height: fade))
    guard subviews.count == 3 else { return }
    // Sem o que esconder, o link fica fora do cartão (recortado).
    let y = m.overflows ? bounds.minY + m.visible + Self.gap : bounds.minY - 10_000
    subviews[2].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(m.toggle))
  }

  /// Sem o link (texto curto), nunca corta.
  private func measure(_ width: CGFloat?, _ subviews: Subviews) -> (width: CGFloat, visible: CGFloat, overflows: Bool, toggle: CGSize) {
    let full = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
    // Meia linha de folga: 4 linhas cheias cabem sem degradê.
    let overflows = subviews.count == 3 && full.height > collapsed + ContextBox.lineHeight / 2
    let visible = overflows && !open ? collapsed : full.height
    let toggle = subviews.count == 3 ? subviews[2].sizeThatFits(.unspecified) : .zero
    return (width ?? full.width, visible, overflows, toggle)
  }
}

/// A pergunta longa: até 4 linhas com "ver pergunta inteira"; aberta, inteira com "mostrar menos".
/// Subviews: o texto inteiro, o cortado em 4 linhas e o link. Se o inteiro cabe nas 4 linhas, não
/// há link. A cópia que não aparece fica fora do cartão.
private struct LineClamp: Layout {
  let open: Bool
  private static let gap: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 3 else { return .zero }
    let m = measure(proposal.width, subviews)
    return CGSize(width: m.width, height: m.shown + (m.overflows ? Self.gap + m.toggle.height : 0))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 3 else { return }
    let m = measure(bounds.width, subviews)
    let away = CGPoint(x: bounds.minX, y: bounds.minY - 10_000)
    let width = ProposedViewSize(width: bounds.width, height: nil)
    let showFull = open || !m.overflows
    subviews[0].place(at: showFull ? bounds.origin : away, proposal: width)
    subviews[1].place(at: showFull ? away : bounds.origin, proposal: width)
    subviews[2].place(
      at: m.overflows ? CGPoint(x: bounds.minX, y: bounds.minY + m.shown + Self.gap) : away,
      proposal: ProposedViewSize(m.toggle))
  }

  private func measure(_ width: CGFloat?, _ subviews: Subviews) -> (width: CGFloat, shown: CGFloat, overflows: Bool, toggle: CGSize) {
    let proposal = ProposedViewSize(width: width, height: nil)
    let full = subviews[0].sizeThatFits(proposal)
    let short = subviews[1].sizeThatFits(proposal)
    let overflows = full.height > short.height + 1
    return (width ?? full.width, open || !overflows ? full.height : short.height, overflows, subviews[2].sizeThatFits(.unspecified))
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Tracinhos e fila

/// Um tracinho por pedido da leva: o atual na cor do painel e mais largo, os resolvidos verdes.
struct RequestPager: View {
  @ObservedObject var deck: RequestDeck
  let accent: Color

  var body: some View {
    HStack(spacing: 4) {
      ForEach(deck.batch, id: \.self) { id in
        let dash = deck.dash(id)
        Capsule()
          .fill(dash == .current ? accent : dash == .done ? Palette.done.opacity(0.8) : Color.white.opacity(0.16))
          .frame(width: dash == .current ? 28 : 18, height: 3)
      }
    }
    .frame(height: 3)
    .animation(.easeInOut(duration: 0.4), value: deck.batch.map { deck.dash($0) })
    .accessibilityElement()
    .accessibilityLabel(Text(verbatim: L10n.string(
      "card.pager", (deck.batch.firstIndex { deck.dash($0) == .current } ?? 0) + 1, deck.batch.count)))
  }
}

/// "Na fila": os outros pedidos esperando (projeto, tipo, quando); clicar abre aquele.
struct RequestQueueList: View {
  @ObservedObject var deck: RequestDeck
  let store: SessionStore
  let now: Date

  /// Linhas à vista; o resto vira "+N na fila" (a fila fica fixa no pé e não pode tomar o miolo).
  static let maxRows = 3

  var body: some View {
    let waiting = deck.waiting
    if !waiting.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        Text(verbatim: L10n.string("card.queue").uppercased())
          .font(.system(size: 10, weight: .semibold))
          .kerning(0.5)
          .foregroundStyle(Color.white.opacity(0.35))
          .padding(EdgeInsets(top: 2, leading: 6, bottom: 6, trailing: 6))
        ForEach(waiting.prefix(Self.maxRows)) { request in
          Button { deck.select(request.id) } label: {
            HStack(spacing: 8) {
              let name = store.displayName(for: request.sessionID)
              Text(verbatim: name.isEmpty ? "Claude" : name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.needsYou))
              Text(verbatim: CardText.kind(request))
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
              Text(verbatim: CardText.ago(request.receivedAt, now: now))
                .font(.system(size: 10.5))
                .foregroundStyle(Color.white.opacity(0.3))
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
          }
          .buttonStyle(QueueRowStyle())
        }
        if waiting.count > Self.maxRows {
          // Abre o primeiro dos que não aparecem.
          Button { deck.select(waiting[Self.maxRows].id) } label: {
            Text(verbatim: L10n.string("card.queue.more", waiting.count - Self.maxRows))
              .font(.system(size: 12))
              .foregroundStyle(Color.white.opacity(0.45))
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.vertical, 7)
              .padding(.horizontal, 8)
          }
          .buttonStyle(QueueRowStyle())
        }
      }
      .padding(EdgeInsets(top: 8, leading: 10, bottom: 10, trailing: 10))
      .overlay(alignment: .top) {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
      }
    }
  }
}

// MARK: - Peças

/// Nome da opção (com "RECOMENDADO") e a descrição por inteiro.
private struct OptionLabel: View {
  let option: QuestionAsk.Option
  let multi: Bool
  let selected: Bool
  let accent: Color

  var body: some View {
    HStack(spacing: 10) {
      OptionMark(multi: multi, selected: selected, accent: accent)
      VStack(alignment: .leading, spacing: 0) {
        // `.lr { flex-direction: column-reverse; gap: 2px }`: "RECOMENDADO" numa linha própria, acima do nome.
        VStack(alignment: .leading, spacing: 2) {
          if option.recommended {
            Text(verbatim: L10n.string("card.question.recommended"))
              .font(.system(size: 9, weight: .bold))
              .kerning(0.4)
              .foregroundStyle(accent)
          }
          Text(verbatim: option.label)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color(white: 0.96))
            .fixedSize(horizontal: false, vertical: true)
        }
        if let detail = option.detail, !detail.isEmpty {
          Text(verbatim: detail)
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .multilineTextAlignment(.leading)
    }
    .padding(.vertical, 9)
    .padding(.leading, 12)
    .padding(.trailing, 10)
  }
}

/// Bolinha (única) ou caixa (múltipla) de 17 pt: enche na cor do painel; o miolo preto cresce com
/// mola na única, o check se desenha na múltipla.
private struct OptionMark: View {
  let multi: Bool
  let selected: Bool
  let accent: Color

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: multi ? 5 : 8.5, style: .continuous)
    ZStack {
      shape.fill(selected ? accent : Color.clear)
      shape.strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5).opacity(selected ? 0 : 1)
      if multi {
        CheckMarkShape()
          .trim(from: 0, to: selected ? 1 : 0)
          .stroke(Color.black, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
          .opacity(selected ? 1 : 0)
          .animation(.easeOut(duration: 0.3), value: selected)
      } else {
        Circle()
          .fill(Color.black)
          .frame(width: 6, height: 6)
          .scaleEffect(selected ? 1 : 0.001)
          .animation(.timingCurve(0.3, 1.7, 0.5, 1, duration: 0.25), value: selected)
      }
    }
    .frame(width: 17, height: 17)
    .animation(.easeInOut(duration: 0.2), value: selected)
    .accessibilityHidden(true)
  }
}

/// A linha do "Outra…": a marca e a folga em volta do campo marcam; o clique no campo só põe o
/// foco (e o foco marca). Mesmo fundo e hover das outras opções.
private struct OtherRow<Field: View>: View {
  let multi: Bool
  let selected: Bool
  let accent: Color
  let onPick: () -> Void
  @ViewBuilder let field: () -> Field
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      OptionMark(multi: multi, selected: selected, accent: accent)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPick)
      field()
    }
    .padding(.vertical, 9)
    .padding(.leading, 12)
    .padding(.trailing, 10)
    .frame(minHeight: 36)
    .background {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.001))
        .onTapGesture(perform: onPick)
    }
    .modifier(OptionBackground(selected: selected, accent: accent, hovering: hovering))
    .onHover { hovering = $0 }
  }
}

/// O conteúdo do pedido em mono (`.cmd` do protótipo), inteiro: até `maxHeight` a caixa abraça o texto;
/// acima disso fica com `maxHeight` e rola, com a barra de rolagem à vista.
private struct CommandBox: View {
  let text: Text
  var maxHeight: CGFloat = 120
  @Environment(\.glassFallback) private var offscreen

  var body: some View {
    let styled = text
      .font(.system(size: 11.5, design: .monospaced))
      .foregroundStyle(Color(white: 0.96))
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
    CappedHeight(max: maxHeight) {
      // Só mede: a altura do texto inteiro na largura disponível.
      styled.hidden()
      if offscreen {
        // O `ImageRenderer` não desenha a rolagem do AppKit: o começo do texto e uma barra no lugar.
        styled
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .overlay(alignment: .topTrailing) { OffscreenScroller(maxHeight: maxHeight) }
      } else {
        ScrollView(.vertical) {
          styled.frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
      }
    }
    // O recorte vale na caixa inteira (dentro do `Layout` o texto passaria da altura).
    .clipped()
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .background {
      let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
      shape.fill(Color.white.opacity(0.06))
        .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }
  }
}

/// Mede a primeira view (sem limite de altura) e fica com essa altura até `max`; a segunda ocupa o
/// espaço todo. Assim a caixa abraça um comando curto e para em `max` num longo, numa passada só.
private struct CappedHeight: Layout {
  let max: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let measure = subviews.first else { return .zero }
    let size = measure.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    return CGSize(width: size.width, height: min(size.height, max))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews {
      subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
  }
}

/// A barra de rolagem desenhada nos renders, só quando o texto passa da altura máxima.
private struct OffscreenScroller: View {
  let maxHeight: CGFloat

  var body: some View {
    GeometryReader { box in
      Capsule()
        .fill(Color.white.opacity(0.35))
        .frame(width: 3, height: box.size.height * 0.45)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .opacity(box.size.height >= maxHeight - 0.5 ? 1 : 0)
    }
  }
}

/// `M4.3 8.8 l2.8 2.7 l5.6 -5.9` numa caixa de 17 pt.
private struct CheckMarkShape: Shape {
  func path(in rect: CGRect) -> Path {
    let s = rect.width / 17
    var path = Path()
    path.move(to: CGPoint(x: 4.3 * s, y: 8.8 * s))
    path.addLine(to: CGPoint(x: 7.1 * s, y: 11.5 * s))
    path.addLine(to: CGPoint(x: 12.7 * s, y: 5.6 * s))
    return path
  }
}

/// Fundo da linha de opção: 4% de branco (7% no hover), na cor do painel quando marcada.
private struct OptionBackground: ViewModifier {
  let selected: Bool
  let accent: Color
  var hovering = false

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    content
      .background {
        shape.fill(selected ? accent.opacity(0.12) : Color.white.opacity(hovering ? 0.07 : 0.04))
          .overlay(shape.strokeBorder(
            selected ? accent.opacity(0.6) : Color.white.opacity(0.08), lineWidth: selected ? 1 : 0.5))
      }
      .animation(.easeOut(duration: 0.15), value: hovering)
      .animation(.easeOut(duration: 0.2), value: selected)
  }
}

private struct OptionStyle: ButtonStyle {
  let selected: Bool
  let accent: Color

  func makeBody(configuration: Configuration) -> some View {
    Styled(configuration: configuration, selected: selected, accent: accent)
  }

  struct Styled: View {
    let configuration: Configuration
    let selected: Bool
    let accent: Color
    @State private var hovering = false

    var body: some View {
      configuration.label
        .modifier(OptionBackground(selected: selected, accent: accent, hovering: hovering))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(configuration.isPressed ? 0.985 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        .onHover { hovering = $0 }
    }
  }
}

/// Cápsula de 44 pt (`.b` do protótipo). Principal: brilho radial da cor do painel vindo de baixo,
/// contorno na mesma cor que acende no hover. Neutro: vidro claro.
struct CapsuleButtonStyle: ButtonStyle {
  let primary: Bool
  let accent: Color

  func makeBody(configuration: Configuration) -> some View {
    Styled(configuration: configuration, primary: primary, accent: accent)
  }

  struct Styled: View {
    let configuration: Configuration
    let primary: Bool
    let accent: Color
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
      let hot = hovering && enabled
      configuration.label
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.white)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background {
          if primary {
            CapsuleGlow(color: accent).clipShape(Capsule())
          } else {
            Capsule().fill(Color.white.opacity(hot ? 0.1 : 0.06))
          }
        }
        .overlay {
          Capsule().strokeBorder(
            primary ? accent.opacity(hot ? 0.7 : 0.32) : Color.white.opacity(0.14),
            lineWidth: primary ? 1 : 0.5)
        }
        // O fio claro de cima (`inset 0 1px 0`).
        .overlay {
          Capsule().strokeBorder(
            LinearGradient(
              stops: [
                .init(color: Color.white.opacity(primary ? (hot ? 0.25 : 0.14) : 0.08), location: 0),
                .init(color: Color.white.opacity(0), location: 0.12),
              ],
              startPoint: .top, endPoint: .bottom),
            lineWidth: 1)
        }
        .shadow(color: primary ? accent.opacity(hot ? 0.35 : 0.1) : .clear, radius: hot ? 16 : 10, y: hot ? 10 : 6)
        .contentShape(Capsule())
        .opacity(enabled ? 1 : 0.4)
        .scaleEffect(configuration.isPressed && enabled ? 0.96 : 1)
        .animation(.timingCurve(0.3, 1.6, 0.5, 1, duration: 0.15), value: configuration.isPressed)
        .animation(.easeOut(duration: 0.25), value: hot)
        .animation(.easeOut(duration: 0.2), value: enabled)
        .onHover { hovering = $0 }
    }
  }
}

/// `radial-gradient(130% 150% at 50% 135%, c .5 0%, c .2 45%, branco .04 85%)`: uma elipse com
/// centro abaixo do botão e raios de 130% da largura e 150% da altura.
private struct CapsuleGlow: View {
  let color: Color

  var body: some View {
    Canvas { gc, size in
      let ry = size.height * 1.5
      let rx = size.width * 1.3
      gc.translateBy(x: size.width / 2, y: size.height * 1.35)
      gc.scaleBy(x: rx / ry, y: 1)
      let gradient = Gradient(stops: [
        .init(color: color.opacity(0.5), location: 0),
        .init(color: color.opacity(0.2), location: 0.45),
        .init(color: Color.white.opacity(0.04), location: 0.85),
      ])
      let big = CGRect(x: -4 * ry, y: -4 * ry, width: 8 * ry, height: 8 * ry)
      gc.fill(Path(big), with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: ry))
    }
  }
}

/// Link do cartão: branco a `rest`, branco cheio no hover.
private struct LinkStyle: ButtonStyle {
  let rest: Double

  func makeBody(configuration: Configuration) -> some View {
    Styled(configuration: configuration, rest: rest)
  }

  struct Styled: View {
    let configuration: Configuration
    let rest: Double
    @State private var hovering = false

    var body: some View {
      configuration.label
        .foregroundStyle(Color.white.opacity(hovering || configuration.isPressed ? 1 : rest))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
  }
}

/// "Ler tudo", "ver pergunta inteira": 11,5 pt na cor do painel, sublinhado no hover.
private struct AccentLinkStyle: ButtonStyle {
  let accent: Color

  func makeBody(configuration: Configuration) -> some View {
    Styled(configuration: configuration, accent: accent)
  }

  struct Styled: View {
    let configuration: Configuration
    let accent: Color
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.system(size: 11.5))
        .foregroundStyle(accent.opacity(configuration.isPressed ? 0.7 : 0.95))
        .underline(hovering)
        .fixedSize()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
  }
}

private struct QueueRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Styled(configuration: configuration)
  }

  struct Styled: View {
    let configuration: Configuration
    @State private var hovering = false

    var body: some View {
      let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
      configuration.label
        .background(shape.fill(Color.white.opacity(hovering ? 0.06 : 0)))
        .contentShape(shape)
        .scaleEffect(configuration.isPressed ? 0.985 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
  }
}

/// Campo de texto do cartão (explicação do "Negar" e "Outra resposta…"). Fora da tela (renders), um
/// `Text` no lugar: o `ImageRenderer` não desenha o campo do AppKit.
private struct CardTextField: View {
  let placeholder: String
  @Binding var text: String
  let multiline: Bool
  let focused: Bool
  let accent: Color
  /// Sem caixa própria: dentro da linha do "Outra…".
  var bare = false
  @Environment(\.glassFallback) private var offscreen

  var body: some View {
    field
      .font(.system(size: 12.5))
      .foregroundStyle(Color.white)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, bare ? 0 : 9)
      .padding(.horizontal, bare ? 0 : 11)
      .background {
        if !bare {
          let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
          shape.fill(Color.black.opacity(0.3))
            .overlay(shape.strokeBorder(
              focused ? accent.opacity(0.8) : Color.white.opacity(0.12), lineWidth: focused ? 1 : 0.5))
            .background(shape.inset(by: -3).stroke(accent.opacity(focused ? 0.15 : 0), lineWidth: 3))
            .animation(.easeOut(duration: 0.2), value: focused)
        }
      }
  }

  @ViewBuilder
  private var field: some View {
    if offscreen {
      Text(verbatim: text.isEmpty ? placeholder : text)
        .foregroundStyle(Color.white.opacity(text.isEmpty ? 0.4 : 1))
        .lineLimit(multiline ? 4 : 1)
        .frame(minHeight: multiline ? 34 : nil, alignment: .topLeading)
    } else if multiline {
      TextField(text: $text, prompt: Text(verbatim: placeholder), axis: .vertical) { EmptyView() }
        .textFieldStyle(.plain)
        .lineLimit(2...4)
    } else {
      TextField(text: $text, prompt: Text(verbatim: placeholder)) { EmptyView() }
        .textFieldStyle(.plain)
    }
  }
}
