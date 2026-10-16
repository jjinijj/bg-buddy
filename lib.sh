# install.sh · uninstall.sh · buddy 가 함께 쓰는 프로세스 도구.
# 패턴 매칭(pkill/pgrep)을 쓰지 않는다. 앱이 남긴 PID 파일의 번호가 정말 이 앱의
# 실행 파일인지 확인한 뒤 그 번호에만 신호를 보낸다.
BB_DIR="$HOME/Applications/BgBuddy"
BB_APP="$BB_DIR/BgBuddy.app"
BB_EXE="$BB_APP/Contents/MacOS/BgBuddy"
BB_PIDFILE="$BB_DIR/.bgbuddy.pid"

# 실행 중이면 PID 를 출력한다. PID 가 재사용돼 다른 프로그램을 가리키면 실패로 본다.
bb_pid() {
  local p
  [ -f "$BB_PIDFILE" ] || return 1
  p=$(tr -dc '0-9' < "$BB_PIDFILE")
  [ -n "$p" ] || return 1
  [ "$(ps -p "$p" -o command= 2>/dev/null)" = "$BB_EXE" ] || return 1
  echo "$p"
}

bb_running() { bb_pid >/dev/null; }

# 앱에 종료를 요청하고 끝날 때까지 기다린다. 3초 안에 안 끝나면 확인한 그 PID 만 TERM.
bb_stop() {
  local p
  p=$(bb_pid) || return 0
  [ -x "$BB_EXE" ] && "$BB_EXE" --quit >/dev/null 2>&1
  for _ in $(seq 1 30); do kill -0 "$p" 2>/dev/null || return 0; sleep 0.1; done
  [ "$(ps -p "$p" -o command= 2>/dev/null)" = "$BB_EXE" ] && kill "$p"
  for _ in $(seq 1 20); do kill -0 "$p" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

# 실행 중이 아니면 연다. 이미 떠 있으면 그대로 둔다.
bb_start() {
  bb_running && return 0
  open "$BB_APP"
  for _ in $(seq 1 30); do bb_running && return 0; sleep 0.1; done
  return 1
}
