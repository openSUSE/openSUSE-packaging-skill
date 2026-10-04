import type { Plugin } from "@opencode-ai/plugin"
import { spawnSync } from "node:child_process"
import { realpathSync } from "node:fs"
import { homedir } from "node:os"
import { join, normalize } from "node:path"

// Pool PR guard for opencode: hands a matching bash/shell, write or edit call to
// the pinned pr-guard.py (and the _pr_guard.py beside it) and refuses the call
// when the guard exits non-zero. Install: contrib/harness/README.md. A missing
// guard or python3 refuses only the calls that match the prefilter.

const GUARD = join(homedir(), ".claude", "hooks", "pr-guard.py")

// Verbatim copy of PREFILTER in pr-guard.py; tests/test-pr-guard.sh compares them.
const PREFILTER = new RegExp(String.raw`\/|~|\.\.|\x60|\$[{A-Za-z_@*('\x22]|tea\b|git-obs|\bobs\b|src\.opensuse\.org|\bpush\b|\b(?:osc|python[0-9.]*|bash|sh|zsh|dash|ksh|node|perl|source|env|uv|eval|cd|pushd)\b|(?:^|[\s;&|(])\.\s|\bsend-pack\b|\btarget-gate\b|\bgh\b|credential|secret-tool|netrc|oscrc|[Aa][Ss][Kk][Pp][Aa][Ss][Ss]|[Aa]uthorization|\b(?:curl|wget|xhs?|https?)\b`)
// As unquoted() in pr-guard.py: $'...' decoded, then quotes and backslashes dropped.
const unquoted = (t: string) =>
  t.replace(/\$'((?:[^'\\]|\\.)*)'/g, (_m: string, body: string) =>
    body.replace(/\\(x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|[0-7]{1,3}|.)/g, (_e: string, e: string) =>
      "xuU".includes(e[0]) && e.length > 1 ? String.fromCodePoint(Math.min(parseInt(e.slice(1), 16), 0x10ffff))
        : /^[0-7]/.test(e) ? String.fromCharCode(parseInt(e, 8)) : e))
    .replace(/["'\\]/g, "")
// As in pr-guard.py: a call run inside the stamp directory, or a directory of
// credential files, is judged whatever it says.
const STAMP_DIR = "target-gate"
const CRED_DIR = new RegExp(String.raw`/\.(?:config/(?:tea|osc|gh|git|mcp-[^/]*)|local/state/osc)(?:/|$)`)
const CRED_HOMES = ["/.config/tea", "/.config/osc", "/.config/gh", "/.local/state/osc", "/.config/mcp-"]
const real = (p: string) => {
  try {
    return realpathSync(p)
  } catch {
    return p
  }
}
const above = (dir: string) => {
  const top = normalize(dir).replace(/\/+$/, "") + "/"
  return [homedir(), real(homedir())].some((h) =>
    CRED_HOMES.some((r) => (h.replace(/\/+$/, "") + r + "/").startsWith(top)))
}
// As watched() in pr-guard.py: that directory or one above the credential
// files, as written or resolved (a symlink, a leading //), is judged too.
const watched = (dir: string) =>
  dir !== "" && [dir, real(dir)].some((d) => d.includes(STAMP_DIR) || CRED_DIR.test(d) || above(d))

export const PoolPrGuardPlugin: Plugin = async ({ directory }) => {
  return {
    "tool.execute.before": async (input, output) => {
      const tool = String(input?.tool ?? "").toLowerCase()
      const args = output?.args as Record<string, unknown> | undefined
      if (!args || typeof args !== "object") return
      const workdir = typeof args.workdir === "string" && args.workdir ? args.workdir : directory

      // The same event shape Claude Code hands its PreToolUse hooks.
      let text: string
      let event: Record<string, unknown>
      if (tool === "bash" || tool === "shell") {
        const command = args.command
        if (typeof command !== "string" || !command) return
        text = command
        event = { tool_name: "Bash", tool_input: { command }, cwd: workdir }
      } else if (tool === "write" || tool === "edit") {
        const file_path = String(args.filePath ?? args.file_path ?? "")
        const body = tool === "write" ? args.content : (args.newString ?? args.new_string)
        const content = typeof body === "string" ? body : ""
        text = file_path + "\n" + content
        event = tool === "write"
          ? { tool_name: "Write", tool_input: { file_path, content }, cwd: workdir }
          : { tool_name: "Edit", tool_input: { file_path, new_string: content }, cwd: workdir }
      } else return

      if (!PREFILTER.test(text) && !PREFILTER.test(unquoted(text))
        && !watched(String(workdir ?? ""))) return
      const r = spawnSync("python3", [GUARD], {
        input: JSON.stringify(event),
        encoding: "utf8",
        timeout: 60_000,
      })
      if (r.error || r.status !== 0) {
        const why = (r.stderr || "").trim()
          || (r.error ? `pr-guard could not run: ${r.error.message}` : `pr-guard exited ${r.status ?? r.signal}`)
        throw new Error(why)
      }
    },
  }
}
