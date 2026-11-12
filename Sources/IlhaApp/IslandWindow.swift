import AppKit
import Combine
import QuartzCore
import SwiftUI
import IlhaCore

/// A ilha que se expande: uma janela sem borda nasce exatamente em cima da cápsula (mesmo retângulo,
/// preta, cantos de 9 pt) e cresce até o cartão — espiada de 300 pt, painel de 340 pt — presa ao topo
/// da ilha, centralizada nela e a 10 pt das bordas da tela. Enquanto cresce, o preto vira o vidro
/// escuro; fechar faz o caminho de volta até a ilha e esconde a janela no fim.
///
/// Frame, cantos, vidro e luz andam juntos, cada um numa mola própria movida por um display link que
/// só existe durante a transição: em repouso a janela está fora da tela e nada roda. Trocar de alvo
/// no meio (espiada → painel, ou voltar antes de fechar) continua do tamanho e da velocidade atuais.
///
/// Quem decide quando abrir e fechar é o `StatusItemController`; aqui chegam o mouse e os cliques
/// da janela, repassados pelos `on…`.
@MainActor
final class IslandWindow {
  /// `notice`: o aviso proativo, que desce sozinho da ilha e fica até você ver ou resolver cada
  /// novidade (ou fechá-lo no ×, ou clicar nele).
  enum Stage { case rest, peek, panel, notice }

  /// O estado pedido por último; durante a transição a janela ainda está a caminho dele.
  private(set) var stage: Stage = .rest

  /// O mouse entrou (`true`) ou saiu (`false`) do cartão.
  var onHover: ((Bool) -> Void)?
  /// Clique na espiada (em qualquer lugar dela).
  var onPeekClick: (() -> Void)?
  /// Clique esquerdo no aviso (em qualquer lugar dele, menos no ×).
  var onNoticeClick: (() -> Void)?
  /// × do aviso (clique ou leitor de tela): o aviso volta para a ilha.
  var onNoticeClose: (() -> Void)?
  /// Clique esquerdo no lugar da ilha, que o cartão cobre.
  var onIslandClick: (() -> Void)?
  /// Clique direito (ou com Control) no lugar da ilha.
  var onIslandSecondaryClick: (() -> Void)?
  /// Esc sem campo de texto em foco.
  var onCancel: (() -> Void)?
  /// Toque numa linha de sessão do painel.
  var onSelectSession: ((String) -> Void)?
  /// "ou abrir no <app>" num cartão: o pedido volta para o app de origem.
  var onHandBack: ((UUID) -> Void)?
  /// `true` quando a janela vai para a frente (o cartão passa a cobrir a ilha: esconda-a), `false`
  /// quando sai (já preta e do tamanho da ilha: mostre-a de volta). Nunca as duas escondidas.
  var onCoverIsland: ((Bool) -> Void)?

  private let usage: UsageController
  private let settings: SettingsStore
  private let update: UpdateController
  /// O quadro do aviso proativo e se ele está à vista; quem o preenche é o `StatusItemController`.
  let notice = NoticePresentation()
  /// Avisos que o painel chegou a mostrar desde que abriu: viram "vistos" quando ele volta à ilha.
  private let shownNotices = ShownNotices()
  /// Os cartões de resposta do painel, alimentados pela fila do `AppModel`.
  private let deck = RequestDeck()
  /// Tela do painel: a principal ou as configurações.
  private let router = PanelRouter()
  /// Tela em que o painel abre da próxima vez (o menu "Configurações…" abre direto nelas).
  private var openingRoute: PanelRouter.Route = .main
  private var requestsSink: AnyCancellable?
  /// O quadro do aviso mudou (linha entrou, ou saiu porque você viu ou o fato passou): a casca mede de
  /// novo e cresce ou encolhe para a altura nova.
  private var noticeBoardSink: AnyCancellable?
  /// Pedidos já vistos na fila: um id novo tira o painel das configurações.
  private var pendingIDs: Set<UUID> = []
  private let anchor: () -> NSRect?
  private let window: IslandPanel
  private let container: ShellContainerView
  private let shell = ShellState()
  private let peekPresentation = PanelPresentation()
  private let panelPresentation = PanelPresentation()
  private let peekHost: PanelHostingView<PeekLayer>
  private let panelHost: PanelHostingView<PanelLayer>
  private let noticeHost: PanelHostingView<NoticeLayer>
  private let ticker = FrameTicker()
  private var motion = ShellMotion()
  /// Mola da transição em curso quando não é a de sempre (o aviso desce e sobe mais rápido); vale
  /// também para os ajustes de tamanho no meio dela.
  private var springResponse: Double?
  private var lastTick: CFTimeInterval?
  /// Quadros desenhados na transição em curso (só para o registro do modo `ILHA_DEBUG`).
  private var frameCount = 0
  /// A ilha está escondida sob o cartão (entre o `orderFront` e o `orderOut`).
  private var coveringIsland = false
  private var transitionStart: CFTimeInterval = 0
  private var relayoutScheduled = false
  /// Muda a cada troca de estado: o esconder atrasado de uma camada só vale se nada mudou depois.
  private var layerGeneration = 0
  /// Idem para o esmaecer da janela com Reduzir movimento.
  private var fadeGeneration = 0
  /// `ILHA_DEBUG=1`: frames do começo e do fim de cada transição no stderr.
  private let debug = ProcessInfo.processInfo.environment["ILHA_DEBUG"] == "1"
  private var transitionName = ""

  init(
    model: AppModel, usage: UsageController, settings: SettingsStore, plugin: PluginController,
    update: UpdateController, metrics: MetricsController, anchor: @escaping () -> NSRect?
  ) {
    self.usage = usage
    self.settings = settings
    self.update = update
    self.anchor = anchor
    let actions = PanelActions()
    peekHost = PanelHostingView(rootView: PeekLayer(model: model, usage: usage, presentation: peekPresentation))
    panelHost = PanelHostingView(rootView: PanelLayer(
      model: model, usage: usage, deck: deck, presentation: panelPresentation, router: router,
      settings: settings, plugin: plugin, update: update, metrics: metrics, shownNotices: shownNotices,
      actions: actions))
    noticeHost = PanelHostingView(rootView: NoticeLayer(presentation: notice))
    container = ShellContainerView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    window = IslandPanel(contentView: container)

    // Fundo atrás de tudo, do tamanho da janela; as camadas de conteúdo têm largura fixa e ficam
    // presas no canto de cima à esquerda, cortadas pela casca enquanto ela cresce (como no protótipo).
    let background = BackgroundHostingView(
      rootView: ShellBackground(model: model, deck: deck, state: shell, router: router, notice: notice))
    background.sizingOptions = []
    background.frame = container.bounds
    background.autoresizingMask = [.width, .height]
    container.addSubview(background)
    for host in [peekHost, panelHost, noticeHost] as [NSView] {
      host.autoresizingMask = []
      host.isHidden = true
      container.addSubview(host)
    }

    actions.open = { [weak self] id in self?.onSelectSession?(id) }
    actions.dismiss = { [weak model] id in model?.dismiss(id) }
    actions.showSettings = { [weak self] in self?.setRoute(.settings) }
    actions.back = { [weak self] in self?.setRoute(.main) }
    actions.quit = { NSApp.terminate(nil) }
    deck.respond = { [weak model] id, decision in model?.respond(id, with: decision) }
    deck.handBack = { [weak self] id in self?.onHandBack?(id) }
    deck.transcript = { [weak model] sessionID in
      model?.store.sessions[sessionID]?.transcriptPath.map { URL(fileURLWithPath: $0) }
    }
    deck.resignTextFocus = { [weak self] in
      guard let self, self.window.firstResponder is NSText else { return }
      self.window.makeFirstResponder(nil)
    }
    // `@Published` avisa antes de gravar, com o valor novo: o baralho já recebe a fila certa.
    requestsSink = model.$requests.sink { [weak self, weak deck] queue in
      MainActor.assumeIsolated {
        deck?.sync(queue)
        self?.noticeNewRequests(queue)
      }
    }
    peekHost.onIntrinsicSizeChange = { [weak self] in self?.scheduleRelayout() }
    panelHost.onIntrinsicSizeChange = { [weak self] in self?.scheduleRelayout() }
    noticeHost.onIntrinsicSizeChange = { [weak self] in self?.scheduleRelayout() }
    // A hospedagem nem sempre avisa quando o conteúdo encolhe (uma linha que sai deixava o cartão
    // alto e a outra no meio). `@Published` avisa antes de gravar; o relayout roda no giro seguinte,
    // já com o quadro novo. Quadro vazio: quem fecha o aviso é o `StatusItemController`.
    noticeBoardSink = notice.$board.sink { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.stage == .notice else { return }
        self.scheduleRelayout()
      }
    }
    notice.onClose = { [weak self] in self?.onNoticeClose?() }
    container.onHover = { [weak self] inside in self?.onHover?(inside) }
    window.onMouseDown = { [weak self] event in self?.handleMouseDown(event) ?? false }
    window.onCancel = { [weak self] in self?.onCancel?() }
    window.onKey = { [weak self] key in self?.handleKey(key) ?? false }
    ticker.onTick = { [weak self] link in self?.tick(link) }
  }

  /// O ponto (na tela) está sobre o cartão como ele aparece agora?
  func contains(_ point: NSPoint) -> Bool {
    window.isVisible && window.frame.contains(point)
  }

  /// O painel recebe o teclado (↩, Esc, 1–9) sem ativar o app: só quando você o abriu com um clique.
  /// `clearingFocus`: nenhum campo de texto começa com o foco (o AppKit e a SwiftUI podem pôr o foco
  /// no primeiro campo ao virar chave, e aí os números iriam para ele). Num clique dentro do painel não
  /// limpa: o clique pode ser no próprio campo.
  func makeKey(clearingFocus: Bool = true) {
    guard stage == .panel, !window.isKeyWindow else { return }
    window.makeKey()
    guard clearingFocus else { return }
    window.makeFirstResponder(nil)
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.window.firstResponder is NSText else { return }
        self.window.makeFirstResponder(nil)
      }
    }
  }

  /// Põe na frente o cartão deste pedido (chegou com o app de origem na frente). Com o painel já
  /// aberto num cartão, ele entra na fila e não troca o que você está respondendo.
  func bringForward(_ request: UUID) {
    guard stage != .panel || deck.shown == nil else { return }
    deck.bringForward(request)
  }

  /// Pedido novo na fila com o painel nas configurações: volta (deslizando) à tela principal, onde
  /// está o cartão dele; senão a sessão ficaria parada sem cartão à vista.
  private func noticeNewRequests(_ queue: RequestQueue) {
    let ids = Set(queue.pending.map(\.id))
    let arrived = !ids.isSubset(of: pendingIDs)
    pendingIDs = ids
    if arrived, router.route == .settings { setRoute(.main) }
  }

  /// "Configurações…" no menu do botão direito: com o painel aberto, desliza até elas; senão, o
  /// painel abre já nelas (quem chama abre o painel em seguida).
  func openSettings() {
    if stage == .panel { setRoute(.settings) } else { openingRoute = .settings }
  }

  func show(_ next: Stage) {
    guard next != stage else {
      relayout()
      return
    }
    let previous = stage
    stage = next
    springResponse = ShellMetrics.springResponse(from: previous, to: next)
    // A luz do aviso fica até a casca voltar à ilha (sem trocar de cor enquanto ela some); a espiada e
    // o painel voltam à luz do humor.
    switch next {
    case .notice: setNoticeLit(true)
    case .peek, .panel: setNoticeLit(false)
    case .rest: break
    }
    // Abrindo o painel: começa na tela pedida (a principal, salvo pelo menu), sem deslizar. Vale
    // também ao reabrir enquanto o cartão ainda se recolhia nas configurações.
    if next == .panel, previous != .panel {
      setRoute(openingRoute, animated: false)
      openingRoute = .main
    }
    // O aviso não mostra o uso do plano: só a espiada e o painel pedem uma leitura.
    if next == .peek || next == .panel { usage.trigger(.surfaceOpened) }
    presentLayers(for: next)
    layoutHosts()

    guard let island = anchor(), let target = targetFrame(for: next, island: island) else {
      // Sem ilha na tela (item fora da barra): volta ao repouso, sem estado preso.
      stage = .rest
      presentLayers(for: .rest)
      hideNow()
      return
    }
    transitionName = "\(previous)→\(next)"
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      showWithoutMotion(target: target, island: island)
      return
    }

    fadeGeneration += 1
    if !window.isVisible {
      // Nasce como a ilha: mesmo retângulo, preta, cantos de 9 pt, já desenhada assim antes de
      // aparecer (nunca um quadro velho de outra abertura).
      motion.jump(frame: island, radius: ShellMetrics.restRadius, glass: 0, tint: 0)
      apply()
      window.alphaValue = 1
      container.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      window.orderFrontRegardless()
      coverIsland(true)
    } else if window.alphaValue < 1 {
      window.alphaValue = 1
    }
    motion.retarget(
      frame: target,
      radius: ShellMetrics.radius(for: next),
      glass: next == .rest ? 0 : 1,
      tint: ShellMetrics.tint(for: next),
      opening: next != .rest,
      response: springResponse)
    let screen = Self.screen(for: island)
    let barHeight = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
    log("início \(Self.describe(window.frame)) ilha \(Self.describe(island)) nível \(window.level.rawValue) "
      + "(barra de menu \(NSWindow.Level.mainMenu.rawValue), itens \(NSWindow.Level.statusBar.rawValue)) "
      + "tela \(screen.map { Self.describe($0.frame) } ?? "?") faixa da barra \(barHeight)")
    startTicking()
  }

  /// A ilha mudou de lugar ou de largura, ou o conteúdo mudou de altura: o cartão vai para o novo alvo.
  func relayout() {
    // Escondida, nada a fazer: `show` refaz as medidas ao abrir.
    guard window.isVisible else { return }
    layoutHosts()
    guard let island = anchor(), let target = targetFrame(for: stage, island: island) else { return }
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      motion.jump(frame: target, radius: motion.radius.target, glass: motion.glass.target, tint: motion.tint.target)
      apply()
      return
    }
    guard target != motion.targetFrame else { return }
    motion.retargetFrame(target, opening: stage != .rest, response: springResponse)
    startTicking()
  }

  // MARK: - Alvos

  private func targetFrame(for stage: Stage, island: NSRect) -> NSRect? {
    let width: CGFloat
    let height: CGFloat
    switch stage {
    case .rest: return island
    case .peek: width = peekWidth; height = peekHost.frame.height
    case .panel: width = panelWidth; height = panelHost.frame.height
    case .notice: width = noticeWidth; height = noticeHost.frame.height
    }
    var x = island.midX - width / 2
    if let visible = Self.screen(for: island)?.visibleFrame {
      x = min(max(x, visible.minX + ShellMetrics.edgeMargin), visible.maxX - ShellMetrics.edgeMargin - width)
    }
    // Preso ao topo da ilha: cresce para baixo e para os lados, nunca para cima.
    return NSRect(x: x, y: island.maxY - height, width: width, height: height)
  }

  /// As camadas têm a altura que o conteúdo pede; o painel para em 690 pt ou no fim da tela.
  private func layoutHosts() {
    let peekHeight = ceil(peekHost.fittingSize.height)
    // O aviso mede o quadro de agora numa hospedagem nova: a camada só redesenha com o quadro novo
    // no giro seguinte, e medi-la aqui descia o aviso vazio e o fazia crescer depois.
    let noticeHeight = ceil(NSHostingView(rootView: NoticeLayer.measured(notice.board)
      .environment(\.displayScale, window.backingScaleFactor)).fittingSize.height)
    var panelLimit = panelMaxHeight
    if let island = anchor(), let visible = Self.screen(for: island)?.visibleFrame {
      panelLimit = min(panelLimit, island.maxY - visible.minY - ShellMetrics.edgeMargin)
    }
    let panelHeight = ceil(min(panelHost.fittingSize.height, panelLimit))
    let peekFrame = NSRect(x: 0, y: 0, width: peekWidth, height: peekHeight)
    let panelFrame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
    let noticeFrame = NSRect(x: 0, y: 0, width: noticeWidth, height: noticeHeight)
    if peekHost.frame != peekFrame { peekHost.frame = peekFrame }
    if panelHost.frame != panelFrame { panelHost.frame = panelFrame }
    if noticeHost.frame != noticeFrame { noticeHost.frame = noticeFrame }
  }

  private func scheduleRelayout() {
    guard !relayoutScheduled else { return }
    relayoutScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.relayoutScheduled = false
        self?.relayout()
      }
    }
  }

  /// Liga a camada do estado novo (entra com opacidade depois de 140 ms) e apaga a outra (200 ms);
  /// a que saiu fica escondida depois do esmaecer, para não pegar mouse nem hover.
  private func presentLayers(for stage: Stage) {
    peekPresentation.shown = stage == .peek
    panelPresentation.shown = stage == .panel
    notice.shown = stage == .notice
    deck.visible = stage == .panel
    if stage == .peek { peekHost.isHidden = false }
    if stage == .panel { panelHost.isHidden = false }
    if stage == .notice { noticeHost.isHidden = false }
    layerGeneration += 1
    let generation = layerGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, generation == self.layerGeneration else { return }
        self.peekHost.isHidden = self.stage != .peek
        self.panelHost.isHidden = self.stage != .panel
        self.noticeHost.isHidden = self.stage != .notice
      }
    }
  }

  // MARK: - Animação

  private func startTicking() {
    frameCount = 0
    transitionStart = CACurrentMediaTime()
    guard !ticker.isRunning else { return }
    lastTick = nil
    ticker.start(on: container)
  }

  private func tick(_ link: CADisplayLink) {
    let now = link.targetTimestamp
    frameCount += 1
    let dt = min(max(now - (lastTick ?? link.timestamp), 0), 0.1)
    lastTick = now
    motion.advance(by: dt)
    if motion.isSettled {
      motion.snap()
      apply()
      finish()
    } else {
      apply()
    }
  }

  private func finish() {
    ticker.stop()
    lastTick = nil
    let island = anchor()
    let matches = island.map { window.frame == Self.aligned($0, scale: window.backingScaleFactor) } ?? false
    log("fim \(Self.describe(window.frame)) em \(frameCount) quadros, \(Int((CACurrentMediaTime() - transitionStart) * 1000)) ms" + (stage == .rest ? " ilha \(island.map { Self.describe($0) } ?? "?") igual: \(matches ? "sim" : "não")" : ""))
    if stage == .rest { hideNow() }
  }

  private func hideNow() {
    ticker.stop()
    // A ilha volta antes, já confirmada no servidor de render, e só então a casca (preta, do tamanho
    // dela) sai: nunca um quadro sem nenhuma das duas.
    if coveringIsland {
      coverIsland(false)
      CATransaction.flush()
    }
    window.orderOut(nil)
    window.alphaValue = 1
    peekHost.isHidden = true
    panelHost.isHidden = true
    noticeHost.isHidden = true
    setNoticeLit(false)
    // De volta à ilha: o painel volta à tela principal (já escondido, sem deslizar).
    setRoute(.main, animated: false)
    markShownNoticesSeen()
  }

  /// O painel voltou à ilha depois de mostrar o aviso das métricas, das sessões de antes ou o
  /// "Atualizada": ele não volta. Já escondido, então o cartão não muda de altura na frente de ninguém.
  /// Um aviso que nunca apareceu (ex.: segurado por um pedido na fila) não conta.
  private func markShownNoticesSeen() {
    let shown = shownNotices.drain()
    if shown.contains(.metrics) || shown.contains(.pluginSessions) {
      settings.update {
        if shown.contains(.metrics) { $0.metricsNoticeSeen = true }
        if shown.contains(.pluginSessions) { $0.pluginNoticeSeen = true }
      }
    }
    if shown.contains(.updated) { update.clearJustUpdated() }
  }

  /// Liga ou desliga a luz na cor do aviso. Com a casca à vista, a cor troca devagar (aviso → painel);
  /// escondida, troca direto, para o aviso já nascer na cor dele.
  private func setNoticeLit(_ lit: Bool) {
    guard shell.noticeLit != lit else { return }
    guard window.isVisible else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { shell.noticeLit = lit }
      return
    }
    shell.noticeLit = lit
  }

  /// Troca a tela do painel. Animada, desliza (o `PanelLayer` e o fundo têm a curva); sem animação,
  /// troca direto. Indo para as configurações, nenhum campo do cartão escondido fica com o teclado.
  private func setRoute(_ route: PanelRouter.Route, animated: Bool = true) {
    guard router.route != route else { return }
    if route == .settings { deck.resignTextFocus() }
    guard animated else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { router.route = route }
      return
    }
    router.route = route
  }

  /// Reduzir movimento: nada cresce; a janela aparece já no tamanho do cartão e some esmaecendo.
  private func showWithoutMotion(target: NSRect, island: NSRect) {
    ticker.stop()
    fadeGeneration += 1
    let generation = fadeGeneration
    if stage == .rest {
      guard window.isVisible else { return }
      log("início \(Self.describe(window.frame)) (Reduzir movimento: esmaece)")
      fade(to: 0) { [weak self] in
        guard let self, generation == self.fadeGeneration else { return }
        self.hideNow()
        self.motion.jump(frame: island, radius: ShellMetrics.restRadius, glass: 0, tint: 0)
        self.apply()
        self.log("fim (escondida)")
      }
      return
    }
    motion.jump(frame: target, radius: ShellMetrics.radius(for: stage), glass: 1, tint: ShellMetrics.tint(for: stage))
    apply()
    log("início/fim \(Self.describe(window.frame)) (Reduzir movimento)")
    if !window.isVisible {
      window.alphaValue = 0
      window.orderFrontRegardless()
      coverIsland(true)
    }
    if window.alphaValue < 1 { fade(to: 1) {} }
  }

  private func fade(to alpha: CGFloat, completion: @escaping @MainActor () -> Void) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.18
      context.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeOut : .easeIn)
      window.animator().alphaValue = alpha
    } completionHandler: {
      MainActor.assumeIsolated { completion() }
    }
  }

  /// Leva o estado da mola para a tela: frame da janela, recorte da casca e o fundo SwiftUI.
  private func apply() {
    let frame = Self.aligned(motion.frame, scale: window.backingScaleFactor)
    let radius = min(max(motion.radius.value, 0), min(frame.width, frame.height) / 2)
    if window.frame != frame { window.setFrame(frame, display: true) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    container.layer?.cornerRadius = radius
    CATransaction.commit()
    shell.radius = radius
    shell.glass = min(max(motion.glass.value, 0), 1)
    shell.tint = min(max(motion.tint.value, 0), 1)
    // Sem sombra enquanto ainda tem o tamanho da ilha (a cápsula não tem sombra); depois, a sombra
    // do sistema acompanha o contorno a cada quadro.
    let wantsShadow = frame.height > 40
    if window.hasShadow != wantsShadow { window.hasShadow = wantsShadow }
    if wantsShadow { window.invalidateShadow() }
  }

  private func coverIsland(_ covered: Bool) {
    guard covered != coveringIsland else { return }
    coveringIsland = covered
    onCoverIsland?(covered)
    log(covered ? "ilha escondida (janela na frente) em \(Self.describe(window.frame))"
      : "ilha de volta (janela saindo) em \(Self.describe(window.frame))")
  }

  // MARK: - Teclado

  /// ↩, Esc e 1–9 com a janela como chave. `true` quando a tecla foi usada.
  private func handleKey(_ key: CardKey) -> Bool {
    guard stage == .panel else {
      if key == .escape, stage != .rest { onCancel?(); return true }
      return false
    }
    // Nas configurações, Esc volta ao painel sem fechar; ↩ e 1–9 não valem para o pedido escondido.
    if router.route == .settings {
      guard key == .escape else { return false }
      setRoute(.main)
      return true
    }
    switch deck.key(key) {
    case .handled: return true
    case .close: onCancel?(); return true
    case .ignored: return false
    }
  }

  // MARK: - Cliques na janela

  /// `true` quando o clique foi tratado aqui e não segue para o conteúdo.
  private func handleMouseDown(_ event: NSEvent) -> Bool {
    let point = window.convertPoint(toScreen: event.locationInWindow)
    let onIsland = anchor()?.contains(point) ?? false
    if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
      guard onIsland else { return false }
      onIslandSecondaryClick?()
      return true
    }
    switch stage {
    case .peek:
      onPeekClick?()
      return true
    case .notice:
      // O × fecha; o resto do aviso abre o painel. Os dois aqui, antes do conteúdo: o botão da
      // SwiftUI fica para o leitor de tela.
      if onNoticeCloseButton(event) { onNoticeClose?() } else { onNoticeClick?() }
      return true
    case .panel:
      // Como no protótipo: com o painel aberto, clicar no lugar da ilha não fecha (fecham clique
      // fora, Esc e as linhas). O clique segue para o conteúdo; mexer no painel aberto sozinho
      // (pedido que chegou) também passa a receber o teclado.
      makeKey(clearingFocus: false)
      return false
    case .rest:
      // Clique no lugar da ilha enquanto o cartão se recolhe: abre o painel de novo.
      guard onIsland else { return false }
      onIslandClick?()
      return true
    }
  }

  /// Modo de teste (`ILHA_DEBUG_CLICK_NOTICE`): um clique esquerdo (aperta e solta) no meio do aviso,
  /// longe do ×, pelo `sendEvent` da janela, o mesmo caminho de um clique de verdade. `false` sem
  /// aviso na tela ou se o evento não pôde ser criado.
  @discardableResult
  func debugClickNoticeCenter() -> Bool {
    guard stage == .notice, window.isVisible else { return false }
    let bounds = container.bounds
    let point = NSPoint(x: bounds.midX, y: bounds.midY)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      guard let event = NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
      else { return false }
      window.sendEvent(event)
    }
    return true
  }

  /// O clique caiu no × do aviso? Na camada do aviso, com y para baixo a partir do topo.
  private func onNoticeCloseButton(_ event: NSEvent) -> Bool {
    let local = noticeHost.convert(event.locationInWindow, from: nil)
    let point = CGPoint(x: local.x, y: noticeHost.isFlipped ? local.y : noticeHost.bounds.height - local.y)
    return NoticeClose.hitRect(topInset: peekTopInset).contains(point)
  }

  // MARK: - Utilidades

  private static func screen(for rect: NSRect) -> NSScreen? {
    NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
  }

  /// Arredonda para o pixel da tela, com a borda de cima fixa (o cartão nunca treme no topo).
  private static func aligned(_ rect: NSRect, scale: CGFloat) -> NSRect {
    let s = max(scale, 1)
    func round(_ v: CGFloat) -> CGFloat { (v * s).rounded() / s }
    let top = round(rect.maxY)
    let width = max(round(rect.width), 1)
    let height = max(round(rect.height), 1)
    return NSRect(x: round(rect.minX), y: top - height, width: width, height: height)
  }

  private static func describe(_ rect: NSRect) -> String {
    func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    return "(\(f(rect.minX)), \(f(rect.minY)), \(f(rect.width))×\(f(rect.height)))"
  }

  private func log(_ message: String) {
    guard debug else { return }
    let time = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
    FileHandle.standardError.write(Data("ilha: \(time) ilha \(transitionName) \(message)\n".utf8))
  }
}

// MARK: - Medidas

private enum ShellMetrics {
  static let restRadius: CGFloat = 9
  static let peekRadius: CGFloat = 22
  static let panelRadius: CGFloat = 26
  static let noticeRadius: CGFloat = 18
  static let edgeMargin: CGFloat = 10

  static func radius(for stage: IslandWindow.Stage) -> CGFloat {
    switch stage {
    case .rest: return restRadius
    case .peek: return peekRadius
    case .panel: return panelRadius
    case .notice: return noticeRadius
    }
  }

  /// Luz do estado vinda de cima: inteira no painel e no aviso, fraca na espiada (como no protótipo).
  static func tint(for stage: IslandWindow.Stage) -> Double {
    switch stage {
    case .rest: return 0
    case .peek: return 0.35
    case .panel, .notice: return 1
    }
  }

  /// O aviso desce numa mola de 0,35 s (com o leve passo além) e, dele à ilha, sobe em 0,25 s sem
  /// passar do ponto. `nil`: as molas de sempre (0,46 s abrindo, 0,3 s fechando).
  static func springResponse(from previous: IslandWindow.Stage, to next: IslandWindow.Stage) -> Double? {
    if next == .notice { return 0.35 }
    if previous == .notice, next == .rest { return 0.25 }
    return nil
  }
}

/// A espiada e o aviso começam 12 pt abaixo do topo do cartão (1 + os 11 pt de margem da própria
/// view): sem a alça, a faixa da ilha sobrava vazia em cima.
private let peekTopInset: CGFloat = 1
/// No painel o conteúdo começa 14 pt abaixo do topo, mais os 12 pt de folga do próprio cartão.
private let panelTopInset: CGFloat = 14

// MARK: - Molas

/// Uma grandeza numa mola de massa 1 (a mesma da SwiftUI: `response` e `dampingFraction`).
private struct SpringChannel {
  var value: Double = 0
  var velocity: Double = 0
  var target: Double = 0
  var response: Double = 0.46
  var damping: Double = 0.82
  /// Abaixo disso (e da velocidade correspondente) a mola é dada como parada.
  let tolerance: Double

  init(tolerance: Double) { self.tolerance = tolerance }

  var isSettled: Bool { abs(value - target) < tolerance && abs(velocity) < tolerance * 10 }

  mutating func advance(by dt: Double) {
    guard dt > 0 else { return }
    let stiffness = pow(2 * .pi / response, 2)
    let friction = 4 * .pi * damping / response
    // Passos de 1 ms (Euler semi-implícito): estável e exato o bastante para um quadro de até 100 ms.
    let steps = max(1, Int((dt / 0.001).rounded(.up)))
    let h = dt / Double(steps)
    for _ in 0..<steps {
      velocity += (-stiffness * (value - target) - friction * velocity) * h
      value += velocity * h
    }
  }

  mutating func snap() {
    value = target
    velocity = 0
  }

  mutating func jump(to v: Double) {
    value = v
    target = v
    velocity = 0
  }

  /// Novo alvo: posição e velocidade continuam de onde estão.
  mutating func retarget(_ v: Double, response: Double, damping: Double) {
    target = v
    self.response = response
    self.damping = damping
  }
}

/// Frame (borda esquerda, topo, largura, altura), cantos, vidro e luz da casca.
private struct ShellMotion {
  var left = SpringChannel(tolerance: 0.3)
  var top = SpringChannel(tolerance: 0.3)
  var width = SpringChannel(tolerance: 0.3)
  var height = SpringChannel(tolerance: 0.3)
  var radius = SpringChannel(tolerance: 0.05)
  var glass = SpringChannel(tolerance: 0.003)
  var tint = SpringChannel(tolerance: 0.003)

  private var geometry: [WritableKeyPath<ShellMotion, SpringChannel>] { [\.left, \.top, \.width, \.height] }
  private var all: [WritableKeyPath<ShellMotion, SpringChannel>] { geometry + [\.radius, \.glass, \.tint] }

  var frame: NSRect {
    NSRect(x: left.value, y: top.value - height.value, width: width.value, height: height.value)
  }

  var targetFrame: NSRect {
    NSRect(x: left.target, y: top.target - height.target, width: width.target, height: height.target)
  }

  var isSettled: Bool { all.allSatisfy { self[keyPath: $0].isSettled } }

  mutating func advance(by dt: Double) {
    for path in all { self[keyPath: path].advance(by: dt) }
  }

  mutating func snap() {
    for path in all { self[keyPath: path].snap() }
  }

  mutating func jump(frame: NSRect, radius r: CGFloat, glass g: Double, tint t: Double) {
    left.jump(to: frame.minX)
    top.jump(to: frame.maxY)
    width.jump(to: frame.width)
    height.jump(to: frame.height)
    radius.jump(to: r)
    glass.jump(to: g)
    tint.jump(to: t)
  }

  /// Abrir: mola de 460 ms com um leve passo além (0,82), o vidro chegando em ~500 ms. Fechar: ~300 ms,
  /// sem passar do ponto (a casca não pode ficar menor que a ilha), voltando ao preto antes de pousar.
  /// `response` troca o tempo do frame e dos cantos (o aviso); o amortecimento segue o sentido.
  mutating func retarget(
    frame: NSRect, radius r: CGFloat, glass g: Double, tint t: Double, opening: Bool, response: Double? = nil
  ) {
    retargetFrame(frame, opening: opening, response: response)
    radius.retarget(r, response: response ?? (opening ? 0.46 : 0.3), damping: opening ? 0.82 : 1)
    glass.retarget(g, response: opening ? 0.5 : 0.26, damping: 1)
    tint.retarget(t, response: opening ? 0.5 : 0.24, damping: 1)
  }

  mutating func retargetFrame(_ frame: NSRect, opening: Bool, response custom: Double? = nil) {
    let response = custom ?? (opening ? 0.46 : 0.3)
    let damping = opening ? 0.82 : 1
    left.retarget(frame.minX, response: response, damping: damping)
    top.retarget(frame.maxY, response: response, damping: damping)
    width.retarget(frame.width, response: response, damping: damping)
    height.retarget(frame.height, response: response, damping: damping)
  }
}

/// Display link da tela da janela, ligado só enquanto há transição.
@MainActor
private final class FrameTicker: NSObject {
  var onTick: ((CADisplayLink) -> Void)?
  private var link: CADisplayLink?

  var isRunning: Bool { link != nil }

  func start(on view: NSView) {
    guard link == nil else { return }
    let link = view.displayLink(target: self, selector: #selector(tick(_:)))
    // `.common`: continua com o menu de contexto aberto (o run loop fica em modo de rastreio).
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick(_ link: CADisplayLink) {
    onTick?(link)
  }
}

// MARK: - Janela e casca

/// Janela sem borda acima da barra de menu (cobre a ilha e cresce sobre a faixa da barra).
///
/// `.nonactivatingPanel`: aparece e recebe cliques sem ativar o app nem tirar o foco do app em que
/// você está. `canBecomeKey` é verdadeiro para o teclado dos cartões; com `becomesKeyOnlyIfNeeded`
/// ela só vira chave quando uma view pedir teclado ou o `IslandWindow` pedir (painel aberto com clique).
private final class IslandPanel: NSPanel {
  /// Clique (esquerdo ou direito) antes de chegar ao conteúdo; `true` quando foi tratado.
  var onMouseDown: ((NSEvent) -> Bool)?
  var onCancel: (() -> Void)?
  /// ↩, Esc e 1–9 antes do conteúdo; `true` quando a tecla foi usada.
  var onKey: ((CardKey) -> Bool)?

  init(contentView: NSView) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = true
    isFloatingPanel = true
    // Depois de `isFloatingPanel`, que põe o nível em `.floating` (abaixo da barra de menu): um acima
    // dos itens da barra, para a casca nascer por cima da própria ilha.
    level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    self.contentView = contentView
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// A casca fica sobre a barra de menu: nada de empurrar a janela para baixo dela.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown || event.type == .rightMouseDown, onMouseDown?(event) == true { return }
    if event.type == .keyDown, handleKeyDown(event) { return }
    super.sendEvent(event)
  }

  /// As teclas do painel (regras em `CardKey.action`).
  private func handleKeyDown(_ event: NSEvent) -> Bool {
    let action = CardKey.action(
      keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags,
      isRepeat: event.isARepeat, typing: firstResponder is NSText,
      composing: (firstResponder as? NSTextView)?.hasMarkedText() == true)
    switch action {
    case .pass:
      return false
    case .swallow:
      return true
    case .unfocus:
      makeFirstResponder(nil)
      return true
    case .card(.escape):
      if onKey?(.escape) == true { return true }
      onCancel?()
      return true
    case .card(let key):
      return onKey?(key) ?? false
    }
  }

  /// Esc: com um campo de texto em foco, só tira o foco dele; senão, fecha.
  override func cancelOperation(_ sender: Any?) {
    if firstResponder is NSText {
      makeFirstResponder(nil)
    } else {
      onCancel?()
    }
  }
}

/// Raiz da janela: recorta tudo no contorno da casca (cantos animados) e avisa quando o mouse
/// entra e sai. Coordenadas viradas: as camadas de conteúdo ficam presas no topo.
private final class ShellContainerView: NSView {
  var onHover: ((Bool) -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerCurve = .continuous
    addTrackingArea(NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

  override var isFlipped: Bool { true }

  override func mouseEntered(with event: NSEvent) { onHover?(true) }
  override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// O fundo não recebe cliques: eles ficam com as camadas de conteúdo (ou com ninguém).
private final class BackgroundHostingView: NSHostingView<ShellBackground> {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Valores da casca a cada quadro, vindos das molas (sem animação da SwiftUI por cima).
@MainActor
private final class ShellState: ObservableObject {
  @Published var radius: CGFloat = ShellMetrics.restRadius
  /// 0 = preto da ilha, 1 = vidro escuro.
  @Published var glass: Double = 0
  /// Força da luz do estado vinda de cima.
  @Published var tint: Double = 0
  /// A luz de cima tem a cor do aviso (âmbar ou verde) em vez da do humor: do aviso até a casca
  /// voltar à ilha ou virar espiada ou painel.
  @Published var noticeLit = false
}

/// O fundo da casca: o vidro escuro de sempre, coberto pelo preto da ilha que vai sumindo, a luz da
/// cor do estado e o fio claro da borda (30% na ilha, 16% no cartão). No aviso só com "concluído",
/// a borda fica verde, com o brilho da etiqueta "trabalhando" passando por ela (parada com Reduzir
/// movimento).
private struct ShellBackground: View {
  @ObservedObject var model: AppModel
  @ObservedObject var deck: RequestDeck
  @ObservedObject var state: ShellState
  @ObservedObject var router: PanelRouter
  @ObservedObject var notice: NoticePresentation
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: state.radius, style: .continuous)
    let mood = deck.accent(sessions: model.store.ordered())
    // No aviso, a luz é a do que aconteceu (âmbar se alguma linha precisa de você, senão verde).
    let noticeGlow: Color? = state.noticeLit ? notice.board.kind.glow : nil
    // A base tem o tamanho exato da casca. O vidro e a luz ficam no fundo dela, como antes: a luz
    // (`TintGlow`) pede no mínimo 220 pt de altura, e a pilha deles passa da casca baixa (o aviso),
    // centrada; o que sobra em cima e embaixo fica fora do recorte. Por isso a borda verde mora na
    // base, e não na pilha: lá ela perdia o fio de cima, o de baixo e os quatro cantos.
    Color.clear
      .background { glassAndLight(shape: shape, mood: mood, noticeGlow: noticeGlow) }
      .overlay {
        // Só no estágio do aviso (`shown`) e sem "precisa de você" (a luz âmbar de cima já marca).
        if notice.shown && notice.board.isOnlyDone {
          ZStack {
            shape.strokeBorder(Palette.done, lineWidth: noticeBorderWidth)
            if !reduceMotion { BorderShimmer(radius: state.radius, lineWidth: noticeBorderWidth) }
          }
          .transition(.opacity.animation(.easeInOut(duration: 0.2)))
        }
      }
      .environment(\.colorScheme, .dark)
      .allowsHitTesting(false)
  }

  /// O vidro, o preto da ilha, a luz e o fio claro, sem mudança: a pilha se mede como sempre.
  private func glassAndLight(shape: RoundedRectangle, mood: SphereMood, noticeGlow: Color?) -> some View {
    ZStack {
      GlassBackground(cornerRadius: state.radius)
      shape.fill(Color.black).opacity(1 - state.glass)
      // Nas configurações a luz do estado esmaece para 35%, no ritmo do deslize.
      TintGlow(color: noticeGlow ?? mood.glow)
        .opacity(state.tint)
        .opacity(router.route == .settings ? 0.35 : 1)
        .clipShape(shape)
        .animation(.easeInOut(duration: 0.6), value: mood)
        .animation(.easeInOut(duration: 0.6), value: noticeGlow)
        .animation(PanelRouteMotion.animation(reduceMotion: reduceMotion), value: router.route)
    }
    .overlay(shape.strokeBorder(Color.white.opacity(0.3 * (1 - state.glass)), lineWidth: 0.5))
  }
}

/// Espessura da borda verde do aviso "concluído".
private let noticeBorderWidth: CGFloat = 1.5

// MARK: - Camadas de conteúdo

/// Entra com opacidade 140 ms depois de a casca começar a crescer (em 280 ms) e sai em 200 ms.
private struct LayerFade: ViewModifier {
  let shown: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let animation: Animation = reduceMotion
      ? .easeOut(duration: 0.18)
      : shown ? .easeOut(duration: 0.28).delay(0.14) : .easeIn(duration: 0.2)
    content
      .opacity(shown ? 1 : 0)
      .animation(animation, value: shown)
      .allowsHitTesting(shown)
      .accessibilityHidden(!shown)
  }
}

private struct PeekLayer: View {
  @ObservedObject var model: AppModel
  @ObservedObject var usage: UsageController
  @ObservedObject var presentation: PanelPresentation

  var body: some View {
    PeekView(
      store: model.store, usage: usage.status, pendingRequests: model.requests.pending.count, showsBackground: false,
      active: presentation.shown)
      .padding(.top, peekTopInset)
      .fixedSize()
      .modifier(LayerFade(shown: presentation.shown))
  }
}

/// O aviso proativo, preso ao topo como a espiada.
private struct NoticeLayer: View {
  @ObservedObject var presentation: NoticePresentation

  /// O mesmo conteúdo, sem o esmaecer, para medir a altura de um quadro.
  static func measured(_ board: NoticeBoard) -> some View {
    NoticeView(board: board).padding(.top, peekTopInset).fixedSize()
  }

  var body: some View {
    NoticeView(board: presentation.board, onClose: { presentation.onClose() })
      .padding(.top, peekTopInset)
      .fixedSize()
      .environment(\.layerShown, presentation.shown)
      .modifier(LayerFade(shown: presentation.shown))
  }
}

/// O painel e as configurações, um ao lado do outro: com a rota `.settings`, o principal sai para a
/// esquerda (28% da largura) esmaecendo e as configurações entram pela direita. Com Reduzir
/// movimento, só a troca de opacidade.
private struct PanelLayer: View {
  @ObservedObject var model: AppModel
  @ObservedObject var usage: UsageController
  let deck: RequestDeck
  @ObservedObject var presentation: PanelPresentation
  @ObservedObject var router: PanelRouter
  /// Observado pela versão dispensada no × (`dismissedUpdate`).
  @ObservedObject var settings: SettingsStore
  /// Observado pelo estado do plugin (aviso das sessões de antes).
  @ObservedObject var plugin: PluginController
  @ObservedObject var update: UpdateController
  let metrics: MetricsController
  let shownNotices: ShownNotices
  let actions: PanelActions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `CFBundleShortVersionString`; sem bundle (`swift run`), "dev".
  private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

  var body: some View {
    let inSettings = router.route == .settings
    let slides = !reduceMotion
    PanelRouteStack(active: inSettings ? 1 : 0) {
      // A esfera só anima e o hover das linhas só vale enquanto o painel é o estado da ilha e a tela à vista.
      PanelView(
        store: model.store, usage: usage.status, deck: deck,
        active: presentation.shown && !inSettings, showsBackground: false,
        onSelect: { [actions] id in actions.open(id) },
        onDismiss: { [actions] id in actions.dismiss(id) },
        onSettings: { [actions] in actions.showSettings() },
        gearDot: update.announces,
        notice: notice(currentNotice))
        .offset(x: inSettings && slides ? -0.28 * panelWidth : 0)
        .opacity(inSettings ? 0 : 1)
        .allowsHitTesting(!inSettings)
        .accessibilityHidden(inSettings)
      SettingsView(
        settings: settings, plugin: plugin,
        // Sem receptor (versão compilada do código), a chave das métricas não faria nada: some.
        showsMetrics: metrics.endpoint != nil,
        footer: SettingsFooter(
          version: Self.version, updateTo: update.available?.version.description,
          // Volta ao painel, onde o aviso mostra o download.
          onUpdate: { [actions, update] in
            actions.back()
            update.install()
          }),
        onBack: { [actions] in actions.back() },
        onQuit: { [actions] in actions.quit() })
        .offset(x: inSettings || !slides ? 0 : panelWidth)
        .opacity(inSettings || slides ? 1 : 0)
        .allowsHitTesting(inSettings)
        .accessibilityHidden(!inSettings)
        .environment(\.layerShown, presentation.shown && inSettings)
    }
    .animation(PanelRouteMotion.animation(reduceMotion: reduceMotion), value: router.route)
    .padding(.top, panelTopInset)
    .frame(maxHeight: .infinity, alignment: .top)
    .modifier(LayerFade(shown: presentation.shown))
    // O aviso conta como mostrado só com o painel aberto na tela principal.
    .onChange(of: presentation.shown && !inSettings ? currentNotice : nil, initial: true) { _, shown in
      shownNotices.saw(shown)
    }
  }

  /// O aviso no topo do cartão. Com um pedido segurado na ilha, só os da atualização aparecem
  /// (métricas e sessões de antes esperam a fila esvaziar).
  private var currentNotice: TopNotice? {
    let held = !model.requests.pending.isEmpty
    return TopNotices.current(
      phase: update.phase, available: update.available, dismissedUpdate: settings.settings.dismissedUpdate,
      justUpdatedTo: update.justUpdatedTo, metricsDue: !held && metrics.noticeDue,
      pluginSessionsDue: !held && pluginSessionsDue, installCommand: UpdateController.installCommand)
  }

  private func notice(_ current: TopNotice?) -> AnyView? {
    guard let current else { return nil }
    return AnyView(TopNoticeView(
      notice: current,
      onUpdate: { [update] in update.install() },
      // O × de cada aviso: métricas e sessões de antes ficam vistos, "Atualizada" sai, e os da
      // atualização ficam com o `UpdateController`.
      onDismiss: { [settings, update] in
        switch current {
        case .metrics: settings.update { $0.metricsNoticeSeen = true }
        case .pluginSessions: settings.update { $0.pluginNoticeSeen = true }
        case .updated: update.clearJustUpdated()
        case .updateAvailable, .downloading, .restarting, .needsTerminal, .updateFailed: update.dismiss()
        }
      },
      onNotes: { [update] in update.openNotes() },
      downloadingVersion: update.available?.version.description))
  }

  /// Aviso das sessões de antes do plugin: o plugin acabou de entrar (nesta abertura) e há sessões
  /// abertas sem ele (só aparecem por completo depois de reabertas).
  private var pluginSessionsDue: Bool {
    !settings.settings.pluginNoticeSeen && plugin.freshlyInstalled && plugin.status == .installed
      && model.store.sessions.values.contains { !$0.hooked }
  }
}

/// Os avisos que o painel mostrou desde a última volta à ilha (só os que viram "vistos" ao fechar).
@MainActor
final class ShownNotices {
  enum Kind: Hashable { case metrics, pluginSessions, updated }
  private var kinds: Set<Kind> = []

  func saw(_ notice: TopNotice?) {
    switch notice {
    case .metrics: kinds.insert(.metrics)
    case .pluginSessions: kinds.insert(.pluginSessions)
    case .updated: kinds.insert(.updated)
    default: break
    }
  }

  /// Devolve e esquece.
  func drain() -> Set<Kind> {
    defer { kinds = [] }
    return kinds
  }
}

/// Hospeda uma camada de conteúdo e avisa quando o tamanho ideal muda.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
  var onIntrinsicSizeChange: (() -> Void)?

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    onIntrinsicSizeChange?()
  }

  /// O primeiro clique já vale, mesmo com o app inativo (a janela nunca ativa o app).
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Liga e desliga uma camada de conteúdo.
@MainActor
final class PanelPresentation: ObservableObject {
  @Published var shown = false
}

/// O que o painel faz ao tocar numa linha, na engrenagem e nas configurações; ligado depois do `init`.
@MainActor
final class PanelActions {
  var open: (String) -> Void = { _ in }
  /// "Remover da ilha" no clique direito de uma linha.
  var dismiss: (String) -> Void = { _ in }
  /// Engrenagem: desliza até as configurações.
  var showSettings: () -> Void = {}
  /// "‹ Voltar" nas configurações.
  var back: () -> Void = {}
  /// "Sair da Work Island" no rodapé das configurações.
  var quit: () -> Void = {}
}
