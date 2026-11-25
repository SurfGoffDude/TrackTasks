// Проверяет готовую ленту публичным ключом из приложения: swift check-appcast.swift <appcast.xml> <архив.zip> <ключ base64>
// Проверяется: подпись ленты, ровно одна запись, https-адрес, длина и подпись архива.
import CryptoKit
import Foundation

func fail(_ why: String) -> Never {
    FileHandle.standardError.write(Data("Лента не принята: \(why)\n".utf8))
    exit(1)
}

let a = CommandLine.arguments
guard a.count == 4, let feed = FileManager.default.contents(atPath: a[1]), let zip = FileManager.default.contents(atPath: a[2]),
      let raw = Data(base64Encoded: a[3]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { fail("нет файлов или ключа") }

// The same cut as in Sparkle's SPUExtractAppcastContent.
guard let mark = feed.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards) else { fail("лента не подписана") }
let content = feed[..<mark.lowerBound]
var fields: [String: String] = [:]
for line in String(decoding: feed[mark.upperBound...], as: UTF8.self).split(separator: "\n") {
    let p = line.split(separator: ":", maxSplits: 1)
    if p.count == 2 { fields[String(p[0])] = p[1].trimmingCharacters(in: .whitespaces) }
}
guard let s = fields["edSignature"].flatMap({ Data(base64Encoded: $0) }), key.isValidSignature(s, for: content) else {
    fail("подпись ленты не подходит к TT_SPARKLE_PUBLIC_KEY")
}

guard let doc = try? XMLDocument(data: Data(content)), let found = try? doc.nodes(forXPath: "//item/enclosure") as? [XMLElement],
      found.count == 1, let e = found.first else { fail("нужна ровно одна запись") }
guard let url = e.attribute(forName: "url")?.stringValue, url.hasPrefix("https://"),
      URL(string: url)?.lastPathComponent == URL(fileURLWithPath: a[2]).lastPathComponent else { fail("адрес архива") }
guard e.attribute(forName: "length")?.stringValue == String(zip.count) else { fail("длина архива") }
guard let z = e.attribute(forName: "sparkle:edSignature")?.stringValue.flatMap({ Data(base64Encoded: $0) }), key.isValidSignature(z, for: zip) else {
    fail("подпись архива не подходит к TT_SPARKLE_PUBLIC_KEY")
}
print("Лента и архив подписаны ключом приложения")
