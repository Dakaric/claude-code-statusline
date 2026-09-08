<p align="center">
  <img src="assets/hero.png" alt="claude-code-statusline — a four-line status line for Claude Code" width="100%">
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Dakaric/claude-code-statusline?color=blue" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/shell-bash-121011?logo=gnubash&logoColor=white" alt="Shell: bash">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey" alt="Platform: macOS | Linux">
  <img src="https://img.shields.io/badge/dependencies-jq-brightgreen" alt="Dependencies: jq">
</p>

# claude-code-statusline

A drop-in status line for [Claude Code](https://claude.com/claude-code) that puts everything you actually glance at on **two tidy lines**: where you are and what you're running up top, and every live metric — context window, prompt-cache TTL, rate limits and weekly pacing — underneath.

A single `bash` script, one `jq` pass per refresh. No daemon, no config file, no dependencies beyond `jq`.

> Unofficial. Not affiliated with or endorsed by Anthropic. It reads the JSON that Claude Code already pipes to its status line command — nothing else.

```
~/Sites/my-project   main
Opus 4.8   effort high
ctxQ A(92)   ctx ███░░░░░░░ 28% (280k/1M)   cache 47m12s/1h
5h 42% (1h58m)   wk 18%   wk-opus 7%   d +6% (3.2d)
```

What changed in each version is in [CHANGELOG.md](CHANGELOG.md).

Segments only appear when there's something to show — a fresh session in a non-git directory is just the path and the model, nothing else.

## Four lines, four jobs

| Line | Question it answers | Segments |
|------|---------------------|----------|
| **Place** | Where am I? | directory · git branch · worktree |
| **Tool** | What am I working with? | model · effort · vim mode |
| **Session** | How is this conversation doing? | context quality · context window · prompt-cache TTL |
| **Limits** | What am I burning, and how fast? | 5h · weekly · weekly-opus · pacing · account switch |

The split is the point. The first two lines barely change within a session, the last two move on every turn. Your eye learns where to look. An empty line disappears entirely rather than leaving a gap, so a session without rate limits is three lines, not four with a hole in it.

## Segments

| Segment | Example | When it shows |
|---------|---------|---------------|
| Directory | `~/Sites/my-project` | always (home collapsed to `~`) |
| Git | ` main` | in a git repo |
| Worktree | `wt my-feature` | when the session runs in a worktree |
| Model | `Opus 4.8` | always |
| Effort | `effort high` | when the model supports the reasoning-effort parameter |
| Prompt-cache | `cache 47m12s/1h` | always — time left before the prompt cache goes cold, over the TTL |
| Vim mode | `[NORMAL]` | when vim mode is enabled |
| Context quality | `ctxQ A(92)` | when a token-optimizer score exists for the session |
| 5h limit | `5h 42% (1h58m)` | when present — percentage used + time left until reset |
| Weekly | `wk 18%` | when present |
| Weekly Opus | `wk-opus 7%` | when present |
| Daily pacing | `d +6% (3.2d)` | with one known account |
| Runway | `rw 2.4d` | with two or more known accounts |
| Account switch | `-> B` | when another account is the better place to work |
| Context window | `ctx ███░░░░░░░ 28% (280k/1M)` | progress bar, green → yellow → red as it fills |

Every percentage colours itself: green under 50%, yellow from 50%, red from 80%.

### `cache 47m12s/1h` — prompt-cache TTL

How long before your prompt cache expires and the next turn pays full price for the whole context again. The TTL is `1h` when `ENABLE_PROMPT_CACHING_1H` is set, otherwise `5m`.

Every API call rewrites the cache and resets the TTL to full — not just your input, but each step the agent takes while it works. So the reference point is the timestamp of the **last assistant message** in the transcript: the clock only starts once the agent is done. (The transcript's file mtime looks like the obvious source and isn't — hooks and background writers touch it without ever touching the cache, which pins the countdown at full.)

It reads `47m12s/1h` → `12m03s/1h` → `2m41s/1h` → `cold`. Cyan while there's room, yellow in the last fifth, red once it's gone. `cold` is your cue that the next message rebuilds the cache from scratch — a good moment to hand off or `/clear` rather than pay for context you no longer need.

### `5h 42% (1h58m)` — the countdown

The five-hour rate limit shows both the percentage used **and** how long until it resets, read from `resets_at` in the payload. Under an hour it collapses to minutes (`(42m)`). You can see at a glance whether to push on or wait it out.

### `d +6% (3.2d)` — daily pacing

The weekly limit is your real budget. Spend it evenly and you "earn" one-seventh (~14.3%) of it per day. The `d` segment compares where you *should* be (by elapsed time) against where you *are* (`wk`):

- **`+6%`** — under budget, money in the bank. Green.
- **`-8%`** — over budget, burning ahead of pace. Yellow.
- **`-20%`** — more than a full day ahead of pace. Red.

The trailing `(3.2d)` is how much of the week is left before the limit resets. It turns an abstract "18% used" into "am I going to run out before Friday?"

With two or more accounts this segment is replaced by the runway, described below.

### Multiple accounts

If you rotate between several Claude subscriptions, one account's seven-day window is no longer your budget — the sum of them is. The status line notices this on its own: it keeps one snapshot per account under `~/.claude/statusline-accounts/`, keyed by the `oauthAccount.accountUuid` from `~/.claude.json`, and switches to the multi-account view once a second file appears. With a single account nothing changes, so a fresh clone never shows any of this.

Accounts are labelled `A`, `B`, `C` in the order they were first seen. The UUID stays in the filename and is never displayed.

```
5h A 87% (0h12m) B free | wk A 24% (5.1d) B 78% (0.9d) | rw 1.8d | -> B
```

**The inactive account's numbers are exact, not stale.** You only ever work in one account at a time, so the other one's usage cannot have moved since you last saw it. And if its window expires while it sits idle, it is back to zero — its own `resets_at` says so.

**`rw 1.8d` — the runway.** Your combined budget refills at `N × 100` points per seven days: 28.6 points a day with two accounts. Burn less than that and you never run dry, which the segment shows as `rw oo`. Burn more and `rw` is how many days the remaining budget lasts at your pace over the last 24 hours, read from a per-account time series next to each snapshot. `rw ?` means there aren't two measurements yet. The maths smooths the individual resets into a steady trickle, so it can be off by hours when a reset is imminent.

**`-> B` — the switch hint.** It appears for either of two reasons: the account you're in is finished (5h or weekly at 95% or more), or more budget is expiring elsewhere than here. The second one is a rate: `remaining / days until reset` is what you'd have to spend per day for nothing to go to waste. An account with 20% left and a reset tomorrow beats one with 60% left and five days to go. Either way the hint only shows when the target has 5h capacity free — a full five-hour window makes the switch pointless no matter how much weekly budget is expiring there.

The numbers behind the hint are on the line, so you can check it rather than trust it. To forget an account you logged into by accident, delete its `.json` and `.history` from `~/.claude/statusline-accounts/`.

### `ctxQ A(92)` — context quality

If you run a token-optimizer plugin that scores context health, its `UserPromptSubmit` hook writes a grade to `~/.claude/token-optimizer/quality-cache-<session>.json` every couple of minutes. The segment surfaces that grade and score (`A(92)`), coloured green/yellow/orange/red by band. No file, no segment — it stays out of the way.

## Install

```bash
# 1. Drop the script anywhere on disk
curl -fsSL https://raw.githubusercontent.com/Dakaric/claude-code-statusline/main/statusline.sh \
  -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then wire it up in `~/.claude/settings.json` (create the file if it doesn't exist):

```json
{
  "statusLine": {
    "command": "~/.claude/statusline.sh"
  }
}
```

The next Claude Code session picks it up. That's the whole install.

### Pin to a release

`main` is the rolling latest. To pin a known version instead, grab it from the [Releases](https://github.com/Dakaric/claude-code-statusline/releases) page — every release ships the script and a `SHA256SUMS` file:

```bash
ver=v1.1.1
base=https://github.com/Dakaric/claude-code-statusline/releases/download/$ver
curl -fsSL "$base/statusline.sh" -o ~/.claude/statusline.sh
curl -fsSL "$base/SHA256SUMS"   -o /tmp/SHA256SUMS

# verify before trusting it
( cd ~/.claude && shasum -a 256 -c /tmp/SHA256SUMS --ignore-missing )  # macOS
# sha256sum -c /tmp/SHA256SUMS --ignore-missing                        # Linux

chmod +x ~/.claude/statusline.sh
```

Check which version you have any time with `statusline.sh --version`.

### Requirements

- `bash` — any modern version
- `jq` — `brew install jq` (macOS) or `apt install jq` (Debian/Ubuntu)
- A terminal with ANSI colour and basic Unicode (block characters for the progress bar)

## Troubleshooting

### The cache segment shows `cache 1h` and never counts down

You're on a build from before the countdown existed. Check in one line:

```bash
grep -c cache_calc ~/.claude/statusline.sh
```

- **`0`** — old script. The cache segment there is a fixed label with no countdown code at all; nothing about your setup can make it move. Re-run the `curl` from [Install](#install), or pin `v1.1.0` or later. **Release `v1.0.0` does not have the countdown.**
- **`1`** — you have the countdown, see the next entry.

Careful with `statusline.sh --version` here: `VERSION` stayed at `1.0.0` while the countdown landed on `main`, so builds pulled from `main` between the two releases report `v1.0.0` and *do* have it. `v1.1.0` onwards the version string is trustworthy again — but the `grep` settles it either way.

### The countdown is there but always reads near-full

Expected, if you're on the 5-minute TTL. Every API call resets the cache clock to full, and the status line only redraws while Claude Code is doing something — so during a turn you're watching a timer that gets reset out from under you. You'd only catch it low in the seconds after the agent finishes.

With `ENABLE_PROMPT_CACHING_1H=1` the TTL is an hour and one turn can't consume it, so the countdown visibly walks down and eventually hits `cold`. If you want to watch it decay on the short TTL, finish a turn and leave the session alone — the next redraw shows the lower value.

### The status line is blank, or just the path and model

`jq` is missing or not on the `PATH` Claude Code runs with. Every field is extracted through it, so without `jq` there's nothing to print. Confirm with `jq --version`, install per [Requirements](#requirements).

If `jq` is fine but the cache countdown is the only thing missing, the payload has no `transcript_path` — some older Claude Code versions don't send it. The segment falls back to a bare `cache 1h` with no time left on it.

### `ctxQ` sits at `…` forever

The placeholder means "no score written yet". The `ctxQ` segment reads a file that a token-optimizer plugin's `UserPromptSubmit` hook writes every couple of minutes to `~/.claude/token-optimizer/quality-cache-<session>.json` — it's not something this script computes. Fresh sessions show `…` for the first few minutes; if it never resolves, that plugin isn't installed or its hook isn't firing:

```bash
ls -la ~/.claude/token-optimizer/
```

No plugin, no score. Drop the `seg_ctxq` block from `line2` if you don't use one.

### The `agt` and `skl` counters are gone

Removed in `v1.1.0`. Earlier versions carried in-flight sub-agent and skill counters on the metrics line; they scanned the plugin cache on every refresh and were dropped. `v1.0.0` still has them if you want them back.

### Nothing changed after editing the script

Claude Code reads the `statusLine` command per session. Start a new session, and check that the path in `~/.claude/settings.json` points at the file you actually edited — a symlinked or second copy under `~/.claude/statusline-command.sh` is a common mix-up. Verify the script runs standalone:

```bash
echo '{}' | ~/.claude/statusline.sh
```

That should print a line, not an error. Also confirm it's executable (`chmod +x`).

## How it works

Claude Code pipes a JSON object to the status line command on every refresh. The script makes one read of the fields it needs:

| Field | Drives |
|-------|--------|
| `workspace.current_dir` / `cwd` | directory, git branch |
| `model.display_name` | model |
| `context_window.{context_window_size, used_percentage, current_usage}` | context window bar |
| `rate_limits.{five_hour, weekly, weekly_opus}.used_percentage` | 5h / weekly / weekly-opus |
| `rate_limits.*.resets_at` | the 5h countdown, pacing, runway and switch hint |
| `prompt_cache.{expires_at, ttl}` | prompt-cache countdown |
| `worktree.name` | worktree indicator |
| `effort.level` | effort indicator |
| `transcript_path` | context-quality score, prompt-cache fallback on older versions |
| `vim.mode` | vim indicator |

The account identity is the one thing the payload does not carry. It comes from `oauthAccount.accountUuid` in `~/.claude.json`.

Rate-limit keys drift between CLI versions (`weekly` vs `seven_day`), so the script takes the **max** of the known aliases instead of trusting one. The transcript is read in a single `jq` pass for the last assistant timestamp that drives the cache countdown.

### Rate-limit snapshot

The Claude Code Agent SDK doesn't expose rate-limit usage — only this status line payload carries it. So on every refresh the script also tees a small snapshot to `~/.claude/jarvis-rate-limits.json`:

```json
{ "rate_limits": { ... }, "captured_at": 1751021400 }
```

Handy if you want an external tool or dashboard to read your current usage. Delete the two `jq`/`echo` lines near the top if you don't want it written.

## Customizing

Every segment is its own block and the colour palette sits at the top of the script. Common tweaks:

- **Colours** — edit the `C_*` ANSI variables near the top.
- **Re-order or drop a segment** — change the `join_segs` argument lists at the bottom (`line1` / `line2`). Move a segment between lines, or delete it from both.
- **Go back to one line** — put every segment into a single `join_segs` call.
- **Bar width** — change `width=10` in `make_bar()`.
- **Cache-countdown thresholds** — the `t*0.2` in the prompt-cache block decides when the countdown turns yellow.

## Releasing

The version lives in one place — the `VERSION` line at the top of `statusline.sh`, surfaced by `statusline.sh --version`. A release is just a matching tag:

```bash
# 1. bump VERSION="x.y.z" in statusline.sh, commit it
# 2. add a "## x.y.z — YYYY-MM-DD" section to CHANGELOG.md, commit it
# 3. tag and push
git tag vx.y.z
git push origin vx.y.z
```

The push triggers [`release.yml`](.github/workflows/release.yml), which **fails the build if the tag doesn't match `VERSION`** or if [`CHANGELOG.md`](CHANGELOG.md) has no section for that version, runs `shellcheck` and the test suite, generates `SHA256SUMS`, and publishes a GitHub Release with the script and checksum attached. So the tag, the script and the release notes can never drift apart.

The release notes are the changelog section, written for people who just want to know what changed — not a list of commit subjects.

## Uninstall

Remove the `statusLine` entry from `~/.claude/settings.json` (or restore your previous one) and delete the script.

## License

MIT — see [LICENSE](LICENSE).
