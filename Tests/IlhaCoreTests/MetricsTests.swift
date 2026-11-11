import Testing
import Foundation
import IlhaCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func utc() -> Calendar {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "UTC")!
  return c
}

private func allEvents() -> [MetricsEvent] {
  [
    MetricsEvents.active(minutes: 5, at: t0),
    MetricsEvents.cardOpened(.espiada, mood: .working, at: t0),
    MetricsEvents.cardClosed(seconds: 3, at: t0),
    MetricsEvents.sessionClicked(state: .done, host: .vscode, at: t0),
    MetricsEvents.answered(isPermission: true, .permitiu, at: t0),
    MetricsEvents.answered(isPermission: false, .respondeu, at: t0),
    MetricsEvents.updated(from: "0.2.0", to: "0.3.0", at: t0),
    MetricsEvents.settingChanged(.metrics, value: "off", at: t0),
  ]
}

@Suite struct MetricsTests {
  @Test func eventsUseOnlyAllowedKeys() {
    let events = allEvents()
    for e in events { #expect(Set(e.props.keys).isSubset(of: MetricsEvents.allowedKeys)) }
    #expect(Set(events.map(\.name)) == [
      "ilha_ativa", "cartao_aberto", "cartao_fechado", "sessao_clicada",
      "respondeu_na_ilha", "atualizou", "configuracao_mudada",
    ])
    #expect(events[4].props["pedido"] == .string("permissao"))
    #expect(events[5].props["pedido"] == .string("pergunta"))
  }

  @Test func cardOpenedProps() {
    let e = MetricsEvents.cardOpened(.painel, mood: .needsYou, at: t0)
    #expect(e.props == ["tipo": .string("painel"), "estado": .string("needsYou")])
  }

  @Test func batchEncodingShape() throws {
    let batch = MetricsBatch(id: UUID(), app: "0.3.0", os: "15.6.1", events: [MetricsEvents.active(minutes: 7, at: t0)])
    let obj = try #require(JSONSerialization.jsonObject(with: batch.encoded()) as? [String: Any])
    #expect(obj["v"] as? Int == 1)
    #expect(obj["app"] as? String == "0.3.0")
    let ev = try #require((obj["events"] as? [[String: Any]])?.first)
    let props = try #require(ev["props"] as? [String: Any])
    #expect(props["minutos"] as? Int == 7)
    #expect(ev["at"] as? String == "2027-01-15T08:00:00Z")
  }

  @Test func metricValueRoundTripsDistinctly() throws {
    let enc = JSONEncoder(), dec = JSONDecoder()
    let s = try dec.decode([String: MetricValue].self, from: enc.encode(["a": MetricValue.string("10")]))
    let i = try dec.decode([String: MetricValue].self, from: enc.encode(["a": MetricValue.int(10)]))
    #expect(s["a"] == .string("10"))
    #expect(i["a"] == .int(10))
    #expect(s["a"] != i["a"])
  }

  @Test func queueCapsAtThousand() {
    var q = MetricsQueue()
    for i in 0..<1005 { q.append(MetricsEvents.active(minutes: i, at: t0), enabled: true) }
    #expect(q.events.count == 1000)
    #expect(q.events.first?.props["minutos"] == .int(5))
    #expect(q.nextBatch().count == 200)
    q.removeFirst(200)
    #expect(q.events.count == 800)
  }

  @Test func queueClearsAndRefusesWhenDisabled() {
    var q = MetricsQueue()
    q.append(MetricsEvents.active(minutes: 1, at: t0), enabled: false)
    #expect(q.events.isEmpty)
    q.append(MetricsEvents.active(minutes: 1, at: t0), enabled: true)
    q.clear()
    #expect(q.events.isEmpty)
  }

  @Test func queueSaveLoadRoundTripAndTolerance() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let url = dir.appendingPathComponent("sub/q.json")
    #expect(MetricsQueue.load(from: url).events.isEmpty)
    var q = MetricsQueue()
    q.append(MetricsEvents.active(minutes: 2, at: t0), enabled: true)
    try q.save(to: url)
    #expect(MetricsQueue.load(from: url) == q)
    try Data("lixo".utf8).write(to: url)
    #expect(MetricsQueue.load(from: url).events.isEmpty)
  }

  @Test func activityFirstCallEmitsZero() {
    var a = DailyActivity(day: "", seconds: 0)
    #expect(a.advance(now: t0, elapsed: 30, calendar: utc()) == 0)
    #expect(a.day == "2027-01-15")
  }

  @Test func activityAccumulatesWithinDay() {
    var a = DailyActivity(day: "", seconds: 0)
    _ = a.advance(now: t0, elapsed: 30, calendar: utc())
    for i in 1...10 {
      #expect(a.advance(now: t0.addingTimeInterval(Double(i) * 30), elapsed: 30, calendar: utc()) == nil)
    }
    #expect(a.seconds == 300)
  }

  @Test func activityEmitsOnDayChange() {
    var a = DailyActivity(day: "2027-01-15", seconds: 0)
    for _ in 0..<10 { _ = a.advance(now: t0, elapsed: 60, calendar: utc()) }
    #expect(a.advance(now: t0.addingTimeInterval(86_400), elapsed: 30, calendar: utc()) == 10)
    #expect(a.day == "2027-01-16")
    #expect(a.seconds == 0)
  }

  @Test func activityIgnoresSleepGap() {
    var a = DailyActivity(day: "2027-01-15", seconds: 0)
    _ = a.advance(now: t0, elapsed: 7200, calendar: utc())
    #expect(a.seconds == 60)
  }

  @Test func activityEmitsOnceAfterManyDays() {
    var a = DailyActivity(day: "2027-01-15", seconds: 120)
    let later = t0.addingTimeInterval(5 * 86_400)
    #expect(a.advance(now: later, elapsed: 60, calendar: utc()) == 2)
    #expect(a.advance(now: later.addingTimeInterval(60), elapsed: 60, calendar: utc()) == nil)
  }
}
