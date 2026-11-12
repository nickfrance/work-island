import Foundation
import Testing
@testable import IlhaCore

@Suite struct AppSettingsTests {
  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ilha-settings-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("settings.json")
  }

  @Test func dormantChoiceIntervals() {
    #expect(DormantChoice.h6.interval == 21_600)
    #expect(DormantChoice.h12.interval == 43_200)
    #expect(DormantChoice.h24.interval == 86_400)
    #expect(DormantChoice.never.interval == nil)
  }

  @Test func settingsDefaults() {
    let s = AppSettings()
    #expect(s.openAtLogin)
    #expect(s.metricsEnabled)
    #expect(s.dormant == .h12)
  }

  @Test func noticeSwitchesDefaultOn() {
    let s = AppSettings()
    #expect(s.noticeNeedsYou)
    #expect(s.noticeDone)
  }

  @Test func noticeSwitchesSurviveRoundTrip() throws {
    let url = tempURL()
    var s = AppSettings()
    s.noticeNeedsYou = false
    s.noticeDone = true
    try s.save(to: url)
    let loaded = AppSettings.load(from: url)
    #expect(loaded.noticeNeedsYou == false)
    #expect(loaded.noticeDone == true)
  }

  @Test func oldFileWithoutNoticeKeysStaysOn() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"dormant":"h24"}"#.utf8).write(to: url)
    let s = AppSettings.load(from: url)
    #expect(s.noticeNeedsYou)
    #expect(s.noticeDone)
    #expect(s.dormant == .h24)
  }

  @Test func badNoticeValueFallsBackToOn() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"noticeDone":"x","noticeNeedsYou":false,"dormant":"h24"}"#.utf8).write(to: url)
    let s = AppSettings.load(from: url)
    #expect(s.noticeDone)
    #expect(s.noticeNeedsYou == false)
    #expect(s.dormant == .h24)
  }

  @Test func settingsRoundTrip() throws {
    let url = tempURL()
    var s = AppSettings()
    s.dormant = .never
    s.openAtLogin = false
    s.anonymousID = UUID()
    s.dismissedUpdate = "0.4.0"
    try s.save(to: url)
    #expect(AppSettings.load(from: url) == s)
  }

  @Test func settingsLoadToleratesMissingKeys() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"dormant":"h24"}"#.utf8).write(to: url)
    var expected = AppSettings()
    expected.dormant = .h24
    #expect(AppSettings.load(from: url) == expected)
  }

  @Test func settingsLoadKeepsGoodFieldsWhenOneIsBad() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"dormant":"h99","metricsEnabled":false}"#.utf8).write(to: url)
    let loaded = AppSettings.load(from: url)
    #expect(loaded.dormant == .h12)
    #expect(loaded.metricsEnabled == false)
  }

  @Test func settingsLoadCorruptGivesDefaults() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: url)
    #expect(AppSettings.load(from: url) == AppSettings())
  }
}
