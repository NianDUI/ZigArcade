#!/bin/zsh
set -eu

if (( $# != 2 )); then
  print -u2 "用法: $0 <Super Mario Bros.nes> <输入日志>"
  exit 64
fi

rom_path=$1
replay_path=$2
[[ -r $rom_path ]] || { print -u2 "无法读取 ROM: $rom_path"; exit 66; }
[[ -r $replay_path ]] || { print -u2 "无法读取输入日志: $replay_path"; exit 66; }

log_dir=$(mktemp -d /tmp/zigarcade-smb-regression.XXXXXX)
log_path="$log_dir/run.log"

zig build
env ROM_PATH="$rom_path" REPLAY_PATH="$replay_path" LOG_PATH="$log_path" \
  script -q /dev/null /bin/zsh -c \
  './zig-out/bin/zigarcade nes "$ROM_PATH" --renderer ansi --audio --replay "$REPLAY_PATH" --log "$LOG_PATH"' \
  >"$log_dir/terminal.out" 2>&1

grep -q 'audio .*non_silent_samples=[1-9]' "$log_path"
grep -q 'audio .*running=1 .*last_render_error=0' "$log_path"
print "SMB 回归通过: $log_path"
