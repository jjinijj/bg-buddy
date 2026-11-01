#!/bin/bash
# 푸시 전 안전 점검. 하나라도 걸리면 0 이 아닌 값으로 끝난다.
# 사용: ./tools/preflight.sh   (또는 git pre-push 훅으로 자동 실행)
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
SKIPPED=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=1; }
# 돌지 못한 검사. 통과로 세지 않는다 — 조용히 넘어가는 것이 가장 위험하다.
skip() { printf "  \033[33m⊘\033[0m %s\n" "$1"; SKIPPED=1; }
note() { printf "  \033[36m·\033[0m %s\n" "$1"; }

SECRETS='sk-ant-[A-Za-z0-9_-]{20}|sk-[A-Za-z0-9]{32}|gh[pousr]_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|xox[baprs]-[A-Za-z0-9-]{10}'
# 숨길 개인 단어(이메일·계정 이름·개인 프로젝트 이름 등)는 저장소에 적지 않는다.
# 적으면 그 줄 자체가 유출이다. 목록은 저장소 밖 파일에서 읽고, 대소문자는 구분하지 않는다.
PRIVFILE="${BGBUDDY_PRIVATE_PATTERNS:-$HOME/.config/bg-buddy/private-patterns}"
PRIVATE=''
PRIVN=0
if [ -f "$PRIVFILE" ]; then
  PRIVATE=$(grep -vE '^[[:space:]]*(#|$)' "$PRIVFILE" | paste -sd'|' -)
  PRIVN=$(grep -cvE '^[[:space:]]*(#|$)' "$PRIVFILE")
fi
# 경로 패턴은 개인 정보가 아니므로 여기 남겨둔다.
PATHPAT='/Users/[a-z]'

echo "== 1. 커밋될 파일 내용"
# git cat-file --batch 는 객체 목록을 표준입력으로 받는다. xargs 로 인자로 넘기면 실패하고,
# 2>/dev/null 이 그 실패를 삼켜 빈 내용을 검사하게 된다 (예전 점검이 그래서 0바이트를 검사하며 늘 통과했다).
# 결과를 변수에 담지도 않는다 — $(...) 에 바이너리(PNG 등)가 섞이면 중간에서 잘린다.
# 검사 범위: 지금 추적되는 파일 + 아직 원격에 없는 커밋이 새로 넣은 blob.
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
candidate_oids() {
  git ls-files -s | awk '{print $2}'
  [ -n "$UPSTREAM" ] && git rev-list "$UPSTREAM..HEAD" --objects 2>/dev/null | awk 'NF>1{print $1}'
}
BLOBINFO=$(candidate_oids | sort -u \
  | git cat-file --batch-check='%(objectname) %(objecttype) %(objectsize)' 2>/dev/null \
  | awk '$2=="blob"{print $1" "$3}')
BLOBN=$(printf '%s\n' "$BLOBINFO" | grep -c '^[0-9a-f]')
EXPECT=$(printf '%s\n' "$BLOBINFO" | awk '{s+=$2} END{print s+0}')
blob_body() { printf '%s\n' "$BLOBINFO" | awk '{print $1}' | git cat-file --batch 2>/dev/null; }
READBYTES=$(blob_body | wc -c | tr -d ' ')

# 검사가 내용을 실제로 읽었는지 먼저 확인한다. cat-file 출력은 객체마다 헤더가 붙으므로
# 읽은 바이트는 blob 크기 합계보다 커야 정상이다. 모자라면 검사가 깨진 것이다.
if [ "$BLOBN" -eq 0 ] || [ "$EXPECT" -eq 0 ] || [ "$READBYTES" -lt "$EXPECT" ]; then
  bad "내용 검사가 깨졌습니다 — blob $BLOBN 개, 기대 $EXPECT 바이트, 실제 읽음 $READBYTES 바이트"
else
  SCOPE="추적 파일"
  [ -n "$UPSTREAM" ] && SCOPE="$SCOPE + $UPSTREAM..HEAD 의 새 blob"
  ok "내용 $READBYTES 바이트 읽음 (blob $BLOBN 개, $SCOPE)"
  [ "$(blob_body | LC_ALL=C grep -acE "$SECRETS")" = 0 ] \
    && ok "자격증명·토큰 패턴 없음" || bad "자격증명 패턴 발견"
  [ "$(blob_body | LC_ALL=C grep -acE "$PATHPAT")" = 0 ] \
    && ok "개인 절대경로 없음" || bad "절대경로 발견"
  if [ -n "$PRIVATE" ]; then
    [ "$(blob_body | LC_ALL=C grep -aciE "$PRIVATE")" = 0 ] \
      && ok "개인 단어 없음 (패턴 $PRIVN 개)" \
      || { bad "개인 단어 발견:"; git grep -n -i -I -E "$PRIVATE" | cut -c1-140 | sed 's/^/      /'; }
  else
    skip "개인 단어 검사 건너뜀 — $PRIVFILE 가 없습니다"
  fi
fi

echo "== 2. 커밋 메타데이터"
# 허용: 개인 noreply(...@users.noreply.github.com) 와 GitHub 웹 커밋의 커미터(noreply@github.com)
REAL=$(git log --all --pretty=format:'%ae%n%ce' \
  | grep -vE 'users\.noreply\.github\.com$|^noreply@github\.com$' | sort -u)
[ -z "$REAL" ] && ok "모든 커밋이 noreply 주소" \
  || { bad "실제 이메일이 커밋에 남아 있음:"; echo "$REAL" | sed 's/^/      /'; }
MSGPAT="$SECRETS|$PATHPAT"
[ -n "$PRIVATE" ] && MSGPAT="$MSGPAT|$PRIVATE"
[ "$(git log --all --pretty=format:'%s%n%b' | grep -ciE "$MSGPAT")" = 0 ] \
  && ok "커밋 메시지 깨끗" || bad "커밋 메시지에 민감 정보"
# 이 저장소는 커밋에 Claude 공동작성자 표시를 넣지 않는다
[ "$(git log --all --pretty=%B | grep -ci 'co-authored-by')" = 0 ] \
  && ok "공동작성자 표시 없음" || bad "Co-Authored-By 가 커밋에 있음"

echo "== 3. 코드 동작"
SCAN="src bin tools build.sh install.sh uninstall.sh lib.sh"
NETPAT="URLSession|URLRequest|dataTask|NWConnection|urllib|requests\.|curl |wget "
CREDPAT="keychain|security find|\.credentials|auth\.json|access_?token|refresh_?token"
# 이 파일 자신은 패턴을 정의하므로 뺀다
NET=$(grep -rniE "$NETPAT|$CREDPAT" $SCAN 2>/dev/null | grep -v DOCTYPE | grep -v '^tools/preflight.sh:' | wc -l | tr -d ' ')
[ "$NET" = 0 ] && ok "외부 통신·자격증명 접근 코드 없음" \
  || { bad "통신·자격증명 접근 발견 ($NET 건):"; grep -rniE "$NETPAT|$CREDPAT" $SCAN | grep -v DOCTYPE | grep -v '^tools/preflight.sh:' | sed 's/^/      /'; }

echo "== 4. 프로세스 종료"
# 이름 패턴으로 프로세스를 찾아 죽이지 않는다. 앱은 PID 파일(lib.sh 의 bb_stop)로만 끈다
KILLS=$(grep -nE '^[^#]*(pkill|pgrep|killall)' install.sh uninstall.sh bin/buddy lib.sh build.sh 2>/dev/null | wc -l | tr -d ' ')
[ "$KILLS" = 0 ] && ok "패턴 종료(pkill·pgrep·killall) 없음" \
  || { bad "패턴 종료 발견:"; grep -nE '^[^#]*(pkill|pgrep|killall)' install.sh uninstall.sh bin/buddy lib.sh build.sh | sed 's/^/      /'; }
grep -q 'bb_pid()' lib.sh && grep -q 'command=' lib.sh && ok "PID 로 끄기 전 실행 파일 확인" || bad "lib.sh 의 PID 확인이 사라졌습니다"

echo "== 5. 추적 파일"
ALLOWED='^(\.gitignore|\.githooks/.*|LICENSE|README\.md|config\.example\.json|install\.sh|uninstall\.sh|build\.sh|lib\.sh|bin/buddy|src/.*|tools/.*|assets/(AppIcon\.icns|screenshot-[a-z-]+\.png)|characters/(default|office)/.*)$'
UNEXPECTED=$(git ls-files | grep -vE "$ALLOWED" | wc -l | tr -d ' ')
[ "$UNEXPECTED" = 0 ] && ok "예상 밖 파일 없음" || { bad "예상 밖 파일:"; git ls-files | grep -vE "$ALLOWED" | sed 's/^/      /'; }
# 팀 캐릭터는 팀 자산이라 저장소에 한 번도 들어간 적이 없어야 한다 (전체 기록)
[ "$(git log --all --name-only --pretty=format: | grep -c '^characters/team')" = 0 ] \
  && ok "팀 캐릭터가 기록에 없음" || bad "characters/team 이 기록에 있음"
[ "$(git ls-files | grep -cE '\.app/|config\.json$|\.bgbuddy\.pid')" = 0 ] \
  && ok "빌드 산출물·개인 설정 미포함" || bad "빌드 산출물이나 개인 설정이 추적되고 있음"

echo "== 6. 사람이 볼 것"
# 패턴 검사는 그림 내용을 못 본다. 올라갈 이미지는 미리보기로 직접 확인한다
IMGS=$([ -n "$UPSTREAM" ] && git diff --name-only "$UPSTREAM..HEAD" | grep -iE '\.(png|jpe?g|webp|gif|icns)$')
if [ -n "$IMGS" ]; then
  note "올라갈 이미지 — 글자·개인 정보가 그려져 있지 않은지 미리보기로 확인할 것:"
  echo "$IMGS" | sed 's/^/      /'
else
  ok "올라갈 새 이미지 없음"
fi

echo
if [ "$FAIL" != 0 ]; then
  echo "점검 실패 — 위 항목을 먼저 해결하세요."
elif [ "$SKIPPED" != 0 ]; then
  echo "점검 통과 — 단, ⊘ 로 표시된 검사는 돌지 않았습니다."
else
  echo "모든 점검 통과 — 푸시해도 안전합니다."
fi
exit $FAIL
