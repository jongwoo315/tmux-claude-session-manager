# tmux-claude-session-manager

[![screenshot](./docs/screenshot.jpg)](https://youtu.be/NnTV6r4l5D0)

Run many [Claude Code](https://claude.com/claude-code) sessions across your
projects, each in its own tmux session — then **list them, see which are done
vs. still working, and jump to one** from a single popup.

If you launch Claude per-directory (one nested session per project), you quickly
end up with a dozen of them and no way to tell which are finished without opening
each one. This plugin gives you:

- 🔢 **A central picker** (`prefix` + `u`) listing every running Claude session.
- 🟢 **Live status** per session — `working` / `waiting` / `bg` / `idle` — driven by
  Claude Code hooks, so you instantly see which need you.
- 👁️ **A live preview** of each session's screen right in the picker.
- 🎯 **Smart jump** — selecting a session switches your client to the window it
  was launched from, then resumes it in a popup over it.
- 🚀 **A launcher** (`prefix` + `y`) that opens/attaches a Claude session for the
  current directory.
- ❌ **Quick kill** (`ctrl-x`) of finished sessions from the picker.

Status is optional: without the hooks the picker still lists, previews, jumps,
and kills — sessions just show `?` instead of a color.

## Prerequisites

- **tmux ≥ 3.2** (for `display-popup`)
- **[fzf](https://github.com/junegunn/fzf)** — the picker UI
- **[Claude Code](https://claude.com/claude-code)** CLI (the `claude` command)
- bash; macOS or Linux
- `node` — only for the optional [web graph](#web-graph-optional); the tmux plugin itself does not need it

## Install (tpm)

Add to `~/.tmux.conf` (or `~/.config/tmux/tmux.conf`):

```tmux
set -g @plugin 'craftzdog/tmux-claude-session-manager'
```

Then hit `prefix` + <kbd>I</kbd> to install.

> **Keybinding note:** by default the plugin binds `prefix` + `y` (launch) and
> `prefix` + `u` (list). If your config binds those elsewhere, either change the
> options below, or make sure the plugin loads **after** your own bindings (put
> `run '~/.tmux/plugins/tpm/tpm'` _after_ them) so the one you want wins.

### Manual install

```sh
git clone https://github.com/craftzdog/tmux-claude-session-manager ~/clone/path
```

Add to `~/.tmux.conf`, then reload (`prefix` + <kbd>r</kbd> or `tmux source ~/.tmux.conf`):

```tmux
run-shell ~/clone/path/claude_session_manager.tmux
```

## Usage

| Key            | Action                                                                          |
| -------------- | ------------------------------------------------------------------------------- |
| `prefix` + `y` | Launch (or re-attach to) a Claude session for the current directory, in a popup |
| `prefix` + `Y` | Launch a **new** session for the current directory, alongside any existing one  |
| `prefix` + `R` | Resume a past conversation in a new picker-tracked session                      |
| `prefix` + `F` | Fork a past conversation into a new session (fresh ID, original untouched)      |
| `prefix` + `u` | Open the session picker                                                         |
| `prefix` + `b` | Jump straight back to the last attached session, skipping the picker            |

`Y`, `R` and `F` all create a session named `claude-<hash>[-N]`, so every one of
them shows up in the picker. They differ only in what Claude is told to do on
attach: start clean, resume in place, or fork.

`R` and `F` run `claude --resume` with no session ID, so Claude's own transcript
picker opens on first attach and you choose the conversation there.

> **Note:** `Y`, `R` and `F` refuse to run from inside a `claude-*` session —
> sessions attach as popups, and popups cannot nest. Press `prefix` + `u` first
> (which closes the popup and reopens the picker on the outer client), or detach,
> then launch.

Inside the picker:

| Key                       | Action                                                                    |
| ------------------------- | ------------------------------------------------------------------------- |
| `enter`                   | Jump to the session (switches to its origin window, resumes in the popup) |
| `ctrl-x`                  | Kill the highlighted session                                              |
| `↑` / `↓`, type to filter | fzf navigation                                                            |

Sessions needing your attention (`waiting`, `idle`) sort to the top, then `bg`,
then `working` — the ones to leave alone sit at the bottom.

## Status setup (optional, recommended)

Status comes from [Claude Code hooks](https://code.claude.com/docs/en/hooks)
that stamp each session's state onto its tmux session. Add the following to your
Claude Code settings (`~/.claude/settings.json`), merging into any existing
`hooks` block. Adjust the path if your plugins live elsewhere (e.g.
`~/.tmux/plugins/...`):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.config/tmux/plugins/tmux-claude-session-manager/scripts/state.sh working"
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.config/tmux/plugins/tmux-claude-session-manager/scripts/state.sh waiting"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.config/tmux/plugins/tmux-claude-session-manager/scripts/state.sh waiting"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.config/tmux/plugins/tmux-claude-session-manager/scripts/state.sh idle"
          }
        ]
      }
    ]
  }
}
```

The state machine:

| Event                                | State        | Meaning                       |
| ------------------------------------ | ------------ | ----------------------------- |
| `UserPromptSubmit`                   | 🔴 `working` | Busy — leave it               |
| `Notification` (permission)          | 🟡 `waiting` | Needs permission              |
| `PreToolUse` (`AskUserQuestion`)     | 🟡 `waiting` | Asking you a question         |
| `Stop`, background tasks still running | 🔵 `bg`    | Answered you; a shell or agent is still out |
| `Stop`, nothing left running         | 🟢 `idle`    | Turn finished — your move     |

`bg` is a picker-only label. The underlying `@claude_state` stays `working`, because
external automation polls that option for "is this session done yet" and only knows
`working`/`waiting`/`idle` — reporting `idle` while background work continues would
let it close a task mid-flight. The picker tells the two apart with a second option,
`@claude_bg`.

That option exists because the picker cross-checks a `working` row against tmux's
`#{window_activity}`: an ESC-interrupt fires no hook at all, so `working` would
otherwise stick forever, and a truly busy session repaints about once a second. A
session parked on background work stops repainting too, so the clock alone cannot
separate them — it read those rows as `idle` and flapped them back to `working` on
every stray repaint, reshuffling the list under `j`/`k`. `@claude_bg` answers it with
the fact instead of a guess.

> Claude Code reloads `hooks` dynamically — no restart needed. Sessions that are
> already running start reporting status on their next event once the hooks are
> added.

## Web graph (optional)

Live node-edge graph of the running claude sessions in a browser. Requires `node`
(no npm install — zero dependencies).

```bash
node ~/.tmux/plugins/tmux-claude-session-manager/scripts/web-server.js   # then open http://localhost:7878
node .../web-server.js 9000    # or PORT=9000 — first arg wins
```

Nothing starts this for you. `git pull` installs the files; the plugin does not
launch a server, so a fresh checkout serves nothing on 7878 until you run it.

Binds `127.0.0.1` and `::1` only. The payload carries session titles and working
directory paths, so it is deliberately not reachable from the LAN.

### Run it at login (macOS LaunchAgent)

Survives reboots and restarts on crash. Write
`~/Library/LaunchAgents/local.claude-session-graph.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.claude-session-graph</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>exec node "$HOME/.tmux/plugins/tmux-claude-session-manager/scripts/web-server.js"</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>/tmp/claude-session-graph.log</string>
  <key>StandardErrorPath</key><string>/tmp/claude-session-graph.log</string>
</dict>
</plist>
```

```bash
plutil -lint ~/Library/LaunchAgents/local.claude-session-graph.plist   # catch typos first
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.claude-session-graph.plist
launchctl list | grep claude-session-graph    # 2nd column is the last exit code
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:7878/
```

Managing it:

```bash
launchctl kickstart -k gui/$(id -u)/local.claude-session-graph   # restart (do this after a git pull)
launchctl bootout   gui/$(id -u)/local.claude-session-graph      # stop + unregister
```

**Why `/bin/zsh -lc` and not `node` directly.** The server shells out to bare
`tmux`, and Homebrew installs it outside launchd's minimal PATH
(`/usr/bin:/bin:/usr/sbin:/sbin`). Run node directly and `tmux list-sessions`
finds nothing — the server answers 200 and streams an **empty graph**, so it
looks healthy while showing no sessions. A login shell loads the real PATH.
`exec` then replaces zsh with node so `KeepAlive` supervises the server rather
than the wrapper shell. Leaving `node` unqualified (rather than
`/opt/homebrew/bin/node`) keeps the same plist working on Intel Macs, where
Homebrew lives in `/usr/local/bin`.

**A `git pull` does not restart it.** New server code needs
`launchctl kickstart -k`, otherwise the old code keeps running.

## Options

Set any of these before the plugin loads (defaults shown):

```tmux
set -g @claude_launch_key     'y'        # prefix key: launch/open for current dir
set -g @claude_new_key        'Y'        # prefix key: launch an additional session
set -g @claude_resume_key     'R'        # prefix key: resume a past conversation
set -g @claude_fork_key       'F'        # prefix key: fork a past conversation
set -g @claude_list_key       'u'        # prefix key: open the picker
set -g @claude_last_key       'b'        # prefix key: jump back to last session
set -g @claude_command        'claude'   # command run in new sessions
set -g @claude_args           ''         # extra args appended to the command
set -g @claude_session_prefix 'claude-'  # tmux session name prefix
set -g @claude_popup_width     '90%'     # popup width
set -g @claude_popup_height    '90%'     # popup height

# Full command lines for the resume and fork keys. Unlike @claude_command these
# are used verbatim, so @claude_args is not appended — put every flag here.
set -g @claude_resume_command 'claude --resume --dangerously-skip-permissions'
set -g @claude_fork_command   'claude --resume --fork-session --dangerously-skip-permissions'

set -g @claude_fzf_options    ''         # extra flags passed to fzf in the picker
```

For example, to skip permission prompts in launched sessions:

```tmux
set -g @claude_args '--dangerously-skip-permissions'
```

## How it works

- The **launcher** creates a detached `claude-<hash-of-dir>` tmux session running
  `claude`, records the window it came from in `@claude_origin`, and attaches to
  it in a popup.
- The **new / resume / fork** keys take the same path, appending `-2`, `-3` … to
  the name when that directory already has a session. Each sets a default
  `@claude_title` (`<dir>#N`, `<dir>#N~resume`, `<dir>#N~fork`) so same-directory
  sessions stay distinguishable in the picker; `/rename` in-session overrides it.
- The **hooks** set `@claude_state` / `@claude_state_at` on each session as Claude
  works.
- The **picker** lists sessions matching the prefix, reads their state and a live
  `capture-pane` preview, and on selection moves your client to the session's
  origin window before resuming it in the popup.
- Pressing `prefix` + `u` **from inside a session popup** detaches that popup
  first (closing it), then reopens the picker full-size on the outer host client —
  so you never end up with a cramped popup-in-popup.

## License

[MIT](LICENSE) © Takuya Matsuyama
