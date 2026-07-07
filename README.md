# claude-status-line

A Claude Code statusline script that shows model, context window usage, and rate limits in the Claude Code UI header.

![statusline example](https://img.shields.io/badge/Claude_Code-statusline-blue)

## What it shows

**Line 1** — model, version, session, vim/agent mode, account, plan, working directory, git branch

**Line 2** — context window progress bar with token breakdown (input, output, cache read/write)

**Line 3** — session cost, lines changed, and session duration

**Line 4** — 5-hour and 7-day rate limit bars with reset countdowns

### Rate limit caching

Claude Code only includes rate limit data in the statusline JSON when it receives fresh headers from the API. Without caching, the rate limit bars disappear between messages. This script persists the last known values to a temp file and shows a `(cached Xm ago)` label when displaying stale data, so the bars are always visible.

## Requirements

- [Claude Code](https://claude.ai/code)
- `jq` on PATH (comes with Git Bash on Windows; `brew install jq` on Mac)
- Bash (Git Bash on Windows, native on Mac/Linux)

## Installation

```bash
git clone git@github.com:gigadude1982/claude-status-line.git
cd claude-status-line
bash install.sh
```

The install script copies `statusline.sh` to `~/.claude/statusline.sh` and prints the exact block to add to `~/.claude/settings.json`.

### Manual settings.json update

Add the `statusLine` block printed by `install.sh` to `~/.claude/settings.json`:

**Mac / Linux**
```json
"statusLine": {
  "type": "command",
  "command": "/Users/<you>/.claude/statusline.sh",
  "padding": 2
}
```

**Windows (Git Bash)**
```json
"statusLine": {
  "type": "command",
  "command": "C:\\Program Files\\Git\\bin\\bash.exe /c/Users/<you>/.claude/statusline.sh",
  "padding": 2
}
```

## Updating

```bash
git pull
bash install.sh
```

## Plan detection

The script reads `~/.claude.json` to determine your subscription tier and displays it in the header:

| Tier | Label |
|------|-------|
| `default_claude_max_5x` | Max 5x |
| `default_claude_max_20x` | Max 20x |
| `default_claude_max_1x` | Max 1x |
| `claude_pro` | Pro (or Max if extra usage enabled) |
