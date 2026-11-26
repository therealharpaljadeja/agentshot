# agentshot

Agent-first macOS screenshot capture, annotation, redaction, scrolling stitching, and beautification.

The primary user is an agent. There is no required interactive editor, overlay, hotkey workflow, or mouse-driven selection. Commands accept explicit inputs and print structured JSON to stdout.

## Status

Early MVP. macOS-only. The implemented surface includes:

- fullscreen capture
- rectangular area capture
- agent-driven scrolling capture sessions
- rectangle, arrow, text, highlight, counter, and crop annotations
- blur, pixelate, erase, and solid redaction
- OCR with bounding boxes and regex-based redaction
- backdrop beautification with padding, rounded corners, shadow, and solid/gradient backgrounds
- CLI and experimental stdio MCP server

Automatic synthetic scrolling, window targeting, pinning, uploads, human editor UI, magnifier, spotlight, freehand drawing, image overlays, QR recognition, and compare helpers are intentionally outside the MVP.

## Installation

`agentshot` is a macOS command-line tool and MCP server. Homebrew is the preferred installation path:

```bash
brew tap therealharpaljadeja/agentshot https://github.com/therealharpaljadeja/agentshot.git
brew trust --tap therealharpaljadeja/agentshot
brew install agentshot
agentshot doctor
```

The explicit tap URL is required because this repository is both the project repository and its own Homebrew tap. Homebrew also requires third-party taps to be explicitly trusted before their formulae can be installed. The formula installs a prebuilt universal macOS binary supporting Apple silicon and Intel Macs running macOS 14 Sonoma or newer.

Homebrew installs the executable at `$(brew --prefix)/bin/agentshot`:

- Apple silicon: usually `/opt/homebrew/bin/agentshot`
- Intel: usually `/usr/local/bin/agentshot`

Use the fully expanded absolute path in MCP configuration. Do not rely on `~`, `$HOME`, or PATH expansion inside agent MCP config files.

There is no `.dmg` or GUI app because there is no GUI `.app` to drag into Applications. To build from source instead, see [docs/agent-integration.md](docs/agent-integration.md) for detailed agent-specific setup and the manual build path.

## Build and test

Requires a macOS machine with Xcode/Swift installed.

```bash
swift build
swift test
```

The debug binary is `.build/debug/agentshot`.

## Permissions

Screen Recording permission is required for capture. macOS grants that permission to the process or parent host that runs the binary, so granting it to one terminal/editor may not grant it to another.

```bash
agentshot doctor
```

MVP scrolling capture is agent-driven: the calling agent scrolls the screen itself. Because agentshot does not inject scroll events, Accessibility permission is not required for the MVP workflow.

## CLI

All successful commands print JSON containing artifact paths, dimensions, checksums, metadata, and warnings. Errors also print JSON and exit non-zero.

### Capture

```bash
agentshot capture fullscreen --out screen.png
agentshot capture area --rect 100,200,800,600 --out area.png
```

Area rectangles use top-left screen points: `x,y,width,height`.

### Annotate

```bash
agentshot annotate area.png --ops ops.json --out annotated.png
```

`--ops` may be a file path or an inline JSON array.

```json
[
  { "type": "rect", "rect": [40, 100, 420, 90], "stroke": "#ff3b30", "strokeWidth": 4 },
  { "type": "arrow", "from": [640, 240], "to": [460, 145], "stroke": "#ff3b30", "strokeWidth": 6 },
  { "type": "text", "at": [80, 360], "text": "Sensitive value" },
  { "type": "highlight", "rect": [42, 104, 160, 24] },
  { "type": "counter", "at": [100, 420] },
  { "type": "counter", "at": [580, 220] }
]
```

Annotation coordinates are top-left image pixels. Arrows do not need angles; direction is derived from `from` and `to`. Counters auto-number in operation order.

A crop operation can be included:

```json
[
  { "type": "crop", "rect": [20, 20, 800, 500] }
]
```

Crop is applied before other operations. Post-crop operation coordinates are interpreted in cropped-image coordinates.

### OCR and redaction

```bash
agentshot ocr input.png
agentshot redact input.png --regex 'sk-[A-Za-z0-9_-]+' --method blur --out safe.png
agentshot redact input.png --rect 20,30,300,60 --method pixelate --out safe.png
```

Methods:

- `blur`
- `pixelate`
- `erase` / `erase-text` — currently fills with the region's average color; useful on uniform backgrounds, not true inpainting
- `solid`

OCR uses Apple Vision on-device. Regex redaction currently redacts the whole OCR line containing a match, padded slightly.

### Beautify

```bash
agentshot beautify annotated.png \
  --padding 64 \
  --radius 24 \
  --shadow 0.25 \
  --background '#dceeff' \
  --out final.png
```

Use a comma-separated pair for a vertical gradient:

```bash
agentshot beautify annotated.png --background '#dceeff,#ffe4f1' --out final.png
```

### Agent-driven scrolling capture

Start a session, capture a frame, scroll using the agent's normal computer/browser control, capture another frame, repeat, then finish:

```bash
agentshot scrollcap start --rect 100,200,800,600 --session s1
agentshot scrollcap frame --session s1
# agent scrolls down
agentshot scrollcap frame --session s1
# agent scrolls down again
agentshot scrollcap frame --session s1
agentshot scrollcap finish --session s1 --out tall.png
```

The stitcher detects vertical overlap between consecutive frames and returns confidence/warnings. It is designed for ordinary mostly-static vertical content. Animated content, parallax, sticky elements inside the capture rect, lazy-loading gaps, and horizontal scrolling remain hard cases.

Session frames are stored under `~/.agentshot/sessions/<id>/` so sessions can span multiple CLI invocations.

## MCP server

For detailed per-agent setup, configuration examples, workflows, and troubleshooting, see [docs/agent-integration.md](docs/agent-integration.md).

Start the experimental stdio MCP server:

```bash
agentshot mcp
```

Tools exposed:

- `doctor`
- `capture_fullscreen`
- `capture_area`
- `annotate`
- `redact`
- `ocr`
- `beautify`
- `scroll_capture_start`
- `scroll_capture_add_frame`
- `scroll_capture_finish`

Example client configuration shape, adapted to the specific agent's MCP syntax:

```json
{
  "mcpServers": {
    "agentshot": {
      "command": "/absolute/path/to/agentshot",
      "args": ["mcp"]
    }
  }
}
```

The MCP adapter is intentionally thin and invokes the same operations as the CLI.

## Output contract

Example success:

```json
{
  "ok": true,
  "artifacts": [
    {
      "kind": "image",
      "path": "/tmp/final.png",
      "width": 1600,
      "height": 1200,
      "units": "image-pixels",
      "sha256": "..."
    }
  ],
  "warnings": []
}
```

Example error:

```json
{
  "ok": false,
  "error": {
    "code": "missing-screen-recording-permission",
    "message": "Screen Recording permission is not granted...",
    "recovery": "Grant Screen Recording permission..."
  }
}
```

## Architecture

```text
CLI ────────┐
            ├── AgentshotCore ── ScreenCaptureKit / Vision / CoreGraphics / CoreImage
MCP stdio ──┘
```

The current implementation is a single Swift package. If permission identity becomes a problem across terminal hosts, capture can move behind a signed daemon while preserving the same CLI/MCP interface.
