#!/usr/bin/env bash
# Behavior tests for home-scoped spawned-crewmate model and Codex effort pins.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-config.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

make_git_project() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# fixture\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

make_fake_tmux() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys|kill-window)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  list-windows) exit 0 ;;
  display-message)
    case "$*" in
      *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_TMUX_WORKTREE" ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

spawn_ordinary() {
  local home=$1 id=$2 harness=$3 log=$4 err=$5
  (
    cd "$WORKTREE" || exit 1
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
      FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_WORKTREE="$WORKTREE" \
      "$SPAWN" "$id" projects/alpha "$harness" > /dev/null 2>"$err"
  )
}

test_codex_pins_and_legacy_command() {
  local home log err expected
  home="$TMP_ROOT/ordinary-home"
  log="$TMP_ROOT/ordinary.log"
  err="$TMP_ROOT/ordinary.err"
  mkdir -p "$home/data/pinned" "$home/data/unpinned" "$home/config" "$home/state" "$home/projects"
  make_git_project "$home/projects/alpha"
  printf 'pinned brief\n' > "$home/data/pinned/brief.md"
  printf 'unpinned brief\n' > "$home/data/unpinned/brief.md"
  printf 'gpt-5.6-terra\n' > "$home/config/crew-model"
  printf 'high\n' > "$home/config/crew-effort"

  spawn_ordinary "$home" pinned codex "$log" "$err" || fail "pinned Codex ordinary spawn failed"
  grep -F -- '-m gpt-5.6-terra' "$log" >/dev/null || fail "ordinary Codex launch omitted the configured model"
  grep -F -- '-c model_reasoning_effort="high"' "$log" >/dev/null || fail "ordinary Codex launch omitted the configured effort"
  grep -F 'notify=[' "$log" >/dev/null || fail "ordinary Codex launch lost its notify hook"
  grep -F "$home/state/pinned.turn-ended" "$log" >/dev/null || fail "ordinary Codex launch lost its turn-end marker"

  rm -f "$home/config/crew-model" "$home/config/crew-effort"
  : > "$log"
  spawn_ordinary "$home" unpinned codex "$log" "$err" || fail "unpinned Codex ordinary spawn failed"
  expected="send-keys -t firstmate:fm-unpinned -l codex --dangerously-bypass-approvals-and-sandbox -c \"notify=[\\\"bash\\\",\\\"-c\\\",\\\"touch '$home/state/unpinned.turn-ended'\\\"]\" \"\$(cat '$home/data/unpinned/brief.md')\""
  grep -Fx "$expected" "$log" >/dev/null || fail "absent Codex pins changed the legacy ordinary launch command"
  pass "ordinary Codex pins, hook retention, and no-config compatibility"
}

test_secondmate_uses_its_own_codex_pins() {
  local main subhome subhome_abs log err
  main="$TMP_ROOT/secondmate-main"
  subhome="$TMP_ROOT/secondmate-home"
  log="$TMP_ROOT/secondmate.log"
  err="$TMP_ROOT/secondmate.err"
  mkdir -p "$main/data" "$main/state" "$subhome/bin" "$subhome/data" "$subhome/config" "$subhome/state" "$subhome/projects"
  printf '# Firstmate\n' > "$subhome/AGENTS.md"
  printf 'model-sm\n' > "$subhome/.fm-secondmate-home"
  printf 'secondmate charter\n' > "$subhome/data/charter.md"
  printf 'gpt-5.6-terra\n' > "$subhome/config/crew-model"
  printf 'high\n' > "$subhome/config/crew-effort"
  subhome_abs=$(cd "$subhome" && pwd -P)

  PATH="$FAKEBIN:$PATH" FM_HOME="$main" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_WORKTREE="$WORKTREE" \
    "$SPAWN" model-sm "$subhome" codex --secondmate > /dev/null 2>"$err" \
    || fail "pinned Codex secondmate spawn failed"
  grep -F -- '-m gpt-5.6-terra' "$log" >/dev/null || fail "secondmate Codex launch omitted its home-scoped model"
  grep -F -- '-c model_reasoning_effort="high"' "$log" >/dev/null || fail "secondmate Codex launch omitted its home-scoped effort"
  grep -F -- "-c 'projects={\"$subhome_abs\"={trust_level=\"trusted\"}}'" "$log" >/dev/null \
    || fail "secondmate Codex launch lost its trust override"
  grep -F 'notify=' "$log" >/dev/null && fail "secondmate Codex launch unexpectedly installed notify"
  pass "secondmate Codex uses home-scoped pins and retains trust configuration"
}

test_claude_pin_and_malformed_values() {
  local home log err
  home="$TMP_ROOT/validation-home"
  log="$TMP_ROOT/validation.log"
  err="$TMP_ROOT/validation.err"
  mkdir -p "$home/data/claude-pin" "$home/data/malformed" "$home/config" "$home/state" "$home/projects"
  make_git_project "$home/projects/alpha"
  printf 'claude brief\n' > "$home/data/claude-pin/brief.md"
  printf 'malformed brief\n' > "$home/data/malformed/brief.md"
  printf 'sonnet\n' > "$home/config/crew-model"

  spawn_ordinary "$home" claude-pin claude "$log" "$err" || fail "pinned Claude spawn failed"
  grep -F -- 'claude --model sonnet --dangerously-skip-permissions' "$log" >/dev/null \
    || fail "Claude launch omitted its existing model pin"

  printf 'foo; rm -rf /\n' > "$home/config/crew-model"
  printf 'high; rm -rf /\n' > "$home/config/crew-effort"
  : > "$log"
  : > "$err"
  spawn_ordinary "$home" malformed codex "$log" "$err" || fail "malformed Codex spawn failed"
  grep -F "warning: ignoring $home/config/crew-model:" "$err" >/dev/null \
    || fail "malformed model did not produce a warning"
  grep -F "warning: ignoring $home/config/crew-effort:" "$err" >/dev/null \
    || fail "malformed effort did not produce a warning"
  grep -F 'foo; rm -rf /' "$log" >/dev/null && fail "malformed model reached the launch string"
  grep -F 'high; rm -rf /' "$log" >/dev/null && fail "malformed effort reached the launch string"
  grep -F -- ' -m ' "$log" >/dev/null && fail "malformed model was not dropped from the launch string"
  grep -F 'model_reasoning_effort' "$log" >/dev/null && fail "malformed effort was not dropped from the launch string"
  pass "Claude model pin remains intact and malformed values cannot inject"
}

WORKTREE="$TMP_ROOT/project/.treehouse/worker"
mkdir -p "$(dirname "$WORKTREE")"
make_git_project "$WORKTREE"
FAKEBIN=$(make_fake_tmux "$TMP_ROOT/fake")

test_codex_pins_and_legacy_command
test_secondmate_uses_its_own_codex_pins
test_claude_pin_and_malformed_values
