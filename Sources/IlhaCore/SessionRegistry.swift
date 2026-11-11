import Foundation

/// O `status` que o Claude Code grava no registro.
public enum RegistryActivity: String, Equatable, Sendable {
    /// Turno rodando.
    case busy
    /// Parado num diálogo esperando você (permissão ou pergunta: `waitingFor`).
    case waiting
    /// Esperando um prompt novo.
    case idle
}

/// Status de uma sessão segundo o registro do Claude Code.
public struct RegistryStatus: Equatable, Sendable {
    public let activity: RegistryActivity
    /// `statusUpdatedAt` (ms desde 1970).
    public let updatedAt: Date

    public init(_ activity: RegistryActivity, updatedAt: Date) {
        self.activity = activity
        self.updatedAt = updatedAt
    }
}

/// Uma entrada de `~/.claude/sessions/<pid>.json` (só os campos que a ilha usa).
public struct RegistryEntry: Decodable, Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let cwd: String
    public let entrypoint: String?
    public let status: String?
    /// ms desde 1970.
    public let startedAt: Double?
    /// Hora de início do processo, no formato do `ctime` ("Fri Oct 23 16:14:09 2026").
    public let procStart: String?
    /// Quando `status` mudou (ms desde 1970); semeia `stateSince`.
    public let statusUpdatedAt: Double?

    public init(
        pid: Int32, sessionId: String, cwd: String, entrypoint: String?, status: String?,
        startedAt: Double?, procStart: String?, statusUpdatedAt: Double? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.entrypoint = entrypoint
        self.status = status
        self.startedAt = startedAt
        self.procStart = procStart
        self.statusUpdatedAt = statusUpdatedAt
    }
}

/// Lê o registro (não documentado) que o Claude Code mantém em `~/.claude/sessions/<pid>.json`
/// para semear o estado com sessões que já estavam abertas antes do app subir e para conferir,
/// a cada tick, se uma sessão "trabalhando" ainda está ocupada.
/// Qualquer falha resulta em lista vazia ou em arquivo ignorado: nunca lança.
public enum SessionRegistry {
    /// Semeia com as sessões cujo processo ainda é aquela sessão (`processMatches`; o app usa
    /// pid vivo + `ProcessIdentity.isSession`). Só arquivos `.json` contam.
    public static func load(
        directory: URL, processMatches: (Int32, RegistryEntry) -> Bool, now: Date
    ) -> [Session] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        var sessions: [Session] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(RegistryEntry.self, from: data),
                  processMatches(entry.pid, entry)
            else { continue }
            sessions.append(Session(
                id: entry.sessionId,
                cwd: entry.cwd,
                host: Host(entrypoint: entry.entrypoint),
                pid: entry.pid,
                state: Self.state(entry.status),
                updatedAt: now,
                createdAt: entry.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? now,
                stateSince: Self.stateSince(entry.statusUpdatedAt, now: now)
            ))
        }
        return sessions
    }

    /// Desde quando a sessão está no estado lido: `statusUpdatedAt`, se for uma data plausível
    /// (depois de 1970 e não no futuro); senão a hora da leitura.
    private static func stateSince(_ statusUpdatedAt: Double?, now: Date) -> Date {
        guard let ms = statusUpdatedAt, ms > 0 else { return now }
        let date = Date(timeIntervalSince1970: ms / 1000)
        return date <= now ? date : now
    }

    private static func state(_ status: String?) -> SessionState {
        switch status.flatMap(RegistryActivity.init(rawValue:)) {
        case .busy: return .working
        case .waiting: return .needsYou
        case .idle, nil: return .idle
        }
    }

    private struct StatusEntry: Decodable {
        let pid: Int32
        let status: String
        let statusUpdatedAt: Double
    }

    /// Status atual de cada pid no registro; arquivos sem `status`/`statusUpdatedAt`, ou com um
    /// `status` desconhecido, ficam de fora.
    public static func statuses(directory: URL) -> [Int32: RegistryStatus] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [:] }

        let decoder = JSONDecoder()
        var result: [Int32: RegistryStatus] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(StatusEntry.self, from: data),
                  let activity = RegistryActivity(rawValue: entry.status)
            else { continue }
            result[entry.pid] = RegistryStatus(
                activity, updatedAt: Date(timeIntervalSince1970: entry.statusUpdatedAt / 1000))
        }
        return result
    }
}
