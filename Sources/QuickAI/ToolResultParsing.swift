import Foundation

/// Inspects a `tool_execution_end` event and extracts a tool-level failure.
/// Any extension can report failures via `result.isError` or `result.details.error`;
/// this is generic and not limited to the web-search extension.
func toolFailure(from obj: [String: Any]) -> (name: String, message: String)? {
    guard obj["type"] as? String == "tool_execution_end",
          let name = obj["toolName"] as? String,
          let result = obj["result"] as? [String: Any] else { return nil }

    let isError = result["isError"] as? Bool ?? false
    let contentText: String? = {
        guard let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else { return nil }
        return text.isEmpty ? nil : text
    }()
    let detailsError = (result["details"] as? [String: Any])?["error"] as? String

    if isError {
        return (name, contentText ?? detailsError ?? "tool reported an error")
    }
    if let detailsError {
        return (name, detailsError)
    }
    return nil
}
