import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct TrophyRecord: Identifiable, Sendable {
    let id: Int
    let name: String
    let detail: String
    let grade: Int
    let hidden: Bool
    let earned: Bool
    let timestamp: UInt64
    let iconPath: String

    var earnedDate: Date? {
        earned && timestamp > 0 ? Date(timeIntervalSince1970: Double(timestamp)) : nil
    }
}

struct TrophyCollection: Identifiable, Sendable {
    let id: String
    let title: String
    let iconPath: String
    let progressStatus: String
    var trophies: [TrophyRecord]
    var progressReadable: Bool { progressStatus == "loaded" || progressStatus == "missing" }
    var earned: [TrophyRecord] { progressReadable ? trophies.filter(\.earned) : [] }
    var progress: Double { trophies.isEmpty ? 0 : Double(earned.count) / Double(trophies.count) }
    func count(grade: Int) -> Int { earned.filter { $0.grade == grade }.count }
}

struct TrophySnapshot: Sendable {
    var collections: [TrophyCollection] = []
    var unreadableIDs: [String] = []
    var hasReadErrors: Bool { !unreadableIDs.isEmpty || collections.contains { !$0.progressReadable } }

    static func decode(_ data: Data, simplifiedChinese: Bool) throws -> Self {
        let reader = TrophyXMLReader(simplifiedChinese: simplifiedChinese)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), reader.validRoot, !reader.invalid else { throw TrophyReadError.invalidData }
        return reader.snapshot
    }
}

enum TrophyReadError: Error { case invalidData, unavailable(Int32) }

private final class TrophyXMLReader: NSObject, XMLParserDelegate {
    let simplifiedChinese: Bool
    var snapshot = TrophySnapshot()
    var validRoot = false
    var invalid = false
    private var current: TrophyCollection?
    private var collectionIDs: Set<String> = []
    private var trophyIDs: Set<Int> = []

    init(simplifiedChinese: Bool) { self.simplifiedChinese = simplifiedChinese }

    private func displayText(_ value: String) -> String {
        simplifiedChinese ? (value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value) : value
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String]) {
        switch elementName {
        case "collections":
            validRoot = a["schema"] == "1"
        case "unreadable":
            if let id = a["id"] { snapshot.unreadableIDs.append(id) }
        case "collection":
            guard let id = a["id"], !id.isEmpty, collectionIDs.insert(id).inserted,
                  let title = a["title"], let progress = a["progress"], current == nil else { invalid = true; return }
            current = TrophyCollection(id: id, title: displayText(title), iconPath: a["icon"] ?? "", progressStatus: progress, trophies: [])
            trophyIDs.removeAll()
        case "trophy":
            guard current != nil, let id = a["id"].flatMap(Int.init), (0..<128).contains(id), trophyIDs.insert(id).inserted,
                  let name = a["name"], let detail = a["detail"], let grade = a["grade"].flatMap(Int.init),
                  (0...4).contains(grade), let timestamp = a["timestamp"].flatMap(UInt64.init),
                  let earned = a["earned"].flatMap(Bool.init), let hidden = a["hidden"].flatMap(Bool.init) else { invalid = true; return }
            current?.trophies.append(TrophyRecord(id: id, name: displayText(name), detail: displayText(detail), grade: grade,
                                                  hidden: hidden, earned: earned, timestamp: timestamp, iconPath: a["icon"] ?? ""))
        default: invalid = true
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "collection", let collection = current {
            snapshot.collections.append(collection)
            current = nil
        }
    }
}
