import type { Plugin } from "@opencode/plugin"
import { spawn } from "node:child_process"
import { homedir } from "node:os"
import { join } from "node:path"

// Bugzilla hand-back guard for opencode 2.x: when a bugzilla MCP call would ask,
// hands it to the pinned bug-guard.py and lets it run unasked only on that
// guard's "allow" -- the security hand-back of a bug your own Factory SR fixes.
// Every other write keeps its ask. Install: contrib/harness/README.md. A missing
// guard or python3, or an opencode that does not pass the call's arguments,
// leaves every call asked.

const GUARD = join(homedir(), ".claude", "hooks", "bug-guard.py")
const PREFIX = "bugzilla_"

// The guard's decision on one event; anything but a clean "allow" reads as ask.
const decide = (event: Record<string, unknown>) =>
  new Promise<string>((done) => {
    let out = ""
    const child = spawn("python3", [GUARD], { stdio: ["pipe", "pipe", "ignore"] })
    const timer = setTimeout(() => child.kill("SIGKILL"), 60_000)
    child.stdout.setEncoding("utf8").on("data", (d: string) => (out += d))
    child.stdin.on("error", () => {})
    child.on("error", () => {
      clearTimeout(timer)
      done("ask")
    })
    child.on("close", (code) => {
      clearTimeout(timer)
      try {
        const verdict = JSON.parse(out)?.hookSpecificOutput?.permissionDecision
        done(code === 0 && verdict === "allow" ? "allow" : "ask")
      } catch {
        done("ask")
      }
    })
    child.stdin.end(JSON.stringify(event))
  })

const plugin: Plugin.Plugin = {
  id: "opensuse-packaging.bug-guard",
  async setup(ctx) {
    // The MCP tool puts its own call's arguments in metadata.input; a Code Mode
    // execute shares one call id across all its inner calls, so nothing keyed by id.
    await ctx.permission.hook("evaluate", async (event) => {
      const action = String(event.action ?? "")
      if (!action.startsWith(PREFIX) || event.source?.type !== "tool") return
      const input = event.metadata?.input
      if (event.effect !== "ask" || input === undefined) return
      if ((await decide({ tool_name: action, tool_input: input })) === "allow") event.effect = "allow"
    })
  },
}

export default plugin
