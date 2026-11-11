import Testing
import IlhaCore

@Test func shortNameTruncates() {
  #expect(ShortName.make(cwd: "/x/claude-menubar") == "claude-me…")
  #expect(ShortName.make(cwd: "/x/AcmeAPI") == "acmeapi")
}

@Test func shortNameEdgeCases() {
  #expect(ShortName.make(cwd: "/a/b/") == "b")
  #expect(ShortName.make(cwd: "/") == "")
  #expect(ShortName.make(cwd: "") == "")
  #expect(ShortName.make(cwd: "/x/abcdefghij") == "abcdefghij")
  #expect(ShortName.make(cwd: "/x/abcdefghijk") == "abcdefghi…")
  #expect(ShortName.make(cwd: "/x/abcdefghijk", maxLength: 5) == "abcd…")
}
