import Foundation
import Testing
import IlhaCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func session(_ state: SessionState, doneSince: Date? = nil) -> Session {
  Session(id: "s", cwd: "/x/a", host: .terminal, state: state, doneSince: doneSince, updatedAt: t0)
}

@Test func stateLabelKinds() {
  #expect(StateLabel.kind(for: session(.working), now: t0) == .working)
  #expect(StateLabel.kind(for: session(.needsYou), now: t0) == .needsYou)
  #expect(StateLabel.kind(for: session(.done, doneSince: t0), now: t0) == .done)
  #expect(StateLabel.kind(for: session(.idle), now: t0) == .idle)
}

@Test func staleLabelCountsWholeMinutes() {
  let s = session(.doneStale, doneSince: t0)
  #expect(StateLabel.kind(for: s, now: t0.addingTimeInterval(600)) == .doneMinutesAgo(10))
  #expect(StateLabel.kind(for: s, now: t0.addingTimeInterval(719)) == .doneMinutesAgo(11))
  #expect(StateLabel.kind(for: s, now: t0.addingTimeInterval(720)) == .doneMinutesAgo(12))
}

@Test func staleLabelEdgeCases() {
  // Mínimo de 1 min, inclusive com relógio voltando.
  #expect(StateLabel.kind(for: session(.doneStale, doneSince: t0), now: t0) == .doneMinutesAgo(1))
  #expect(StateLabel.kind(for: session(.doneStale, doneSince: t0), now: t0.addingTimeInterval(-90)) == .doneMinutesAgo(1))
  // Sem `doneSince` não há como contar: fica só "concluído".
  #expect(StateLabel.kind(for: session(.doneStale), now: t0) == .done)
}
