import Foundation

enum FileSupport {
    static var fm: FileManager { .default }

    static func isFile(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    static func read(_ url: URL) -> String? {
        guard let data = fm.contents(atPath: url.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func size(_ url: URL) -> Int {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// Directories from the filesystem root down to `url`, inclusive.
    static func ancestors(of url: URL) -> [URL] {
        var chain: [URL] = []
        var current = url.standardizedFileURL
        while true {
            chain.append(current)
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        return chain.reversed()
    }

    /// Nearest directory at or above `url` that contains a `.git` entry.
    static func gitRoot(of url: URL) -> URL? {
        for dir in ancestors(of: url).reversed() where exists(dir.appendingPathComponent(".git")) {
            return dir
        }
        return nil
    }

    /// True when `url` is `root` or lies below it.
    static func isWithin(_ url: URL, _ root: URL) -> Bool {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + path.dropFirst(1) }
        return path
    }

    /// Recursively lists regular files below `dir`, skipping heavy or hidden
    /// directories, up to `maxDepth` levels and `limit` results. Only files
    /// passing `include` count toward the limit, so a search for a few names
    /// is not cut short by a large tree.
    static func walk(_ dir: URL, maxDepth: Int = 6, limit: Int = 2000,
                     skipHidden: Bool = true, include: (URL) -> Bool = { _ in true }) -> [URL] {
        let skip: Set<String> = ["node_modules", ".git", ".build", "build", "DerivedData",
                                 "Pods", ".venv", "venv", "__pycache__", "dist", "target"]
        var result: [URL] = []
        func visit(_ url: URL, depth: Int) {
            guard depth <= maxDepth, result.count < limit,
                  let children = try? fm.contentsOfDirectory(
                      at: url, includingPropertiesForKeys: [.isDirectoryKey],
                      options: skipHidden ? [.skipsHiddenFiles] : []) else { return }
            for child in children.sorted(by: { $0.path < $1.path }) {
                if result.count >= limit { return }
                // Follows symlinks, so linked rule folders are walked; the depth
                // bound stops cycles.
                if isDirectory(child) {
                    if !skip.contains(child.lastPathComponent) { visit(child, depth: depth + 1) }
                } else if include(child) {
                    result.append(child.standardizedFileURL)
                }
            }
        }
        visit(dir, depth: 0)
        return result
    }
}

public enum TokenEstimator {
    /// Rough count: ~4 bytes per token for ASCII text, ~1 token per
    /// non-ASCII scalar (CJK and the like).
    public static func estimate(_ text: String) -> Int {
        var ascii = 0, other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return Int((Double(ascii) / 4).rounded(.up)) + other
    }
}

enum Frontmatter {
    /// Splits a leading `---` YAML block from the body. Returns nil fields
    /// when there is none.
    static func split(_ text: String) -> (yaml: String?, body: String) {
        // Windows editors may save a UTF-8 BOM ahead of the block.
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return (nil, text) }
        // Windows line endings would leave a \r on every key and on the closing ---.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return (nil, text) }
        let yaml = lines[1..<end].joined(separator: "\n")
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (yaml, body)
    }

    /// Reads a YAML string list such as `paths:` in either block or inline
    /// form. Enough for rule frontmatter; not a general YAML parser.
    static func list(_ key: String, in yaml: String) -> [String] {
        let lines = yaml.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) else { return [] }
        let inline = lines[i].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if inline.hasPrefix("[") {
            let inner = inline.dropFirst()
            return commaList(String(inner.hasSuffix("]") ? inner.dropLast() : inner)).map(unquote).filter { !$0.isEmpty }
        }
        if !inline.isEmpty { return [unquote(inline)] }
        var items: [String] = []
        for line in lines[(i + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { break }
            items.append(unquote(String(t.dropFirst(2))))
        }
        return items
    }

    static func scalar(_ key: String, in yaml: String) -> String? {
        for line in yaml.components(separatedBy: "\n") where line.hasPrefix(key + ":") {
            let v = unquote(String(line.dropFirst(key.count + 1)))
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// Reads a YAML scalar: a matching pair of quotes is removed, with the
    /// escapes `quoted` writes undone.
    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, let q = t.first, q == "\"" || q == "'", t.last == q else { return t }
        let inner = t.dropFirst().dropLast()
        if q == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var out = "", escaped = false
        for c in inner {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// `value` as a YAML double-quoted string; `unquote` reads it back.
    static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + escaped + "\""
    }

    /// Splits comma-separated globs, leaving the commas inside `{a,b}` alone.
    static func commaList(_ s: String) -> [String] {
        var items: [String] = [], current = "", depth = 0
        for c in s {
            switch c {
            case "{": depth += 1
            case "}": depth = max(0, depth - 1)
            case "," where depth == 0:
                items.append(current)
                current = ""
                continue
            default: break
            }
            current.append(c)
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

enum Glob {
    /// Converts a glob with `**`, `*`, `?` and `{a,b}` into an anchored regex.
    static func regex(_ pattern: String) -> NSRegularExpression? {
        var out = "^"
        var chars = Array(pattern)[...]
        var braceDepth = 0
        while let c = chars.first {
            chars = chars.dropFirst()
            switch c {
            case "*":
                if chars.first == "*" {
                    chars = chars.dropFirst()
                    if chars.first == "/" {
                        chars = chars.dropFirst()
                        out += "(?:.*/)?"
                    } else {
                        out += ".*"
                    }
                } else {
                    out += "[^/]*"
                }
            case "?": out += "[^/]"
            case "{": braceDepth += 1; out += "(?:"
            case "}" where braceDepth > 0: braceDepth -= 1; out += ")"
            case "," where braceDepth > 0: out += "|"
            default: out += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        return try? NSRegularExpression(pattern: out + "$")
    }

    static func matches(_ pattern: String, _ relativePath: String) -> Bool {
        guard let re = regex(pattern) else { return false }
        return re.firstMatch(in: relativePath, range: NSRange(relativePath.startIndex..., in: relativePath)) != nil
    }

    static func hasWildcard(_ s: String) -> Bool { s.contains { "*?{[".contains($0) } }

    /// Expands a glob relative to `base` into matching files.
    static func expand(_ pattern: String, base: URL) -> [URL] {
        guard hasWildcard(pattern) else {
            let url = URL(fileURLWithPath: pattern, relativeTo: base).standardizedFileURL
            return FileSupport.isFile(url) ? [url] : []
        }
        // Walk only from the longest literal directory prefix.
        let full = pattern.hasPrefix("/") ? pattern : base.standardizedFileURL.path + "/" + pattern
        let parts = full.split(separator: "/").map(String.init)
        let literal = parts.prefix { !hasWildcard($0) }
        let root = URL(fileURLWithPath: "/" + literal.joined(separator: "/")).standardizedFileURL
        let rest = parts.dropFirst(literal.count).joined(separator: "/")
        return FileSupport.walk(root, skipHidden: false).filter { url in
            matches(rest, String(url.path.dropFirst(root.path.count + 1)))
        }
    }
}

enum JSONC {
    /// Removes // and /* */ comments and trailing commas so JSONSerialization
    /// can read opencode.jsonc.
    static func object(from text: String) -> [String: Any]? {
        var out = ""
        // A byte-order mark isn't JSON.
        var i = text.first == "\u{FEFF}" ? text.index(after: text.startIndex) : text.startIndex
        var inString = false
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i) < text.endIndex ? text[text.index(after: i)] : nil
            if inString {
                out.append(c)
                if c == "\\", let n = next { out.append(n); i = text.index(i, offsetBy: 2); continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true; out.append(c)
            } else if c == "/" && next == "/" {
                // isNewline, since "\r\n" is one Character that isn't "\n".
                while i < text.endIndex && !text[i].isNewline { i = text.index(after: i) }
                continue
            } else if c == "/" && next == "*" {
                i = text.index(i, offsetBy: 2)
                while i < text.endIndex {
                    if text[i] == "*", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "/" {
                        i = text.index(i, offsetBy: 2); break
                    }
                    i = text.index(after: i)
                }
                continue
            } else {
                out.append(c)
            }
            i = text.index(after: i)
        }
        return (try? JSONSerialization.jsonObject(with: Data(dropTrailingCommas(out).utf8))) as? [String: Any]
    }

    /// Removes a comma that only whitespace separates from a closing } or ],
    /// leaving string contents alone.
    private static func dropTrailingCommas(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var inString = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "\\", i + 1 < chars.count { out.append(c); out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}
