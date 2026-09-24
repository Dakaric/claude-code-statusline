#!/usr/bin/env bash
# Das Branch-Segment gegen echtes git: normaler Branch aus einem Unterordner heraus,
# losgeloester HEAD und ein Worktree, dessen .git eine Datei mit Verweis ist. Erwartet
# wird jeweils, was git selbst ueber HEAD sagt.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
test_now=1788870000
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
failed=0

git_quiet() { git -C "$sandbox/repo" -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }

mkdir -p "$sandbox/repo/sub/dir"
git_quiet init -b feature/zweig
git_quiet commit --allow-empty -m eins
git_quiet worktree add -b wt-zweig "$sandbox/wt"
detached_sha=$(git -C "$sandbox/repo" rev-parse --short HEAD)

# Gibt die Git-Zeile der Statusline fuer ein Arbeitsverzeichnis aus.
branch_line() {
  jq -n --arg cwd "$1" '{workspace: {current_dir: $cwd}, model: {display_name: "M"}}' \
    | HOME="$sandbox/home" NO_COLOR=1 STATUSLINE_NOW="$test_now" \
      env -u ENABLE_PROMPT_CACHING_1H bash "$root/statusline.sh" | head -1
}

expect_branch() {
  local name=$1 cwd=$2 expected=$3 actual
  actual=$(branch_line "$cwd")
  if [ "$actual" != "$cwd |  $expected" ]; then
    printf 'FEHLER branch %s: erwartet "%s", bekommen "%s"\n' "$name" "$cwd |  $expected" "$actual"
    failed=1
  fi
}

expect_branch unterordner "$sandbox/repo/sub/dir" feature/zweig
expect_branch worktree "$sandbox/wt" wt-zweig
git_quiet checkout --detach
expect_branch losgeloest "$sandbox/repo" "$detached_sha"

actual=$(branch_line "$sandbox")
if [ "$actual" != "$sandbox" ]; then
  printf 'FEHLER branch ohne-repo: erwartet "%s", bekommen "%s"\n' "$sandbox" "$actual"
  failed=1
fi

[ "$failed" = 0 ] && printf 'ok     branch (Unterordner, Worktree, losgeloest, ohne Repo)\n'
exit "$failed"
