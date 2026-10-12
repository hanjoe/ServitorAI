import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { readdir } from "node:fs/promises";
import { resolve, relative, sep } from "node:path";

const MAX_ENTRIES = 200;
const IGNORED = new Set([".git", "node_modules", ".build", "DerivedData"]);

/** Read-only, bounded directory listing. No shell or filesystem mutations. */
export default function (pi: ExtensionAPI): void {
  pi.registerTool({
    name: "list_files",
    label: "List Files",
    description: "List file and directory names in a directory (read-only; max depth 3 and 200 entries).",
    promptSnippet: "List directory contents without running shell commands",
    parameters: Type.Object({
      path: Type.String({ description: "Directory path to list" }),
      maxDepth: Type.Optional(Type.Number({ minimum: 1, maximum: 3, description: "Maximum recursion depth (default 1)" })),
    }),
    async execute(_id, params, signal) {
      const root = resolve(params.path);
      const maxDepth = Math.max(1, Math.min(3, params.maxDepth ?? 1));
      const results: string[] = [];
      async function walk(dir: string, depth: number): Promise<void> {
        if (signal.aborted || results.length >= MAX_ENTRIES) return;
        let entries;
        try { entries = await readdir(dir, { withFileTypes: true }); }
        catch (error) {
          results.push(`${relative(root, dir) || "."}/ [unavailable: ${(error as Error).message}]`);
          return;
        }
        entries.sort((a, b) => a.name.localeCompare(b.name));
        for (const entry of entries) {
          if (signal.aborted || results.length >= MAX_ENTRIES) return;
          const rel = relative(root, resolve(dir, entry.name)).split(sep).join("/");
          results.push(entry.isDirectory() ? `${rel}/` : rel);
          if (entry.isDirectory() && depth < maxDepth && !IGNORED.has(entry.name)) {
            await walk(resolve(dir, entry.name), depth + 1);
          }
        }
      }
      await walk(root, 1);
      const suffix = results.length >= MAX_ENTRIES ? `\n… truncated at ${MAX_ENTRIES} entries` : "";
      return { content: [{ type: "text", text: results.join("\n") + suffix || "(empty directory)" }], details: {} };
    },
  });
}
