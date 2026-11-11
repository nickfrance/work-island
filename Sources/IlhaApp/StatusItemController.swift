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

    // Pedido novo com o app de origem na frente: a pergunta some de lá enquanto a ilha a segura,
    // então o painel abre sozinho no cartão dele (para ninguém achar que a sessão travou). Sem virar
    // chave: o teclado continua no app em que você está.
    model.onRequestArrived = { [weak self] request, originFrontmost in
      guard originFrontmost else { return }
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
  }

  // MARK: - Ilha

  /// A cápsula na tela: o botão tem 3 pt de folga dos lados (para o brilho) e a altura da barra;
  /// a cápsula tem 18 pt, centrada nele. Com várias telas, é a cópia da barra onde o cartão está
  /// aberto (`pinnedScreen`) ou, em repouso, a cópia sob o mouse (`IslandAnchor`).
  private func islandRect() -> NSRect? {
    guard let window = hostingView.window else { return nil }
    let host = window.convertToScreen(hostingView.convert(hostingView.bounds, to: nil))
    let height: CGFloat = 18
    let real = NSRect(x: host.minX + 3, y: host.midY - height / 2, width: max(host.width - 6, height), height: height)
    let screens = NSScreen.screens.map(\.frame)
    guard let home = screens.first(where: { $0.intersects(real) }) else { return real }
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
    // Saindo do repouso (mesmo com o cartão ainda se recolhendo): prende na tela da ilha sob o mouse.
    if stage != .rest, island.stage == .rest {
      pinnedScreen = nil
      if let rect = islandRect() { pinnedScreen = NSScreen.screens.first { $0.frame.intersects(rect) }?.frame }
    }
    let before = island.stage
    island.show(stage)
    recordCardChange(from: before, to: island.stage)
    if stage == .panel { installClickMonitors() } else { removeClickMonitors() }
    if stage == .peek { installMoveMonitor() } else { removeMoveMonitor() }
  }

  /// Métricas: saindo do repouso → `cartao_aberto` com o humor da esfera; de volta a ele →
  /// `cartao_fechado` com os segundos desde a abertura. Espiada → painel não conta de novo.
  private func recordCardChange(from before: IslandWindow.Stage, to after: IslandWindow.Stage) {
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
