import Foundation

struct LibraryPackage: Identifiable, Codable, Equatable {
    let id: UUID
    var relativePath: String?
    var fileName: String
    var fileSize: UInt64
    var title: String
    var titleID: String
    var contentID: String
    var version: String
    var category: String
    var kindRawValue: String
    let dateAdded: Date
    var iconFileName: String?

    var kind: PKGMetadata.Kind {
        PKGMetadata.Kind(rawValue: kindRawValue) ?? .other
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var packages: [LibraryPackage] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: Double = 0
    @Published private(set) var lastError: String?

    private let fm = FileManager.default
    private let indexFileName = "library-index.json"
    private let iconsDirectoryName = "LibraryIcons"

    init() {
        createLibraryFolderIfNeeded()
        loadIndex()
    }

    var libraryFolderURL: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PKG Sender", isDirectory: true)
    }

    func createLibraryFolderIfNeeded() {
        do {
            try fm.createDirectory(at: libraryFolderURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: iconsDirectoryURL, withIntermediateDirectories: true)
        } catch { lastError = error.localizedDescription }
    }

    func fileURL(for package: LibraryPackage) -> URL? {
        if let relativePath = package.relativePath {
            let savedURL = libraryFolderURL.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: savedURL.path) { return savedURL }
        }

        // Most library PKGs live directly in the app folder. Check that cheap path
        // before falling back to a recursive recovery scan.
        let directURL = libraryFolderURL.appendingPathComponent(package.fileName)
        if fm.fileExists(atPath: directURL.path) { return directURL }

        // Recover stale library records by locating the PKG again inside the app's
        // library folder. This prevents a valid file from being shown as Missing
        // just because its previously saved relative path became stale.
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: libraryFolderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "pkg",
                  url.lastPathComponent.caseInsensitiveCompare(package.fileName) == .orderedSame else { continue }
            if package.fileSize == 0 { return url }
            let size = (try? url.resourceValues(forKeys: Set(keys)).fileSize).map(UInt64.init) ?? 0
            if size == package.fileSize { return url }
        }
        return nil
    }

    func isFileAvailable(_ package: LibraryPackage) -> Bool {
        fileURL(for: package) != nil
    }

    func iconData(for package: LibraryPackage) -> Data? {
        guard let name = package.iconFileName else { return nil }
        return try? Data(contentsOf: iconsDirectoryURL.appendingPathComponent(name))
    }

    // Called when a PKG is selected from Home. The library record is created
    // immediately after metadata is read; sending is not required.
    func addSelectedPackage(url: URL, metadata: PKGMetadata) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let relativePath: String?
        let rootPath = libraryFolderURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            relativePath = String(filePath.dropFirst(rootPath.count + 1))
        } else {
            relativePath = nil
        }
        upsert(url: url, relativePath: relativePath, size: size, metadata: metadata)
        sortAndSave()
    }

    func scan() {
        guard !isScanning else { return }
        createLibraryFolderIfNeeded()
        isScanning = true
        scanProgress = 0
        lastError = nil

        let root = libraryFolderURL
        let existing = packages
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
            let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, _ in true })
            var urls: [URL] = []
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension.lowercased() == "pkg" { urls.append(url) }
            }

            // Metadata is permanent until the user explicitly removes it from the Library.
            // A scan only refreshes file availability. Missing files keep their saved metadata.
            var result = existing.map { item -> LibraryPackage in
                var copy = item
                copy.relativePath = nil
                return copy
            }

            for (offset, url) in urls.enumerated() {
                let relative = String(url.path.dropFirst(root.path.count + (url.path.count > root.path.count ? 1 : 0)))
                let size = (try? url.resourceValues(forKeys: keys).fileSize).map(UInt64.init) ?? 0

                if let metadata = try? PKGMetadataParser.parse(url: url) {
                    DispatchQueue.main.sync {
                        self.upsertInto(&result, url: url, relativePath: relative, size: size, metadata: metadata)
                    }
                }

                let progress = urls.isEmpty ? 1 : Double(offset + 1) / Double(urls.count)
                DispatchQueue.main.async { self.scanProgress = progress }
            }

            DispatchQueue.main.async {
                self.packages = result
                self.sortAndSave()
                self.isScanning = false
                self.scanProgress = 1
                self.removeUnusedIcons()
            }
        }
    }

    func removeFromLibrary(_ package: LibraryPackage) {
        packages.removeAll { $0.id == package.id }
        saveIndex()
        removeUnusedIcons()
    }

    private func upsert(url: URL, relativePath: String?, size: UInt64, metadata: PKGMetadata) {
        upsertInto(&packages, url: url, relativePath: relativePath, size: size, metadata: metadata)
    }

    private func upsertInto(_ array: inout [LibraryPackage], url: URL, relativePath: String?, size: UInt64, metadata: PKGMetadata) {
        let match = array.firstIndex { item in
            if !metadata.contentID.isEmpty && !item.contentID.isEmpty {
                return item.contentID.caseInsensitiveCompare(metadata.contentID) == .orderedSame &&
                       item.version == metadata.version && item.kindRawValue == metadata.kind.rawValue
            }
            if !metadata.titleID.isEmpty && !item.titleID.isEmpty {
                return item.titleID.caseInsensitiveCompare(metadata.titleID) == .orderedSame &&
                       item.version == metadata.version && item.kindRawValue == metadata.kind.rawValue
            }
            return item.fileName.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame && item.fileSize == size
        }

        if let index = match {
            array[index].relativePath = relativePath ?? array[index].relativePath
            array[index].fileName = url.lastPathComponent
            array[index].fileSize = size
            array[index].title = metadata.title
            array[index].titleID = metadata.titleID
            array[index].contentID = metadata.contentID
            array[index].version = metadata.version
            array[index].category = metadata.category
            array[index].kindRawValue = metadata.kind.rawValue
            if array[index].iconFileName == nil { array[index].iconFileName = saveIcon(metadata.iconData) }
        } else {
            array.append(LibraryPackage(
                id: UUID(), relativePath: relativePath, fileName: url.lastPathComponent,
                fileSize: size, title: metadata.title, titleID: metadata.titleID,
                contentID: metadata.contentID, version: metadata.version,
                category: metadata.category, kindRawValue: metadata.kind.rawValue,
                dateAdded: Date(), iconFileName: saveIcon(metadata.iconData)
            ))
        }
    }

    private func saveIcon(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try data.write(to: iconsDirectoryURL.appendingPathComponent(name), options: .atomic)
            return name
        } catch { return nil }
    }

    private func sortAndSave() {
        packages.sort {
            if $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedSame { return $0.kindRawValue < $1.kindRawValue }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        saveIndex()
    }

    private var appSupportURL: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private var indexURL: URL { appSupportURL.appendingPathComponent(indexFileName) }
    private var iconsDirectoryURL: URL { appSupportURL.appendingPathComponent(iconsDirectoryName, isDirectory: true) }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([LibraryPackage].self, from: data) else { return }
        packages = decoded
    }

    private func saveIndex() {
        guard let data = try? JSONEncoder().encode(packages) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func removeUnusedIcons() {
        let used = Set(packages.compactMap(\.iconFileName))
        guard let files = try? fm.contentsOfDirectory(at: iconsDirectoryURL, includingPropertiesForKeys: nil) else { return }
        for file in files where !used.contains(file.lastPathComponent) { try? fm.removeItem(at: file) }
    }
}
