# claude-code-statusline

A drop-in status line for [Claude Code](https://claude.ai/code) with everything you actually want to see at a glance: working directory, git branch, model, context usage with a progress bar, rate limits — and a live count of the sub-agents and skills you're using in the current session.

```
~/Sites/my-project   main   Opus 4.7   ctx ███░░░░░░░ 28% (280k/1M)   5h 42%   wk 18%   agt 3/33 +1bg   skl 7/141
```

## Segments

| Segment   | Example                       | When it shows |
|-----------|-------------------------------|---------------|
| Directory | `~/Sites/my-project`          | always (home collapsed to `~`) |
| Git       | ` main`                      | when in a git repo |
| Model     | `Opus 4.7`                    | always |
| Context   | `ctx ███░░░░░░░ 28% (280k/1M)` | progress bar, color shifts green → yellow → red as the window fills |
| 5h limit  | `5h 42%`                      | when present |
| Weekly    | `wk 18%`                      | when present |
| Weekly Opus | `wk-opus 7%`                | when present |
| Agents    | `agt 3/33 +1bg`               | `used/available`, `+Nbg` if N background agents are still running |
| Skills    | `skl 7/141`                   | unique skills invoked in this session / total available |
| Vim mode  | `[NORMAL]`                    | when vim mode is enabled |

Segments only appear when there's something to show — no clutter on a fresh session.

### How `agt` and `skl` work

- **Used** comes from the session transcript (`transcript_path` in the status line input). The script counts `Task` and `Skill` tool calls — so it reflects actual usage, not what's installed.
- **Available** is the total count of installed sub-agents (`~/.claude/agents/`, project-local `.claude/agents/`, and plugin agents) and skills (`SKILL.md` files in the same locations). This is cached for 5 minutes per working directory because scanning the plugin cache is expensive.
- **+Nbg** counts `Task` calls with `run_in_background: true` that don't have a matching `tool_result` yet — i.e. agents you dispatched that are still working.

## Installation

```bash
# 1. Drop the script anywhere on disk
curl -fsSL https://raw.githubusercontent.com/Dakaric/claude-code-statusline/main/statusline.sh \
  -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh

# 2. Wire it up in ~/.claude/settings.json
```

Add this to `~/.claude/settings.json` (create the file if it doesn't exist):

```json
{
  "statusLine": {
    "command": "~/.claude/statusline.sh"
  }
}
```

That's it. The next Claude Code session will use the new status line.

### Requirements

- `bash` (any modern version)
- `jq` — `brew install jq` on macOS, `apt install jq` on Debian/Ubuntu
- A terminal with ANSI color and basic Unicode (block characters for the progress bar)

## How it works

Claude Code pipes a JSON object to the status line command on every refresh. The script reads the relevant fields:

- `workspace.current_dir` / `cwd` — working directory
- `model.display_name` — current model
- `context_window.{context_window_size, used_percentage, current_usage}` — context utilization
- `rate_limits.{five_hour, weekly, weekly_opus}.used_percentage` — rate limits
- `transcript_path` — path to the JSONL transcript of the current session, used for the agent/skill counts
- `vim.mode` — vim mode indicator

The transcript is parsed with a single `jq` pass; on a 4 MB transcript this takes ~50 ms. Available counts are cached at `$TMPDIR/claude-statusline-avail-<cwd-hash>.cache`.

## Customizing

Open the script — every segment is its own block, and the color palette is at the top. Common tweaks:

- Change colors: edit the `C_*` ANSI variables near the top.
- Hide a segment: comment out the matching `line="${line}${SEP}${seg_*}"` line at the bottom.
- Adjust the context bar width: change `width=10` in `make_bar()`.
- Change the avail-cache TTL: the `300` (seconds) literal in the agents/skills block.

## Uninstall

Remove the `statusLine` entry from `~/.claude/settings.json` (or set it back to whatever you used before) and delete the script.

## License

MIT — see [LICENSE](LICENSE).
