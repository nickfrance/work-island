import Testing
import Foundation
import IlhaCore

private let t = Date(timeIntervalSince1970: 1_800_000_000)

private func reading(
  session: Int = 40, week: Int? = 10, sessionReset: Date? = nil, weekReset: Date? = nil, readAt: Date = t
) -> UsageResult {
  .reading(UsageReading(
    session: UsageWindow(percent: session, resetsAt: sessionReset),
    week: week.map { UsageWindow(percent: $0, resetsAt: weekReset) },
    readAt: readAt))
}

/// Uma tentativa que terminou com `result` em `at`.
private func attempted(_ result: UsageResult?, at: Date = t) -> UsageSchedule {
  var schedule = UsageSchedule()
  schedule.begin(at: at)
  schedule.finish(result, at: at)
  return schedule
}

@Test func launchAlwaysReads() {
  #expect(UsageSchedule().shouldRead(.launch, now: t, paused: false))
  #expect(attempted(reading()).shouldRead(.launch, now: t, paused: false))
}

@Test func turnEndsAreThrottled() {
  var schedule = UsageSchedule()
  schedule.begin(at: t)
  schedule.finish(reading(), at: t)
  #expect(!schedule.shouldRead(.turnEnded, now: t.addingTimeInterval(119), paused: false))
  #expect(schedule.shouldRead(.turnEnded, now: t.addingTimeInterval(120), paused: false))
  #expect(UsageSchedule().shouldRead(.turnEnded, now: t, paused: false))
}

@Test func nothingWhileInFlight() {
  var schedule = UsageSchedule()
  schedule.begin(at: t)
  #expect(schedule.inFlight)
  let later = t.addingTimeInterval(5000)
  for trigger in [UsageTrigger.launch, .turnEnded, .surfaceOpened, .timer] {
    #expect(!schedule.shouldRead(trigger, now: later, paused: false))
  }
}

@Test func pausedNeverReads() {
  for trigger in [UsageTrigger.launch, .turnEnded, .surfaceOpened, .timer] {
    #expect(!UsageSchedule().shouldRead(trigger, now: t, paused: true))
  }
}

@Test func surfaceRereadsAfterAMinute() {
  let schedule = attempted(reading())
  #expect(!schedule.shouldRead(.surfaceOpened, now: t.addingTimeInterval(60), paused: false))
  #expect(schedule.shouldRead(.surfaceOpened, now: t.addingTimeInterval(61), paused: false))
  #expect(UsageSchedule().shouldRead(.surfaceOpened, now: t, paused: false))
}

@Test func timerAfterFifteenMinutes() {
  let schedule = attempted(reading())
  #expect(!schedule.shouldRead(.timer, now: t.addingTimeInterval(899), paused: false))
  #expect(schedule.shouldRead(.timer, now: t.addingTimeInterval(900), paused: false))
  #expect(UsageSchedule().shouldRead(.timer, now: t, paused: false))
}

@Test func timerAtReset() {
  let schedule = attempted(reading(sessionReset: t.addingTimeInterval(300)))
  #expect(!schedule.shouldRead(.timer, now: t.addingTimeInterval(299), paused: false))
  #expect(schedule.shouldRead(.timer, now: t.addingTimeInterval(301), paused: false))
}

@Test func nextWakeIsTheEarlier() {
  let withReset = attempted(reading(sessionReset: t.addingTimeInterval(300)))
  #expect(withReset.nextWake(now: t) == t.addingTimeInterval(305))
  let withoutReset = attempted(reading())
  #expect(withoutReset.nextWake(now: t) == t.addingTimeInterval(900))
  #expect(UsageSchedule().nextWake(now: t) == t)
}

@Test func failedProbeKeepsLastReading() {
  var schedule = attempted(reading(session: 55, week: 22, sessionReset: t.addingTimeInterval(3600)))
  let before = schedule.status(now: t.addingTimeInterval(130))
  schedule.begin(at: t.addingTimeInterval(120))
  schedule.finish(nil, at: t.addingTimeInterval(121))
  #expect(!schedule.inFlight)
  #expect(schedule.status(now: t.addingTimeInterval(130)) == before)
  #expect(before == .fresh(session: 55, week: 22, resetsAt: t.addingTimeInterval(3600), weekResetsAt: nil))
  #expect(UsageSchedule().status(now: t) == .loading)
}

@Test func commandFailedKeepsLastReading() {
  var schedule = attempted(reading(session: 55, week: 22, sessionReset: t.addingTimeInterval(3600)))
  let before = schedule.status(now: t.addingTimeInterval(130))
  schedule.begin(at: t.addingTimeInterval(120))
  schedule.finish(.commandFailed, at: t.addingTimeInterval(121))
  #expect(!schedule.inFlight)
  #expect(schedule.result == reading(session: 55, week: 22, sessionReset: t.addingTimeInterval(3600)))
  #expect(schedule.status(now: t.addingTimeInterval(130)) == before)
  // Sem resultado anterior, continua carregando e tenta de novo em 2 min, como uma falha sem saída.
  let first = attempted(.commandFailed)
  #expect(first.result == nil)
  #expect(first.status(now: t) == .loading)
  #expect(first.nextWake(now: t) == t.addingTimeInterval(120))
}

@Test func passedResetShowsZero() {
  let schedule = attempted(reading(session: 80, week: 30, sessionReset: t.addingTimeInterval(10)))
  #expect(schedule.status(now: t.addingTimeInterval(11)) == .fresh(session: 0, week: 30, resetsAt: nil, weekResetsAt: nil))
  #expect(schedule.status(now: t.addingTimeInterval(9)) == .fresh(session: 80, week: 30, resetsAt: t.addingTimeInterval(10), weekResetsAt: nil))
}

@Test func weekResetIsCarriedUntilItPasses() {
  let schedule = attempted(reading(
    session: 20, week: 54, sessionReset: t.addingTimeInterval(1000), weekReset: t.addingTimeInterval(600)))
  #expect(schedule.status(now: t.addingTimeInterval(60)) == .fresh(
    session: 20, week: 54, resetsAt: t.addingTimeInterval(1000), weekResetsAt: t.addingTimeInterval(600)))
  // A semana que já renovou conta 0% e não tem mais hora para mostrar; a sessão segue.
  #expect(schedule.status(now: t.addingTimeInterval(601)) == .fresh(
    session: 20, week: 0, resetsAt: t.addingTimeInterval(1000), weekResetsAt: nil))
}

@Test func oldReadingGoesStale() {
  let schedule = attempted(reading(session: 70, week: 15, sessionReset: t.addingTimeInterval(7200)))
  #expect(schedule.status(now: t.addingTimeInterval(1200)) == .fresh(session: 70, week: 15, resetsAt: t.addingTimeInterval(7200), weekResetsAt: nil))
  #expect(schedule.status(now: t.addingTimeInterval(1201)) == .stale(session: 70, week: 15, minutesAgo: 20))
}

@Test func unreadableAndUnlimitedPassThrough() {
  #expect(attempted(.unreadable).status(now: t) == .unreadable)
  #expect(attempted(.unlimited).status(now: t) == .unlimited)
}

@Test func failedReadAfterResetIsThrottled() {
  var schedule = attempted(reading(sessionReset: t.addingTimeInterval(300)))
  schedule.begin(at: t.addingTimeInterval(301))
  schedule.finish(nil, at: t.addingTimeInterval(301))
  #expect(!schedule.shouldRead(.timer, now: t.addingTimeInterval(302), paused: false))
  #expect(schedule.shouldRead(.timer, now: t.addingTimeInterval(301 + 900), paused: false))
}

@Test func nextWakeIsNowWhenResetIsDue() {
  let schedule = attempted(reading(sessionReset: t.addingTimeInterval(300)))
  let now = t.addingTimeInterval(400)
  #expect(schedule.nextWake(now: now) == now)
}

@Test func readingTakenAfterItsResetDoesNotTrigger() {
  var schedule = UsageSchedule()
  schedule.begin(at: t)
  schedule.finish(reading(sessionReset: t.addingTimeInterval(300), readAt: t.addingTimeInterval(400)), at: t.addingTimeInterval(400))
  #expect(!schedule.shouldRead(.timer, now: t.addingTimeInterval(500), paused: false))
}

@Test func firstResultRetriesAfterTwoMinutes() {
  let schedule = attempted(nil)
  #expect(!schedule.shouldRead(.timer, now: t.addingTimeInterval(119), paused: false))
  #expect(schedule.shouldRead(.timer, now: t.addingTimeInterval(120), paused: false))
  #expect(schedule.shouldRead(.timer, now: t.addingTimeInterval(120), paused: false, lowPower: true))
}

@Test func nextWakeRetriesSoonWithoutResult() {
  let schedule = attempted(nil)
  #expect(schedule.nextWake(now: t) == t.addingTimeInterval(120))
  #expect(schedule.nextWake(now: t, lowPower: true) == t.addingTimeInterval(120))
}

@Test func lowPowerSkipsIdleRefresh() {
  let schedule = attempted(reading())
  #expect(!schedule.shouldRead(.timer, now: t.addingTimeInterval(900), paused: false, lowPower: true))
  #expect(schedule.shouldRead(.timer, now: t.addingTimeInterval(900), paused: false))
  // Sem leitura ociosa, o timer não acorda à toa.
  #expect(schedule.nextWake(now: t, lowPower: true) == .distantFuture)
}

@Test func lowPowerStillReadsOnLaunchTurnAndSurface() {
  let schedule = attempted(reading())
  #expect(schedule.shouldRead(.launch, now: t, paused: false, lowPower: true))
  #expect(schedule.shouldRead(.turnEnded, now: t.addingTimeInterval(120), paused: false, lowPower: true))
  #expect(schedule.shouldRead(.surfaceOpened, now: t.addingTimeInterval(61), paused: false, lowPower: true))
  #expect(UsageSchedule().shouldRead(.timer, now: t, paused: false, lowPower: true))
}

@Test func lowPowerStillReadsAtReset() {
  let schedule = attempted(reading(sessionReset: t.addingTimeInterval(300)))
  #expect(!schedule.shouldRead(.timer, now: t.addingTimeInterval(299), paused: false, lowPower: true))
  #expect(schedule.shouldRead(.timer, now: t.addingTimeInterval(301), paused: false, lowPower: true))
  #expect(schedule.nextWake(now: t, lowPower: true) == t.addingTimeInterval(305))
}

@Test func staleAgeScalesToHoursAndDays() {
  #expect(UsageAge(minutes: 25) == .minutes(25))
  #expect(UsageAge(minutes: 59) == .minutes(59))
  #expect(UsageAge(minutes: 60) == .hours(1))
  #expect(UsageAge(minutes: 480) == .hours(8))
  #expect(UsageAge(minutes: 1439) == .hours(23))
  #expect(UsageAge(minutes: 1440) == .days(1))
  #expect(UsageAge(minutes: 2 * 1440 + 1000) == .days(2))
  #expect(UsageAge(minutes: -3) == .minutes(0))
}
