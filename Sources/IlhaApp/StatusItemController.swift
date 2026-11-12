import AppKit
import IlhaCore
import Combine
import SwiftUI

/// Item de largura variável na barra de menu cujo botão hospeda a `IslandView`. Passar o mouse faz
/// a ilha crescer até a espiada; clicar (na ilha ou na espiada) até o painel de sessões; clique
/// direito (ou com Control) abre o menu com "Configurações…" e "Sair da Work Island". O crescer é
/// da `IslandWindow`; aqui fica quando abrir e fechar.
@MainActor
final class StatusItemController: NSObject {
  private let model: AppModel
  private let usage: UsageController
  private let update: UpdateController
  private let metrics: MetricsController
  private let settings: SettingsStore
  /// Quando o cartão saiu do repouso (para o `cartao_fechado`); `nil` em repouso.
  private var cardOpenedAt: Date?
  private let statusItem: NSStatusItem
  private let hostingView: IslandHostingView
  private var resizeScheduled = false
  /// Segunda medida, depois que a mola das etiquetas assenta.
  private var settleResize: DispatchWorkItem?
  /// Último tamanho aplicado ao item: invalidações que não mudam a largura não refazem nada.
  private var lastSize: NSSize?
  /// Sessões e uso mudaram: a ilha remede (o aviso de tamanho do `NSHostingView` nem sempre vem).
  private var contentChanges: [AnyCancellable] = []

  private var island: IslandWindow!
  /// 160 ms com o mouse na ilha antes da espiada.
  private var peekPending: DispatchWorkItem?
  /// 120 ms de folga depois de o mouse sair da ilha e da espiada, antes de fechar.
  private var leavePending: DispatchWorkItem?
  private var clickMonitors: [Any] = []
  /// Só com a espiada aberta: mouse andando fora do app. Garante o fechar mesmo se a área de rastreio
  /// do cartão não tiver visto a entrada (a janela nasce embaixo de um cursor parado).
  private var moveMonitor: Any?
  /// Só com o cartão na tela: a janela do item andou na barra (outro item mudou de largura).
  private var barWindowObserver: NSObjectProtocol?

  /// O que já virou aviso: uma vez por novidade.
  private var noticeGate = NoticeGate()
  /// Novidades esperando o 1 s antes de avisar, uma por sessão.
  private var noticeCandidates: [String: NoticeCandidate] = [:]
  /// App que vem para a frente: tira do aviso os "concluído" daquele app (você foi ver).
  private var activationObserver: NSObjectProtocol?
  /// Prazo de 10 s dos "concluído" que entraram no aviso com o app de origem já na frente (o "veio
  /// para a frente" não chegaria), por sessão. As outras linhas não têm prazo.
  private var frontDoneExpiries: [String: DispatchWorkItem] = [:]
  /// Estado de cada sessão na última mudança do `store`: quem volta a trabalhar libera novos avisos.
  private var noticeStates: [String: SessionState] = [:]
  /// Longe da tela (bloqueada, apagada ou outra sessão de usuário na frente): ninguém veria o aviso.
  private var screenLocked = false
  private var screensAsleep = false
  private var sessionInactive = false
  private var away: Bool { screenLocked || screensAsleep || sessionInactive }
  /// Avisos que chegaram longe da tela: descem juntos, 1 s depois da volta, os que ainda valem.
  private var heldNotices = NoticeBoard()
  private var returnWork: DispatchWorkItem?
  private var awayObservers: [NSObjectProtocol] = []
  /// `ILHA_DEBUG_AWAY`: o bloqueio é de mentira; a conferência com o sistema não o desfaz.
  private var simulatingLock = false
  private var storeSink: AnyCancellable?
  /// Última ilha medida na barra e a tela dela: com a barra escondida (app em tela cheia) a ilha não
  /// pode ser medida, e o aviso desce de onde ela estaria.
  private var lastIsland: (rect: NSRect, home: NSRect)?

  private lazy var contextMenu: NSMenu = {
    let menu = NSMenu()
    let settings = NSMenuItem(
      title: L10n.string("settings.menuItem"), action: #selector(settingsClicked(_:)), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: L10n.string("menu.quit"), action: #selector(quitClicked(_:)), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    return menu
  }()

  init(
    model: AppModel, usage: UsageController, settings: SettingsStore, plugin: PluginController,
    update: UpdateController, metrics: MetricsController
  ) {
    self.model = model
    self.usage = usage
    self.update = update
    self.metrics = metrics
    self.settings = settings
    // Primeira abertura: nasce junto do relógio, e não na ponta que o notch esconde.
    BarPlacement.seedIfNeeded(.standard)
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.autosaveName = BarPlacement.autosaveName
    hostingView = IslandHostingView(rootView: IslandView(model: model, usage: usage, update: update))

    super.init()

    island = IslandWindow(
      model: model, usage: usage, settings: settings, plugin: plugin, update: update, metrics: metrics
    ) { [weak self] in
      self?.islandRect()
    }
    island.onHover = { [weak self] inside in self?.cardHover(inside) }
    island.onPeekClick = { [weak self] in self?.openPanel() }
    island.onIslandClick = { [weak self] in self?.openPanel() }
    island.onCoverIsland = { [weak self] covered in self?.setIslandCovered(covered) }
    island.onIslandSecondaryClick = { [weak self] in self?.secondaryClick() }
    island.onCancel = { [weak self] in self?.present(.rest) }
    island.onSelectSession = { [weak self] id in self?.openSession(id) }
    island.onHandBack = { [weak self] id in self?.handBack(id) }
    island.onNoticeClick = { [weak self] in self?.noticeClicked() }
    island.onNoticeClose = { [weak self] in self?.noticeClosed() }
    model.onAttention = { [weak self] id, state in self?.noticeCandidate(id, state: state, requestID: nil) }
    storeSink = model.$store.sink { [weak self] store in
      MainActor.assumeIsolated { self?.storeChanged(store) }
    }

    // Pedido novo com o app de origem na frente: a pergunta some de lá enquanto a ilha a segura,
    // então o painel abre sozinho no cartão dele (para ninguém achar que a sessão travou). Sem virar
    // chave: o teclado continua no app em que você está.
    model.onRequestArrived = { [weak self] request, originFrontmost in
      guard originFrontmost else {
        self?.noticeCandidate(request.sessionID, state: .needsYou, requestID: request.id)
        return
      }
      // Essa abertura vale como o aviso deste pedido.
      self?.noticeShownElsewhere(request)
      let id = request.id
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, self.model.requests.pending.contains(where: { $0.id == id }) else { return }
          self.island.bringForward(id)
          self.present(.panel)
        }
      }
    }

    hostingView.onIntrinsicSizeChange = { [weak self] in self?.scheduleResize() }
    // O `invalidateIntrinsicContentSize` não chega quando as etiquetas mudam (a hospedagem fica fora
    // do Auto Layout, no botão da barra), e o item ficava com a largura antiga, cortando a ilha nas
    // duas pontas. O `objectWillChange` vem antes da mudança; o ajuste roda no giro seguinte.
    // A seta da versão nova também muda a largura (o progresso do download, não).
    let arrow = update.$announces.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
    for publisher in [model.objectWillChange.eraseToAnyPublisher(), usage.objectWillChange.eraseToAnyPublisher(), arrow] {
      contentChanges.append(publisher.sink { [weak self] _ in
        MainActor.assumeIsolated { self?.scheduleResize() }
      })
    }

    if let button = statusItem.button {
      button.title = ""
      button.image = nil
      button.setAccessibilityLabel("Work Island")
      button.addSubview(hostingView)
      button.target = self
      button.action = #selector(islandClicked(_:))
      button.sendAction(on: [.leftMouseDown, .rightMouseDown])
      button.addTrackingArea(NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self,
        userInfo: nil))
    }
    resize()
    scheduleDebugTour()
    scheduleDebugNotice()
    scheduleDebugNoticeClick()
    observeAway()
    observeActivation()
    scheduleDebugAway()
  }

  // MARK: - Ilha

  /// A cápsula na tela: o botão tem 3 pt de folga dos lados (para o brilho) e a altura da barra;
  /// a cápsula tem 18 pt, centrada nele. Com várias telas, é a cópia da barra onde o cartão está
  /// aberto (`pinnedScreen`) ou, em repouso, a cópia sob o mouse (`IslandAnchor`).
  /// Com o cartão fora e a barra escondida (app em tela cheia), vale a última ilha medida.
  private func islandRect() -> NSRect? {
    let screens = NSScreen.screens.map(\.frame)
    let measured = hostingView.window.map { window -> NSRect in
      let host = window.convertToScreen(hostingView.convert(hostingView.bounds, to: nil))
      let height: CGFloat = 18
      return NSRect(x: host.minX + 3, y: host.midY - height / 2, width: max(host.width - 6, height), height: height)
    }
    if let measured, let home = screens.first(where: { $0.intersects(measured) }) {
      lastIsland = (measured, home)
    } else if pinnedScreen == nil || !(lastIsland.map { screens.contains($0.home) } ?? false) {
      return measured
    }
    guard let (real, home) = lastIsland else { return measured }
    let target = pinnedScreen.flatMap { pinned in screens.contains(pinned) ? pinned : nil }
      ?? IslandAnchor.screen(for: real, mouse: NSEvent.mouseLocation, screens: screens)
      ?? home
    return IslandAnchor.mirrored(real, from: home, to: target)
  }

  /// Tela em que o cartão abriu: ele fica nela até voltar a ser a ilha, mesmo que a barra ativa (e a
  /// janela do item) troque de tela no meio.
  private var pinnedScreen: NSRect?

  /// Junta várias invalidações num ajuste só, fora do passe de layout em andamento. Com etiquetas
  /// entrando ou saindo na mola, a primeira medida pode sair no meio da animação, mais estreita que a
  /// final, e a ilha ficaria cortada nas pontas: mede de novo quando a mola assenta.
  private func scheduleResize() {
    settleResize?.cancel()
    let settle = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.resize() }
    }
    settleResize = settle
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: settle)
    guard !resizeScheduled else { return }
    resizeScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.resizeScheduled = false
        self?.resize()
      }
    }
  }

  /// Folga sobre a mola das etiquetas (resposta de 0,45 s) para ela assentar.
  private static let settleDelay: TimeInterval = 0.9

  /// A largura do item acompanha a largura ideal da ilha; a altura é a do botão da barra.
  private func resize() {
    let width = ceil(hostingView.fittingSize.width)
    let height = statusItem.button?.bounds.height ?? NSStatusBar.system.thickness
    let size = NSSize(width: width, height: height)
    guard size != lastSize else { return }
    lastSize = size
    if statusItem.length != width { statusItem.length = width }
    hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    // A ilha mudou de largura: o cartão volta a ficar centralizado nela no próximo giro (o item
    // ainda vai se reposicionar na barra).
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { self?.island.relayout() }
    }
  }

  /// O cartão cobre a ilha (da janela na frente até ela sair): o conteúdo da ilha some na hora, o
  /// brilho das etiquetas para, e o cartão segue a ilha se o item andar na barra.
  private func setIslandCovered(_ covered: Bool) {
    if !covered { pinnedScreen = nil }
    hostingView.alphaValue = covered ? 0 : 1
    hostingView.rootView = IslandView(model: model, usage: usage, update: update, covered: covered)
    if let barWindowObserver {
      NotificationCenter.default.removeObserver(barWindowObserver)
      self.barWindowObserver = nil
    }
    if covered, let barWindow = statusItem.button?.window {
      barWindowObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didMoveNotification, object: barWindow, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.island.relayout() }
      }
    }
  }

  // MARK: - Mouse

  // Nome Objective-C explícito: a área de rastreio chama `mouseEntered:`, e sem isso o Swift
  // gera `mouseEnteredWith:` (esta classe não é um NSResponder), que nunca é chamado.
  @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
    cancelLeave()
    armPeek()
  }

  @objc(mouseExited:) func mouseExited(with event: NSEvent) {
    // Ao abrir, o cartão cobre a ilha e ela "perde" o mouse: quem decide é a conferência atrasada.
    if island.stage == .rest { cancelPeek() }
    scheduleLeave()
  }

  /// O mouse no cartão. Voltar para o lugar da ilha enquanto ele ainda se recolhe arma a espiada de novo.
  /// No aviso, a espiada não arma (o aviso cobre a ilha).
  private func cardHover(_ inside: Bool) {
    if inside {
      cancelLeave()
      if island.stage == .rest, let rect = islandRect(), rect.contains(NSEvent.mouseLocation) { armPeek() }
    } else {
      if island.stage == .rest { cancelPeek() }
      scheduleLeave()
    }
  }

  private func armPeek() {
    guard island.stage == .rest else { return }
    peekPending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.peekPending = nil
        if self.island.stage == .rest { self.present(.peek) }
      }
    }
    peekPending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(160), execute: work)
  }

  private func cancelPeek() {
    peekPending?.cancel()
    peekPending = nil
  }

  private func cancelLeave() {
    leavePending?.cancel()
    leavePending = nil
  }

  /// Fora da ilha e da espiada por 120 ms: a espiada volta para a ilha. O painel não fecha com hover.
  /// Uma conferência por vez: mexer o mouse lá fora não adia o fechar.
  private func scheduleLeave() {
    guard island.stage == .peek, leavePending == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.leavePending = nil
        guard self.island.stage == .peek else { return }
        let mouse = NSEvent.mouseLocation
        let overIsland = self.islandRect()?.contains(mouse) ?? false
        if !overIsland && !self.island.contains(mouse) { self.present(.rest) }
      }
    }
    leavePending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
  }

  // MARK: - Cliques

  @objc private func islandClicked(_ sender: Any?) {
    if let event = NSApp.currentEvent,
       event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
      secondaryClick()
      return
    }
    openPanel()
  }

  /// Clique na ilha, na espiada (ou no lugar da ilha enquanto o cartão se recolhe): abre o painel já
  /// recebendo o teclado (↩, Esc, 1–9), sem ativar o app. Com ele aberto não fecha — como no
  /// protótipo; fecham clique fora, Esc e as linhas.
  private func openPanel() {
    if island.stage != .panel { present(.panel) }
    island.makeKey()
  }

  private func secondaryClick() {
    present(.rest)
    showContextMenu()
  }

  /// O menu só fica no item enquanto está aberto: sem ele, o clique esquerdo volta a ser da ilha.
  private func showContextMenu() {
    statusItem.menu = contextMenu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  /// "Configurações…": o mesmo cartão, já na tela de configurações, recebendo o teclado (Esc volta).
  @objc private func settingsClicked(_ sender: Any?) {
    island.openSettings()
    openPanel()
  }

  @objc private func quitClicked(_ sender: Any?) {
    NSApp.terminate(nil)
  }

  // MARK: - Estados

  private func present(_ stage: IslandWindow.Stage) {
    cancelPeek()
    cancelLeave()
    if stage != .notice || island.stage != .notice { cancelFrontDoneExpiries() }
    // Saindo do repouso (mesmo com o cartão ainda se recolhendo): prende na tela da ilha sob o mouse.
    // O aviso desce na tela do mouse, onde estiver; fora de todas, na tela da própria ilha.
    if stage != .rest, island.stage == .rest {
      pinnedScreen = nil
      if stage == .notice {
        _ = islandRect()
        pinnedScreen = IslandAnchor.screen(containing: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.frame))
          ?? lastIsland?.home
      } else if let rect = islandRect() {
        pinnedScreen = NSScreen.screens.first { $0.frame.intersects(rect) }?.frame
      }
    }
    let before = island.stage
    island.show(stage)
    recordCardChange(from: before, to: island.stage)
    if stage == .panel { installClickMonitors() } else { removeClickMonitors() }
    if stage == .peek { installMoveMonitor() } else { removeMoveMonitor() }
  }

  /// Métricas: saindo do repouso → `cartao_aberto` com o humor da esfera; de volta a ele →
  /// `cartao_fechado` com os segundos desde a abertura. Espiada → painel não conta de novo. O aviso
  /// conta como repouso: repouso ↔ aviso não registra nada, e aviso → painel abre o painel.
  private func recordCardChange(from before: IslandWindow.Stage, to after: IslandWindow.Stage) {
    let before = before == .notice ? .rest : before
    let after = after == .notice ? .rest : after
    let now = Date()
    if before == .rest, after != .rest {
      cardOpenedAt = now
      let mood = SphereMood(sessions: model.store.ordered(), hasPendingRequest: !model.requests.pending.isEmpty)
      metrics.record(MetricsEvents.cardOpened(after == .panel ? .painel : .espiada, mood: mood.sessionState, at: now))
    } else if before != .rest, after == .rest, let opened = cardOpenedAt {
      cardOpenedAt = nil
      metrics.record(MetricsEvents.cardClosed(seconds: max(0, Int(now.timeIntervalSince(opened).rounded())), at: now))
    }
  }

  /// Clique numa linha: a ilha se recolhe, o app da sessão vem para a frente e, depois de o
  /// conteúdo apagar, a concluída é marcada como vista (assim a linha não troca de cor antes).
  private func openSession(_ id: String) {
    guard island.stage == .panel, let session = model.store.sessions[id] else { return }
    metrics.record(MetricsEvents.sessionClicked(state: session.state, host: session.host, at: Date()))
    present(.rest)
    HostAppOpener.open(session)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      MainActor.assumeIsolated { self?.model.markSeen(id) }
    }
  }

  /// "ou abrir no <app>": a ilha se recolhe e o pedido volta para o app de origem, que vem para a frente.
  private func handBack(_ id: UUID) {
    present(.rest)
    model.handBack(id)
  }

  /// Clique em outro app fecha o painel. Cliques na ilha ficam com `islandClicked`, e no cartão
  /// (que agora é a janela inteira) com a `IslandWindow`.
  private func installClickMonitors() {
    guard clickMonitors.isEmpty else { return }
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.present(.rest) }
    }) {
      clickMonitors.append(global)
    }
  }

  private func removeClickMonitors() {
    clickMonitors.forEach(NSEvent.removeMonitor)
    clickMonitors.removeAll()
  }

  private func installMoveMonitor() {
    guard moveMonitor == nil else { return }
    moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleLeave() }
    }
  }

  private func removeMoveMonitor() {
    if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
    moveMonitor = nil
  }

  // MARK: - Aviso proativo

  /// Uma novidade esperando para virar aviso.
  private struct NoticeCandidate {
    let kind: NoticeKind
    var requestID: UUID?
    let work: DispatchWorkItem
  }

  /// O estado precisa durar isso antes de avisar, para não piscar.
  private static let noticeSettle: TimeInterval = 1

  /// Sessão que chegou a "precisa de você" ou "concluído", ou pedido novo. O estado e o pedido chegam
  /// juntos (o mesmo evento): viram uma novidade só, com o pedido, e a espera não recomeça.
  private func noticeCandidate(_ id: String, state: SessionState, requestID: UUID?) {
    noticeLog("chegou \(id.prefix(8)) \(state.rawValue)\(requestID == nil ? "" : " com pedido")")
    let kind: NoticeKind
    switch state {
    case .needsYou: kind = .needsYou
    case .done: kind = .done
    default: return
    }
    if noticeCandidates[id]?.kind == kind {
      if let requestID { noticeCandidates[id]?.requestID = requestID }
      return
    }
    noticeCandidates[id]?.work.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.noticeSettled(id) }
    }
    noticeCandidates[id] = NoticeCandidate(kind: kind, requestID: requestID, work: work)
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeSettle, execute: work)
  }

  /// Passado o 1 s: a sessão ainda está no mesmo estado (e o pedido, se houver, ainda espera), a
  /// novidade não avisou antes e a chave dela está ligada → aviso.
  private func noticeSettled(_ id: String) {
    guard let candidate = noticeCandidates.removeValue(forKey: id) else { return }
    noticeLog("novidade \(id.prefix(8)) \(candidate.kind) assentou (estado agora \(model.store.sessions[id]?.state.rawValue ?? "sumiu"))")
    let store = model.store
    guard let session = store.sessions[id], session.state == candidate.kind.sessionState,
          session.attended != false
    else { return }
    let pending = model.requests.pending.filter { $0.sessionID == id }
    if let requestID = candidate.requestID, !pending.contains(where: { $0.id == requestID }) { return }
    let prefs = settings.settings
    guard noticeGate.admit(
      sessionID: id, kind: candidate.kind, requestID: candidate.requestID,
      needsYouOn: prefs.noticeNeedsYou, doneOn: prefs.noticeDone)
    else { noticeLog("portão recusou \(id.prefix(8)) \(candidate.kind)"); return }
    let request = candidate.kind == .needsYou ? pending.max { $0.receivedAt < $1.receivedAt } : nil
    showNotice([noticeEntry(session, kind: candidate.kind, request: request, store: store)])
  }

  private func noticeEntry(_ session: Session, kind: NoticeKind, request: PendingRequest?, store: SessionStore) -> NoticeEntry {
    let name = store.displayName(for: session.id, maxLength: 28)
    return NoticeEntry(
      sessionID: session.id, kind: kind, title: session.taskTitle ?? name,
      detail: NoticeDetail.make(session: session, name: name, request: request))
  }

  /// O pedido abriu o painel sozinho (app de origem na frente): essa abertura foi o aviso dele. A
  /// novidade fica marcada como avisada, para não descer um aviso depois.
  private func noticeShownElsewhere(_ request: PendingRequest) {
    if noticeCandidates[request.sessionID]?.kind == .needsYou {
      noticeCandidates.removeValue(forKey: request.sessionID)?.work.cancel()
    }
    _ = noticeGate.admit(
      sessionID: request.sessionID, kind: .needsYou, requestID: request.id, needsYouOn: true, doneOn: true)
  }

  /// Sessão que volta a trabalhar libera um novo "precisa de você" e um novo "concluído".
  private func storeChanged(_ store: SessionStore) {
    for (id, session) in store.sessions where session.state == .working && noticeStates[id] != .working {
      noticeGate.sessionWorked(id)
    }
    noticeStates = store.sessions.mapValues(\.state)
    pruneNotice(store)
  }

  /// Com o aviso na tela, a linha cujo fato passou sai: "precisa de você" de uma sessão que já não
  /// precisa (respondida, ou de volta ao trabalho), "concluído" de uma que voltou a trabalhar; e a
  /// de uma sessão que sumiu do store.
  private func pruneNotice(_ store: SessionStore) {
    guard island.stage == .notice else { return }
    leaveNotice(island.notice.board.passed(states: store.sessions.mapValues(\.state)), reason: "o fato passou")
  }

  private func observeActivation() {
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
      MainActor.assumeIsolated { self?.appActivated(bundleID) }
    }
  }

  /// O app de origem veio para a frente: os "concluído" dele saem (você foi ver). "Precisa de
  /// você" fica até ser resolvido.
  private func appActivated(_ bundleID: String?) {
    guard island.stage == .notice, let bundleID else { return }
    let seen = island.notice.board.doneSeen(frontmost: bundleID, hosts: model.store.sessions.mapValues(\.host))
    leaveNotice(seen, reason: "\(bundleID) na frente")
  }

  /// Tira estas linhas do aviso. Se não sobraria nenhuma, o aviso sobe com elas (sem mostrar a
  /// casca vazia nem trocar a cor da luz enquanto se recolhe); a próxima descida monta um quadro novo.
  private func leaveNotice(_ ids: Set<String>, reason: String) {
    guard !ids.isEmpty else { return }
    let board = island.notice.board
    noticeLog("\(ids.count) linha(s) saem (\(reason)); \(board.entries.count - ids.count) ficam")
    if board.wouldEmpty(removing: ids) {
      present(.rest)
      return
    }
    for id in ids {
      island.notice.board.remove(sessionID: id)
      frontDoneExpiries.removeValue(forKey: id)?.cancel()
    }
  }

  /// Clique no aviso: abre o painel já no cartão do pedido que o aviso mostra (o mais recente da
  /// sessão "precisa de você" mais ao topo, como no aviso); sem pedido, abre como sempre.
  private func noticeClicked() {
    let pending = model.requests.pending
    for entry in island.notice.board.entries where entry.kind == .needsYou {
      let mine = pending.filter { $0.sessionID == entry.sessionID }
      if let request = mine.max(by: { $0.receivedAt < $1.receivedAt }) {
        island.bringForward(request.id)
        break
      }
    }
    openPanel()
  }

  /// × do aviso: ele volta para a ilha. As novidades que ele mostrava continuam avisadas (o portão
  /// não muda): a mesma não desce de novo.
  private func noticeClosed() {
    guard island.stage == .notice else { return }
    noticeLog("fechado no × com \(island.notice.board.entries.count) linha(s)")
    present(.rest)
  }

  /// Com a espiada ou o painel abertos a novidade já está à vista: nada. Em repouso, o aviso desce
  /// com ela; já aberto, ela entra como mais uma linha (no topo do seu tipo). Nenhuma linha tem
  /// prazo: cada uma sai quando você vê ou resolve a novidade.
  private func showNotice(_ entries: [NoticeEntry]) {
    guard !entries.isEmpty else { return }
    // Marcado como bloqueado mas o sistema diz que não está: o desbloqueio se perdeu; volta agora.
    if screenLocked, !simulatingLock, Self.screenIsLockedNow() == false { awayEvent(Self.screenUnlockedName) }
    // Longe da tela, ou no 1 s depois da volta: guarda, para descer tudo num aviso só.
    if away || returnWork != nil {
      noticeLog("guardado: \(entries.map(\.title)) (fora \(away), volta pendente \(returnWork != nil))")
      for entry in entries.reversed() { heldNotices.add(entry) }
      return
    }
    noticeLog("mostrar \(entries.map(\.title)) no estágio \(island.stage)")
    switch island.stage {
    case .peek, .panel:
      return
    case .rest:
      var board = NoticeBoard()
      for entry in entries.reversed() { board.add(entry) }
      island.notice.board = board
      present(.notice)
    case .notice:
      for entry in entries.reversed() { island.notice.board.add(entry) }
    }
    guard island.stage == .notice else { return }
    // "Concluído" com o app de origem já na frente: 10 s e sai. Uma entrada nova da mesma sessão
    // (pedido, ou concluído com o app atrás) fica fixa e não herda o prazo.
    let front = NoticeBoard.doneInFront(
      entries, frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
      hosts: model.store.sessions.mapValues(\.host))
    for entry in entries {
      if front.contains(entry.sessionID) { startFrontDoneExpiry(entry.sessionID) } else {
        frontDoneExpiries.removeValue(forKey: entry.sessionID)?.cancel()
      }
    }
  }

  private func startFrontDoneExpiry(_ id: String) {
    frontDoneExpiries[id]?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.frontDoneExpired(id) }
    }
    frontDoneExpiries[id] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + NoticeBoard.frontDoneSeconds, execute: work)
  }

  private func frontDoneExpired(_ id: String) {
    frontDoneExpiries[id] = nil
    guard island.stage == .notice,
          island.notice.board.entries.contains(where: { $0.sessionID == id && $0.kind == .done })
    else { return }
    leaveNotice([id], reason: "concluído com o app na frente, 10 s")
  }

  /// Saindo do aviso (ou descendo um novo): nenhum prazo fica para trás.
  private func cancelFrontDoneExpiries() {
    frontDoneExpiries.values.forEach { $0.cancel() }
    frontDoneExpiries.removeAll()
  }

  // MARK: - Modo de teste

  /// `ILHA_DEBUG=1 ILHA_DEBUG_TOUR=<segundos>`: depois desse tempo a ilha passa sozinha por
  /// repouso → espiada → painel → repouso → espiada → repouso → painel → repouso (o `IslandWindow`
  /// registra os frames de cada transição no stderr). Sem as duas variáveis, nada acontece.
  private func scheduleDebugTour() {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ILHA_DEBUG"] == "1", let delay = environment["ILHA_DEBUG_TOUR"].flatMap(Double.init) else { return }
    // Cada passo agenda o seguinte: um prazo longo (o atraso inicial) ganha folga de segundos no
    // GCD, e os passos sairiam quase juntos.
    let steps: [(TimeInterval, IslandWindow.Stage)] = [
      (delay, .peek), (1.5, .panel), (2, .rest), (1.5, .peek), (1.5, .rest), (1.5, .panel), (2, .rest),
    ]
    func run(_ index: Int) {
      guard index < steps.count else { return }
      let (wait, stage) = steps[index]
      DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
        MainActor.assumeIsolated {
          self?.present(stage)
          run(index + 1)
        }
      }
    }
    run(0)
  }

  // MARK: - Longe da tela

  private static let debugNotices = ProcessInfo.processInfo.environment["ILHA_DEBUG"] == "1"

  /// `ILHA_DEBUG=1`: cada passo do aviso no stderr (chegou, guardou, mostrou, voltou).
  private func noticeLog(_ message: @autoclosure () -> String) {
    guard Self.debugNotices else { return }
    let time = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
    FileHandle.standardError.write(Data("ilha: \(time) aviso: \(message())\n".utf8))
  }

  private static let screenLockedName = Notification.Name("com.apple.screenIsLocked")
  private static let screenUnlockedName = Notification.Name("com.apple.screenIsUnlocked")

  /// Tela bloqueada e desbloqueada (avisos distribuídos do sistema, sem permissão), telas apagando
  /// e acendendo, e troca rápida de usuário. Os distribuídos pedem entrega imediata: o padrão
  /// segura a entrega enquanto o app não está ativo, e a ilha nunca se ativa.
  private func observeAway() {
    let distributed = DistributedNotificationCenter.default()
    for name in [Self.screenLockedName, Self.screenUnlockedName] {
      distributed.addObserver(
        self, selector: #selector(screenLockChanged(_:)), name: name, object: nil,
        suspensionBehavior: .deliverImmediately)
    }
    let workspace = NSWorkspace.shared.notificationCenter
    let names: [Notification.Name] = [
      NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
      NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
    ]
    for name in names {
      awayObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        let name = note.name
        MainActor.assumeIsolated { self?.awayEvent(name) }
      })
    }
  }

  @objc private func screenLockChanged(_ note: Notification) {
    awayEvent(note.name)
  }

  /// O que o sistema diz agora sobre o bloqueio (`nil` se não disser): corrige a marca se um
  /// aviso de bloqueio ou desbloqueio se perdeu.
  private static func screenIsLockedNow() -> Bool? {
    guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
    return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
  }

  private func awayEvent(_ name: Notification.Name) {
    let wasAway = away
    switch name {
    case Self.screenLockedName: screenLocked = true
    case Self.screenUnlockedName: screenLocked = false
    case NSWorkspace.screensDidSleepNotification: screensAsleep = true
    case NSWorkspace.screensDidWakeNotification: screensAsleep = false
    case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
    case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
    default: return
    }
    noticeLog("\(name.rawValue) → fora \(away) (bloqueada \(screenLocked), apagada \(screensAsleep), outra sessão \(sessionInactive))")
    if away, !wasAway { wentAway() } else if !away, wasAway { cameBack() }
  }

  /// Saiu da tela com um aviso aberto: ninguém vai vê-lo; as linhas voltam com o que chegar depois.
  private func wentAway() {
    returnWork?.cancel()
    returnWork = nil
    guard island.stage == .notice else { return }
    for entry in island.notice.board.entries.reversed() { heldNotices.add(entry) }
    present(.rest)
  }

  /// De volta: 1 s depois (o tempo de a tela assentar), um aviso só com o que ainda vale.
  private func cameBack() {
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { self?.flushHeldNotices() }
    }
    returnWork?.cancel()
    returnWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeSettle, execute: work)
  }

  private func flushHeldNotices() {
    returnWork = nil
    noticeLog("volta: \(heldNotices.entries.count) guardado(s), fora \(away)")
    guard !away, !heldNotices.isEmpty else { return }
    let prefs = settings.settings
    let entries = heldNotices.stillShowing(
      states: model.store.sessions.mapValues(\.state),
      needsYouOn: prefs.noticeNeedsYou, doneOn: prefs.noticeDone)
    heldNotices = NoticeBoard()
    showNotice(entries)
  }

  /// `ILHA_DEBUG=1` + `ILHA_DEBUG_AWAY=<início>,<fim>` (segundos): finge a tela bloqueada nesse
  /// intervalo, para ver o aviso guardado descer na volta sem bloquear o Mac de verdade.
  private func scheduleDebugAway() {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ILHA_DEBUG"] == "1",
          let parts = environment["ILHA_DEBUG_AWAY"]?.split(separator: ",").compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
          parts.count == 2 else { return }
    simulatingLock = true
    for (delay, name) in [(parts[0], Self.screenLockedName), (parts[1], Self.screenUnlockedName)] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        MainActor.assumeIsolated {
          FileHandle.standardError.write(Data("ilha: teste \(name.rawValue)\n".utf8))
          self?.awayEvent(name)
        }
      }
    }
  }

  /// `ILHA_DEBUG=1 ILHA_DEBUG_CLICK_NOTICE=<segundos>`: depois desse tempo, se o aviso estiver na
  /// tela, um clique esquerdo de mentira no meio dele (longe do ×) entra pelo caminho de sempre da
  /// janela; o registro diz o estágio antes e depois. Sem as duas variáveis, nada acontece.
  private func scheduleDebugNoticeClick() {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ILHA_DEBUG"] == "1",
          let delay = environment["ILHA_DEBUG_CLICK_NOTICE"].flatMap(Double.init) else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        let before = self.island.stage
        guard before == .notice else {
          self.noticeLog("clique de teste: sem aviso na tela (estágio \(before)), nada a clicar")
          return
        }
        let sent = self.island.debugClickNoticeCenter()
        self.noticeLog("clique de teste no meio do aviso (enviado \(sent)): estágio \(before) → \(self.island.stage)")
      }
    }
  }

  /// `ILHA_DEBUG=1 ILHA_DEBUG_NOTICE=<segundos>`: depois desse tempo desce um aviso com as duas
  /// primeiras sessões, a primeira como "precisa de você" e a segunda como "concluído" (sem passar
  /// pelas regras nem pelas chaves). Com `ILHA_DEBUG_NOTICE_KIND=done`, as duas como "concluído"
  /// (para ver a borda verde). Sem as duas primeiras variáveis, nada acontece.
  private func scheduleDebugNotice() {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ILHA_DEBUG"] == "1", let delay = environment["ILHA_DEBUG_NOTICE"].flatMap(Double.init) else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        let store = self.model.store
        let kinds: [NoticeKind] = environment["ILHA_DEBUG_NOTICE_KIND"] == "done" ? [.done, .done] : [.needsYou, .done]
        let entries = zip(store.ordered(), kinds).map { session, kind in
          let request = kind == .needsYou ? self.model.requests.pending.last { $0.sessionID == session.id } : nil
          return self.noticeEntry(session, kind: kind, request: request, store: store)
        }
        FileHandle.standardError.write(Data("ilha: aviso de teste com \(entries.count) linha(s)\n".utf8))
        self.showNotice(entries)
      }
    }
  }
}

/// Hospeda a ilha e avisa quando o tamanho ideal muda. Não captura cliques: eles ficam com o
/// botão do item, que abre a espiada e o painel.
final class IslandHostingView: NSHostingView<IslandView> {
  var onIntrinsicSizeChange: (() -> Void)?

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    onIntrinsicSizeChange?()
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
