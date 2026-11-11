import Testing
import Foundation
import IlhaCore

private let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!

private var calendar: Calendar {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = saoPaulo
  return c
}

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
  calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

/// 2026-10-23 15:00 em São Paulo.
private let now = date(2026, 10, 23, 15)

private func output(_ text: String, isError: Bool = false) -> Data {
  try! JSONSerialization.data(withJSONObject: ["is_error": isError, "result": text] as [String: Any])
}

private func parse(_ text: String) -> UsageResult {
  UsageParser.parse(output(text), now: now, calendar: calendar)
}

private let realOutput = """
You are currently using your subscription to power your Claude Code usage

Current session: 10% used · resets Oct 23 at 6:30pm (America/Sao_Paulo)
Current week (all models): 49% used · resets Oct 29 at 4am (America/Sao_Paulo)
Current week (Fable): 3% used · resets Oct 29 at 4am (America/Sao_Paulo)

What's contributing to your limits usage?
Last 24h · 4908 requests · 24 sessions
  97%  Give "general-purpose" subagents a cheaper model
"""

@Test func currentFormatIsRead() {
  guard case .reading(let reading) = parse(realOutput) else {
    Issue.record("esperava .reading")
    return
  }
  #expect(reading.session.percent == 10)
  #expect(reading.session.resetsAt == date(2026, 10, 23, 18, 30))
  #expect(reading.week?.percent == 49)
  #expect(reading.week?.resetsAt == date(2026, 10, 29, 4))
  #expect(reading.readAt == now)
}

@Test func legacyWeekLineIsRead() {
  let text = "Current session: 8% used · resets 1:29pm\nCurrent week: 39% used"
  guard case .reading(let reading) = parse(text) else {
    Issue.record("esperava .reading")
    return
  }
  #expect(reading.session.percent == 8)
  #expect(reading.session.resetsAt == date(2026, 10, 24, 13, 29))
  #expect(reading.week?.percent == 39)
  #expect(reading.week?.resetsAt == nil)
}

@Test func modelOnlyWeekIsIgnored() {
  let text = "Current session: 10% used\nCurrent week (Fable): 3% used · resets Oct 29 at 4am (America/Sao_Paulo)"
  guard case .reading(let reading) = parse(text) else {
    Issue.record("esperava .reading")
    return
  }
  #expect(reading.week == nil)
}

@Test func resetAcrossNewYear() {
  let late = date(2026, 12, 30, 10)
  let parsed = UsageParser.parseReset("Jan 2 at 9am (America/Sao_Paulo)", now: late, calendar: calendar)
  #expect(parsed == date(2027, 1, 2, 9))
}

@Test func garbageResetKeepsPercent() {
  guard case .reading(let reading) = parse("Current session: 12% used · resets sometime") else {
    Issue.record("esperava .reading")
    return
  }
  #expect(reading.session.percent == 12)
  #expect(reading.session.resetsAt == nil)
}

@Test func errorIsCommandFailed() {
  #expect(UsageParser.parse(output(realOutput, isError: true), now: now, calendar: calendar) == .commandFailed)
  #expect(UsageParser.parse(Data("não é json".utf8), now: now, calendar: calendar) == .commandFailed)
  #expect(parse("") == .commandFailed)
  #expect(parse("  \n ") == .commandFailed)
}

@Test func failedToLoadIsCommandFailed() {
  #expect(parse("Failed to load usage data: rate limited") == .commandFailed)
  // Mesmo com algo que pareça leitura junto: o comando disse que falhou.
  #expect(parse("Failed to load usage data\nCurrent session: 10% used") == .commandFailed)
}

@Test func unknownSubscriptionTextIsUnreadable() {
  let text = "You are currently using your subscription to power your Claude Code usage\n\nSessão atual: 10% usado"
  #expect(parse(text) == .unreadable)
  #expect(parse("Sessão atual: 10% usado") == .unreadable)
  #expect(parse("You are currently using your subscription to power your Claude Code usage") == .unreadable)
  // Os "97%" do resto do texto nunca viram leitura.
  #expect(parse("You are currently using your subscription\n  97%  Give subagents a cheaper model") == .unreadable)
}

@Test func apiAccountIsUnlimited() {
  #expect(parse("Usage limits are not available when using an API key") == .unlimited)
  #expect(parse("You are using API usage billing") == .unlimited)
  #expect(parse("Usage limits do not apply on Amazon Bedrock") == .unlimited)
  #expect(parse("Usage limits do not apply on Google Vertex AI") == .unlimited)
  // Com "%" no texto não é conta sem limite: é formato que não conhecemos.
  #expect(parse("API key in use · 40% of budget") == .unreadable)
}

@Test func modelSessionLineIsIgnored() {
  let text = """
  Current session (Fable): 95% used · resets Oct 23 at 5pm (America/Sao_Paulo)
  Current session: 10% used · resets Oct 23 at 6:30pm (America/Sao_Paulo)
  """
  guard case .reading(let reading) = parse(text) else {
    Issue.record("esperava .reading")
    return
  }
  #expect(reading.session.percent == 10)
  #expect(reading.session.resetsAt == date(2026, 10, 23, 18, 30))
  // Só a de modelo: não há leitura da janela de 5 h.
  #expect(parse("Current session (Fable): 95% used") == .unreadable)
  // "(all models)" vale como a sessão.
  guard case .reading(let all) = parse("Current session (all models): 33% used") else {
    Issue.record("esperava .reading")
    return
  }
  #expect(all.session.percent == 33)
}

@Test func nonGregorianCalendarGivesTheSameResets() {
  var islamic = Calendar(identifier: .islamicUmmAlQura)
  islamic.timeZone = saoPaulo
  let expected = UsageParser.parse(output(realOutput), now: now, calendar: calendar)
  #expect(UsageParser.parse(output(realOutput), now: now, calendar: islamic) == expected)
  let late = date(2026, 12, 30, 10)
  #expect(UsageParser.parseReset("Jan 2 at 9am (America/Sao_Paulo)", now: late, calendar: islamic) == date(2027, 1, 2, 9))
  #expect(UsageParser.parseReset("1:29pm", now: now, calendar: islamic) == date(2026, 10, 24, 13, 29))
}
