import type { Plugin } from "@opencode/plugin"
import { spawn } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import { realpathSync } from "node:fs"
import { homedir } from "node:os"
import { join, normalize, resolve } from "node:path"

// Pool PR guard for opencode 2.x: hands a matching shell, write or edit call to
// the pinned pr-guard.py (and the _pr_guard.py beside it) and refuses the call
// when the guard exits non-zero. A shell call the guard asks about goes to
// opencode's own permission prompt, with the guard's reason, and runs only on the
// user's answer; without that prompt (an older 2.x) it is refused, and the agent
// takes the step the ask names or reports it as a blocker. Install:
// contrib/harness/README.md. A missing guard or python3 refuses only the calls
// that match the prefilter. opencode 1.x does not run this file; it takes
// ../opencode/pool-pr-guard.ts.

const GUARD = join(homedir(), ".claude", "hooks", "pr-guard.py")

// Verbatim copy of PREFILTER in pr-guard.py; tests/test-pr-guard.sh compares them.
const PREFILTER = new RegExp(String.raw`\/|~|\.\.|\x60|\$[{A-Za-z_@*('\x22]|tea\b|git-obs|\bobs\b|src\.opensuse\.org|\bpush\b|\b(?:osc|python[0-9.]*|bash|sh|zsh|dash|ksh|node|perl|source|env|uv|eval|cd|pushd|sleep|rm|find)\b|-delete\b|(?:^|[\s;&|(])\.\s|\bsend-pack\b|\btarget-gate\b|\bincoming-review\b|\bgh\b|credential|secret-tool|netrc|oscrc|[Aa][Ss][Kk][Pp][Aa][Ss][Ss]|[Aa]uthorization|\b(?:curl|wget|xhs?|https?)\b`)
// As unquoted() in pr-guard.py: $'...' decoded, then quotes and backslashes dropped.
const unquoted = (t: string) =>
  t.replace(/\\\n/g, "").replace(/\$'((?:[^'\\]|\\.)*)'/g, (_m: string, body: string) =>
    body.replace(/\\(x[0-9a-fA-F]{1,2}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}|[0-7]{1,3}|.)/g, (_e: string, e: string) =>
      "xuU".includes(e[0]) && e.length > 1 ? String.fromCodePoint(Math.min(parseInt(e.slice(1), 16), 0x10ffff))
        : /^[0-7]/.test(e) ? String.fromCharCode(parseInt(e, 8)) : e))
    .replace(/["'\\]/g, "")
// As in pr-guard.py: a call run inside the stamp or state directory, or a
// directory of credential files, is judged whatever it says.
const STAMP_DIR = "target-gate"
const STATE_DIR = new RegExp(String.raw`/\.local/+state/+opensuse-packaging(?:/|$)`)
const CRED_DIR = new RegExp(String.raw`/\.(?:config/(?:tea|osc|gh|git|mcp-[^/]*)|local/state/osc|ssh)(?:/|$)`)
const CRED_HOMES = ["/.config/tea", "/.config/osc", "/.config/gh", "/.local/state/osc", "/.config/mcp-", "/.ssh"]
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
  dir !== "" && [dir, real(dir)].some((d) => d.includes(STAMP_DIR) || STATE_DIR.test(d) || CRED_DIR.test(d) || above(d))

// As opencode reads a path argument: "~" is the home directory.
const home = (p: string) => (p === "~" ? homedir() : p.startsWith("~/") ? join(homedir(), p.slice(2)) : p)

// As pr-guard.py: every call of the agent that reviews a contributor's submission is judged.
const READER = "incoming-review"

// The guard's verdict on one event, without blocking the service the sessions share:
// undefined lets the call run, refuse says why it is refused, ask is the guard's
// reason for leaving it to the user.
type Verdict = { refuse: string } | { ask: string } | undefined
const judge = (event: Record<string, unknown>) =>
  new Promise<Verdict>((done) => {
    let err = ""
    let out = ""
    const child = spawn("python3", [GUARD], { stdio: ["pipe", "pipe", "pipe"] })
    const timer = setTimeout(() => child.kill("SIGKILL"), 60_000)
    child.stdout.setEncoding("utf8").on("data", (d: string) => (out += d))
    child.stderr.setEncoding("utf8").on("data", (d: string) => (err += d))
    child.stdin.on("error", () => {})
    child.on("error", (e) => {
      clearTimeout(timer)
      done({ refuse: `pr-guard could not run: ${e.message}` })
    })
    child.on("close", (code, signal) => {
      clearTimeout(timer)
      done(code === 0 ? asked(out) : { refuse: err.trim() || `pr-guard exited ${code ?? signal}` })
    })
    child.stdin.end(JSON.stringify(event))
  })
// The guard's ask on stdout.
const asked = (out: string): Verdict => {
  if (!out.trim()) return undefined
  try {
    const d = JSON.parse(out)?.hookSpecificOutput
    if (d?.permissionDecision !== "ask") return undefined
    return { ask: String(d.permissionDecisionReason) }
  } catch {
    return { refuse: `pr-guard printed what it should not: ${out.trim().slice(0, 200)}` }
  }
}
// An ask with no prompt to hand it to, as a refusal naming the step for the agent to take.
const cannot = (reason: string) =>
  `${reason} (opencode cannot ask here: on your own commit or request this names a missing step, so take it and retry; never hand the user an osc, tea or git-obs command; if it persists, report the blocker)`

// opencode's permission service, where this opencode has one (2.2.7 does).
type Permission = {
  assert?: (request: Record<string, unknown>) => Promise<unknown>
  hook?: (name: string, f: (event: Record<string, unknown>) => Promise<void>) => Promise<unknown>
}
// The asks this plugin raised and the user has not answered, by nonce; the calls an
// answer was given for, by session, message and the command's sha256.
const pending = new Set<string>()
const granted = new Map<string, string>()
const sha256 = (s: string) => createHash("sha256").update(s).digest("hex")

// The user's go on one shell call the guard asks about, through opencode's prompt:
// the permission check carries a nonce only this plugin's evaluate hook turns into an
// ask, and the answer holds for this call alone. A rejection or any error refuses.
const userGo = async (perm: Permission, event: Record<string, unknown>, command: string, reason: string) => {
  const { sessionID, messageID, id } = event
  if (typeof sessionID !== "string" || typeof messageID !== "string" || typeof id !== "string")
    throw new Error(cannot(reason))
  const nonce = randomUUID()
  pending.add(nonce)
  try {
    await perm.assert!({ sessionID, agent: event.agent, action: "shell", resources: [command, reason],
      metadata: { guard: nonce } })
  } catch (e) {
    throw new Error(`${reason} (not approved: ${e instanceof Error ? e.message : String(e)})`)
  } finally {
    pending.delete(nonce)
  }
  const key = `${sessionID}:${messageID}:${sha256(command)}`
  if (granted.has(key)) throw new Error(`${reason} (an approval for this call is already in use)`)
  granted.set(key, id)
  const call = granted.get(key)
  granted.delete(key)
  if (call !== id) throw new Error(`${reason} (the approval was for another call)`)
}

const plugin: Plugin.Plugin = {
  id: "opensuse-packaging.pool-pr-guard",
  async setup(ctx) {
    // Only an ask this plugin raised, by its nonce, becomes the user's prompt; a hook
    // that cannot be set leaves every ask refused, never the guard unloaded.
    const perm = (ctx as { permission?: Permission }).permission
    let prompts = false
    if (typeof perm?.assert === "function" && typeof perm?.hook === "function") {
      try {
        await perm.hook("evaluate", async (ev) => {
          const nonce = (ev.metadata as Record<string, unknown> | undefined)?.guard
          if (typeof nonce !== "string" || !pending.has(nonce)) return
          ev.effect = "ask"
          ev.message = String((ev.resources as unknown[] | undefined)?.[1] ?? "pr-guard asks")
        })
        prompts = true
      } catch {
        prompts = false
      }
    }
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

      // As Claude Code's agent_type: only a changes-review agent records a change review,
      // only an incoming-review agent a contributor's, and that one only reads.
      if (typeof event.agent === "string" && event.agent) guardEvent.agent_type = event.agent

      if (!PREFILTER.test(text) && !PREFILTER.test(unquoted(text)) && !watched(workdir)
        && event.agent !== READER) return
      const verdict = await judge(guardEvent)
      if (verdict === undefined) return
      if ("refuse" in verdict) throw new Error(verdict.refuse)
      if (tool !== "shell" || !prompts || !perm) throw new Error(cannot(verdict.ask))
      await userGo(perm, event as Record<string, unknown>, String(args.command), verdict.ask)
    })
  },
}

export default plugin
