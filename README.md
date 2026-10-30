# BrainFog

A native macOS app for seeing and managing the layered memory and context of AI coding agents: Claude Code, Codex, OpenCode, Cursor, Gemini CLI, GitHub Copilot, Devin Desktop (formerly Windsurf), and Cline.

Its core is the **Context Lens**: pick any folder, and BrainFog applies each agent's real loading rules to show which files it reads at launch, in what order, how many tokens each takes, and which files are shadowed, cut off, or loaded on demand. It also lists each agent's MCP servers and can copy one to another agent. It shows which agents read the shared AGENTS.md and fixes the ones that don't, flags health problems, and keeps every version of the files it sees. Every change it makes is shown as a diff first. See [docs/DESIGN.md](docs/DESIGN.md) for the design and roadmap.

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
