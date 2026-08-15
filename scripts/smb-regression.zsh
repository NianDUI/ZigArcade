#!/bin/zsh
set -euo pipefail

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
  './zig-out/bin/zigarcade nes "$ROM_PATH" --renderer ansi --audio --max-frames 1800 --replay "$REPLAY_PATH" --log "$LOG_PATH"' \
  2>&1 | /usr/bin/tail -c 65536 >"$log_dir/terminal.out"

[[ -s $log_path ]] || {
  print -u2 "SMB 回归未生成运行日志: $log_dir"
  /usr/bin/tail -c 4096 "$log_dir/terminal.out" >&2
  exit 1
}

grep -q 'audio .*non_silent_samples=[1-9]' "$log_path" || {
  print -u2 "SMB 回归未检测到非静音音频: $log_dir"
  /usr/bin/tail -20 "$log_path" >&2
  exit 1
}
grep -q 'audio .*running=1 .*last_render_error=0' "$log_path" || {
  print -u2 "SMB 回归音频设备状态异常: $log_dir"
  /usr/bin/tail -20 "$log_path" >&2
  exit 1
}
print "SMB 回归通过: $log_path"
