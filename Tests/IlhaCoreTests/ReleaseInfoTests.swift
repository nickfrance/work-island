import Testing
import Foundation
import IlhaCore

@Test func semverParsesAndOrders() {
  #expect(SemVer("v0.10.0")! > SemVer("0.9.9")!)
  #expect(SemVer("abc") == nil)
  #expect(SemVer("1.2") == nil)
  #expect(SemVer("1.2.3.4") == nil)
  #expect(SemVer("v1.2.3")!.description == "1.2.3")
  #expect(SemVer("0.4.0") == SemVer("v0.4.0"))
}

private func json(_ s: String) -> Data { Data(s.utf8) }

@Test func parseLatestReadsTagNotesAssetDigest() {
  let body = """
  {"tag_name":"v0.4.0","html_url":"https://github.com/nickfrance/work-island/releases/tag/v0.4.0",
   "assets":[{"name":"WorkIsland.zip","browser_download_url":"https://example.com/WorkIsland.zip","digest":"sha256:ab12"}]}
  """
  let info = ReleaseInfo.parseLatest(json(body))
  #expect(info?.version == SemVer("0.4.0"))
  #expect(info?.notesURL.absoluteString == "https://github.com/nickfrance/work-island/releases/tag/v0.4.0")
  #expect(info?.assetURL.absoluteString == "https://example.com/WorkIsland.zip")
  #expect(info?.sha256 == "ab12")
}

@Test func parseLatestRejectsNonReleaseBodies() {
  #expect(ReleaseInfo.parseLatest(json(#"{"message":"Not Found"}"#)) == nil)
  #expect(ReleaseInfo.parseLatest(json(#"{"message":"API rate limit exceeded"}"#)) == nil)
  #expect(ReleaseInfo.parseLatest(json("{")) == nil)
  let otherName = #"{"tag_name":"v0.4.0","html_url":"https://x.com/r","assets":[{"name":"Other.zip","browser_download_url":"https://x.com/a","digest":"sha256:ab"}]}"#
  #expect(ReleaseInfo.parseLatest(json(otherName)) == nil)
  let noDigest = #"{"tag_name":"v0.4.0","html_url":"https://x.com/r","assets":[{"name":"WorkIsland.zip","browser_download_url":"https://x.com/a"}]}"#
  #expect(ReleaseInfo.parseLatest(json(noDigest)) == nil)
}
