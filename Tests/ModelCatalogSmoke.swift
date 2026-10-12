import Foundation

@main
enum ModelCatalogSmoke {
    static func main() {
        let available = [
            ModelOption(provider: "github-copilot", modelId: "claude-sonnet-5", label: "Claude Sonnet 5"),
            ModelOption(provider: "github-copilot", modelId: "gpt-5-mini", label: "GPT-5 Mini"),
            ModelOption(provider: "ollama-cloud", modelId: "deepseek-v4", label: "DeepSeek V4"),
        ]
        let favourites = [
            ModelOption(provider: "ollama-cloud", modelId: "missing", label: "Unavailable"),
            ModelOption(provider: "github-copilot", modelId: "gpt-5-mini", label: "My GPT"),
        ]
        let ordered = ModelCatalog.ordered(available: available, favourites: favourites)
        expect(ordered.map(\.modelId) == ["gpt-5-mini", "claude-sonnet-5", "deepseek-v4"], "favourites first; unavailable favourites skipped")
        expect(ordered[0].label == "My GPT", "favourite label retained")

        let rpcModel = ModelOption.fromRPC(["provider": "github-copilot", "id": "gpt-5-mini", "name": "GPT-5 Mini (latest)"])
        expect(rpcModel == ModelOption(provider: "github-copilot", modelId: "gpt-5-mini", label: "GPT-5 Mini (latest)"), "pi RPC model shape adapts")
        expect(ModelOption.fromRPC(["provider": "github-copilot", "name": "missing id"]) == nil, "malformed RPC model ignored")

        let fallback = ModelCatalog.choose(available: ordered, previous: nil,
                                          configuredProvider: "ollama-cloud", configuredModel: "missing",
                                          piCurrentProvider: "github-copilot", piCurrentModel: "claude-sonnet-5")
        expect(fallback?.modelId == "claude-sonnet-5", "current pi model used when configured model unavailable")
        let configured = ModelCatalog.choose(available: ordered, previous: nil,
                                             configuredProvider: "github-copilot", configuredModel: "gpt-5-mini",
                                             piCurrentProvider: "github-copilot", piCurrentModel: "claude-sonnet-5")
        expect(configured?.modelId == "gpt-5-mini", "configured model preferred when available")
        let previous = ModelCatalog.choose(available: ordered,
                                           previous: ModelOption(provider: "github-copilot", modelId: "gpt-5-mini", label: "GPT"),
                                           configuredProvider: "github-copilot", configuredModel: "claude-sonnet-5",
                                           piCurrentProvider: "github-copilot", piCurrentModel: "claude-sonnet-5")
        expect(previous?.modelId == "gpt-5-mini", "user's prior selection retained")
        expect(ModelCatalog.choose(available: [], previous: nil, configuredProvider: "x", configuredModel: "y",
                                   piCurrentProvider: nil, piCurrentModel: nil) == nil, "empty auth/model catalog handled")
    }

    private static func expect(_ condition: Bool, _ label: String) {
        guard condition else {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }
}
