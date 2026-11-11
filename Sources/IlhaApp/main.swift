import AppKit

// `--uninstall`: tratado antes de qualquer janela ou da ilha. Tira o item de início e o plugin e sai.
// Não chama `ensureInstalled`. Limpa também `installedPluginVersion`: se a pasta de dados sobreviver
// (app apagado sem o script), uma nova instalação não pode achar que o plugin ainda está lá.
if CommandLine.arguments.contains("--uninstall") {
  LoginItem.set(false)
  await PluginController.uninstall()
  let store = SettingsStore()
  store.update { $0.installedPluginVersion = nil }
  exit(0)
}

// App de barra de menu: sem ícone no Dock e sem roubar o foco (nunca chama `activate`).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let settings = SettingsStore()
// Primeira abertura: registra o item de início. Lê `lastRunVersion` ANTES de qualquer gravação dele;
// a gravação de `lastRunVersion` (a cada abertura) tem de ficar DEPOIS desta checagem.
if settings.settings.lastRunVersion == nil, settings.settings.openAtLogin {
  if !LoginItem.set(true) { settings.update { $0.openAtLogin = false } }
}
// Toda abertura: com a escolha ligada e o item sumido do sistema (ex. app trocado na atualização),
// registra de novo. Só `.notRegistered`: "precisa de aprovação" é escolha de quem usa, em Ajustes.
if settings.settings.openAtLogin, LoginItem.isNotRegistered {
  LoginItem.set(true)
}
// Métricas anônimas: só com receptor no Info.plist (versões do `release.sh`) e a chave ligada.
// Ligadas às mudanças de preferência só depois da checagem de primeira abertura (que não é escolha sua).
let metrics = MetricsController(settings: settings)
settings.onChange = { key, value in metrics.settingChanged(key, value: value) }
let model = AppModel()
model.dormantAfter = { settings.settings.dormant.interval }
let usage = UsageController()
// Instala ou atualiza o plugin do Claude Code (sem retentativa automática); o estado aparece nas configurações.
let plugin = PluginController(settings: settings)
// Atualização pela própria ilha. O `start` grava `lastRunVersion`: fica depois da checagem de
// primeira abertura lá em cima.
let update = UpdateController(settings: settings, model: model)
let statusItemController = StatusItemController(
  model: model, usage: usage, settings: settings, plugin: plugin, update: update, metrics: metrics)
model.onTurnEnded = { usage.trigger(.turnEnded) }
model.onAnswered = { request, outcome in metrics.answered(request, outcome) }
// Antes do `update.start()`: é ele que avisa a atualização, uma vez, na abertura.
update.onUpdated = { from, to in metrics.updated(from: from, to: to) }
model.start()
usage.start()
update.start()
metrics.start()
Task { await plugin.ensureInstalled() }

// "Sair da Work Island" passa por `terminate`, que avisa aqui antes de sair: o socket é removido.
let terminationObserver = NotificationCenter.default.addObserver(
  forName: NSApplication.willTerminateNotification, object: nil, queue: .main
) { _ in
  MainActor.assumeIsolated {
    model.stop()
    usage.stop()
    metrics.flush()
  }
}

// `kill` (SIGTERM) e Ctrl-C (SIGINT) não passam por `terminate`: o mesmo encerramento limpo, depois sai.
let signalSources = [SIGTERM, SIGINT].map { number in
  signal(number, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
  source.setEventHandler {
    MainActor.assumeIsolated {
      model.stop()
      usage.stop()
      metrics.flush()
    }
    exit(0)
  }
  source.resume()
  return source
}

app.run()
