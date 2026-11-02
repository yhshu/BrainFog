# BrainFog

A native macOS app for seeing and managing the layered memory and context of coding agents: Claude Code, Codex, Cursor, GitHub Copilot, Gemini, OpenCode, Cline, and Devin.

Its core is the **Context Lens**: pick any project folder, and BrainFog applies each agent's loading rules to show which files it reads at launch, in what order, how many tokens each takes, and which files are shadowed, cut off, or loaded on demand. 
It also lists each agent's MCP servers and can copy one to another agent. 
It shows which agents read the shared AGENTS.md and fixes the ones that don't, keeps one set of global instructions in step across agents, flags health problems, and keeps every version of the files it sees, with a timeline of what changed. 
Projects can be moved as `.agentpack` files, with credentials taken out. 
Every change it makes is shown as a diff first, except switching an MCP server off, which happens at once and stays in History. See [docs/DESIGN.md](docs/DESIGN.md) for the design and roadmap.

## Install

Requires macOS 26 or later on Apple Silicon.

1. Download `BrainFog-<version>-macOS.zip` from the [latest release](https://github.com/yhshu/BrainFog/releases/latest), unzip it, and move `BrainFog.app` to Applications.
2. The app isn't notarized yet, so macOS blocks it the first time. Open it once, then go to System Settings → Privacy & Security, click **Open Anyway** next to the BrainFog message, and confirm.

Or clear the quarantine flag in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/BrainFog.app
```

## Build

Requires macOS 26 or later. The Command Line Tools are enough:

```bash
./scripts/build-app.sh                                 # builds build/BrainFog.app
./scripts/test.sh                                      # runs the tests
swift run --build-system native brainfog-cli <folder>    # prints the resolved context
swift scripts/make-icon.swift Resources/AppIcon.png    # redraws the app icon
```

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): the source is available and may be used and modified for noncommercial purposes. Commercial use is not permitted.

Required Notice: Copyright (c) 2026 Yiheng Shu
