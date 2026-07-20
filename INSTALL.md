# INSTALL — jongwoo315 fork

이 fork는 [craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager) 기반 개인 패치 버전.

> **Source of truth:** 상세 셋업/트러블슈팅 기록은 Notion 참고 →
> https://www.notion.so/jongwoo315/tmux-claude-session-manager-38f41e6165c08000a138ea332a6d5521
> 이 문서는 코드 재현에 필요한 **외부 설정(dotfiles) 스냅샷**만 담는다.
> 실제 dotfile은 이 repo가 아니라 각 머신 + Notion에서 관리.

## 플러그인 설치 (TPM)

`~/.tmux.conf`:

```tmux
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'jongwoo315/tmux-claude-session-manager'   # 이 fork
run '~/.tmux/plugins/tpm/tpm'   # 반드시 마지막 줄
```

`prefix + I` 로 설치.

## 필요한 외부 설정 (fork 코드가 의존)

### 1. `~/.tmux.conf` — cursor + @claude_command

```tmux
# iterm2 cursor style
set -ga terminal-overrides ',xterm-256color:Ss=\E[%p1%d q:Se=\E[2 q'
# nested tmux client (popup) 로 cursor-shape forward
set -ga terminal-overrides ',tmux-256color:Ss=\E[%p1%d q:Se=\E[2 q'

# 세션 시작 시 blinking-bar cursor. session-manager는 interactive shell 없이
# claude 직접 실행 → zsh precmd cursor fix 안 돌아서 여기서 지정. exec로 claude가 pane PID 1 유지.
set -g @claude_command        "printf '\033[5 q'; exec claude --dangerously-skip-permissions"
set -g @claude_resume_command "printf '\033[5 q'; exec claude --resume --dangerously-skip-permissions"
set -g @claude_fork_command   "printf '\033[5 q'; exec claude --resume --fork-session --dangerously-skip-permissions"
```

### 2. `~/.zshrc` — prompt마다 bar cursor 복원

```zsh
# TUI 앱(yazi 등)이 block cursor로 바꾸고 복원 안 함. oh-my-zsh precmd와 공존하도록
# bare precmd() 대신 precmd_functions 에 append.
_reset_cursor_bar() { printf '\e[5 q'; }
precmd_functions+=(_reset_cursor_bar)
```

### 3. `~/.claude/settings.json` — 상태 훅 (picker 색상)

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [ { "type": "command",
        "command": "$HOME/.tmux/plugins/tmux-claude-session-manager/scripts/state.sh working" } ] }
    ],
    "Notification": [
      { "matcher": "permission_prompt", "hooks": [ { "type": "command",
        "command": "$HOME/.tmux/plugins/tmux-claude-session-manager/scripts/state.sh waiting" } ] }
    ],
    "PreToolUse": [
      { "matcher": "AskUserQuestion", "hooks": [ { "type": "command",
        "command": "$HOME/.tmux/plugins/tmux-claude-session-manager/scripts/state.sh waiting" } ] }
    ],
    "PostToolUse": [
      { "hooks": [ { "type": "command",
        "command": "$HOME/.tmux/plugins/tmux-claude-session-manager/scripts/state.sh working" } ] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [ { "type": "command",
        "command": "$HOME/.tmux/plugins/tmux-claude-session-manager/scripts/state.sh idle" } ] }
    ]
  }
}
```

상태 머신: `UserPromptSubmit`=working, `Notification`(permission)=waiting, `PreToolUse`(AskUserQuestion)=waiting, `PostToolUse`(matcher 없음 = 모든 tool 완료)=working, `Stop`=idle.

> **PostToolUse=working 이유:** AskUserQuestion 응답/취소는 `UserPromptSubmit`을 안 켜서 `waiting`에 머묾. tool 완료 시마다 working으로 flip해 해소. matcher 생략 = 모든 tool 대상.

## 키바인드 (fork 추가분)

| Key | Action |
| --- | --- |
| `prefix + y` | 현재 dir Claude 세션 launch |
| `prefix + Y` | 같은 dir 추가 세션 launch |
| `prefix + u` | 세션 목록 (picker) |
| `prefix + R` | picker 추적 `claude --resume` 세션 |
| `prefix + F` | 현재 세션에서 fork |
| picker `ctrl-r` | rename / `ctrl-x` kill |

## 적용 (편집 후)

```sh
chmod +x scripts/{launch-new,resume-new,fork-new,rename}.sh
bash ~/.tmux/plugins/tmux-claude-session-manager/claude_session_manager.tmux
# .tmux 파일은 bash 실행파일. tmux source-file 하지 말 것 (invalid environment variable 에러)
```

## Upstream 동기화 (craftzdog 최신 반영)

```sh
git fetch upstream
git rebase upstream/main          # 패치가 upstream 위로 replay
# 충돌 해결 후:
git push --force-with-lease origin main
```

- 신규 파일(`*-new.sh`, `rename.sh`)은 additive → 충돌 없음.
- `picker.sh` / `launch.sh` / `.tmux` 편집만 충돌 가능 → 최소·국소 유지.

> ⚠️ **blind `git rebase upstream/main` 금지.** 아래 `afa093b`가 딸려와 `state.sh`를
> 삭제 → waiting-badge + 상태 훅 전부 깨짐. 안전 커밋만 **cherry-pick** 하거나,
> rebase 중 `afa093b`를 반드시 drop 할 것.

### Upstream 커밋 검토 기록 (2026-07-20 기준, `54403a3`)

이 시점 fork는 upstream보다 9 commits behind. 각 upstream 커밋 판정:

| 커밋 | 내용 | 판정 |
| --- | --- | --- |
| `afa093b` | 상태를 `claude agents --json`로 전환, **`state.sh` 삭제** | ❌ **절대 병합 금지** — badge/훅 전멸 |
| `6e65e9c` | 키바인드 `#{q:}` shell-quote (커맨드 인젝션) | ✅ **반영 완료** (`54403a3`, fork 신규 바인드까지 확대) |
| `5a0821a` | README url 수정 | ✅ 무해 (원하면 반영) |
| `45d593f` | picker 팝업을 invoking client로 scope | ⏭️ 스킵 — fork가 이미 해결(`4620415`,`16e3751`) |
| `da665cd` | 오버레이 파괴 후 picker 재오픈 | ⏭️ 스킵 — fork popup 처리와 중복/충돌 |
| `6b4e73b` | preview를 list 위로 stack | ⏭️ 스킵 — fork가 이미 preview 잘림 해결(`ff97ced`) |
| `59bc4fa` `a29d32d` | `@claude_fzf_options` / `CLAUDE_PICKER` export | 🟡 additive — 원하면 `picker.sh`에 수동 포팅 |

**핵심:** upstream은 훅 기반 상태(`state.sh`)를 버리고 `claude agents --json`로 갈아탐.
이 fork는 훅 기반을 유지하므로 상태 관련 커밋(`afa093b`)은 영구 divergence.
