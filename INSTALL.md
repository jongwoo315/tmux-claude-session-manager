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
    "Stop": [
      { "matcher": "", "hooks": [ { "type": "command",
        "command": "$HOME/.tmux/plugins/tmux-claude-session-manager/scripts/state.sh idle" } ] }
    ]
  }
}
```

상태 머신: `UserPromptSubmit`=working, `Notification`(permission)=waiting, `PreToolUse`(AskUserQuestion)=waiting, `Stop`=idle.

> **미해결 이슈:** AskUserQuestion 60s 타임아웃 취소 후 재프롬프트 시 상태가 `waiting`에 머무는 케이스 있음. 원인 미확정 (Notion 참고).

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
