import Foundation

/// The frontmatter a kind of rule file understands, so the editor can show
/// it as a form instead of raw YAML.
public struct RuleFormat: Sendable, Hashable {
    public struct Field: Sendable, Hashable, Identifiable {
        public enum Kind: Sendable, Hashable {
            case text
            /// A YAML list, edited as comma-separated text.
            case list
            /// A comma-separated string (Cursor `globs`, Copilot `applyTo`).
            case commaText
            case bool
            case choice([String])
        }
        public var id: String { key }
        public var key: String
        public var label: String
        public var kind: Kind
        public var help: String
    }

    public var name: String
    public var fields: [Field]

    /// The format for `url`, judged by where it sits and its name.
    public static func detect(_ url: URL) -> RuleFormat? {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent
        if name == "SKILL.md" { return skill }
        if url.pathExtension == "mdc", path.contains("/.cursor/rules/") { return cursor }
        if name.hasSuffix(".instructions.md") { return copilot }
        if path.contains("/.devin/rules/") || path.contains("/.windsurf/rules/") { return devin }
        if path.contains("/.claude/rules/") { return claude }
        if path.contains("/.clinerules/") || path.contains("/Cline/Rules/") { return cline }
        return nil
    }

    static let skill = RuleFormat(name: "Skill", fields: [
        .init(key: "name", label: "Name", kind: .text, help: "Lowercase words joined by hyphens"),
        .init(key: "description", label: "Description", kind: .text,
              help: "What the skill does and when to use it; the agent decides from this alone"),
    ])

    static let claude = RuleFormat(name: "Claude Code rule", fields: [
        .init(key: "paths", label: "Only for files", kind: .list,
              help: "Globs such as src/api/**/*.ts. Empty: loaded in every session"),
    ])

    static let cursor = RuleFormat(name: "Cursor rule", fields: [
        .init(key: "alwaysApply", label: "Every chat", kind: .bool, help: "Applied to every chat"),
        .init(key: "globs", label: "Files", kind: .commaText,
              help: "Applied when matching files are in context, e.g. *.ts, src/**"),
        .init(key: "description", label: "Description", kind: .text,
              help: "Lets the agent decide when the rule is relevant"),
    ])

    static let copilot = RuleFormat(name: "Copilot instructions", fields: [
        .init(key: "applyTo", label: "Files", kind: .commaText,
              help: "Applied when working on matching files, e.g. **/*.ts. ** means every file"),
        .init(key: "description", label: "Description", kind: .text,
              help: "Lets the agent pick the file when no glob matches"),
    ])

    static let devin = RuleFormat(name: "Devin rule", fields: [
        .init(key: "trigger", label: "Activation", kind: .choice(["always_on", "glob", "model_decision", "manual"]),
              help: "always_on: every session · glob: matching files · model_decision: when the description fits · manual: only when invoked"),
        .init(key: "globs", label: "Files", kind: .commaText, help: "Used when activation is glob"),
        .init(key: "description", label: "Description", kind: .text, help: "Used when activation is model_decision"),
    ])

    static let cline = RuleFormat(name: "Cline rule", fields: [
        .init(key: "paths", label: "Only for files", kind: .list,
              help: "Globs such as src/**/*.ts. Only Cline’s older extension honours this; the newer one always applies the rule"),
    ])

    // MARK: Reading and writing values

    /// The field's value as the form shows it.
    public static func value(of field: Field, in text: String) -> String {
        let yaml = Frontmatter.split(text).yaml ?? ""
        switch field.kind {
        case .list: return Frontmatter.list(field.key, in: yaml).joined(separator: ", ")
        // Reads folded and literal blocks (`key: >`) too, not just their marker.
        default: return SkillResolver.frontmatter(text)[field.key] ?? Frontmatter.scalar(field.key, in: yaml) ?? ""
        }
    }

    /// `text` with the field set to `value`; an empty value removes the key.
    public static func setting(_ field: Field, to value: String, in text: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        let lines: [String]?
        switch field.kind {
        case .list:
            let items = Frontmatter.commaList(v)
            lines = items.isEmpty ? nil : ["\(field.key):"] + items.map { "  - \(Frontmatter.quoted($0))" }
        case .bool:
            lines = ["\(field.key): \(v == "true" ? "true" : "false")"]
        case .commaText where field.key == "globs":
            // Cursor and Windsurf write globs bare and parse them leniently.
            lines = v.isEmpty ? nil : ["\(field.key): \(v)"]
        case .text, .commaText, .choice:
            lines = v.isEmpty ? nil : ["\(field.key): \(Frontmatter.quoteIfNeeded(v))"]
        }
        return Frontmatter.replacing(field.key, with: lines, in: text)
    }
}

extension Frontmatter {
    /// Replaces the top-level `key` (and any indented lines under it) with
    /// `lines`, or removes it when `lines` is nil. Adds a frontmatter block
    /// when there is none.
    static func replacing(_ key: String, with lines: [String]?, in text: String) -> String {
        // A leading BOM stays where it is, ahead of the block.
        if text.hasPrefix("\u{FEFF}") { return "\u{FEFF}" + replacing(key, with: lines, in: String(text.dropFirst())) }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = split(normalized)
        guard let yaml = parts.yaml else {
            guard let lines else { return text }
            return "---\n" + lines.joined(separator: "\n") + "\n---\n" + (text.hasPrefix("\n") ? text : "\n" + text)
        }
        let body = parts.body
        var yamlLines = yaml.isEmpty ? [] : yaml.components(separatedBy: "\n")
        var insertAt = yamlLines.count
        if let start = yamlLines.firstIndex(where: { $0.hasPrefix(key + ":") }) {
            var end = start + 1
            while end < yamlLines.count, yamlLines[end].hasPrefix(" ") || yamlLines[end].hasPrefix("\t")
                    || yamlLines[end].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                end += 1
            }
            yamlLines.removeSubrange(start..<end)
            insertAt = start
        }
        if let lines { yamlLines.insert(contentsOf: lines, at: insertAt) }
        if yamlLines.isEmpty {
            // Nothing left: drop the block, and the blank line that followed it.
            return body.hasPrefix("\n") ? String(body.dropFirst()) : body
        }
        return "---\n" + yamlLines.joined(separator: "\n") + "\n---\n" + body
    }

    static func quoteIfNeeded(_ value: String) -> String {
        let special = ": #{}[],&*!|>'\"%@`"
        let needs = value.contains { special.contains($0) } || value.hasPrefix(" ") || value.hasPrefix("-")
        guard needs else { return value }
        return quoted(value)
    }
}
