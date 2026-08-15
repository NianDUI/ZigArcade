#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  print -u2 "用法: $0 <Super Mario Bros.nes> <输入日志> [帧数，默认 10500]"
  exit 64
fi

rom_path=$1
replay_path=$2
max_frames=${3:-10500}
[[ -r $rom_path ]] || { print -u2 "无法读取 ROM: $rom_path"; exit 66; }
[[ -r $replay_path ]] || { print -u2 "无法读取输入日志: $replay_path"; exit 66; }
[[ $max_frames == <-> ]] && (( max_frames >= 1 && max_frames <= 100000 )) || {
  print -u2 "帧数必须在 1 到 100000 之间: $max_frames"
  exit 64
}
replay_frame_count=$(/usr/bin/awk '
  /^frame=[0-9]+ input_actions=/ {
    frame = $1
    sub("frame=", "", frame)
    if (frame + 0 > last) last = frame + 0
  }
  END { print last + 0 }
' "$replay_path")
(( replay_frame_count >= max_frames )) || {
  print -u2 "回放日志过短：仅含 $replay_frame_count 帧，需至少 $max_frames 帧"
  exit 65
}

log_dir=$(mktemp -d /tmp/zigarcade-smb-regression.XXXXXX)
log_path="$log_dir/run.log"

zig build
env ROM_PATH="$rom_path" REPLAY_PATH="$replay_path" LOG_PATH="$log_path" MAX_FRAMES="$max_frames" \
  script -q /dev/null /bin/zsh -c \
  './zig-out/bin/zigarcade nes "$ROM_PATH" --renderer ansi --audio --max-frames "$MAX_FRAMES" --replay "$REPLAY_PATH" --log "$LOG_PATH"' \
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
if (( max_frames >= 10262 )); then
  /usr/bin/awk '
    /^frame=[0-9]+ player state=0b / { completed = 1 }
    completed && /^frame=[0-9]+ player state=06 / { transition = 1 }
    END { exit (completed && transition) ? 0 : 1 }
  ' "$log_path" || {
    print -u2 "SMB 回归未观察到第一关结束及过场状态: $log_dir"
    /usr/bin/tail -40 "$log_path" >&2
    exit 1
  }
fi
print "SMB 回归通过: $log_path"
