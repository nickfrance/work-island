import Testing
import Foundation
import IlhaCore

private func input(_ json: String) -> JSONValue {
  try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

@Test func writeCarriesTheWholeContent() {
  let change = FileChange(toolName: "Write", toolInput: input(#"{"file_path":"/x/a.txt","content":"oi\ntchau"}"#))
  #expect(change == FileChange(path: "/x/a.txt", kind: .write("oi\ntchau")))
}

@Test func editCarriesOldNewAndReplaceAll() {
  let change = FileChange(toolName: "Edit", toolInput: input(
    #"{"file_path":"/x/a.swift","old_string":"let a = 1","new_string":"let a = 2","replace_all":true}"#))
  #expect(change == FileChange(path: "/x/a.swift", kind: .edits([.init(old: "let a = 1", new: "let a = 2", replaceAll: true)])))
}

@Test func editWithoutReplaceAllIsSingle() {
  let change = FileChange(toolName: "Edit", toolInput: input(#"{"file_path":"/x/a","old_string":"a","new_string":""}"#))
  #expect(change?.kind == .edits([.init(old: "a", new: "", replaceAll: false)]))
}

@Test func multiEditKeepsEveryEditInOrder() {
  let change = FileChange(toolName: "MultiEdit", toolInput: input(
    #"{"file_path":"/x/a","edits":[{"old_string":"1","new_string":"2"},{"old_string":"3","new_string":"4","replace_all":true}]}"#))
  #expect(change?.kind == .edits([.init(old: "1", new: "2", replaceAll: false), .init(old: "3", new: "4", replaceAll: true)]))
}

@Test func otherToolsAndBrokenInputsGiveNil() {
  #expect(FileChange(toolName: "Bash", toolInput: input(#"{"command":"ls"}"#)) == nil)
  #expect(FileChange(toolName: "Write", toolInput: input(#"{"file_path":"/x/a"}"#)) == nil)
  #expect(FileChange(toolName: "Edit", toolInput: input(#"{"old_string":"a","new_string":"b"}"#)) == nil)
  #expect(FileChange(toolName: "MultiEdit", toolInput: input(#"{"file_path":"/x/a","edits":[]}"#)) == nil)
  #expect(FileChange(toolName: "MultiEdit", toolInput: input(#"{"file_path":"/x/a","edits":[{"old_string":1}]}"#)) == nil)
}
