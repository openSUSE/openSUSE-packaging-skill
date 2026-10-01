import type { Plugin } from "@opencode/plugin"
import { spawn } from "node:child_process"
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

// As opencode reads a path argument: "~" is the home directory.
const home = (p: string) => (p === "~" ? homedir() : p.startsWith("~/") ? join(homedir(), p.slice(2)) : p)

// The guard's verdict on one event, without blocking the service the sessions share:
// undefined lets the call run, anything else is why it is refused.
const judge = (event: Record<string, unknown>) =>
  new Promise<string | undefined>((done) => {
    let err = ""
    const child = spawn("python3", [GUARD], { stdio: ["pipe", "ignore", "pipe"] })
    const timer = setTimeout(() => child.kill("SIGKILL"), 60_000)
    child.stderr.setEncoding("utf8").on("data", (d: string) => (err += d))
    child.stdin.on("error", () => {})
    child.on("error", (e) => {
      clearTimeout(timer)
      done(`pr-guard could not run: ${e.message}`)
    })
    child.on("close", (code, signal) => {
      clearTimeout(timer)
      done(code === 0 ? undefined : err.trim() || `pr-guard exited ${code ?? signal}`)
    })
    child.stdin.end(JSON.stringify(event))
  })

const plugin: Plugin.Plugin = {
  id: "opensuse-packaging.pool-pr-guard",
  async setup(ctx) {
    await ctx.tool.hook("execute.before", async (event) => {
      const tool = String(event.tool ?? "").toLowerCase()
      if (tool !== "shell" && tool !== "write" && tool !== "edit") return
      // A guarded tool whose input this file cannot read is refused, not waved through.
      const args = event.input as Record<string, unknown> | undefined
      if (!args || typeof args !== "object") throw new Error(`pool-pr-guard: ${tool} call without input`)
      // Relative paths are relative to the session's directory, as opencode reads them.
      const dir = ctx.location.directory
      const workdir = resolve(dir, typeof args.workdir === "string" ? home(args.workdir) : "")

      // The event Claude Code hands its PreToolUse hooks, file_path absolute.
      let text: string
      let guardEvent: Record<string, unknown>
      if (tool === "shell") {
        const command = args.command
        if (typeof command !== "string") throw new Error("pool-pr-guard: shell call without a command")
        if (!command) return
        text = command
        guardEvent = { tool_name: "Bash", tool_input: { command }, cwd: workdir }
      } else {
        const path = args.path
        const body = tool === "write" ? args.content : args.newString
        if (typeof path !== "string" || !path || typeof body !== "string")
          throw new Error(`pool-pr-guard: ${tool} call without a path or text`)
        const file_path = resolve(dir, home(path))
        text = file_path + "\n" + body
        guardEvent = tool === "write"
          ? { tool_name: "Write", tool_input: { file_path, content: body }, cwd: workdir }
          : { tool_name: "Edit", tool_input: { file_path, new_string: body }, cwd: workdir }
      }

      if (!PREFILTER.test(text) && !PREFILTER.test(unquoted(text))
        && !workdir.includes(STAMP_DIR) && !CRED_DIR.test(workdir)) return
      const why = await judge(guardEvent)
      if (why !== undefined) throw new Error(why)
    })
  },
}

export default plugin
