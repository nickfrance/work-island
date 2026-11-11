import AppKit
import SwiftUI
import IlhaCore

/// Entrada do aviso no topo do cartão: desce do topo e acende em 0,45 s, na curva do deslize das
/// telas (`cubic-bezier(.32,.72,0,1)`). Com Reduzir movimento, só a opacidade, curta.
enum NoticeMotion {
  static let enter: Animation = .timingCurve(0.32, 0.72, 0, 1, duration: 0.45)
  static let fade: Animation = .easeOut(duration: 0.2)

  static func animation(reduceMotion: Bool) -> Animation { reduceMotion ? fade : enter }

  static func transition(reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
  }
}

/// O aviso no topo do cartão (`atualizacao.html`, opção A): uma pílula a 10 pt das bordas, cantos de
/// 14 pt, branco a 8% com fio a 14%. Círculo de 26 pt à esquerda, título de 12,5 pt e linha de
/// 10,5 pt a 50%, botão branco e um × de 20 pt à direita. Só aparece no painel (a espiada é outra view).
struct TopNoticeView: View {
  let notice: TopNotice
  /// "Atualizar".
  let onUpdate: () -> Void
  /// O ×.
  let onDismiss: () -> Void
  /// "O que mudou ↗".
  let onNotes: () -> Void
  /// A versão que está baixando ("Baixando a 0.4.0…"); sem ela, "Baixando a versão nova…".
  var downloadingVersion: String?
  /// A versão que roda agora ("Você está na 0.3.0").
  var currentVersion: String = TopNoticeView.bundleVersion

  /// `CFBundleShortVersionString`; sem bundle (`swift run`), "dev".
  static let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    // O botão fica na linha, como no mockup, quando os textos cabem inteiros ao lado dele; senão
    // ("Work Island 0.4.0 disponível" não cabe) desce para baixo dos textos.
    ViewThatFits(in: .horizontal) {
      layout(buttonInline: true)
      layout(buttonInline: false)
    }
    .padding(.vertical, 9)
    .padding(.leading, 12)
    .padding(.trailing, 10)
    .background(shape.fill(Color.white.opacity(0.08)))
    .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
    .padding(.horizontal, 10)
    .padding(.top, 10)
    // Trocar de aviso (versão nova → baixando → reiniciando) só esmaece o miolo.
    .animation(.easeOut(duration: 0.2), value: notice)
  }

  private func layout(buttonInline: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: tall ? .top : .center, spacing: 10) {
        NoticeIcon(kind: icon)
        texts
          .frame(maxWidth: .infinity, alignment: .leading)
        if buttonInline { button }
        if dismissible { DismissButton(action: onDismiss) }
      }
      // O comando longo do Terminal não decide se o botão cabe na linha de cima.
      FillWidth { extra }
        // Alinhado com os textos: círculo (26) + espaço (10).
        .padding(.leading, 36)
      if !buttonInline {
        button
          .padding(.top, 7)
          .padding(.leading, 36)
      }
    }
  }

  /// Avisos de mais de uma linha alinham pelo topo; os curtos, pelo centro, como no mockup.
  private var tall: Bool {
    switch notice {
    case .metrics, .pluginSessions, .needsTerminal: return true
    default: return false
    }
  }

  private var icon: NoticeIcon.Kind {
    switch notice {
    case .updateAvailable: return .symbol("arrow.down")
    case .downloading, .restarting: return .spinner
    case .updated: return .done
    case .updateFailed: return .symbol("exclamationmark")
    case .needsTerminal: return .symbol("terminal")
    case .metrics: return .symbol("chart.bar.fill")
    case .pluginSessions: return .symbol("arrow.clockwise")
    }
  }

  @ViewBuilder private var texts: some View {
    VStack(alignment: .leading, spacing: 1) {
      switch notice {
      case .updateAvailable(let info, _):
        NoticeTitle(L10n.string("notice.available.title", info.version.description))
        HStack(spacing: 0) {
          NoticeDetail(L10n.string("notice.available.current", currentVersion) + " · ")
          NotesLink(action: onNotes)
        }
      case .downloading(let progress):
        NoticeTitle(downloadingVersion.map { L10n.string("notice.downloading", $0) }
          ?? L10n.string("notice.downloading.unknown"))
        ProgressBar(progress: progress)
          .padding(.top, 5)
      case .restarting:
        NoticeTitle(L10n.string("notice.restarting.title"))
        NoticeDetail(L10n.string("notice.restarting.detail"))
      case .updated(let version):
        NoticeTitle(L10n.string("notice.updated", version))
        NotesLink(action: onNotes)
      case .updateFailed:
        NoticeTitle(L10n.string("notice.failed.title"))
        NoticeDetail(L10n.string("notice.failed.detail"))
      case .needsTerminal:
        NoticeTitle(L10n.string("notice.terminal.title"))
      case .metrics:
        NoticeTitle(L10n.string("notice.metrics.title"))
        NoticeDetail(L10n.string("notice.metrics.detail"))
      case .pluginSessions:
        NoticeTitle(L10n.string("notice.pluginSessions.title"))
        NoticeDetail(L10n.string("notice.pluginSessions.detail"))
      }
    }
  }

  /// O botão branco: "Atualizar" na versão nova, "Copiar" no Terminal.
  @ViewBuilder private var button: some View {
    switch notice {
    case .updateAvailable(_, false):
      WhiteButton(title: L10n.string("notice.update"), action: onUpdate)
    case .needsTerminal(let command):
      CopyButton(command: command)
    default:
      EmptyView()
    }
  }

  /// O ×. Não aparece enquanto baixa ou reinicia, nem esperando a resposta: o usuário já pediu.
  private var dismissible: Bool {
    switch notice {
    case .downloading, .restarting, .updateAvailable(_, true): return false
    default: return true
    }
  }

  /// O que vem embaixo da linha principal: o recado da espera ou o comando do Terminal.
  @ViewBuilder private var extra: some View {
    switch notice {
    case .updateAvailable(_, true):
      Text(verbatim: L10n.string("notice.waiting"))
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.75))
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .padding(.top, 7)
    case .needsTerminal(let command):
      Text(verbatim: command)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.75))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.28)))
        .padding(.top, 7)
    default:
      EmptyView()
    }
  }
}

/// Ocupa a largura oferecida sem pedir nenhuma: no tamanho ideal (o que o `ViewThatFits` mede),
/// a largura é zero.
private struct FillWidth: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 0
    let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews {
      subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
  }
}

/// Título do aviso: 12,5 pt semibold.
private struct NoticeTitle: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(verbatim: text)
      .font(.system(size: 12.5, weight: .semibold))
      .foregroundStyle(Color(white: 0.96))
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Linha de baixo: 10,5 pt, branco a 50%.
private struct NoticeDetail: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(verbatim: text)
      .font(.system(size: 10.5))
      .foregroundStyle(Color.white.opacity(0.5))
      .lineSpacing(1.5)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// O círculo de 26 pt: branco a 12% com o símbolo branco; verde no "Atualizada"; um arco girando
/// enquanto baixa ou reinicia.
private struct NoticeIcon: View {
  enum Kind: Equatable { case symbol(String), spinner, done }
  let kind: Kind

  var body: some View {
    let ok = kind == .done
    ZStack {
      Circle().fill(ok ? Palette.done.opacity(0.22) : Color.white.opacity(0.12))
      switch kind {
      case .symbol(let name):
        Image(systemName: name)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.white)
      case .done:
        Image(systemName: "checkmark")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(Palette.done)
      case .spinner:
        Spinner()
      }
    }
    .frame(width: 26, height: 26)
    .accessibilityHidden(true)
  }
}

/// Três quartos de círculo dando uma volta por segundo; parado com a camada fora da tela ou
/// com Reduzir movimento.
private struct Spinner: View {
  @Environment(\.layerShown) private var layerShown
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !layerShown || reduceMotion)) { context in
      let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
      Circle()
        .trim(from: 0, to: 0.75)
        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        .frame(width: 11, height: 11)
        .rotationEffect(.degrees(turn * 360))
    }
  }
}

/// Barra de 3 pt: branco a 12% com o progresso em branco.
private struct ProgressBar: View {
  let progress: Double

  var body: some View {
    let fraction = CGFloat(min(1, max(0, progress)))
    RoundedRectangle(cornerRadius: 2)
      .fill(Color.white.opacity(0.12))
      .frame(height: 3)
      .overlay(alignment: .leading) {
        GeometryReader { geometry in
          RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: geometry.size.width * fraction)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 2))
      .animation(.linear(duration: 0.25), value: fraction)
      .accessibilityElement()
      .accessibilityValue(Text(verbatim: "\(Int((fraction * 100).rounded()))%"))
  }
}

/// "O que mudou ↗": 10,5 pt, branco a 75% que acende no hover.
private struct NotesLink: View {
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.layerShown) private var layerShown

  var body: some View {
    Button(action: action) {
      Text(verbatim: L10n.string("notice.whatsNew"))
        .font(.system(size: 10.5))
        .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.75))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onChange(of: layerShown) { _, shown in
      if !shown { hovering = false }
    }
  }
}

/// Botão branco em pílula ("Atualizar", "Copiar"): 11,5 pt semibold, texto preto.
private struct WhiteButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(verbatim: title)
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(Color.black)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white))
        .contentShape(Capsule())
    }
    .buttonStyle(PressStyle())
  }
}

/// "Copiar": põe o comando na área de transferência e mostra "Copiado" por 1,5 s.
private struct CopyButton: View {
  let command: String
  @State private var copied = false

  var body: some View {
    WhiteButton(title: L10n.string(copied ? "notice.terminal.copied" : "notice.terminal.copy")) {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(command, forType: .string)
      copied = true
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.5))
        copied = false
      }
    }
  }
}

/// O × de 20 pt: branco a 40%, que acende sobre um círculo branco a 10% no hover.
private struct DismissButton: View {
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.layerShown) private var layerShown

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.4))
        .frame(width: 20, height: 20)
        .background(Circle().fill(Color.white.opacity(hovering ? 0.1 : 0)))
        .contentShape(Circle())
    }
    .buttonStyle(PressStyle())
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onChange(of: layerShown) { _, shown in
      if !shown { hovering = false }
    }
    .help(Text(verbatim: L10n.string("notice.dismiss")))
    .accessibilityLabel(Text(verbatim: L10n.string("notice.dismiss")))
  }
}

/// Encolhe um pouco ao apertar.
private struct PressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
  }
}
