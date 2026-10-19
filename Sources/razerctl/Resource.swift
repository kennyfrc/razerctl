import Foundation

/// Declarative state, Kubernetes style: you write the spec you want, the agent keeps the
/// mouse matching it, and the status reports what it actually saw.
struct MouseSpec: Codable, Equatable {
    var dpi: Int?
    var pollingHz: Int?
}

struct MouseResource: Equatable {
    var apiVersion = "razerctl.dev/v1"
    var kind = "Mouse"
    var name = "mouse"
    var spec = MouseSpec()

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/razerctl", isDirectory: true)
    static let file = directory.appendingPathComponent("mouse.yaml")
    /// Old flat config, read once so existing settings move into the resource.
    static let legacyFile = directory.appendingPathComponent("config.json")

    // MARK: - Storage

    static func load() -> MouseResource? {
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            return try? parse(text)
        }
        guard let data = try? Data(contentsOf: legacyFile),
              let legacy = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return nil }
        var resource = MouseResource()
        resource.spec.dpi = legacy["dpi"]
        resource.spec.pollingHz = legacy["polling"]
        try? resource.save()
        return resource
    }

    func save() throws {
        try FileManager.default.createDirectory(at: MouseResource.directory, withIntermediateDirectories: true)
        try rendered().write(to: MouseResource.file, atomically: true, encoding: .utf8)
    }

    // MARK: - Parsing

    /// Accepts the subset of YAML this resource needs (nested maps and scalars) or JSON.
    static func parse(_ text: String) throws -> MouseResource {
        let dictionary = try MiniYAML.parse(text)
        try rejectUnknown(dictionary, allowed: ["apiVersion", "kind", "metadata", "spec"], at: "top level")

        if let version = dictionary["apiVersion"] as? String, version != "razerctl.dev/v1" {
            throw CLIError("unsupported apiVersion '\(version)', expected razerctl.dev/v1")
        }
        if let kind = dictionary["kind"] as? String, kind != "Mouse" {
            throw CLIError("unsupported kind '\(kind)', expected Mouse")
        }

        var resource = MouseResource()
        if let metadata = dictionary["metadata"] {
            guard let map = metadata as? [String: Any] else { throw CLIError("metadata must be a map") }
            try rejectUnknown(map, allowed: ["name"], at: "metadata")
            if let name = map["name"] as? String, !name.isEmpty { resource.name = name }
        }

        if let spec = dictionary["spec"] {
            guard let map = spec as? [String: Any] else { throw CLIError("spec must be a map") }
            try rejectUnknown(map, allowed: ["dpi", "pollingHz"], at: "spec")

            if let value = try integer(map["dpi"], field: "spec.dpi") {
                guard value >= RazerCommands.dpiMin, value <= RazerCommands.dpiMax else {
                    throw CLIError("spec.dpi must be between \(RazerCommands.dpiMin) and \(RazerCommands.dpiMax)")
                }
                resource.spec.dpi = value
            }
            if let value = try integer(map["pollingHz"], field: "spec.pollingHz") {
                guard RazerCommands.supportedRates.contains(value) else {
                    let rates = RazerCommands.supportedRates.map(String.init).joined(separator: ", ")
                    throw CLIError("spec.pollingHz must be one of \(rates)")
                }
                resource.spec.pollingHz = value
            }
        }
        return resource
    }

    static func integer(_ value: Any?, field: String) throws -> Int? {
        guard let value else { return nil }
        if let number = value as? Int { return number }
        if let text = value as? String, let number = Int(text) { return number }
        throw CLIError("\(field) must be a whole number")
    }

    static func rejectUnknown(_ dictionary: [String: Any], allowed: [String], at place: String) throws {
        let unknown = dictionary.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw CLIError("unknown field(s) in \(place): \(unknown.joined(separator: ", "))")
        }
    }

    // MARK: - Rendering

    /// YAML for the desired part only. Status is rendered by the caller.
    func rendered() -> String {
        var lines = [
            "apiVersion: \(apiVersion)",
            "kind: \(kind)",
            "metadata:",
            "  name: \(name)",
            "spec:",
        ]
        lines.append("  dpi: \(spec.dpi.map(String.init) ?? "null")")
        lines.append("  pollingHz: \(spec.pollingHz.map(String.init) ?? "null")")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Just enough YAML for a resource file: nested maps of scalars. JSON also works.
enum MiniYAML {
    static func parse(_ text: String) throws -> [String: Any] {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }

        var lines: [(indent: Int, content: String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { continue }
            let indent = line.prefix { $0 == " " }.count
            var content = trimmed
            if let hash = content.range(of: " #") {
                content = String(content[..<hash.lowerBound])
            }
            lines.append((indent, content))
        }
        guard !lines.isEmpty else { throw CLIError("the file is empty") }

        var index = 0
        func block(_ indent: Int) throws -> [String: Any] {
            var result: [String: Any] = [:]
            while index < lines.count {
                let line = lines[index]
                if line.indent < indent { break }
                if line.indent > indent { throw CLIError("unexpected indent at '\(line.content)'") }
                guard let colon = line.content.firstIndex(of: ":") else {
                    throw CLIError("expected 'key: value' at '\(line.content)'")
                }
                let key = String(line.content[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line.content[line.content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                index += 1
                if value.isEmpty {
                    let nextIndent = index < lines.count ? lines[index].indent : indent
                    result[key] = nextIndent > indent ? try block(nextIndent) : NSNull()
                } else {
                    result[key] = scalar(value)
                }
            }
            return result
        }

        return try block(lines[0].indent)
    }

    static func scalar(_ value: String) -> Any {
        var text = value
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast())
        } else if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            text = String(text.dropFirst().dropLast())
        }
        if let number = Int(text) { return number }
        if text == "true" { return true }
        if text == "false" { return false }
        if text == "null" || text == "~" { return NSNull() }
        return text
    }
}
