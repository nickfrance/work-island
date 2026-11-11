import Foundation
import Testing

/// As tabelas de texto do app (`Sources/IlhaApp/Resources`), lidas direto do repositório: o alvo
/// de testes não enxerga o app, mas as duas línguas precisam andar juntas.
private let resources = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("Sources/IlhaApp/Resources", isDirectory: true)
private let appSources = resources.deletingLastPathComponent()
private let languages = ["pt-BR", "en"]

private func table(_ language: String, _ file: String) throws -> [String: Any] {
  let url = resources.appendingPathComponent("\(language).lproj/\(file)")
  let data = try Data(contentsOf: url)
  let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
  return try #require(plist as? [String: Any], "\(language)/\(file) não é um dicionário")
}

/// Especificadores de um valor, sem a posição e em ordem: "%2$@ e %1$d" → ["%@", "%d"].
/// "%%" é só o sinal de porcento; "%#@x@" é a variável de plural do `.stringsdict`.
private func specifiers(_ value: String) -> [String] {
  let pattern = /%(?:\d+\$)?(#@\w+@|l{0,2}[@dDiuUxXfeEgGcs%])/
  return value.matches(of: pattern).map { "%" + String($0.output.1) }.filter { $0 != "%%" }.sorted()
}

@Test func everyKeyExistsInBothLanguages() throws {
  let tables = try languages.map { try table($0, "Localizable.strings") }
  let keys = tables.map { Set($0.keys) }
  #expect(!keys[0].isEmpty)
  #expect(keys[0] == keys[1], "só em pt-BR: \(keys[0].subtracting(keys[1])); só em en: \(keys[1].subtracting(keys[0]))")
  for (language, strings) in zip(languages, tables) {
    for (key, value) in strings {
      let text = try #require(value as? String, "\(language) \(key) não é texto")
      #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) \(key) vazio")
    }
  }
  for key in keys[0].intersection(keys[1]) {
    let pt = tables[0][key] as? String ?? "", en = tables[1][key] as? String ?? ""
    #expect(specifiers(pt) == specifiers(en), "\(key): \(pt) × \(en)")
  }
}

@Test func everyPluralExistsInBothLanguages() throws {
  let tables = try languages.map { try table($0, "Localizable.stringsdict") }
  let keys = tables.map { Set($0.keys) }
  #expect(!keys[0].isEmpty)
  #expect(keys[0] == keys[1], "só em pt-BR: \(keys[0].subtracting(keys[1])); só em en: \(keys[1].subtracting(keys[0]))")
  // Um plural não pode repetir uma chave do `.strings`: a tabela é a mesma ("Localizable").
  let strings = try table("pt-BR", "Localizable.strings")
  #expect(keys[0].isDisjoint(with: strings.keys), "chaves nos dois arquivos: \(keys[0].intersection(strings.keys))")

  for key in keys[0].intersection(keys[1]) {
    let entries = try languages.map { language -> [String: Any] in
      try #require(tables[languages.firstIndex(of: language)!][key] as? [String: Any], "\(language) \(key)")
    }
    let formats = entries.map { $0["NSStringLocalizedFormatKey"] as? String ?? "" }
    #expect(formats.allSatisfy { !$0.isEmpty }, "\(key) sem NSStringLocalizedFormatKey")
    #expect(specifiers(formats[0]) == specifiers(formats[1]), "\(key): \(formats[0]) × \(formats[1])")
    let variables = entries.map { Set($0.keys).subtracting(["NSStringLocalizedFormatKey"]) }
    #expect(variables[0] == variables[1] && !variables[0].isEmpty, "\(key): variáveis \(variables)")

    for variable in variables[0].intersection(variables[1]) {
      let rules = try entries.map { try #require($0[variable] as? [String: String], "\(key).\(variable)") }
      #expect(rules[0]["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType")
      #expect(rules[0]["NSStringFormatSpecTypeKey"] == rules[1]["NSStringFormatSpecTypeKey"])
      #expect(rules[0]["NSStringFormatValueTypeKey"] == rules[1]["NSStringFormatValueTypeKey"])
      for (language, rule) in zip(languages, rules) {
        let forms = rule.filter { $0.key != "NSStringFormatSpecTypeKey" && $0.key != "NSStringFormatValueTypeKey" }
        #expect(forms["other"] != nil, "\(language) \(key).\(variable) sem a forma other")
        for (form, text) in forms {
          #expect(!text.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) \(key).\(variable).\(form) vazio")
        }
        // O número aparece na forma geral; as outras podem escrevê-lo por extenso, mas não trazem outro tipo.
        let other = specifiers(forms["other"] ?? "")
        #expect(other == ["%" + (rule["NSStringFormatValueTypeKey"] ?? "")], "\(language) \(key).\(variable).other")
        for (form, text) in forms {
          #expect(Set(specifiers(text)).isSubset(of: other), "\(language) \(key).\(variable).\(form)")
        }
      }
    }
  }
}

/// Os argumentos de cada `L10n.string(…)` (ou `string(…)`, dentro do próprio `L10n`), até o
/// parêntese que fecha a chamada.
private func l10nCalls(in code: String) -> [Substring] {
  code.ranges(of: "string(").filter { range in
    // Não conta `localizedString(`, `attributedString(` e afins.
    range.lowerBound == code.startIndex || !code[code.index(before: range.lowerBound)].isLetter
  }.map { range in
    var depth = 1, end = range.upperBound
    while end < code.endIndex, depth > 0 {
      if code[end] == "(" { depth += 1 } else if code[end] == ")" { depth -= 1 }
      end = code.index(after: end)
    }
    return code[range.upperBound..<end]
  }
}

/// Toda chave citada no código do app existe na tabela (senão a interface mostraria a chave).
/// Conta cada literal com cara de chave dentro de um `string(…)`, inclusive os escolhidos
/// por um `? :` ("panel.title.result" : "panel.title.nothing").
@Test func everyKeyUsedInCodeExists() throws {
  var known = Set(try table("pt-BR", "Localizable.strings").keys)
  known.formUnion(try table("pt-BR", "Localizable.stringsdict").keys)
  let files = try FileManager.default.contentsOfDirectory(at: appSources, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "swift" }
  var used = Set<String>()
  for file in files {
    let code = try String(contentsOf: file, encoding: .utf8)
    for call in l10nCalls(in: code) {
      for match in call.matches(of: /"([a-z]+(?:\.[A-Za-z]+)+)"/) { used.insert(String(match.output.1)) }
    }
  }
  #expect(used.count >= 25, "achou só \(used.count) chaves no código")
  #expect(used.isSubset(of: known), "sem texto: \(used.subtracting(known).sorted())")
}
