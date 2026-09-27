import type { Plugin } from "@opencode-ai/plugin"
import { spawnSync } from "node:child_process"
import { homedir } from "node:os"
import { join } from "node:path"

// Pool PR guard for opencode: hands a matching bash/shell, write or edit call to
// the pinned pr-guard.py (and the _pr_guard.py beside it) and refuses the call
// when the guard exits non-zero. Install: contrib/harness/README.md. A missing
// guard or python3 refuses only the calls that match the prefilter.

const GUARD = join(homedir(), ".claude", "hooks", "pr-guard.py")

// Verbatim copy of PREFILTER in pr-guard.py; tests/test-pr-guard.sh compares them.
const PREFILTER = new RegExp(String.raw`\/|tea\b|git-obs|\bgit\b[^\n;&|]*\bobs\b|src\.opensuse\.org|\bpush\b|\bosc\b|\b(?:python[0-9.]*|bash|sh|zsh|dash|ksh|node|perl|source|env|uv|eval)\b|(?:^|[\s;&|(])\.\s|\bsend-pack\b|\btarget-gate\b`)
// As in pr-guard.py: a call run inside the stamp directory is judged whatever it says.
const STAMP_DIR = "target-gate"

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

      if (!PREFILTER.test(text) && !String(workdir ?? "").includes(STAMP_DIR)) return
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
