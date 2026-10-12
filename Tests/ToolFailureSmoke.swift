import Foundation

@main
enum ToolFailureSmoke {
    static func main() {
        // Failure flagged by isError + content text.
        let err1: [String: Any] = [
            "type": "tool_execution_end",
            "toolName": "web_search",
            "result": [
                "isError": true,
                "content": [["type": "text", "text": "ddgr search failed: exit code 1"]],
                "details": ["error": "exit code 1"],
            ],
        ]
        if let f = toolFailure(from: err1) {
            expect(f.name == "web_search", "extracts tool name")
            expect(f.message == "ddgr search failed: exit code 1", "prefers content text over details.error")
        } else {
            expect(false, "detects isError failure")
        }

        // Failure only via details.error (legacy extension shape).
        let err2: [String: Any] = [
            "type": "tool_execution_end",
            "toolName": "web_search",
            "result": [
                "isError": false,
                "content": [["type": "text", "text": "some text"]],
                "details": ["error": "network timeout"],
            ],
        ]
        if let f = toolFailure(from: err2) {
            expect(f.message == "network timeout", "extracts details.error when isError is false")
        } else {
            expect(false, "detects details.error failure")
        }

        // Successful result must not be reported as failure.
        let ok: [String: Any] = [
            "type": "tool_execution_end",
            "toolName": "read",
            "result": [
                "isError": false,
                "content": [["type": "text", "text": "file contents"]],
                "details": [:],
            ],
        ]
        expect(toolFailure(from: ok) == nil, "ignores successful tool results")

        // Missing required fields returns nil.
        let broken: [String: Any] = ["type": "tool_execution_end"]
        expect(toolFailure(from: broken) == nil, "ignores malformed event")

        print("PASS: tool-failure parsing checks complete")
    }

    private static func expect(_ condition: Bool, _ label: String) {
        guard condition else {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }
}
