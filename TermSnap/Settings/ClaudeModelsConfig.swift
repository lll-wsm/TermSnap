import Foundation

// MARK: - Models

struct ClaudeProvider: Equatable {
    let modelName: String
    let smallFastModel: String?
    let defaultSonnetModel: String?
    let defaultOpusModel: String?
    let defaultHaikuModel: String?
    let baseURL: String
    let apiKeyEnv: String       // literal e.g. "$GLM_API_KEY" — expanded by Terminal's zsh
    let iconOverride: ProviderIconSpec?
}

/// Per-provider icon customization read from the JSON `icon` object. All fields optional.
/// Drives ClaudeProviderIcon's rendering — if absent, a neutral gray fallback is used.
struct ProviderIconSpec: Equatable {
    let label: String?       // 1-2 character mark
    let color: String?       // hex string for background, e.g. "#FF6B00" or "FF6B00"
    let textColor: String?   // hex string for foreground; defaults to white
    let shape: String?       // "rounded" (default) | "circle" | "square"
}

/// Ordered list of providers parsed from claude-models.json living in the App Group container.
///
/// The file format intentionally mirrors what users already have at `~/.config/claude-models.json`.
/// Key order is preserved by scanning the raw JSON text (JSONSerialization loses order).
struct ClaudeModelsConfig: Equatable {
    let defaultKey: String?
    let providers: [(key: String, value: ClaudeProvider)]

    static func == (lhs: ClaudeModelsConfig, rhs: ClaudeModelsConfig) -> Bool {
        lhs.defaultKey == rhs.defaultKey &&
        lhs.providers.count == rhs.providers.count &&
        zip(lhs.providers, rhs.providers).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    func provider(forKey key: String) -> ClaudeProvider? {
        providers.first(where: { $0.key == key })?.value
    }
}

// MARK: - File location (App Group container)

extension ClaudeModelsConfig {
    static let appGroupIdentifier = "group.com.lll.TermSnap"

    /// `~/Library/Group Containers/group.com.lll.TermSnap/Library/Application Support/TermSnap/claude-models.json`
    static var configURL: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return nil }
        return container
            .appendingPathComponent("Library/Application Support/TermSnap", isDirectory: true)
            .appendingPathComponent("claude-models.json")
    }

    /// First-run: if no config exists in the App Group container, copy from `~/.config/claude-models.json`
    /// (if user already has one), otherwise write a single-provider sample.
    static func bootstrapIfNeeded() {
        guard let target = configURL else { return }
        if FileManager.default.fileExists(atPath: target.path) { return }

        let dir = target.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let homeConfig = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-models.json")
        if FileManager.default.fileExists(atPath: homeConfig.path),
           let data = try? Data(contentsOf: homeConfig) {
            try? data.write(to: target, options: .atomic)
            return
        }

        try? sampleJSON.data(using: .utf8)?.write(to: target, options: .atomic)
    }

    static let sampleJSON = """
    {
      "default": "glm",
      "models": {
        "glm": {
          "model_name": "GLM-5.1",
          "small_fast_model": "GLM-5.1",
          "default_sonnet_model": "GLM-5.1",
          "default_opus_model": "GLM-5.1",
          "default_haiku_model": "GLM-5.1",
          "base_url": "https://open.bigmodel.cn/api/anthropic",
          "api_key_env": "$GLM_API_KEY"
        }
      }
    }
    """
}

// MARK: - Loading / parsing

extension ClaudeModelsConfig {
    /// Load from the App Group container. Returns nil if missing or unparseable.
    static func load() -> ClaudeModelsConfig? {
        guard let url = configURL, let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> ClaudeModelsConfig? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsDict = obj["models"] as? [String: Any] else { return nil }

        let defaultKey = obj["default"] as? String
        let text = String(data: data, encoding: .utf8) ?? ""
        let ordered = orderedModelKeys(from: text, allKeys: Set(modelsDict.keys))

        let providers: [(String, ClaudeProvider)] = ordered.compactMap { key in
            guard let raw = modelsDict[key] as? [String: Any],
                  let p = decodeProvider(from: raw) else { return nil }
            return (key, p)
        }
        return ClaudeModelsConfig(defaultKey: defaultKey, providers: providers)
    }

    private static func decodeProvider(from raw: [String: Any]) -> ClaudeProvider? {
        guard let name = raw["model_name"] as? String,
              let url = raw["base_url"] as? String,
              let env = raw["api_key_env"] as? String else { return nil }
        return ClaudeProvider(
            modelName: name,
            smallFastModel: raw["small_fast_model"] as? String,
            defaultSonnetModel: raw["default_sonnet_model"] as? String,
            defaultOpusModel: raw["default_opus_model"] as? String,
            defaultHaikuModel: raw["default_haiku_model"] as? String,
            baseURL: url,
            apiKeyEnv: env,
            iconOverride: decodeIcon(from: raw["icon"])
        )
    }

    private static func decodeIcon(from raw: Any?) -> ProviderIconSpec? {
        guard let dict = raw as? [String: Any] else { return nil }
        let label = dict["label"] as? String
        let color = dict["color"] as? String
        let textColor = dict["text_color"] as? String
        let shape = dict["shape"] as? String
        // Skip an empty icon object — saves callers a non-nil-but-useless check.
        if label == nil && color == nil && textColor == nil && shape == nil { return nil }
        return ProviderIconSpec(label: label, color: color, textColor: textColor, shape: shape)
    }

    /// Recover key order by regex-scanning the raw JSON text for `"name": {` occurrences.
    /// Provider value objects are flat (no nested `{`), so the only `"key": {` matches are
    /// the `models` wrapper plus each provider — we filter to known provider keys.
    static func orderedModelKeys(from text: String, allKeys: Set<String>) -> [String] {
        let pattern = #""([A-Za-z0-9_\-]+)"\s*:\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Array(allKeys).sorted()
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))

        var ordered: [String] = []
        for m in matches where m.numberOfRanges > 1 {
            let key = ns.substring(with: m.range(at: 1))
            if allKeys.contains(key), !ordered.contains(key) {
                ordered.append(key)
            }
        }
        // Append any keys regex missed (e.g. odd formatting) so we don't silently drop providers.
        for k in allKeys where !ordered.contains(k) { ordered.append(k) }
        return ordered
    }
}

// MARK: - Command composition

extension ClaudeModelsConfig {
    /// Build the inline-env command snippet for a provider — NOT including `cd`.
    /// Example: `ANTHROPIC_BASE_URL=… ANTHROPIC_AUTH_TOKEN=$GLM_API_KEY ANTHROPIC_MODEL=GLM-5.1 claude`
    ///
    /// All variables are inline so they apply only to the `claude` child process and never
    /// pollute the parent shell. `apiKeyEnv` is passed through verbatim (e.g. `$GLM_API_KEY`)
    /// so Terminal's zsh expands it from the user's shell env at exec time — keeping the real
    /// token out of `.zsh_history` and our process.
    static func launchSnippet(for provider: ClaudeProvider) -> String {
        var parts = [
            "ANTHROPIC_BASE_URL=\(provider.baseURL)",
            "ANTHROPIC_AUTH_TOKEN=\(provider.apiKeyEnv)",
            "ANTHROPIC_MODEL=\(provider.modelName)",
        ]
        if let v = provider.smallFastModel    { parts.append("ANTHROPIC_SMALL_FAST_MODEL=\(v)") }
        if let v = provider.defaultSonnetModel { parts.append("ANTHROPIC_DEFAULT_SONNET_MODEL=\(v)") }
        if let v = provider.defaultOpusModel   { parts.append("ANTHROPIC_DEFAULT_OPUS_MODEL=\(v)") }
        if let v = provider.defaultHaikuModel  { parts.append("ANTHROPIC_DEFAULT_HAIKU_MODEL=\(v)") }
        parts.append("claude")
        return parts.joined(separator: " ")
    }
}
