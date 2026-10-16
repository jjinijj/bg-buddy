#!/bin/bash
# BG Buddy 제거 — Claude 대화 기록이나 설정은 건드리지 않습니다.
set -e
DEST="$HOME/Applications/BgBuddy"
. "$DEST/lib.sh" 2>/dev/null || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
launchctl bootout "gui/$(id -u)/local.bgbuddy" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.bgbuddy.plist"
bb_stop || true
# 직접 넣은 캐릭터가 있으면 지우기 전에 알린다
EXTRA=$(ls "$DEST/characters" 2>/dev/null | grep -vx default || true)
if [ -n "$EXTRA" ]; then
  BACKUP="$HOME/BgBuddy-characters-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$BACKUP"
  for c in $EXTRA; do cp -R "$DEST/characters/$c" "$BACKUP/"; done
  echo "직접 넣은 캐릭터를 $BACKUP 에 백업했습니다."
fi
rm -rf "$DEST"
rm -f "$HOME/.local/bin/buddy"
defaults delete local.bgbuddy 2>/dev/null || true
echo "제거 완료."
