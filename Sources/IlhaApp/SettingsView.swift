import AppKit
import SwiftUI
import IlhaCore

/// O rodapé das configurações: a versão à esquerda (ou, com versão nova, o botão de atualizar).
struct SettingsFooter {
  let version: String
  /// Versão nova disponível ("Atualizar para %@" no lugar da versão); `nil` sem novidade.
  let updateTo: String?
  let onUpdate: () -> Void
}

/// A tela de configurações dentro do cartão, como no mockup `configuracoes.html`: barra com
/// "‹ Voltar", grupos Geral / Sessões / Claude Code e o rodapé com a versão e "Sair".
/// Tem a altura do próprio conteúdo: o cartão cresce ou encolhe até ela.
struct SettingsView: View {
  @ObservedObject var settings: SettingsStore
  @ObservedObject var plugin: PluginController
  /// A linha "Enviar métricas de uso anônimas" (escondida quando a versão não tem receptor).
  let showsMetrics: Bool
  let footer: SettingsFooter
  let onBack: () -> Void
  let onQuit: () -> Void
  /// A tela à vista (o cartão aberto nas configurações).
  @Environment(\.layerShown) private var layerShown

  init(
    settings: SettingsStore, plugin: PluginController, showsMetrics: Bool = true, footer: SettingsFooter,
    onBack: @escaping () -> Void, onQuit: @escaping () -> Void
  ) {
    self.settings = settings
    self.plugin = plugin
    self.showsMetrics = showsMetrics
    self.footer = footer
    self.onBack = onBack
    self.onQuit = onQuit
  }

  var body: some View {
    VStack(spacing: 0) {
      SettingsNavBar(onBack: onBack)
      general
      sessions
      notices
      claudeCode
      Spacer(minLength: 18)
      SettingsFooterBar(footer: footer, onQuit: onQuit)
    }
    .frame(width: panelWidth, alignment: .top)
    // Sempre na altura ideal: saindo de cena com o cartão mais baixo, nada se espreme.
    .fixedSize(horizontal: false, vertical: true)
    .foregroundStyle(Color(white: 0.96))
    .environment(\.colorScheme, .dark)
    // A chave "Abrir ao ligar o Mac" mostra o que o sistema diz (pode ter sido desligado em Ajustes).
    .onChange(of: layerShown, initial: true) { _, shown in
      guard shown else { return }
      let real = LoginItem.isEnabled
      if settings.settings.openAtLogin != real { settings.update(silently: true) { $0.openAtLogin = real } }
    }
  }

  // MARK: - Grupos

  private var general: some View {
    SettingsGroup(title: L10n.string("settings.group.general")) {
      SettingsItem(title: L10n.string("settings.openAtLogin")) {
        Toggle(isOn: openAtLogin) { EmptyView() }
          .toggleStyle(IslandSwitchStyle())
          .accessibilityLabel(Text(verbatim: L10n.string("settings.openAtLogin")))
      }
      if showsMetrics {
        SettingsDivider()
        SettingsItem(
          title: L10n.string("settings.metrics"), detail: L10n.string("settings.metrics.detail")
        ) {
          Toggle(isOn: metrics) { EmptyView() }
            .toggleStyle(IslandSwitchStyle())
            .accessibilityLabel(Text(verbatim: L10n.string("settings.metrics")))
        }
      }
    }
  }

  private var sessions: some View {
    SettingsGroup(title: L10n.string("settings.group.sessions")) {
      SettingsItem(title: L10n.string("settings.dormant"), detail: L10n.string("settings.dormant.detail")) {
        EmptyView()
      }
      DormantPicker(selection: dormant)
        .padding(.horizontal, 12)
        .padding(.bottom, 11)
    }
  }

  private var notices: some View {
    SettingsGroup(title: L10n.string("settings.group.notices")) {
      SettingsItem(
        title: L10n.string("settings.notice.needsYou"), detail: L10n.string("settings.notice.detail")
      ) {
        Toggle(isOn: noticeNeedsYou) { EmptyView() }
          .toggleStyle(IslandSwitchStyle())
          .accessibilityLabel(Text(verbatim: L10n.string("settings.notice.needsYou")))
      }
      SettingsDivider()
      SettingsItem(title: L10n.string("settings.notice.done")) {
        Toggle(isOn: noticeDone) { EmptyView() }
          .toggleStyle(IslandSwitchStyle())
          .accessibilityLabel(Text(verbatim: L10n.string("settings.notice.done")))
      }
    }
  }

  private var claudeCode: some View {
    SettingsGroup(title: L10n.string("settings.group.claudeCode")) {
      SettingsItem(title: L10n.string("settings.plugin"), detail: L10n.string("settings.plugin.detail")) {
        PluginStatusView(status: plugin.status) {
          // Um toque por vez: com a instalação em curso (`.checking`), o segundo toque não faz nada.
          Task { @MainActor [plugin] in
            guard plugin.status != .checking else { return }
            await plugin.reinstall()
          }
        }
      }
    }
  }

  // MARK: - Ligações com as preferências

  /// Liga ou desliga o item de início e grava o estado que o sistema confirmou (pode recusar).
  private var openAtLogin: Binding<Bool> {
    Binding(
      get: { settings.settings.openAtLogin },
      set: { on in
        LoginItem.set(on)
        let real = LoginItem.isEnabled
        settings.update { $0.openAtLogin = real }
      })
  }

  private var metrics: Binding<Bool> {
    Binding(
      get: { settings.settings.metricsEnabled },
      set: { on in settings.update { $0.metricsEnabled = on } })
  }

  private var noticeNeedsYou: Binding<Bool> {
    Binding(
      get: { settings.settings.noticeNeedsYou },
      set: { on in settings.update { $0.noticeNeedsYou = on } })
  }

  private var noticeDone: Binding<Bool> {
    Binding(
      get: { settings.settings.noticeDone },
      set: { on in settings.update { $0.noticeDone = on } })
  }

  private var dormant: Binding<DormantChoice> {
    Binding(
      get: { settings.settings.dormant },
      set: { choice in settings.update { $0.dormant = choice } })
  }
}

// MARK: - Barra de cima

/// 52 pt: "‹ Voltar" à esquerda, o título centralizado no cartão e um fio embaixo.
private struct SettingsNavBar: View {
  let onBack: () -> Void

  var body: some View {
    ZStack {
      Text(verbatim: L10n.string("settings.title"))
        .font(.system(size: 14, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      HStack(spacing: 0) {
        BackButton(action: onBack)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
    }
    .frame(height: 52)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
    }
  }
}

private struct BackButton: View {
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.layerShown) private var layerShown

  var body: some View {
    Button(action: action) {
      HStack(spacing: 2) {
        Image(systemName: "chevron.left")
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 16, height: 16)
        Text(verbatim: L10n.string("settings.back"))
          .font(.system(size: 13))
      }
      .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.7))
      .padding(.vertical, 6)
      .padding(.leading, 4)
      .padding(.trailing, 8)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Color.white.opacity(hovering ? 0.08 : 0)))
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.2), value: hovering)
    .onChange(of: layerShown) { _, shown in
      if !shown { hovering = false }
    }
  }
}

// MARK: - Grupos e linhas

/// Rótulo em versalete cinza e a caixa das linhas (branco a 4,5%, cantos de 14 pt, fio de 8%).
private struct SettingsGroup<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      Text(verbatim: title.uppercased())
        .font(.system(size: 10.5, weight: .semibold))
        .kerning(0.4)
        .foregroundStyle(Color.white.opacity(0.38))
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) { content }
        .background(shape.fill(Color.white.opacity(0.045)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }
    .padding(.horizontal, 14)
    .padding(.top, 14)
  }
}

/// Uma linha: o texto (com a explicação embaixo, se houver) e o controle à direita.
private struct SettingsItem<Accessory: View>: View {
  let title: String
  var detail: String?
  @ViewBuilder let accessory: Accessory

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
          .font(.system(size: 12.5))
        if let detail {
          Text(verbatim: detail)
            .font(.system(size: 10.5))
            .foregroundStyle(Color.white.opacity(0.42))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      accessory
    }
    .frame(minHeight: 22)
    .padding(.vertical, 11)
    .padding(.horizontal, 12)
    .accessibilityElement(children: .contain)
  }
}

private struct SettingsDivider: View {
  var body: some View {
    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
  }
}

// MARK: - Controles

/// A chave do mockup: 34 × 20, verde `#34C759` ligada, branco a 18% desligada, bolinha de 16 pt.
private struct IslandSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      Capsule()
        .fill(configuration.isOn ? Palette.done : Color.white.opacity(0.18))
        .frame(width: 34, height: 20)
        .overlay(alignment: .leading) {
          Circle()
            .fill(Color.white)
            .frame(width: 16, height: 16)
            .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
            .offset(x: configuration.isOn ? 16 : 2)
        }
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .animation(.timingCurve(0.32, 0.72, 0, 1, duration: 0.22), value: configuration.isOn)
    .accessibilityRepresentation {
      Toggle(isOn: configuration.$isOn) { configuration.label }
    }
  }
}

/// 6 h · 12 h · 24 h · Nunca: o controle segmentado do mockup.
private struct DormantPicker: View {
  @Binding var selection: DormantChoice

  var body: some View {
    HStack(spacing: 2) {
      ForEach(DormantChoice.allCases, id: \.self) { choice in
        let on = choice == selection
        Button { selection = choice } label: {
          Text(verbatim: Self.label(choice))
            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.white : Color.white.opacity(0.6))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(on ? 0.16 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
    .padding(2)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
    .animation(.easeOut(duration: 0.18), value: selection)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: L10n.string("settings.dormant")))
  }

  private static func label(_ choice: DormantChoice) -> String {
    switch choice {
    case .h6: return L10n.string("settings.dormant.h6")
    case .h12: return L10n.string("settings.dormant.h12")
    case .h24: return L10n.string("settings.dormant.h24")
    case .never: return L10n.string("settings.dormant.never")
    }
  }
}

/// À direita do plugin: instalado (verde), conferindo, Claude Code ausente ou a falha (as duas com o botão).
private struct PluginStatusView: View {
  let status: PluginController.Status
  let onReinstall: () -> Void

  var body: some View {
    switch status {
    case .installed:
      Text(verbatim: L10n.string("settings.plugin.installed"))
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Palette.done)
    case .checking:
      Text(verbatim: L10n.string("settings.plugin.checking"))
        .font(.system(size: 11.5))
        .foregroundStyle(Color.white.opacity(0.42))
    case .claudeMissing:
      // Com o botão também: o Claude Code pode ter sido instalado depois da abertura do app.
      VStack(alignment: .trailing, spacing: 6) {
        Text(verbatim: L10n.string("settings.plugin.claudeMissing"))
          .font(.system(size: 11.5))
          .foregroundStyle(Color.white.opacity(0.55))
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 110, alignment: .trailing)
          .fixedSize(horizontal: false, vertical: true)
        ReinstallButton(action: onReinstall)
      }
    case .failed(let reason):
      VStack(alignment: .trailing, spacing: 6) {
        Text(verbatim: L10n.string("settings.plugin.failed"))
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(Palette.needsYou)
          .help(reason)
        // Some assim que a reinstalação começa (`.checking`); o toque repetido antes disso é barrado
        // no próprio `onReinstall`.
        ReinstallButton(action: onReinstall)
      }
    }
  }
}

/// "Instalar de novo", no feitio do `.kbd` do mockup, um pouco mais claro por ser um botão.
private struct ReinstallButton: View {
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Text(verbatim: L10n.string("settings.plugin.reinstall"))
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.75))
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.white.opacity(hovering ? 0.14 : 0.08)))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize()
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.2), value: hovering)
  }
}

// MARK: - Rodapé

private struct SettingsFooterBar: View {
  let footer: SettingsFooter
  let onQuit: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      if let next = footer.updateTo {
        FooterLink(title: L10n.string("settings.updateTo", next), action: footer.onUpdate)
      } else {
        Text(verbatim: L10n.string("settings.version", footer.version))
          .foregroundStyle(Color.white.opacity(0.38))
      }
      Spacer(minLength: 8)
      FooterLink(title: L10n.string("settings.quit"), action: onQuit)
    }
    .font(.system(size: 11))
    .padding(.vertical, 12)
    .padding(.horizontal, 18)
    .overlay(alignment: .top) {
      Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
    }
  }
}

/// Texto clicável do rodapé: branco a 62%, branco no hover.
private struct FooterLink: View {
  let title: String
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.layerShown) private var layerShown

  var body: some View {
    Button(action: action) {
      Text(verbatim: title)
        .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.62))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onChange(of: layerShown) { _, shown in
      if !shown { hovering = false }
    }
  }
}
