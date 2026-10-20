#!/usr/bin/env bash
# Live check: a real fm-control.sh relaunch (real tmux on a private lab socket,
# real claude binary as the replacement harness) of a task whose record already
# carries pr=/pr_head= and an armed PR merge poll. After the relaunch the record
# must still end with the pr= identity tail and the armed poll must still pass
# the watcher's authentication (fm_pr_poll_snapshot_capture).
# Usage: fm-live-relaunch-pr.sh <worktree-root> <trace:on|off>
set -u
ROOT=$1 TRACE=$2
ID=rlv$RANDOM
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB" "/tmp/fm-$ID"
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/user-home"
export TMUX_TMPDIR="$LAB/tmux"
STATE="$LAB/state"

# Disposable project + task worktree.
PROJ="$LAB/projects/demo" WT="$LAB/wt-$ID"
git init -q -b main "$PROJ"
git -C "$PROJ" -c user.email=lab@example.invalid -c user.name=lab commit -q --allow-empty -m init
git -C "$PROJ" worktree add -q -b "fm/$ID" "$WT"

mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Live relaunch check for $ID.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF

# Real tmux server on the lab socket; the task window holds an idle shell
# (agent already gone), as after a crash.
tmux -L fm-lab new-session -d -s labses -n "fm-$ID" -c "$WT" "bash --noprofile --norc"
TMUX_SOCK=$(tmux -L fm-lab display-message -p '#{socket_path}')

{
  echo "window=labses:fm-$ID"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "tasktmp=/tmp/fm-$ID"
  echo "model=default"
  echo "effort=default"
  echo "pr=https://github.com/example/repo/pull/47"
  echo "pr_head=0123456789abcdef0123456789abcdef01234567"
} > "$STATE/$ID.meta"

if [ "$TRACE" = on ]; then
  touch "$LAB/config/trace-context"
  printf '%s\n' "$$" > "$STATE/.lock"
  printf '%s on\n' "$$" > "$STATE/.trace-context-effective"
fi

# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
fm_pr_poll_prepare "$STATE" "$ID" github https://github.com/example/repo/pull/47 \
  github.com example/repo 47 "$POLL" && fm_pr_poll_publish_prepared || { echo "arm failed"; exit 1; }
if fm_pr_poll_snapshot_capture "$STATE" "$ID" "$POLL"; then
  echo "BEFORE relaunch: armed PR poll authenticates: yes"
else
  echo "BEFORE relaunch: armed PR poll authenticates: NO"; exit 1
fi
echo "--- record before relaunch ($STATE/$ID.meta) ---"; cat "$STATE/$ID.meta"

echo "--- \$ bin/fm-control.sh $ID relaunch --note 'continuing after PR open' ---"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  FM_HOME="$LAB" HOME="$LAB/user-home" TMUX="$TMUX_SOCK,0,0" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "continuing after PR open" 2>&1
rc=$?
echo "relaunch exit code: $rc"
echo "--- record after relaunch ---"; cat "$STATE/$ID.meta"
echo "--- live tmux pane after relaunch: pane command ---"
tmux -L fm-lab list-panes -a -F '#{session_name}:#{window_name} #{pane_current_command}'
if fm_pr_poll_snapshot_capture "$STATE" "$ID" "$POLL"; then
  echo "AFTER relaunch: armed PR poll authenticates: yes (pr=$FM_PR_META_URL)"
  auth=0
else
  echo "AFTER relaunch: armed PR poll authenticates: NO"
  auth=1
fi
last_key=$(grep -v '^x_' "$STATE/$ID.meta" | tail -n 2 | cut -d= -f1 | tr '\n' ' ')
echo "last two non-x_ keys: $last_key"
[ "$rc" = 0 ] && [ "$auth" = 0 ]
