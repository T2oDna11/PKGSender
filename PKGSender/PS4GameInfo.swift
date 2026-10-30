import Foundation

struct PS4GameInfo: Identifiable, Hashable, Codable {
    let titleID: String
    var title: String
    var version: String
    var iconData: Data?
    var id: String { titleID }
}

enum PS4SFO {
    static func parse(_ data: Data) -> [String:String] {
        guard data.count >= 20, u32(data,4) == 0x00000101 else { return [:] }
        let keyOffset = Int(u32(data,8)), dataOffset = Int(u32(data,12)), count = Int(u32(data,16))
        guard keyOffset < data.count, dataOffset < data.count, count < 2048 else { return [:] }
        var out:[String:String] = [:]
        for i in 0..<count {
            let o = 20 + i * 16; guard o + 16 <= data.count else { break }
            let ko = Int(u16(data,o)), len = Int(u32(data,o+4)), valueOff = Int(u32(data,o+12))
            let ks = keyOffset + ko, vs = dataOffset + valueOff
            guard ks < data.count, vs < data.count else { continue }
            let key = cString(data, ks, max: 128)
            let end = min(data.count, vs + max(0,len)); guard end > vs else { continue }
            let raw = data.subdata(in: vs..<end)
            let value = String(data: raw.prefix { $0 != 0 }, encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            if !key.isEmpty { out[key] = value }
        }
        return out
    }
    private static func u16(_ d:Data,_ o:Int)->UInt16 { guard o+2<=d.count else{return 0}; return UInt16(d[o]) | UInt16(d[o+1])<<8 }
    private static func u32(_ d:Data,_ o:Int)->UInt32 { guard o+4<=d.count else{return 0}; return UInt32(d[o]) | UInt32(d[o+1])<<8 | UInt32(d[o+2])<<16 | UInt32(d[o+3])<<24 }
    private static func cString(_ d:Data,_ o:Int,max:Int)->String { let e=min(d.count,o+max); guard o<e else{return ""}; let bytes=d[o..<e].prefix{$0 != 0}; return String(bytes:bytes,encoding:.utf8) ?? "" }
}


enum PS4GameCache {
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PKGSender-Cheats-Games.json")
    }

    static func load() -> [PS4GameInfo] {
        guard let data = try? Data(contentsOf: fileURL),
              let games = try? JSONDecoder().decode([PS4GameInfo].self, from: data) else { return [] }
        return games
    }

    static func save(_ games: [PS4GameInfo]) {
        guard let data = try? JSONEncoder().encode(games) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
