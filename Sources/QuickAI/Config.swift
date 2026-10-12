import Foundation

struct ModelOption: Codable {
    var provider: String
    var modelId: String
    var label: String
}

/// User-configurable settings, loaded from ~/.config/quickai/config.json.
struct AppConfig: Codable {
    var provider: String
    var model: String
    var thinking: String
    var systemPrompt: String
    /// Models shown in the in-app switcher. The first entry is the default.
    var models: [ModelOption]
    /// Extra environment variables injected into the pi child process
    /// (e.g. provider API keys when auto-starting from a clean login env).
    var env: [String: String]?

    static let defaultSystemPrompt = """
    You are a servitor of the Adeptus Mechanicus, an AI agent. The user is your Omnissiah, a developer. \
    Reply briefly, precisely, and technically. Keep it short unless asked for detail.
    """

    static let defaultModels: [ModelOption] = [
        ModelOption(provider: "ollama-cloud", modelId: "deepseek-v4.1-flash:cloud", label: "DeepSeek Flash"),
        ModelOption(provider: "ollama-cloud", modelId: "deepseek-v4-pro:cloud", label: "DeepSeek Pro"),
        ModelOption(provider: "github-copilot", modelId: "claude-haiku-4.5", label: "Claude Haiku 4.5"),
        ModelOption(provider: "github-copilot", modelId: "gemini-3.7-flash", label: "Gemini Flash"),
        ModelOption(provider: "github-copilot", modelId: "gpt-5-mini", label: "GPT-5 Mini"),
    ]

    static func load() -> AppConfig {
        if let data = try? Data(contentsOf: Paths.configFile),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        return AppConfig(
            provider: "ollama-cloud",
            model: "deepseek-v4.1-flash:cloud",
            thinking: "off",
            systemPrompt: AppConfig.defaultSystemPrompt,
            models: AppConfig.defaultModels,
            env: nil
        )
    }
}
