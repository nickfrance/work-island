import Foundation
import Testing
@testable import IlhaCore

@Suite struct ReleaseBuildTests {
  @Test func releaseFlagTrueIsRelease() {
    #expect(ReleaseBuild.isRelease([ReleaseBuild.infoKey: true]))
  }

  @Test func missingOrFalseIsBuiltFromSource() {
    #expect(!ReleaseBuild.isRelease(nil))
    #expect(!ReleaseBuild.isRelease([:]))
    #expect(!ReleaseBuild.isRelease([ReleaseBuild.infoKey: false]))
  }

  @Test func onlyABooleanCounts() {
    #expect(!ReleaseBuild.isRelease([ReleaseBuild.infoKey: "true"]))
    #expect(!ReleaseBuild.isRelease([ReleaseBuild.infoKey: "YES"]))
  }

  /// Uma versão publicada sem receptor de métricas continua se atualizando sozinha.
  @Test func independentOfMetricsAddress() {
    #expect(ReleaseBuild.isRelease([ReleaseBuild.infoKey: true, "WorkIslandMetricsURL": ""]))
    #expect(!ReleaseBuild.isRelease(["WorkIslandMetricsURL": "https://example.com/e"]))
  }

  /// O Info.plist que o bundle-app.sh escreve tem de ler como esperado (XML <true/> → Bool).
  @Test func plistBooleanDecodesAsBool() throws {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict><key>WorkIslandRelease</key><true/></dict></plist>
      """
    let info = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any]
    #expect(ReleaseBuild.isRelease(info))
  }
}
