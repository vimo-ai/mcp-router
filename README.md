<!-- <p align="center">
  <img src=".github/assets/logo.svg" width="180" alt="MCP Router Logo">
</p> -->

<h1 align="center">MCP Router</h1>

<p align="center">
  <strong>One endpoint. All your MCP servers.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-blue" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-5.9+-orange" alt="Swift">
  <img src="https://img.shields.io/badge/Rust-1.75+-red" alt="Rust">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

<p align="center">
  <a href="https://vimo.run/docs/mcp-router">Documentation</a> •
  <a href="https://github.com/vimo-ai/mcp-router/releases">Download</a>
</p>

---

## Why?

- **Context cost** — Every MCP server loads all tool schemas upfront. With dozens of servers, that's a lot of tokens before you even start.
- **Config everywhere** — Every project needs its own `.mcp.json`. Change a server, update every project.
- **Different needs** — Web projects need Chrome DevTools. Backend needs database tools. iOS needs Xcode tools.

MCP Router solves this with one HTTP endpoint that routes to all your servers, progressive tool discovery, and workspace-based configuration.

## Features

- **Single Endpoint** — Configure servers once, connect from anywhere via `localhost:19104`
- **Progressive Disclosure** — AI queries tool schemas on demand, not all at once
- **Workspaces** — Different projects use different server combinations via tokens
- **One-Click Setup** — Auto-configure Claude Code and Codex from the app

## Quick Start

### 1. Install

Download from [GitHub Releases](https://github.com/vimo-ai/mcp-router/releases), unzip, and move to Applications.

### 2. Add Your Servers

Open the app → Settings → Servers. Add your MCP servers (stdio or http).

### 3. Configure Claude Code

One-click from app (Settings → Integration), or manually:

```bash
claude mcp add mcp-router -- npx -y mcp-remote http://localhost:19104
```

### 4. Done

Restart Claude Code. It now sees 4 meta tools:

| Tool | Purpose |
|------|---------|
| `mcp_router__list_servers` | List available servers |
| `mcp_router__list_tools` | List tools for a server |
| `mcp_router__describe` | Get tool parameter schema |
| `mcp_router__call` | Call a backend tool |

AI uses these to progressively discover and call your actual tools.

## Workspaces

Different projects can use different server combinations:

1. Create a workspace in Settings → Workspaces
2. Select which servers to enable
3. Get a token
4. Add the token to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "mcp-router": {
      "type": "http",
      "url": "http://localhost:19104",
      "headers": {
        "X-Workspace-Token": "your-token"
      }
    }
  }
}
```

Without a token, requests use the Default Workspace.

## Build from Source

```bash
git clone https://github.com/vimo-ai/mcp-router.git
cd mcp-router && ./scripts/build-core.sh
open mcp-router.xcodeproj  # Cmd+R
```

## Documentation

- [Why MCP Router?](https://vimo.run/docs/mcp-router/why) — The problems and our approach
- [Installation](https://vimo.run/docs/mcp-router/installation) — Download and configure
- [Usage Guide](https://vimo.run/docs/mcp-router/usage) — Workspaces, tokens, troubleshooting
- [Architecture](https://vimo.run/docs/mcp-router/architecture) — Technical details

## License

[MIT](./LICENSE)
