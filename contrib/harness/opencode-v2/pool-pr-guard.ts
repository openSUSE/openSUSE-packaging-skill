import type { Plugin } from "@opencode/plugin"
import { spawnSync } from "node:child_process"
import { homedir } from "node:os"
import { join, resolve } from "node:path"

// Pool PR guard for opencode 2.x: hands a matching shell, write or edit call to
// the pinned pr-guard.py (and the _pr_guard.py beside it) and refuses the call
// when the guard exits non-zero. Install: contrib/harness/README.md. A missing
// guard or python3 refuses only the calls that match the prefilter. opencode 1.x
// does not run this file; it takes ../opencode/pool-pr-guard.ts.

const GUARD = join(homedir(), ".claude", "hooks", "pr-guard.py")

// Verbatim copy of PREFILTER in pr-guard.py; tests/test-pr-guard.sh compares them.
const PREFILTER = new RegExp(String.raw`\/|tea\b|git-obs|\bgit\b[^\n;&|]*\bobs\b|src\.opensuse\.org|\bpush\b|\bosc\b|\b(?:python[0-9.]*|bash|sh|zsh|dash|ksh|node|perl|source|env|uv|eval)\b|(?:^|[\s;&|(])\.\s|\bsend-pack\b|\btarget-gate\b|(?:^|[;&|(\n!{]|\b(?:do|then|else|elif|if|while|until|command|exec|nohup|time|builtin|setsid|stdbuf|nice|ionice|sudo|doas|xargs|timeout|watch|parallel)\b)\s*[\x22']?\$[{A-Za-z_@*]|\bgh\b|credential|secret-tool|netrc|oscrc|[Aa][Ss][Kk][Pp][Aa][Ss][Ss]|[Aa]uthorization|\b(?:curl|wget|xhs?|https?)\b`)
// As unquoted() in pr-guard.py: $'...' decoded, then quotes and backslashes dropped.
const unquoted = (t: string) =>
  t.replace(/\$'((?:[^'\\]|\\.)*)'/g, (_m: string, body: string) =>
    body.replace(/\\(x[0-9a-fA-F]{1,2}|[0-7]{1,3}|.)/g, (_e: string, e: string) =>
      e[0] === "x" && e.length > 1 ? String.fromCharCode(parseInt(e.slice(1), 16))
        : /^[0-7]/.test(e) ? String.fromCharCode(parseInt(e, 8)) : e))
    .replace(/["'\\]/g, "")
// As in pr-guard.py: a call run inside the stamp directory, or a directory of
// credential files, is judged whatever it says.
const STAMP_DIR = "target-gate"
const CRED_DIR = new RegExp(String.raw`/\.(?:config/(?:tea|osc|gh|mcp-[^/]*)|local/state/osc)(?:/|$)`)

const plugin: Plugin.Plugin = {
  id: "opensuse-packaging.pool-pr-guard",
  async setup(ctx) {
    await ctx.tool.hook("execute.before", (event) => {
      const tool = String(event.tool ?? "").toLowerCase()
      const args = event.input as Record<string, unknown> | undefined
      if (!args || typeof args !== "object") return
      const workdir = resolve(ctx.location.directory, typeof args.workdir === "string" ? args.workdir : "")

      // The same event shape Claude Code hands its PreToolUse hooks.
      let text: string
      let guardEvent: Record<string, unknown>
      if (tool === "shell") {
        const command = args.command
        if (typeof command !== "string" || !command) return
        text = command
        guardEvent = { tool_name: "Bash", tool_input: { command }, cwd: workdir }
      } else if (tool === "write" || tool === "edit") {
        const file_path = String(args.path ?? args.filePath ?? args.file_path ?? "")
        const body = tool === "write" ? args.content : (args.newString ?? args.new_string)
        const content = typeof body === "string" ? body : ""
        text = file_path + "\n" + content
        guardEvent = tool === "write"
          ? { tool_name: "Write", tool_input: { file_path, content }, cwd: workdir }
          : { tool_name: "Edit", tool_input: { file_path, new_string: content }, cwd: workdir }
      } else return

      if (!PREFILTER.test(text) && !PREFILTER.test(unquoted(text))
        && !workdir.includes(STAMP_DIR) && !CRED_DIR.test(workdir)) return
      const r = spawnSync("python3", [GUARD], {
        input: JSON.stringify(guardEvent),
        encoding: "utf8",
        timeout: 60_000,
      })
      if (r.error || r.status !== 0) {
        const why = (r.stderr || "").trim()
          || (r.error ? `pr-guard could not run: ${r.error.message}` : `pr-guard exited ${r.status ?? r.signal}`)
        throw new Error(why)
      }
    })
  },
}

export default plugin
