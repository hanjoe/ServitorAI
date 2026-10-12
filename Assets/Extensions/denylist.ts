// @ts-nocheck
// @ts-nocheck
// Shared path denylist for the read-only tools ServitorAI exposes to pi.
//
// This is a best-effort guard, NOT a sandbox: it keeps a prompt-injected model
// from reading the obvious credential stores and private data in $HOME. Paths
// are canonicalised the way pi's own `read` tool does (~, @-prefix, unicode
// spaces, NFC/NFD) and symlinks are resolved before matching, case-insensitively
// (APFS is case-insensitive by default).

import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";

const HOME = homedir();

/** Directories under $HOME whose whole subtree is off limits. */
const DENIED_DIRS = [
  ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker",
  ".config/gcloud", ".config/gh", ".config/op", ".config/servitorai",
  ".local/share/pass-cli",
  ".pi", // pi auth tokens, provider config and chat sessions
  "Library/Keychains", "Library/Cookies", "Library/Safari",
  "Library/Application Support/Google",
  "Library/Application Support/Firefox",
  "Library/Application Support/BraveSoftware",
  "Library/Application Support/Microsoft Edge",
];

/** Path prefixes under $HOME (match files and directories that start with it). */
const DENIED_PREFIXES = [
  ".config/proton",      // proton-cache.sh and friends
  ".local/share/proton", // Proton Pass CLI data
];

/** Individual credential / history files under $HOME. */
const DENIED_FILES = [
  ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".config/git/credentials",
  ".zsh_history", ".bash_history", ".python_history", ".psql_history",
  ".mysql_history", ".node_repl_history",
];

/** File names that are sensitive wherever they live. */
const DENIED_NAMES: RegExp[] = [
  /^\.env(\..+)?$/i,                 // .env, .env.local, .env.production …
  /\.(pem|key|p12|pfx|kdbx|keystore|jks)$/i,
  /^id_[a-z0-9]+(_sk)?$/i,           // ssh private keys wherever they live (~/.ssh is denied wholesale anyway)
];
/** …except the harmless templates people commit on purpose. */
const ALLOWED_NAMES = /^\.env\.(example|sample|template|dist)$/i;

const NORMALIZE_SPACES = /[\u00A0\u1680\u2000-\u200A\u202F\u205F\u3000]/g;

function safeRealpath(p: string): string | undefined {
  try { return realpathSync.native(p); } catch { return undefined; }
}

/** Real path of the longest existing ancestor + the not-yet-existing tail. */
function realish(abs: string): string {
  let cur = abs;
  const tail: string[] = [];
  for (;;) {
    const real = safeRealpath(cur);
    if (real !== undefined) return join(real, ...[...tail].reverse());
    const parent = dirname(cur);
    if (parent === cur) return abs;
    tail.push(basename(cur));
    cur = parent;
  }
}

function candidates(input: string, cwd: string): string[] {
  let p = input.replace(/^@/, "").replace(NORMALIZE_SPACES, " ");
  if (p === "~") p = HOME;
  else if (p.startsWith("~/")) p = join(HOME, p.slice(2));
  const out = new Set<string>();
  for (const variant of new Set([p, p.normalize("NFC"), p.normalize("NFD")])) {
    const abs = resolve(cwd, variant);          // lexical (collapses ..)
    out.add(abs);
    out.add(realish(abs));
    // The kernel resolves `symlink/..` physically, not lexically — also try
    // the un-normalised path so `link/../x` can't dodge the lexical check.
    const raw = variant.startsWith("/") ? variant : `${cwd}/${variant}`;
    const kernel = safeRealpath(raw);
    if (kernel !== undefined) out.add(kernel);
  }
  return [...out].map((c) => c.toLowerCase());
}

const ROOTS = [...new Set([HOME, safeRealpath(HOME) ?? HOME])].map((r) => r.toLowerCase());

/**
 * The app's real config dir (it honours XDG_CONFIG_HOME, so it may not be
 * ~/.config/servitorai). Passed in by the app; denied as an absolute path.
 */
const APP_CONFIG_DIRS = [process.env.SERVITORAI_CONFIG_DIR]
  .filter((d): d is string => !!d)
  .flatMap((d) => [d, safeRealpath(d) ?? d])
  .map((d) => d.toLowerCase());

/** Returns a human-readable reason if `input` must not be accessed, else null. */
export function deniedReason(input: string, cwd: string = process.cwd()): string | null {
  for (const c of candidates(input, cwd)) {
    for (const d of APP_CONFIG_DIRS) {
      if (c === d || c.startsWith(`${d}/`)) return "the ServitorAI config directory holds API keys and chat history";
    }
    for (const root of ROOTS) {
      for (const d of DENIED_DIRS) {
        const full = `${root}/${d.toLowerCase()}`;
        if (c === full || c.startsWith(`${full}/`)) return `"${d}" holds credentials or private data`;
      }
      for (const d of DENIED_PREFIXES) {
        if (c.startsWith(`${root}/${d.toLowerCase()}`)) return `"${d}*" holds credentials`;
      }
      for (const f of DENIED_FILES) {
        if (c === `${root}/${f.toLowerCase()}`) return `"${f}" holds credentials or history`;
      }
    }
    const name = basename(c);
    if (ALLOWED_NAMES.test(name)) continue;
    if (DENIED_NAMES.some((re) => re.test(name))) return `"${name}" looks like a secret or key file`;
  }
  return null;
}
