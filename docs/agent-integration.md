# Agent integration guide

This guide shows how to connect `agentshot` to coding agents through MCP, and how to use the CLI directly when MCP is unavailable or unsuitable.

`agentshot` is **macOS-only**. It captures the screen of the machine where the `agentshot` process runs. It cannot capture your local Mac screen when the agent is running in a Linux cloud container unless that container is somehow controlling the Mac through a separate remote-desktop/computer-use mechanism.

## 1. What agentshot provides

| Capability | MCP tool | CLI command |
|---|---|---|
| Check permissions/environment | `doctor` | `agentshot doctor` |
| Capture a full display | `capture_fullscreen` | `agentshot capture fullscreen` |
| Capture an explicit rectangle | `capture_area` | `agentshot capture area` |
| Annotate an image | `annotate` | `agentshot annotate` |
| OCR an image | `ocr` | `agentshot ocr` |
| Blur/pixelate/erase/solid redaction | `redact` | `agentshot redact` |
| Add a polished backdrop | `beautify` | `agentshot beautify` |
| Start scrolling capture | `scroll_capture_start` | `agentshot scrollcap start` |
| Capture one scrolling frame | `scroll_capture_add_frame` | `agentshot scrollcap frame` |
| Stitch scrolling frames | `scroll_capture_finish` | `agentshot scrollcap finish` |

Important model of scrolling capture: **agentshot does not scroll the screen**. The calling agent scrolls using its own browser/computer-control mechanism, then calls `scroll_capture_add_frame` after each scroll. `agentshot` captures and stitches the frames.

## 2. Install once on macOS

There is no `.dmg` or GUI app. `agentshot` is a CLI/MCP server, so Homebrew is the preferred installation path:

```bash
brew tap therealharpaljadeja/agentshot https://github.com/therealharpaljadeja/agentshot.git
brew trust --tap therealharpaljadeja/agentshot
brew install agentshot
```

The explicit tap URL is required because this repository is both the project repository and its own Homebrew tap. Homebrew also requires third-party taps to be explicitly trusted before their formulae can be installed. The formula installs a prebuilt universal macOS binary supporting Apple silicon and Intel Macs running macOS 14 Sonoma or newer.

Homebrew installs the executable at `$(brew --prefix)/bin/agentshot`:

- Apple silicon: usually `/opt/homebrew/bin/agentshot`
- Intel: usually `/usr/local/bin/agentshot`

The examples in this guide use `/opt/homebrew/bin/agentshot`. If your machine uses a different Homebrew prefix, substitute the fully expanded output of:

```bash
brew --prefix
```

To build manually instead:

```bash
git clone git@github.com:therealharpaljadeja/agentshot.git
cd agentshot
swift build -c release
mkdir -p "$HOME/.local/bin"
cp .build/release/agentshot "$HOME/.local/bin/agentshot"
```

Then use the expanded absolute path in every MCP configuration.

**Do not rely on `~`, `$HOME`, or PATH expansion in MCP config files.** Most MCP clients launch the command directly rather than through a shell. Prefer a fully expanded absolute path.

Verify the binary:

```bash
/opt/homebrew/bin/agentshot doctor
```

Expected shape:

```json
{
  "ok": true,
  "permissions": {
    "screenRecording": true,
    "accessibility": true,
    "accessibilityRequiredForMVP": false
  }
}
```

`accessibility` may be false; that is fine for the MVP because agentshot does not inject scroll events. `screenRecording` must be true for captures.

Verify the MCP server handshake directly:

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' \
  | /opt/homebrew/bin/agentshot mcp
```

You should receive one line of JSON containing `serverInfo.name: agentshot`.

## 3. Screen Recording permission model

macOS Screen Recording permission is often granted to the **host application** that launches the command, not to `agentshot` as a standalone signed app. That means permission can differ by agent:

- Claude Code in Terminal may require Terminal or iTerm to have Screen Recording permission.
- Cursor-launched MCP servers may require Cursor itself to have permission.
- Devin Local may require the terminal/app host that starts Devin.
- A shell test can succeed while an agent-launched MCP server fails, or vice versa.

If capture fails with `missing-screen-recording-permission`:

1. Run the agent's `doctor` tool or ask the agent to run `/opt/homebrew/bin/agentshot doctor`.
2. Open **System Settings → Privacy & Security → Screen Recording**.
3. Enable the host application named in the failure context: Terminal, iTerm, Cursor, Visual Studio Code, or the relevant agent host.
4. Restart that host application.
5. Retry `doctor` from inside the same agent.

## 4. Coordinate systems and output contract

### Capture rectangles

Capture rectangles use top-left screen points relative to the selected display:

```json
{ "rect": [100, 200, 800, 600], "out": "/tmp/area.png" }
```

Use `displayIndex` when there are multiple displays. The default is `0`.

### Annotation rectangles and points

Annotation coordinates use top-left image pixels in the input image. Arrows use only endpoints; no angle is required. Counters automatically number themselves in operation order.

Example annotation operation array:

```json
[
  { "type": "rect", "rect": [40, 100, 420, 90], "stroke": "#ff3b30", "strokeWidth": 4 },
  { "type": "arrow", "from": [640, 240], "to": [460, 145], "stroke": "#ff3b30", "strokeWidth": 6 },
  { "type": "highlight", "rect": [42, 104, 160, 24], "color": "#ffeb3b", "opacity": 0.45 },
  { "type": "text", "at": [80, 360], "text": "Check this value" },
  { "type": "counter", "at": [100, 420] },
  { "type": "counter", "at": [580, 220] }
]
```

### Output contract

Successful calls return JSON with artifact paths, dimensions, hashes, operation metadata, and warnings. Errors return JSON and a non-zero exit code in the CLI. Agents should inspect `warnings` instead of assuming success means pixel-perfect output.

## 5. Claude Code

Official reference: [Connect Claude Code to tools via MCP](https://code.claude.com/docs/en/mcp).

### Install

Run this in a terminal, not inside a Claude conversation:

```bash
claude mcp add --transport stdio --scope user agentshot \
  -- /opt/homebrew/bin/agentshot mcp
```

The `--` separator is important: everything after it is passed to the server command.

### Verify

```bash
claude mcp list
```

Inside Claude Code, use the MCP status UI/command if available in your version, or ask:

```text
Use the agentshot doctor tool and report the JSON permission status.
```

### Example prompts

Fullscreen capture:

```text
Use agentshot capture_fullscreen to save the current screen to /tmp/claude-screen.png. Return the artifact metadata and do not describe sensitive text aloud.
```

Area capture plus annotation:

```text
Use agentshot to capture screen rectangle [100,200,900,650] into /tmp/area.png. Annotate it with a red rectangle around the main content, an arrow pointing to the primary button, and counters at the three important UI elements. Save it as /tmp/annotated.png and beautify it as /tmp/final.png.
```

Scrolling capture:

```text
Use agentshot scrolling capture. Start a session for rectangle [0,120,1600,980], capture a frame, scroll the browser down using your available computer-control/browser tools, capture another frame, repeat until the bottom, then finish the session into /tmp/tall.png. Report overlap confidence and warnings.
```

### Claude-specific notes

- If Claude Code runs inside Terminal or iTerm, macOS may require Screen Recording permission for that terminal application.
- If you configure with local scope instead of user scope, the server is only available in the project where you registered it.
- Claude cannot scroll the screen through agentshot itself. It needs a separate browser/computer-control ability or the user must scroll when asked.

## 6. OpenAI Codex

Official references: [Codex configuration reference](https://developers.openai.com/codex/config-reference) and [Codex CLI MCP commands](https://developers.openai.com/codex/cli).

Codex CLI and the Codex IDE extension share MCP configuration in `~/.codex/config.toml`.

### Install with the Codex CLI

```bash
codex mcp add agentshot -- /opt/homebrew/bin/agentshot mcp
```

Verify:

```bash
codex mcp list
codex mcp get agentshot --json
```

### Manual `config.toml` alternative

Add this to `~/.codex/config.toml`:

```toml
[mcp_servers.agentshot]
command = "/opt/homebrew/bin/agentshot"
args = ["mcp"]
```

If you installed in your home directory, use the expanded path instead:

```toml
[mcp_servers.agentshot]
command = "/Users/yourname/.local/bin/agentshot"
args = ["mcp"]
```

### Example prompt

```text
Use the agentshot MCP tools. First call doctor. If screen recording is available, capture rectangle [100,200,800,600] to /tmp/codex-area.png, OCR it, redact anything matching sk-[A-Za-z0-9_-]+ with blur, then write the safe image to /tmp/codex-safe.png.
```

### Codex-specific notes

- Codex may ask for approval before using MCP tools. Approve capture tools only when you expect screen access.
- If Codex is running in a cloud or Linux environment, the MCP server cannot capture your Mac screen. Use a local Codex installation on the Mac you want to capture.
- For scrolling capture, Codex must have some separate mechanism that can scroll the target application. agentshot only captures and stitches.

## 7. Cursor

Official reference: [Cursor MCP documentation](https://cursor.com/docs/mcp).

### Global configuration

Create or edit `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "agentshot": {
      "command": "/opt/homebrew/bin/agentshot",
      "args": ["mcp"]
    }
  }
}
```

If the file already contains other servers, add only the `agentshot` entry inside the existing `mcpServers` object.

### Project configuration

For a project-specific server, create `.cursor/mcp.json` in the project root with the same shape. Project configuration takes precedence over the global file when names collide.

### Enable and verify

1. Restart Cursor after editing the file.
2. Open Cursor's MCP/Customize UI.
3. Confirm `agentshot` is connected and its tools are visible.
4. Ask Cursor Agent:

```text
Use agentshot doctor and tell me whether screen recording is available.
```

### Example prompt

```text
Use agentshot capture_area with rect [0,120,1600,980] and output /tmp/cursor-area.png. Then annotate the primary error text with a red rectangle and counter annotations for the failing steps. Save the annotated image to /tmp/cursor-annotated.png.
```

### Cursor-specific notes

- Cursor may require Screen Recording permission for the Cursor application itself.
- Cursor may require approval before MCP tool use depending on your approval settings.
- Cursor's local app can use this because it runs on your Mac. A hosted/cloud Cursor agent cannot use a local macOS binary to capture your screen.

## 8. Devin and Devin Local/Desktop

Official references: [Devin CLI MCP configuration](https://docs.devin.ai/cli/extensibility/mcp/configuration) and [custom MCP servers in Devin](https://docs.devin.ai/work-with-devin/mcp#setting-up-a-custom-mcp-server).

There are two different cases.

### 8a. Devin Local / Devin CLI on a Mac

Use the Devin CLI:

```bash
devin mcp add --scope user agentshot -- /opt/homebrew/bin/agentshot mcp
devin mcp list
```

Or edit `~/.config/devin/mcp_config.json`:

```json
{
  "mcpServers": {
    "agentshot": {
      "command": "/opt/homebrew/bin/agentshot",
      "args": ["mcp"]
    }
  }
}
```

For one project only, use `.devin/mcp_config.json` in the project. For personal local overrides, use `.devin/mcp_config.local.json`.

Example prompt:

```text
Use agentshot doctor, then capture the current display to /tmp/devin-screen.png. If capture succeeds, OCR it and summarize only non-sensitive UI state.
```

### 8b. Devin cloud sessions

A normal Devin cloud session runs in a cloud VM, not on your Mac. In that environment:

- `/opt/homebrew/bin/agentshot` usually does not exist.
- The VM may be Linux, while agentshot is macOS-only.
- Even if the command existed, it would capture the cloud VM's screen, not your Mac's screen.

Therefore, do **not** configure agentshot as an organization-wide cloud MCP server unless your Devin workers are known to be macOS machines with agentshot preinstalled. For normal cloud Devin sessions, use Devin's built-in screenshot/browser/computer tools instead.

If you do operate macOS workers, the custom MCP server shape is:

```json
{
  "transport": "STDIO",
  "command": "/opt/homebrew/bin/agentshot",
  "args": ["mcp"],
  "env_variables": {}
}
```

The binary must already exist at that path in the worker image or blueprint.

## 9. Gemini CLI

Official reference: [Gemini CLI MCP server configuration](https://github.com/google-gemini/gemini-cli/blob/main/docs/tools/mcp-server.md).

Gemini CLI reads `~/.gemini/settings.json` for user-level configuration and `.gemini/settings.json` in a project for project-level configuration.

Add or merge:

```json
{
  "mcpServers": {
    "agentshot": {
      "command": "/opt/homebrew/bin/agentshot",
      "args": ["mcp"],
      "trust": false
    }
  }
}
```

Keep `trust` false unless you explicitly want tool calls to run without confirmation.

Restart Gemini CLI and use its `/mcp` command to confirm that the server and tools are visible.

Example prompt:

```text
Use the agentshot MCP server. Capture the full screen to /tmp/gemini-full.png, redact token-like strings matching sk-[A-Za-z0-9_-]+, and save the safe result as /tmp/gemini-safe.png.
```

## 10. Windsurf

Official reference: [Windsurf Cascade MCP configuration](https://docs.devin.ai/windsurf/plugins/cascade/mcp).

Windsurf's current local agent uses the Devin-style MCP configuration. Edit `~/.config/devin/mcp_config.json` on macOS:

```json
{
  "mcpServers": {
    "agentshot": {
      "command": "/opt/homebrew/bin/agentshot",
      "args": ["mcp"]
    }
  }
}
```

For project-only use, create `.devin/mcp_config.json` at the project root. For personal project overrides, use `.devin/mcp_config.local.json`.

If you are using the legacy Cascade interface, open its MCP menu, choose **Open MCP config file**, and add the same `mcpServers` entry to the file it opens. Refresh the MCP server list afterward.

Example prompt:

```text
Use agentshot capture_fullscreen to save /tmp/windsurf-screen.png, then use OCR to identify the active error message without reproducing secrets.
```

## 11. Cline

Official reference: [Cline MCP documentation](https://github.com/cline/cline/blob/main/docs/mcp/mcp-overview.mdx).

Cline supports an interactive MCP wizard and a CLI install form.

From a terminal:

```bash
cline mcp install agentshot -- /opt/homebrew/bin/agentshot mcp
```

Alternatively, open Cline's MCP settings JSON and add:

```json
{
  "mcpServers": {
    "agentshot": {
      "command": "/opt/homebrew/bin/agentshot",
      "args": ["mcp"]
    }
  }
}
```

Restart or reload Cline if the server does not appear immediately.

Example prompt:

```text
Use agentshot doctor. If permissions are available, capture rectangle [100,200,800,600], annotate the failing UI element, redact any API keys, and produce a beautified final image.
```

## 12. VS Code Copilot

Official reference: [VS Code MCP configuration reference](https://code.visualstudio.com/docs/agents/reference/mcp-configuration).

Current VS Code Copilot MCP configuration uses a top-level `mcpServers` object. For user-wide use, edit `~/.copilot/mcp-config.json` unless your `COPILOT_HOME` is customized:

```json
{
  "mcpServers": {
    "agentshot": {
      "command": "/opt/homebrew/bin/agentshot",
      "args": ["mcp"]
    }
  }
}
```

For workspace-shared use, place `.mcp.json` at the workspace root with the same shape when your VS Code version offers workspace-root configuration.

The guided route is often safer:

1. Open a Copilot chat session.
2. Run **Chat: Open Customizations**.
3. Select **MCP Servers**.
4. Choose **Add Server**.
5. Use command `/opt/homebrew/bin/agentshot` with argument `mcp`.
6. Save it to the Copilot global destination.

Older VS Code/Copilot documentation may mention `.vscode/mcp.json` with a top-level `servers` object. That is a legacy editor-managed format; prefer the current Copilot configuration flow when available.

## 13. Generic MCP configuration for other agents

Most MCP-capable agents use one of these two shapes.

JSON shape:

```json
{
  "mcpServers": {
    "agentshot": {
      "command": "/opt/homebrew/bin/agentshot",
      "args": ["mcp"]
    }
  }
}
```

TOML shape:

```toml
[mcp_servers.agentshot]
command = "/opt/homebrew/bin/agentshot"
args = ["mcp"]
```

If the agent has an add-server command, the common pattern is:

```bash
<agent-cli> mcp add agentshot -- /opt/homebrew/bin/agentshot mcp
```

Check that the client expects stdio. agentshot currently does not expose HTTP or SSE.

## 14. CLI fallback for agents without MCP

Almost every coding agent can run shell commands even when it cannot use MCP. In that case, have the agent invoke the CLI directly.

Capture:

```bash
/opt/homebrew/bin/agentshot capture fullscreen --out /tmp/full.png
/opt/homebrew/bin/agentshot capture area --rect 100,200,800,600 --out /tmp/area.png
```

Annotate:

```bash
cat > /tmp/ops.json <<'JSON'
[
  {"type":"rect","rect":[40,100,420,90],"stroke":"#ff3b30","strokeWidth":4},
  {"type":"counter","at":[100,420]},
  {"type":"counter","at":[580,220]}
]
JSON
/opt/homebrew/bin/agentshot annotate /tmp/area.png --ops /tmp/ops.json --out /tmp/annotated.png
```

Redact:

```bash
/opt/homebrew/bin/agentshot redact /tmp/annotated.png \
  --regex 'sk-[A-Za-z0-9_-]+' \
  --method blur \
  --out /tmp/safe.png
```

Beautify:

```bash
/opt/homebrew/bin/agentshot beautify /tmp/safe.png \
  --out /tmp/final.png \
  --padding 64 \
  --radius 24 \
  --shadow 0.25 \
  --background '#dceeff,#ffe4f1'
```

Scrolling capture:

```bash
/opt/homebrew/bin/agentshot scrollcap start --rect 0,120,1600,980 --session demo
/opt/homebrew/bin/agentshot scrollcap frame --session demo
# The agent or user scrolls down here.
/opt/homebrew/bin/agentshot scrollcap frame --session demo
# The agent or user scrolls down again.
/opt/homebrew/bin/agentshot scrollcap frame --session demo
/opt/homebrew/bin/agentshot scrollcap finish --session demo --out /tmp/tall.png
```

## 15. Recommended agent workflows

### Safe screenshot question answering

1. `doctor`
2. `capture_fullscreen` or `capture_area`
3. `ocr`
4. Answer from OCR/metadata without unnecessarily repeating secrets
5. If sharing the image, run `redact` first

### Debug evidence capture

1. Capture the relevant area.
2. Annotate important elements with counters in reading order.
3. Add arrows or rectangles around the failure.
4. Redact secrets.
5. Beautify the result for an issue, PR, or design document.

### Long-page capture

1. Start a scrolling session for the viewport rectangle.
2. Capture the first frame.
3. Agent scrolls down less than one viewport.
4. Wait briefly for rendering/lazy loading.
5. Capture the next frame.
6. Repeat until the bottom.
7. Finish and inspect `overlaps`, `confidence`, and `warnings`.

Small overlaps are supported, but overlapping by roughly 20–40% of the viewport usually produces more reliable stitching than scrolling a near-full viewport.

## 16. Privacy and security notes

- Screenshots can contain secrets, personal data, private code, and confidential customer information.
- Regex redaction runs locally, but OCR text and image paths may enter the coding agent's cloud context once the agent reads them.
- Regex redaction output intentionally reports match counts and rectangles rather than echoing the matched secret text.
- `ocr` itself returns recognized text. Avoid OCRing sensitive images unless you are comfortable with that text entering the agent context.
- Raw scrolling frames are stored under `~/.agentshot/sessions/<session-id>/frames` with owner-only permissions. They are currently retained after stitching so the agent can debug stitching problems. Delete the session directory when finished if the content is sensitive:

```bash
rm -rf "$HOME/.agentshot/sessions/demo"
```

- Prefer explicit small capture rectangles over fullscreen captures when possible.
- Redact before attaching images to PRs, issues, Slack, or cloud-hosted agent conversations.

## 17. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `missing-screen-recording-permission` | Host app lacks macOS permission | Grant Screen Recording to Terminal/iTerm/Cursor/VS Code/agent host, restart host |
| `capture-timeout` | Display asleep, permission problem, or no frame delivered | Wake display, verify `doctor`, retry; if persistent, capture fullscreen once and compare |
| MCP server does not appear | Config path wrong or command path not absolute | Verify config file location, use `/opt/homebrew/bin/agentshot`, restart agent |
| `command not found` in agent | PATH differs or `~` was not expanded | Use fully expanded absolute path |
| `session-exists` | Previous scrolling session was not cleaned up | Finish it or delete `~/.agentshot/sessions/<id>` |
| Stitch warnings or gaps | Scrolled too far, lazy loading, animation, sticky headers | Scroll smaller increments, wait after scrolling, retry capture |
| `duplicate-frame-skipped` | Scroll did not move | Usually harmless; scroll farther or finish |
| `nothing-redacted` | Explicit/regex redaction rectangle did not intersect the image | Check coordinate system and image dimensions |
| Capture works in terminal but not in agent | macOS permission belongs to a different host | Run `doctor` from inside the agent and grant permission to that host |
| Cloud agent cannot use it | agentshot is macOS-only and captures only the machine where it runs | Use a local macOS agent/worker or the cloud agent's built-in browser screenshots |

## 18. Quick smoke test after configuring any agent

Paste this prompt into the agent:

```text
Use the agentshot MCP tools. Call doctor first. If screen recording is available, capture a small rectangle [20,20,300,200] to /tmp/agentshot-smoke.png, then report only the output dimensions, whether warnings were empty, and the file path. Do not quote any text visible in the screenshot.
```

A successful result means MCP configuration, process launch, screen permission, and image output are all working.
