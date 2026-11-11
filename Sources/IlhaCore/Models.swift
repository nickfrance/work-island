import Foundation

public enum Host: String, Codable, Sendable {
    case desktop, vscode, terminal, unknown

    public init(entrypoint: String?) {
        switch entrypoint {
        case "claude-desktop": self = .desktop
        case "claude-vscode": self = .vscode
        case "cli": self = .terminal
        default: self = .unknown
        }
    }

    /// Em ordem de preferência: quando a ilha precisa escolher um app do tipo, vale o primeiro.
    public var bundleIdentifiers: [String] {
        switch self {
        case .desktop:
            return ["com.anthropic.claudefordesktop"]
        case .vscode:
            return ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.google.antigravity"]
        case .terminal:
            return ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]
        case .unknown:
            return []
        }
    }

    public var label: String {
        switch self {
        case .desktop: return "Claude"
        case .vscode: return "VS Code"
        case .terminal: return "Terminal"
        case .unknown: return ""
        }
    }
}

public enum SessionState: String, Codable, Sendable {
    case working, needsYou, done, doneStale, idle
}

public struct Session: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var cwd: String
    public var host: Host
    public var pid: Int32?
    public var state: SessionState
    public var doneSince: Date?
    public var updatedAt: Date
    /// Quando a sessão apareceu na ilha; ordena os sufixos "·2" (estáveis pela vida da sessão).
    public var createdAt: Date
    /// Quando `state` mudou pela última vez; ordena as etiquetas dentro de cada estado.
    public var stateSince: Date
    /// Pasta que dá o nome da etiqueta, fixada na criação (`CLAUDE_PROJECT_DIR` ou o primeiro `cwd`).
    /// Um `cd` depois muda `cwd`, nunca o nome. Vazia até a primeira pasta conhecida.
    public var projectDir: String
    /// `false` em execuções roteirizadas (`CLAUDE_CODE_SESSION_ATTENDED=0`): aparecem, mas não chamam atenção.
    public var attended: Bool?
    /// Transcrição da sessão (`transcript_path` dos eventos, ou achada pelo id ao semear).
    public var transcriptPath: String?
    /// Título da transcrição (`custom-title`, senão `ai-title`); `nil` até o Claude Code gravar um.
    public var title: String?
    /// Primeira mensagem útil, já em uma linha: o título enquanto a transcrição não tem um.
    public var firstPrompt: String?
    /// O último `Stop` deixou tarefa em segundo plano rodando: a sessão segue trabalhando, e nem o
    /// registro do Claude Code ("ocioso", até `staleAfter` depois de `holdSince`) nem um `idle_prompt`
    /// a levam a `idle`. As bordas de turno e o próximo `Stop` desligam.
    public var backgroundHold: Bool
    /// Quando a espera por tarefa em segundo plano começou (o `Stop` que a ligou); `nil` sem espera.
    /// Passados `staleAfter` dela, o registro do Claude Code volta a poder levar a sessão a `idle`.
    public var holdSince: Date?
    /// Já chegou algum evento do plugin desta sessão. Sem ele, só o registro do Claude Code diz o que
    /// ela está fazendo, e o fim de turno que o registro mostra é a única notícia de "concluído".
    public var hooked: Bool
    /// `needsYou` porque o turno acabou com uma pergunta escrita (não um diálogo do Claude Code): o
    /// "ocioso" do registro e o `idle_prompt` não a tiram; só uma resposta (ou o turno seguinte). Desliga
    /// sozinho quando a sessão sai de `needsYou`.
    public var askedInText: Bool

    public init(
        id: String,
        cwd: String,
        host: Host,
        pid: Int32? = nil,
        state: SessionState,
        doneSince: Date? = nil,
        updatedAt: Date,
        createdAt: Date? = nil,
        stateSince: Date? = nil,
        projectDir: String? = nil,
        attended: Bool? = nil,
        transcriptPath: String? = nil,
        title: String? = nil,
        backgroundHold: Bool = false,
        holdSince: Date? = nil,
        hooked: Bool = false,
        askedInText: Bool = false
    ) {
        self.id = id
        self.cwd = cwd
        self.host = host
        self.pid = pid
        self.state = state
        self.doneSince = doneSince
        self.updatedAt = updatedAt
        self.createdAt = createdAt ?? updatedAt
        self.stateSince = stateSince ?? updatedAt
        self.projectDir = projectDir ?? cwd
        self.attended = attended
        self.transcriptPath = transcriptPath
        self.title = title
        self.backgroundHold = backgroundHold
        self.holdSince = holdSince
        self.hooked = hooked
        self.askedInText = askedInText
    }

    // Decodificação à mão: `state.json` gravado antes de `backgroundHold`/`holdSince`/`hooked` existirem não
    // tem as chaves. Campo novo em `Session` tem de entrar aqui também (com `decodeIfPresent` e um
    // padrão), senão some na volta do disco; o teste de ida e volta em ModelsTests pega o esquecimento.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cwd = try c.decode(String.self, forKey: .cwd)
        host = try c.decode(Host.self, forKey: .host)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        state = try c.decode(SessionState.self, forKey: .state)
        doneSince = try c.decodeIfPresent(Date.self, forKey: .doneSince)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        stateSince = try c.decode(Date.self, forKey: .stateSince)
        projectDir = try c.decode(String.self, forKey: .projectDir)
        attended = try c.decodeIfPresent(Bool.self, forKey: .attended)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        firstPrompt = try c.decodeIfPresent(String.self, forKey: .firstPrompt)
        backgroundHold = try c.decodeIfPresent(Bool.self, forKey: .backgroundHold) ?? false
        holdSince = try c.decodeIfPresent(Date.self, forKey: .holdSince)
        hooked = try c.decodeIfPresent(Bool.self, forKey: .hooked) ?? false
        askedInText = try c.decodeIfPresent(Bool.self, forKey: .askedInText) ?? false
    }

    /// Caminho de onde sai o nome curto: a pasta fixada, ou `cwd` enquanto ela não existe.
    public var nameSource: String { projectDir.isEmpty ? cwd : projectDir }

    /// Título da tarefa como na barra lateral do Claude: o da transcrição, senão a primeira mensagem.
    public var taskTitle: String? { title ?? firstPrompt }
}
