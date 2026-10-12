import Foundation

struct ModelOption: Codable, Equatable {
    var provider: String
    var modelId: String
    var label: String

    /// Adapt pi's RPC Model shape to the app's persisted/favourites shape.
    static func fromRPC(_ value: [String: Any]) -> ModelOption? {
        guard let provider = value["provider"] as? String,
              let modelId = value["id"] as? String else { return nil }
        let label = (value["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? modelId
        return ModelOption(provider: provider, modelId: modelId, label: label)
    }
}

/// Pure model-catalog ordering/selection logic shared by startup and tests.
enum ModelCatalog {
    static func ordered(available: [ModelOption], favourites: [ModelOption]) -> [ModelOption] {
        var result: [ModelOption] = []
        for favourite in favourites {
            guard let model = available.first(where: { $0.provider == favourite.provider && $0.modelId == favourite.modelId }),
                  !result.contains(where: { $0.provider == model.provider && $0.modelId == model.modelId }) else { continue }
            result.append(ModelOption(provider: model.provider, modelId: model.modelId,
                                      label: favourite.label.isEmpty ? model.label : favourite.label))
        }
        for model in available where !result.contains(where: { $0.provider == model.provider && $0.modelId == model.modelId }) {
            result.append(model)
        }
        return result
    }

    /// Keep the user's prior pick when still usable; otherwise prefer the
    /// configured default, pi's current selection, then the first available.
    static func choose(available: [ModelOption], previous: ModelOption?, configuredProvider: String,
                       configuredModel: String, piCurrentProvider: String?, piCurrentModel: String?) -> ModelOption? {
        func find(_ provider: String?, _ id: String?) -> ModelOption? {
            guard let provider, let id else { return nil }
            return available.first { $0.provider == provider && $0.modelId == id }
        }
        return find(previous?.provider, previous?.modelId)
            ?? find(configuredProvider, configuredModel)
            ?? find(piCurrentProvider, piCurrentModel)
            ?? available.first
    }
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
