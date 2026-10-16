# BG Buddy

Claude Code 가 백그라운드에서 작업을 돌리는 동안 화면 구석의 캐릭터가 움직이고,
작업이 끝나 결과가 돌아오면 말풍선으로 알려주는 macOS 플로팅 HUD.

```
        ╭──────────────────────╮
        │ 끝났어!               │
        │ Audit data services  │
        │ my-app · 2분 13초     │
        ╰─────────┬────────────╯
               (•ᴗ•)  ③        ← 도는 작업이 여럿이면 개수 배지
```

- 작업 중 — 캐릭터가 움직입니다
- 끝남 — 기뻐하는 동작과 말풍선 (실패하면 빨간 말풍선)
- 쉬는 중 — 잠든 모습 (숨기도록 설정할 수도 있음)

터미널 `claude`, 데스크톱 앱의 Code 탭, VS Code 확장 어디서 실행한 세션이든
**이 맥에서 도는 Claude Code 세션이면 모두** 잡힙니다.

## 설치

**필요한 것은 Xcode Command Line Tools 하나뿐입니다.** 없으면 먼저 설치하세요:

```bash
xcode-select --install
```

```bash
git clone <저장소 주소> bg-buddy
cd bg-buddy
./install.sh
```

스크립트가 하는 일:

1. `~/Applications/BgBuddy/` 에 소스와 캐릭터 복사
2. `swiftc` 로 그 자리에서 빌드 — 남이 서명한 바이너리를 받는 게 아니라
   내 맥에서 컴파일하므로 Gatekeeper 차단이 없습니다
3. `~/.local/bin/buddy` CLI 설치
4. 로그인 시 자동 실행 등록 (LaunchAgent)
5. 실행 — 캐릭터가 화면 **오른쪽 아래**에 뜹니다

Claude Code 설정은 건드리지 않습니다. 훅도 등록하지 않습니다.

동작 확인:

```bash
buddy doctor     # 세션·트랜스크립트·캐릭터 점검
buddy test       # 말풍선 시험
```

업데이트는 `git pull && ./install.sh`, 제거는 `./uninstall.sh` 입니다.
직접 넣은 캐릭터는 제거 전에 홈 폴더로 백업합니다.

## 조작

- **드래그** 이동 (위치 저장됨)
- **클릭** — 말풍선이 떠 있으면 닫기, 아니면 지금 도는 작업 보기
- **마우스 올리기** — 도는 작업 목록 툴팁
- **우클릭** — 캐릭터 보이기 · 작업 목록 · 캐릭터 · 크기 · 쉴 때 숨기기 · 메뉴 막대 아이콘 · 말풍선 테스트 · 종료

### 메뉴 막대 아이콘

화면 맨 위 메뉴 막대 오른쪽에 캐릭터 아이콘이 생깁니다. 클릭하면 우클릭 메뉴와 같은 메뉴가 열립니다.

- 작업이 돌면 아이콘 옆에 개수(`2`), 방금 끝났으면 잠깐 `✓`
- **캐릭터 보이기**를 끄면 캐릭터와 말풍선이 모두 사라지고, 끝난 작업은 메뉴 막대의 `✓` 로만 알립니다.
  다시 켰을 때 지난 알림이 몰려 뜨지 않습니다
- **쉴 때 숨기기**는 작업이 없을 때만 숨고, 작업이 돌거나 끝나면 나타납니다
- 캐릭터와 메뉴 막대 아이콘을 둘 다 끌 수는 없습니다 — 다시 켤 곳이 없어지므로 하나를 끄면 다른 하나가 켜집니다

캐릭터와 말풍선이 아닌 투명한 부분은 클릭이 아래 창으로 그대로 통과합니다.

## 명령

```
buddy                    캐릭터 띄우기
buddy tasks [--debug]    지금 도는 백그라운드 작업과 최근 끝난 작업
buddy doctor             감지·캐릭터 점검
buddy test [종류]        시험 (done | failed | many | working | extra)
buddy show | hide        캐릭터 켜기 / 끄기
buddy character [이름]   캐릭터 목록 / 바꾸기
buddy import 이미지 이름  스프라이트 시트를 캐릭터로 가져오기
buddy set 키 값          설정 바꾸기 (예: buddy set sound Glass)
buddy config | open      설정 파일 / 캐릭터 폴더 열기
buddy stop | restart | status | rebuild | login-on | login-off
```

## 설정

`~/Applications/BgBuddy/config.json` — `buddy set 키 값` 으로 바꾸면 바로 반영됩니다.

| 키 | 기본값 | 설명 |
|---|---|---|
| `character` | `"default"` | 쓸 캐릭터 폴더 이름 |
| `visible` | `true` | 캐릭터 보이기. 끄면 메뉴 막대에만 표시 |
| `menu_bar_icon` | `true` | 메뉴 막대 아이콘 |
| `size` | `1` | 캐릭터 기본 크기에 곱하는 배율 (메뉴의 작게 0.75 · 크게 1.5 · 아주 크게 2) |
| `scale` | `null` | 고급: 캐릭터의 `scale` 을 이 값으로 바꿔 씀. 보통은 `size` 를 쓰세요 |
| `bubble_seconds` | `15` | 말풍선 표시 시간. `0` 이면 클릭할 때까지 |
| `sound` | `null` | 끝날 때 낼 시스템 소리 이름 (`Glass`, `Pop`, `Hero` …) |
| `hide_when_idle` | `false` | 도는 작업이 없으면 캐릭터 숨기기 |
| `ignore_kinds` | `[]` | 무시할 작업 종류. 예: `["monitor"]` |
| `max_task_hours` | `12` | 이보다 오래 끝나지 않은 작업은 목록에서 뺌 |
| `claude_dir` | — | Claude 설정 폴더. 없으면 `CLAUDE_CONFIG_DIR`, 그다음 `~/.claude` |

## 캐릭터 바꾸기

캐릭터는 `~/Applications/BgBuddy/characters/<이름>/` 폴더 하나입니다:

```
characters/my-cat/
├── character.json
└── sheet.png        모든 프레임을 같은 크기 칸에 왼쪽→오른쪽, 위→아래로
```

```json
{
  "sheet": "sheet.png",
  "frameWidth": 32, "frameHeight": 24,
  "scale": 3,
  "pixelated": true,
  "animations": {
    "working": { "frames": [0, 1, 2, 3], "fps": 4, "bob": 2 },
    "done":    { "frames": [4, 5, 5, 4], "fps": 5, "loop": false },
    "idle":    { "frames": [6], "fps": 0.5, "bob": 1,
                 "every": [20, 60],
                 "extras": [ { "frames": [6, 0, 0, 0, 6], "fps": 3 } ] },
    "failed":  { "frames": [7], "fps": 1 }
  }
}
```

| 필드 | 설명 |
|---|---|
| `frames` | 프레임 번호 (0부터) |
| `fps` | 초당 프레임 |
| `loop` | 반복 여부. `done` 만 기본값이 `false` |
| `bob` | 프레임마다 통통 튀는 높이(pt). 그림이 거의 같은 프레임도 움직여 보입니다 |
| `extras` | 반복하는 동안 가끔 한 번씩 끼워 넣는 동작 목록. 각 항목은 `frames`·`fps`·`bob` |
| `every` | `extras` 를 몇 초에 한 번 할지 `[최소, 최대]`. 기본 `[20, 60]`, 그 사이 무작위 |
| `pixelated` | `true` 면 확대할 때 픽셀을 뭉개지 않음 |

없는 상태는 비슷한 것으로 대신합니다 (`failed` 가 없으면 `idle`).

`extras` 는 같은 동작만 반복하면 단조로워서 넣은 기능입니다 — 자다가 가끔 눈을 뜨거나
하품하는 식입니다. 상태가 바뀌면 하던 동작을 바로 끊습니다. `buddy test extra` 로
기다리지 않고 바로 볼 수 있습니다.

**캐릭터 하나에 시트 한 장**으로 관리하세요. 동작을 늘릴 때는 기존 프레임 번호를 그대로 두고
뒤에 붙이면 다른 애니메이션 설정을 고칠 필요가 없습니다. 이미지 생성 AI 로 늘릴 때는
추가 프레임만 따로 받지 말고, 기존 시트를 참고 이미지로 주고 전체를 한 장으로 다시 받는
편이 크기·선 굵기·색이 맞습니다.

### 이미지 생성 AI 로 만든 시트 가져오기

AI 가 준 시트는 흰 배경, 압축 번짐, 프레임마다 다른 크기가 흔합니다.
`buddy import` 가 정리해 줍니다:

```bash
buddy import ~/Downloads/sheet.png my-cat
buddy character my-cat
```

1. 테두리에서 이어진 배경색만 지웁니다 — 캐릭터 안쪽의 흰색은 남습니다
2. 떨어진 덩어리를 프레임으로 찾아 줄 순서로 세웁니다
3. 대표색 몇 개로 맞춰 번짐을 없앱니다
4. 격자가 깨끗한 픽셀아트면 원래 픽셀 크기로 되돌립니다. AI 가 그린 "픽셀아트"는
   칸 크기가 들쭉날쭉해서 억지로 맞추면 외곽선이 뭉개지므로, 그때는 원본 해상도를 유지합니다
5. 발바닥을 맞춰 같은 크기 칸에 담습니다

애니메이션 프레임 번호는 만들어진 `character.json` 에서 직접 고르세요.
격자 감지가 틀리면 `--pixel 8` 처럼 한 칸 크기를 직접 줄 수 있습니다.

시트를 요청할 때 이렇게 말하면 정리가 쉽습니다:

> 투명 배경 픽셀아트 스프라이트 시트, 같은 크기 칸 8개를 가로 한 줄로,
> 모든 칸에서 발바닥 위치는 같게. 1~4 걷기, 5~6 기뻐서 점프, 7 잠자기, 8 시무룩.

## 동작 방식

**Claude Code 의 공개되지 않은 내부 기록 형식을 읽습니다.** Claude Code 업데이트로
형식이 바뀌면 감지가 멈출 수 있습니다. 이상하면 `buddy doctor` 로 확인하세요.
확인한 버전: Claude Code 2.1.259 ~ 2.1.295.

1. `~/.claude/sessions/<pid>.json` — 실행 중인 세션 레지스트리. 살아 있는 pid 만 고릅니다
2. `~/.claude/projects/*/<세션 ID>.jsonl` — 세션 트랜스크립트. 1초마다 늘어난 부분만 읽습니다

| 시점 | 트랜스크립트에 남는 것 |
|---|---|
| 시작 | 도구 결과(`toolUseResult`)에 `backgroundTaskId`(Bash) · `isAsync`(Agent) · `taskId`(Monitor 등) |
| 끝 | `<task-notification>` 의 `<status>` — `completed` / `failed` |

시작할 때의 도구 호출 ID 와 알림의 `<tool-use-id>` 로 정확히 짝을 짓습니다.
알림은 큐에 들어갈 때와 대화에 전달될 때 여러 번 기록되는데, 가장 먼저 온 것을 씁니다 —
Claude 가 다른 일을 하느라 알림을 늦게 읽어도 말풍선은 결과가 도착한 순간 뜹니다.

- Monitor 의 중간 이벤트(`<event>`)는 끝난 것으로 보지 않습니다
- 사용자가 멈춘 작업(`TaskStop`)은 말풍선 없이 치웁니다
- 세션이 끝나면 남은 작업도 조용히 치웁니다
- 앱을 켤 때 과거 기록을 다시 읽지만, 이미 끝난 작업으로는 말풍선을 띄우지 않습니다

### 앱 끄기

`buddy stop`·`restart`·설치 스크립트는 이름 패턴으로 프로세스를 찾아 죽이지 않습니다.
앱이 켜질 때 `~/Applications/BgBuddy/.bgbuddy.pid` 에 자기 PID 를 남기고, 스크립트는

1. 그 PID 의 실행 파일이 정말 BgBuddy 인지 확인하고 (PID 가 다른 프로그램에 재사용됐을 수 있음)
2. 앱에 종료를 요청해 스스로 끝내게 하고
3. 3초 안에 안 끝날 때만 그 PID 하나에 종료 신호를 보냅니다

로그인 자동 실행으로 뜬 앱은 `launchctl` 이 라벨(`local.bgbuddy`)로 관리합니다.

### 잡히지 않는 것

- **클라우드 세션** (claude.ai/code 웹 등) — 원격에서 돌아 이 맥에 기록이 없습니다
- **다른 기기의 세션**
- **Codex 등 다른 도구**

## 개인정보

트랜스크립트에는 대화 내용이 그대로 들어 있습니다. BG Buddy 는 **읽기만 하고,
네트워크를 전혀 쓰지 않습니다.** 말풍선에는 작업 설명(도구 호출의 `description`)과
세션 이름만 표시합니다.

## 라이선스

코드는 MIT. 기본 캐릭터 이미지는 이미지 생성 AI(ChatGPT)로 만들었습니다.
