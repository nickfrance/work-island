import SwiftUI
import IlhaCore

/// Largura do aviso: compacto, menor que a espiada.
let noticeWidth: CGFloat = 268

/// O × do aviso: no canto de cima à direita, centrado na primeira linha. Os números servem à view e
/// ao clique da `IslandWindow` (que trata os cliques do aviso antes do conteúdo).
enum NoticeClose {
  /// Lado do botão (o círculo do hover).
  static let size: CGFloat = 22
  /// Do topo da `NoticeView` ao topo do botão: o centro dele fica na altura da primeira linha.
  static let top: CGFloat = 7
  /// Da borda direita do aviso à borda direita do botão.
  static let trailing: CGFloat = 7
  /// Espaço que a linha de cima (nome e estado) de cada linha do aviso deixa à direita para o ×,
  /// além dos 12 pt da margem: o estado nunca fica embaixo dele, e a coluna do estado segue
  /// alinhada entre as linhas.
  static let reserve: CGFloat = 21
  /// Folga do alvo do clique em volta do botão (alvo de ~28 pt, como a engrenagem do painel).
  static let slop: CGFloat = 3

  /// Onde o clique fecha o aviso, com o topo da `NoticeView` a `topInset` do topo da camada
  /// (coordenadas com y para baixo, origem no canto de cima à esquerda).
  static func hitRect(topInset: CGFloat) -> CGRect {
    CGRect(x: noticeWidth - trailing - size, y: topInset + top, width: size, height: size)
      .insetBy(dx: -slop, dy: -slop)
  }
}

/// O que o aviso mostra e se ele é o estado da ilha agora. Quem preenche o quadro é o
/// `StatusItemController`; a casca (`IslandWindow`) liga e desliga a camada.
@MainActor
final class NoticePresentation: ObservableObject {
  @Published var board = NoticeBoard()
  @Published var shown = false
  /// × do aviso (pelo leitor de tela; o clique do mouse chega pela `IslandWindow`).
  var onClose: () -> Void = {}
}

/// Aviso proativo (B2): uma linha por novidade, com o ponto e o nome da sessão, o estado à direita
/// na cor dele e, embaixo, menor, a pergunta, o pedido de permissão ou onde a sessão roda. Mais de
/// três novidades viram "+N" na última linha. No canto de cima à direita, o × fecha o aviso. O fundo
/// (vidro, luz de cima e a borda verde do "concluído") é da casca.
struct NoticeView: View {
  let board: NoticeBoard
  var onClose: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(board.visible.enumerated()), id: \.element.sessionID) { index, entry in
        if index > 0 {
          Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5)
            .padding(.vertical, 7)
        }
        NoticeRow(entry: entry)
      }
      if board.overflow > 0 {
        Text(verbatim: L10n.string("notice.more", board.overflow))
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(Color.white.opacity(0.4))
          // Na coluna do título (ponto de 7 pt e 8 pt de espaço).
          .padding(.leading, 15)
          .padding(.top, 7)
      }
    }
    // Do lado e embaixo como a espiada; em cima, os mesmos 11 pt dela, para o texto começar 12 pt
    // abaixo do lugar da ilha.
    .padding(EdgeInsets(top: 11, leading: 12, bottom: 9, trailing: 12))
    .frame(width: noticeWidth, alignment: .leading)
    .overlay(alignment: .topTrailing) {
      NoticeCloseButton(action: onClose)
        .padding(.top, NoticeClose.top)
        .padding(.trailing, NoticeClose.trailing)
    }
    .environment(\.colorScheme, .dark)
  }
}

/// O × no estilo da engrenagem do painel: branco a 42% que acende no hover, num círculo que aparece
/// junto; menor que ela (o aviso tem ~50 pt de altura por linha).
private struct NoticeCloseButton: View {
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.layerShown) private var layerShown

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(Color.white.opacity(hovering ? 0.9 : 0.42))
        .frame(width: NoticeClose.size, height: NoticeClose.size)
        .background(Circle().fill(Color.white.opacity(hovering ? 0.09 : 0)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.2), value: hovering)
    .onChange(of: layerShown) { _, shown in
      if !shown { hovering = false }
    }
    .help(Text(verbatim: L10n.string("notice.close")))
    .accessibilityLabel(Text(verbatim: L10n.string("notice.close")))
  }
}

private struct NoticeRow: View {
  let entry: NoticeEntry

  var body: some View {
    let state = entry.kind.sessionState
    HStack(alignment: .top, spacing: 8) {
      StateDot(state: state, animated: false)
        // Centro do ponto na altura da primeira linha (como na linha da espiada).
        .padding(.top, 4.5)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(verbatim: entry.title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(white: 0.96))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(verbatim: L10n.state(entry.kind == .needsYou ? .needsYou : .done))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.color(for: state))
            .lineLimit(1)
            // O estado nunca é cortado; quem cede espaço é o título.
            .fixedSize()
        }
        // A coluna do ×: o estado da primeira linha nunca fica embaixo dele.
        .padding(.trailing, NoticeClose.reserve)
        Text(verbatim: detail)
          .font(.system(size: 10.5))
          .foregroundStyle(Color.white.opacity(0.4))
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var detail: String {
    switch entry.detail {
    case .question(let text): return "“\(text)”"
    case .permission(let command): return L10n.string("notice.permission", command)
    case .place(let place): return place
    }
  }
}

extension NoticeKind {
  /// O estado da sessão que o aviso conta (cor do ponto, do estado e da luz).
  var sessionState: SessionState { self == .needsYou ? .needsYou : .done }

  /// Luz de cima da casca durante o aviso: âmbar ou verde.
  var glow: Color { Palette.color(for: sessionState) }
}
