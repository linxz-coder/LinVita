import Foundation

@main enum TrophyModelTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let snapshot = try TrophySnapshot.decode(data, simplifiedChinese: true)
        precondition(snapshot.collections.count == 1 && !snapshot.hasReadErrors)
        let game = snapshot.collections[0]
        precondition(game.id == "NPWR02155_00" && game.trophies.count == 56)
        precondition(game.earned.map(\.id) == [53, 54] && game.count(grade: 4) == 2)
        precondition(game.earned[0].name == "触碰背面" && game.earned[1].name == "收藏家")
        precondition(game.earned[0].earnedDate == Date(timeIntervalSince1970: 1793718811))
        precondition(game.earned[1].earnedDate == Date(timeIntervalSince1970: 1793773049))
        precondition(abs(game.progress - 2.0/56.0) < 0.000001)
        precondition(game.trophies.filter { !$0.earned }.allSatisfy { $0.earnedDate == nil })
        let original = try TrophySnapshot.decode(data, simplifiedChinese: false)
        precondition(original.collections[0].earned[0].name == "觸碰背面")
        let xml = String(decoding: data, as: UTF8.self)
        let unreadable = try TrophySnapshot.decode(Data(xml.replacingOccurrences(of: "progress=\"loaded\"", with: "progress=\"unreadable\"").utf8), simplifiedChinese: true)
        precondition(unreadable.hasReadErrors && !unreadable.collections[0].progressReadable)
        precondition(unreadable.collections[0].earned.isEmpty)
        for bad in [String(xml.dropLast(20)), xml.replacingOccurrences(of: "schema=\"1\"", with: "schema=\"2\""), xml.replacingOccurrences(of: "id=\"54\"", with: "id=\"53\"")] {
            do { _ = try TrophySnapshot.decode(Data(bad.utf8), simplifiedChinese: true); preconditionFailure("Malformed or duplicate data accepted") }
            catch TrophyReadError.invalidData { }
        }
        let empty = try TrophySnapshot.decode(Data("<collections schema=\"1\" user=\"00\"/>".utf8), simplifiedChinese: true)
        precondition(empty.collections.isEmpty && !empty.hasReadErrors)
        print("PASS: phone-derived 2/56 trophies, grades, timestamps, simplified text, locked dates, empty data and invalid progress/XML")
    }
}
