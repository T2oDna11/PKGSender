import Foundation

struct CheatRepository: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var url: String
    var enabled: Bool
    var isDefault: Bool
}

struct RemoteCheat: Identifiable, Hashable, Codable {
    let repositoryID: UUID
    let repositoryName: String
    let titleID: String
    let version: String
    let gameName: String
    let format: String
    let fileName: String
    let downloadURL: URL
    var id: String { "\(repositoryID.uuidString)|\(fileName)" }
}

@MainActor
final class CheatRepositoryStore: ObservableObject {
    static let officialID = UUID(uuidString: "A9FCA96D-88B8-4C8E-B846-1F31A48A20A1")!
    @Published var repositories: [CheatRepository] = []
    private let key = "PKGSender.CheatRepositories.v1"

    init() { load() }

    func load() {
        var custom: [CheatRepository] = []
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([CheatRepository].self, from: data) { custom = saved.filter { !$0.isDefault } }
        repositories = [CheatRepository(id: Self.officialID, name: "GoldHEN Official", url: "https://github.com/GoldHEN/GoldHEN_Cheat_Repository", enabled: true, isDefault: true)] + custom
    }
    func save() { if let data = try? JSONEncoder().encode(repositories.filter { !$0.isDefault }) { UserDefaults.standard.set(data, forKey: key) } }
    func add(_ repo: CheatRepository) { repositories.append(repo); save() }
    func remove(at offsets: IndexSet) { repositories.remove(atOffsets: offsets); save() }
    func toggle(_ id: UUID) { guard let i = repositories.firstIndex(where: {$0.id == id}) else { return }; repositories[i].enabled.toggle(); save() }
}

enum CheatRepositoryClient {
    struct RepoCheck { let name: String; let owner: String; let repo: String; let branch: String; let cheatCount: Int }

    static func validate(urlString: String) async throws -> RepoCheck {
        let parts = try githubParts(urlString)
        let infoURL = URL(string: "https://api.github.com/repos/\(parts.owner)/\(parts.repo)")!
        let (infoData, response) = try await URLSession.shared.data(from: infoURL)
        try validateHTTP(response)
        let info = try JSONSerialization.jsonObject(with: infoData) as? [String:Any]
        let branch = info?["default_branch"] as? String ?? "main"
        let name = info?["name"] as? String ?? parts.repo
        let cheats = try await fetchGitHubTree(owner: parts.owner, repo: parts.repo, branch: branch, repositoryID: UUID(), repositoryName: name)
        guard !cheats.isEmpty else { throw RepoError.noCheats }
        return RepoCheck(name: name, owner: parts.owner, repo: parts.repo, branch: branch, cheatCount: cheats.count)
    }

    static func allCheats(repositories: [CheatRepository], forceRefresh: Bool = false) async -> [RemoteCheat] {
        let signature = repositories.filter { $0.enabled }.map { "\($0.id.uuidString)|\($0.url)|\($0.enabled)" }.joined(separator: ";")
        if !forceRefresh, let cached = await RepositoryCatalogCache.shared.value(for: signature) { return cached }
        var output: [RemoteCheat] = []
        for repo in repositories where repo.enabled {
            do {
                if repo.isDefault { output += try await officialCheats(titleID: "", repository: repo) }
                else {
                    let parts = try githubParts(repo.url)
                    let infoURL = URL(string: "https://api.github.com/repos/\(parts.owner)/\(parts.repo)")!
                    let (infoData, response) = try await URLSession.shared.data(from: infoURL); try validateHTTP(response)
                    let info = try JSONSerialization.jsonObject(with: infoData) as? [String:Any]
                    let branch = info?["default_branch"] as? String ?? "main"
                    output += try await fetchGitHubTree(owner: parts.owner, repo: parts.repo, branch: branch, repositoryID: repo.id, repositoryName: repo.name)
                }
            } catch { continue }
        }
        let cleaned = deduplicated(output)
        await RepositoryCatalogCache.shared.store(cleaned, for: signature)
        return cleaned
    }

    static func cheats(for titleID: String, repositories: [CheatRepository]) async -> [RemoteCheat] {
        var output: [RemoteCheat] = []
        for repo in repositories where repo.enabled {
            do {
                if repo.isDefault { output += try await officialCheats(titleID: titleID, repository: repo) }
                else { output += try await githubCheats(titleID: titleID, repository: repo) }
            } catch { continue }
        }
        return deduplicated(output)
    }


    private static func deduplicated(_ cheats: [RemoteCheat]) -> [RemoteCheat] {
        var seen = Set<String>()
        return cheats.filter {
            let key = "\($0.titleID.uppercased())|\($0.version)|\($0.format.lowercased())|\($0.fileName.lowercased())"
            return seen.insert(key).inserted
        }.sorted {
            if $0.version == $1.version { return $0.repositoryName < $1.repositoryName }
            return $0.version > $1.version
        }
    }

    static func download(_ cheat: RemoteCheat) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: cheat.downloadURL)
        try validateHTTP(response)
        return data
    }

    private static func officialCheats(titleID: String, repository: CheatRepository) async throws -> [RemoteCheat] {
        var result: [RemoteCheat] = []
        for ext in ["json","shn","mc4"] {
            let indexURL = URL(string: "https://raw.githubusercontent.com/GoldHEN/GoldHEN_Cheat_Repository/main/\(ext).txt")!
            let (data, response) = try await URLSession.shared.data(from: indexURL); try validateHTTP(response)
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) {
                let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, (titleID.isEmpty || pair[0].uppercased().contains(titleID.uppercased())), let parsed = parseFile(pair[0]) else { continue }
                let escaped = pair[0].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pair[0]
                let raw = URL(string: "https://raw.githubusercontent.com/GoldHEN/GoldHEN_Cheat_Repository/main/\(ext)/\(escaped)")!
                result.append(RemoteCheat(repositoryID: repository.id, repositoryName: repository.name, titleID: parsed.titleID, version: parsed.version, gameName: pair[1], format: ext, fileName: pair[0], downloadURL: raw))
            }
        }
        return result
    }

    private static func githubCheats(titleID: String, repository: CheatRepository) async throws -> [RemoteCheat] {
        let parts = try githubParts(repository.url)
        let infoURL = URL(string: "https://api.github.com/repos/\(parts.owner)/\(parts.repo)")!
        let (infoData, response) = try await URLSession.shared.data(from: infoURL); try validateHTTP(response)
        let info = try JSONSerialization.jsonObject(with: infoData) as? [String:Any]
        let branch = info?["default_branch"] as? String ?? "main"
        return try await fetchGitHubTree(owner: parts.owner, repo: parts.repo, branch: branch, repositoryID: repository.id, repositoryName: repository.name).filter { $0.titleID.caseInsensitiveCompare(titleID) == .orderedSame }
    }

    private static func fetchGitHubTree(owner: String, repo: String, branch: String, repositoryID: UUID, repositoryName: String) async throws -> [RemoteCheat] {
        let treeURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/git/trees/\(branch)?recursive=1")!
        let (data, response) = try await URLSession.shared.data(from: treeURL); try validateHTTP(response)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String:Any], let tree = root["tree"] as? [[String:Any]] else { throw RepoError.invalidResponse }
        var result: [RemoteCheat] = []
        for item in tree {
            guard item["type"] as? String == "blob", let path = item["path"] as? String else { continue }
            let file = (path as NSString).lastPathComponent
            guard let parsed = parseFile(file), ["json","shn","mc4"].contains(parsed.format) else { continue }
            let escapedPath = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            guard let raw = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/\(escapedPath)") else { continue }
            result.append(RemoteCheat(repositoryID: repositoryID, repositoryName: repositoryName, titleID: parsed.titleID, version: parsed.version, gameName: parsed.titleID, format: parsed.format, fileName: file, downloadURL: raw))
        }
        return result
    }

    private static func parseFile(_ file: String) -> (titleID:String, version:String, format:String)? {
        let ext = (file as NSString).pathExtension.lowercased()
        guard ["json","shn","mc4"].contains(ext) else { return nil }
        let base = (file as NSString).deletingPathExtension
        let pattern = "(CUSA\\d{5})[_-](\\d{1,2}\\.\\d{1,3})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let m = regex.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)), let r1 = Range(m.range(at:1), in:base), let r2 = Range(m.range(at:2), in:base) else { return nil }
        return (String(base[r1]).uppercased(), String(base[r2]), ext)
    }

    private static func githubParts(_ input: String) throws -> (owner:String, repo:String) {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { throw RepoError.invalidURL }
        let c = url.pathComponents.filter { $0 != "/" }
        guard c.count >= 2 else { throw RepoError.invalidURL }
        return (c[0], c[1].replacingOccurrences(of: ".git", with: ""))
    }
    private static func validateHTTP(_ response: URLResponse) throws { guard let h = response as? HTTPURLResponse, (200..<300).contains(h.statusCode) else { throw RepoError.invalidResponse } }
    enum RepoError: LocalizedError { case invalidURL, invalidResponse, noCheats; var errorDescription:String? { switch self { case .invalidURL:return "Enter a GitHub repository URL."; case .invalidResponse:return "Repository could not be read."; case .noCheats:return "No supported JSON, SHN or MC4 cheat files were detected." } } }
}

enum CheatLocalStore {
    static var root: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PKG Sender", isDirectory: true).appendingPathComponent("Cheats", isDirectory: true) }
    static func prepare() { for f in ["JSON","SHN","MC4"] { try? FileManager.default.createDirectory(at: root.appendingPathComponent(f, isDirectory:true), withIntermediateDirectories:true) } }
    static func url(for cheat: RemoteCheat) -> URL { root.appendingPathComponent(cheat.format.uppercased(), isDirectory:true).appendingPathComponent(cheat.fileName) }
    static func isDownloaded(_ cheat: RemoteCheat) -> Bool { FileManager.default.fileExists(atPath: url(for: cheat).path) }
    static func save(_ data: Data, cheat: RemoteCheat) throws { prepare(); try data.write(to: url(for: cheat), options:.atomic) }
    static func downloadedFiles() -> [URL] { prepare(); let fm = FileManager.default; guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }; return en.compactMap { $0 as? URL }.filter { ["json","shn","mc4"].contains($0.pathExtension.lowercased()) } }
}


private actor RepositoryCatalogCache {
    static let shared = RepositoryCatalogCache()
    private struct Entry { let date: Date; let cheats: [RemoteCheat] }
    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 15 * 60

    func value(for key: String) -> [RemoteCheat]? {
        guard let entry = entries[key], Date().timeIntervalSince(entry.date) < ttl else { return nil }
        return entry.cheats
    }

    func store(_ cheats: [RemoteCheat], for key: String) {
        entries[key] = Entry(date: Date(), cheats: cheats)
    }
}
