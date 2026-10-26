import Foundation

/// Removes parts of a Hugging Face hub cache so that the space is really
/// freed (v4.2). Snapshot entries are symlinks into the repo's `blobs/`,
/// which with newer `huggingface_hub` versions are themselves symlinks into
/// a shared `<hub>/blobs/` store. Deleting a snapshot folder alone leaves
/// all the data behind — so this follows each link chain and deletes the
/// targets that no remaining link uses.
enum HFCacheJanitor {
    /// Deletes `paths` (snapshot files or folders inside `hubRoot`) and every
    /// blob that only they referenced. Returns the bytes freed.
    @discardableResult
    static func remove(_ paths: [URL], hubRoot: URL) throws -> Int64 {
        let fm = FileManager.default
        let hub = canonical(hubRoot.path)
        // 1. Every link chain below the paths: immediate targets and final files.
        var intermediates = Set<String>()
        var finals = Set<String>()
        for path in paths where fm.fileExists(atPath: path.path) || isSymlink(path.path) {
            for link in symlinks(under: path) {
                var current = link
                var hops = 0
                while let target = linkTarget(of: current), hops < 8 {
                    hops += 1
                    if isSymlink(target) { intermediates.insert(target) } else { finals.insert(target); break }
                    current = target
                }
            }
        }
        var freed: Int64 = 0
        for path in paths where fm.fileExists(atPath: path.path) || isSymlink(path.path) {
            try fm.removeItem(at: path)
        }
        // 2. Repo-level blob links that no snapshot uses any more.
        let snapshotTargets = Set(allSymlinks(in: hub).filter { !intermediates.contains($0) }.compactMap(linkTarget))
        for link in intermediates where !snapshotTargets.contains(link) {
            try? fm.removeItem(atPath: link)
        }
        // 3. Data files no remaining link resolves to.
        let stillUsed = Set(allSymlinks(in: hub).compactMap { resolvedPath($0) })
        for file in finals where !stillUsed.contains(file) && file.hasPrefix(hub + "/") {
            freed += (try? fm.attributesOfItem(atPath: file)[.size] as? Int64) ?? 0
            try? fm.removeItem(atPath: file)
            try? fm.removeItem(atPath: file + ".refs")
        }
        return freed
    }

    /// Removes a whole repo (`models--org--name`) from the cache.
    @discardableResult
    static func removeRepo(_ repo: String, hubRoot: URL) throws -> Int64 {
        let dir = repoDirectory(repo, hubRoot: hubRoot)
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        let freed = try remove([dir.appendingPathComponent("snapshots", isDirectory: true)], hubRoot: hubRoot)
        try? FileManager.default.removeItem(at: dir)
        return freed
    }

    static func repoDirectory(_ repo: String, hubRoot: URL) -> URL {
        hubRoot.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// Bytes a folder occupies, following the snapshot links to their data.
    static func resolvedSize(of url: URL) -> Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        let fm = FileManager.default
        guard let items = fm.enumerator(atPath: url.path) else { return 0 }
        for case let relative as String in items {
            let path = url.appendingPathComponent(relative).path
            guard let real = resolvedPath(path) ?? (isSymlink(path) ? nil : path), !seen.contains(real) else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: real, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            seen.insert(real)
            total += (try? fm.attributesOfItem(atPath: real)[.size] as? Int64) ?? 0
        }
        return total
    }

    // MARK: Links

    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// Absolute, normalized target of one link hop.
    private static func linkTarget(of path: String) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        let base = (path as NSString).deletingLastPathComponent
        // Lexical on purpose: Foundation's standardizing resolves ".." through
        // symlinks and would skip the repo-level link this needs to see.
        return canonical(lexical(destination.hasPrefix("/") ? destination : base + "/" + destination))
    }

    private static func resolvedPath(_ path: String) -> String? {
        guard isSymlink(path) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func symlinks(under url: URL) -> [String] {
        let root = canonical(url.path)
        if isSymlink(root) { return [root] }
        return allSymlinks(in: root)
    }

    /// The path with its parent folders resolved but not the item itself.
    private static func canonical(_ path: String) -> String {
        let clean = lexical(path)
        let parent = URL(fileURLWithPath: (clean as NSString).deletingLastPathComponent).resolvingSymlinksInPath().path
        return (parent as NSString).appendingPathComponent((clean as NSString).lastPathComponent)
    }

    /// Removes "." and ".." without touching the file system.
    private static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(component) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func allSymlinks(in root: String) -> [String] {
        guard let items = FileManager.default.enumerator(atPath: root) else { return [] }
        var links: [String] = []
        for case let relative as String in items {
            let path = (root as NSString).appendingPathComponent(relative)
            if isSymlink(path) { links.append(canonical(path)) }
        }
        return links
    }
}
