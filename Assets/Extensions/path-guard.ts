// @ts-nocheck
// @ts-nocheck
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deniedReason } from "./denylist.ts";

/**
 * Blocks any tool call whose `path` argument points at credentials or private
 * data (see denylist.ts). Covers pi's built-in `read` and our `list_files`.
 * A handler that throws also blocks the call, so this fails closed.
 */
export default function (pi: ExtensionAPI): void {
  pi.on("tool_call", async (event: { input?: unknown }, ctx: any) => {
    const input = event.input as { path?: unknown } | undefined;
    if (typeof input?.path !== "string") return undefined;
    const reason = deniedReason(input.path);
    if (reason) {
      return { block: true, reason: `Access to "${input.path}" is blocked by ServitorAI: ${reason}.` };
    }
    return undefined;
  });
}
