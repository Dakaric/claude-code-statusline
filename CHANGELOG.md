# Changelog

What changed in each release, in plain words. Newest first.

## 1.2.0 — 2026-09-08

### Added

- **Support for more than one Claude account.** If you rotate between subscriptions, the status line keeps track of each one and shows both at once. It notices the second account by itself, the first time you send a prompt from it. With a single account nothing changes.
- **`rw 1.8d` — the runway.** How many days your combined budget lasts at the pace you've been going for the last 24 hours. `rw oo` means you're spending less than the accounts refill, so you won't run out at all.
- **`-> B` — when to switch accounts.** It appears when the account you're in is used up, or when budget is about to expire in another one and would otherwise go to waste. The numbers behind the advice are on the same line, so you can check it.
- **Worktree and effort.** The status line now shows which git worktree you're in and which reasoning effort level is set.

### Changed

- **Four lines instead of two**, one topic each: where you are, what you're working with, how this conversation is doing, what you're spending. A line with nothing to show disappears rather than leaving a gap.
- **The weekly limit turns red at 90% instead of 80%.** On a weekly budget, 80% used is normal spending, not an emergency.
- **The pacing number moved behind the weekly one**, because it describes it.
- The screenshot at the top of the README was two versions out of date and advertised counters that no longer exist.

### Fixed

- **The prompt-cache countdown is read from Claude Code instead of calculated.** Claude Code now reports when the cache expires, which is more reliable than working it out from the conversation log. The old method still runs on older Claude Code versions.
- The status line wrote an error message when `~/.claude` did not exist yet.

### Behind the scenes

- A test suite with a fixed clock, so the time-based parts can be checked without waiting for real hours to pass, and a check that runs on every push instead of only at release time.

## 1.1.1 — 2026-08-05

### Fixed

- **Percentages showed as 0** on systems that use a comma as the decimal separator, which is most of continental Europe.
- The cache segment said `kalt` in German while everything around it was English. It now says `cold`.

## 1.1.0 — 2026-08-05

### Fixed

- **The cache countdown never ran out.** Background writers touching the conversation log reset it, so it kept showing a full cache that had long gone cold. It now follows the last actual exchange with Claude.
- **`ctxQ` left an empty gap** in a fresh session, which looked like something was broken. It shows a placeholder until a score exists.

### Removed

- The agent and skill counters (`agt`, `skl`). They had been dropped from the code earlier without the surrounding parts being cleaned up, which is what broke the release build.

### Added

- A troubleshooting section in the README for the questions that came up most.

## 1.0.0 — 2026-06-27

First public release. Directory, git branch and model on one line; context window bar, 5-hour and weekly rate limits, daily pacing and prompt-cache countdown on the other. Everything appears only when there is something to show.
