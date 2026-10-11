#!/bin/bash
# BG Buddy 설치 — 소스에서 직접 빌드하므로 코드 서명 문제가 없습니다.
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/Applications/BgBuddy"
BIN="$HOME/.local/bin"
APP="$DEST/BgBuddy.app"
AGENT="$HOME/Library/LaunchAgents/local.bgbuddy.plist"

command -v swiftc >/dev/null || {
  echo "swiftc 가 없습니다. Xcode Command Line Tools 를 먼저 설치하세요:"
  echo "  xcode-select --install"; exit 1; }

echo "==> 파일 설치: $DEST"
mkdir -p "$DEST/characters" "$BIN"
cp "$REPO/src/BgBuddy.swift" "$REPO/build.sh" "$DEST/"; chmod +x "$DEST/build.sh"
# 저장소의 캐릭터만 덮어쓴다. 직접 넣은 캐릭터 폴더는 건드리지 않는다.
cp -R "$REPO/characters/." "$DEST/characters/"
if [ ! -f "$DEST/config.json" ]; then
  cp "$REPO/config.example.json" "$DEST/config.json"
  # 로그인 시 뜨는 앱은 셸 환경변수를 못 받으므로 지금 값을 설정에 적어둔다
  if [ -n "$CLAUDE_CONFIG_DIR" ]; then
    /usr/bin/python3 - "$DEST/config.json" "$CLAUDE_CONFIG_DIR" <<'PY'
import json, sys
p, d = sys.argv[1], sys.argv[2]
c = json.load(open(p)); c["claude_dir"] = d
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False)
PY
    echo "    CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR 를 설정에 기록"
  fi
fi
cp "$REPO/bin/buddy" "$BIN/buddy"; chmod +x "$BIN/buddy"

echo "==> 빌드"
bash "$DEST/build.sh" "$DEST"

echo "==> 로그인 시 자동 실행 등록"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.bgbuddy</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/BgBuddy</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/local.bgbuddy" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || true

# 자동 실행 등록이 띄운 것까지 모두 끈 뒤, 완전히 꺼진 걸 확인하고 하나만 연다
pkill -f "MacOS/BgBuddy$" 2>/dev/null || true
for _ in $(seq 1 30); do pgrep -f "MacOS/BgBuddy$" >/dev/null || break; sleep 0.1; done
open "$APP"
echo
echo "설치 완료. 캐릭터가 화면 오른쪽 아래에 떠 있습니다."
echo "  buddy test     말풍선 시험"
echo "  buddy tasks    지금 도는 백그라운드 작업"
echo "  buddy doctor   감지가 되는지 점검"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "  ※ PATH 에 $BIN 을 추가해야 buddy 명령을 쓸 수 있습니다:"
     echo "     echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac
