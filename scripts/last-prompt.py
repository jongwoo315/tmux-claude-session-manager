#!/usr/bin/env python3
"""Last thing the user typed in each session id given on argv, as "<sid>\t<text>".

Arguments are "<sid>" or "<sid>:<cutoff>", cutoff being an epoch second past which
a prompt is not this pane's. A transcript belongs to a CONVERSATION, not to a tmux
pane, and `claude --resume` on the same conversation from a second window appends
its turns to the same file under the same sessionId — no field in the record says
which process wrote it, and the second process's sessions/<pid>.json is removed
when it exits, so after the fact the timestamps are the only surviving evidence.
The caller passes a cutoff only for a pane sitting `idle`, where its own last turn
has already ended and nothing newer can legitimately be its own. Measured across 8
live sessions: seven had their newest prompt 0-99 min BEFORE the pane's last state
stamp, and the one that had been resumed elsewhere was 287 min after it.

Called once per picker title-cache rebuild with every session id at once. One
interpreter start amortised over the whole list is the point: doing this in the
shell costs a `tail` plus a parser per session, and transcripts run to 86MB so
the file cannot simply be read.

The record test matches web-server.js. Five things count as the user speaking:

  * a prompt — type "user", not a sidechain (subagent) turn, string content, and
    a promptSource of typed/queued/suggestion_accepted/sdk. `sdk` is the launch
    prompt of a headless session (orch ralph loops, cron jobs); it is the only
    thing those sessions are ever asked, so without it they show no prompt at
    all. `system` is excluded — those are <task-notification> blocks, not words
    anyone wrote.
  * a `!` shell command — same but promptSource is null and the content is
    wrapped in <bash-input>. Reported with a leading "! ".
  * a prompt with an attached image — content is a list holding an `image` block.
    The text the user typed sits in sibling `text` blocks with the image's own
    `[Image #N]` placeholder already inlined, so joining them reproduces what the
    TUI shows. An image dropped with nothing typed leaves no text block at all;
    that gets a synthesised `[image]`.
  * an AskUserQuestion answer — a tool_result whose toolUseResult carries the
    picks. See from_answers.
  * a prompt typed while Claude was busy — an `attachment` record, never re-emitted
    as a `user` one. See from_queued.

Everything else that arrives as type "user" is machinery: tool results (also list
content — told apart by the `tool_result` block), system-reminders, slash-command
expansions, task notifications. In one 17-session sample those were 1440 of 1633
user records, which is what the filter is really for.

`!` was excluded at first on the theory that a stray `! ls` would bury the last
real instruction. Measured across the live list, exactly one session of 17 had a
`!` as its newest input — and it was `arp -n … && curl -sS …`, which said more
about what that session was doing than its last prose prompt did.
"""
import calendar
import glob
import json
import os
import sys
import time

SRC = {'typed', 'queued', 'suggestion_accepted', 'sdk'}
BANG_OPEN = '<bash-input>'
BANG_CLOSE = '</bash-input>'
# Escalating tail windows. 256KB covers a session typed in recently; a long
# autonomous stretch buries the prompt under tool traffic, so grow rather than
# report nothing. 4MB is the giving-up point.
STEPS = (256 * 1024, 1024 * 1024, 4 * 1024 * 1024)
MAX = 400


def index_transcripts():
    base = os.path.join(os.path.expanduser('~'), '.claude', 'projects')
    found = {}
    for p in glob.glob(os.path.join(base, '*', '*.jsonl')):
        found.setdefault(os.path.basename(p)[:-6], p)
    return found


def from_blocks(content):
    """What the user typed in a list-content record, or '' if it wasn't them.

    Only an image attachment puts a user's own words in a list; a `tool_result`
    block means machinery. Bare `text` lists are slash-command expansions and
    system-reminders, so an image block is what makes the record a prompt.
    """
    kinds = set()
    texts = []
    images = 0
    for b in content:
        if not isinstance(b, dict):
            continue
        kind = b.get('type')
        kinds.add(kind)
        if kind == 'text':
            t = b.get('text')
            if isinstance(t, str) and t.strip():
                texts.append(' '.join(t.split()))
        elif kind == 'image':
            images += 1
    if images == 0 or 'tool_result' in kinds:
        return ''
    if texts:
        return ' '.join(texts)[:MAX]
    return '[image]' if images == 1 else '[image x%d]' % images


def from_answers(rec):
    """What the user picked in an AskUserQuestion box, or ''.

    The answer arrives as a tool_result, so it looks like machinery, but it is the
    user speaking — and a session driven by question boxes has no typed prompt for
    as long as that lasts, which left the row advertising something hours stale.
    toolUseResult carries the picks structured (answers maps question -> label);
    each question's short `header` is prefixed so a bare list of labels does not
    float without its subject.
    """
    tur = rec.get('toolUseResult')
    if not isinstance(tur, dict):
        return ''
    answers = tur.get('answers')
    if not isinstance(answers, dict) or not answers:
        return ''
    headers = {}
    for q in tur.get('questions') or []:
        if isinstance(q, dict) and q.get('question'):
            headers[q['question']] = q.get('header') or ''
    parts = []
    for question, answer in answers.items():
        head = headers.get(question, '')
        parts.append('%s: %s' % (head, answer) if head else str(answer))
    return ' · '.join(' '.join(p.split()) for p in parts)[:MAX]


def from_queued(rec):
    """A prompt typed while Claude was busy, or ''.

    A queued prompt is never re-emitted as a `user` record — it exists only as this
    attachment plus a pair of queue-operation entries — so the filters above walk
    straight past a turn the user really did type. `commandMode` separates it from
    the harness queueing its own work: across 115 of these, all 107
    "task-notification" ones were machine text and all 8 "prompt" ones were human.
    """
    att = rec.get('attachment') or {}
    if att.get('type') != 'queued_command' or att.get('commandMode') != 'prompt':
        return ''
    text = att.get('prompt')
    if not isinstance(text, str) or not text.strip():
        return ''
    return ' '.join(text.split())[:MAX]


def too_new(rec, cutoff):
    """True if this record post-dates the pane's own last turn.

    A record with no parsable timestamp is never rejected — the cutoff is a filter
    against a known second writer, not a validity check, so an unreadable stamp
    should leave the old behaviour in place rather than blank the row.
    """
    if not cutoff:
        return False
    ts = rec.get('timestamp')
    if not isinstance(ts, str) or len(ts) < 19:
        return False
    try:
        return calendar.timegm(time.strptime(ts[:19], '%Y-%m-%dT%H:%M:%S')) > cutoff
    except ValueError:
        return False


def last_prompt(path, cutoff=0):
    try:
        size = os.path.getsize(path)
    except OSError:
        return ''
    for window in STEPS:
        try:
            with open(path, 'rb') as fh:
                fh.seek(max(0, size - window))
                buf = fh.read()
        except OSError:
            return ''
        for line in reversed(buf.split(b'\n')):
            # The first line of a tail is usually a partial record; it fails the
            # '{' test or the parse, which is the intent.
            if line[:1] != b'{':
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            kind = rec.get('type')
            if kind == 'attachment':
                found = from_queued(rec)
                if not found:
                    continue
                if too_new(rec, cutoff):
                    continue
                return found
            if kind != 'user' or rec.get('isSidechain'):
                continue
            text = (rec.get('message') or {}).get('content')
            if isinstance(text, list):
                # An image attachment lands here whatever the promptSource is —
                # the older records carry none at all. An AskUserQuestion answer
                # is a tool_result, so it has to be recognised before from_blocks
                # rejects the whole list as machinery.
                found = from_answers(rec) or from_blocks(text)
            elif not isinstance(text, str):
                continue
            else:
                text = text.strip()
                if rec.get('promptSource') in SRC:
                    found = ' '.join(text.split())[:MAX] if text else ''
                else:
                    # A `!` command has no promptSource, so it has to be recognised
                    # by its wrapper. The tags hold only the command — its output
                    # lands in a separate record — so stripping them leaves exactly
                    # what was typed.
                    if not (text.startswith(BANG_OPEN) and text.endswith(BANG_CLOSE)):
                        continue
                    cmd = text[len(BANG_OPEN):-len(BANG_CLOSE)].strip()
                    found = ('! ' + ' '.join(cmd.split()))[:MAX] if cmd else ''
            if not found:
                continue
            # Only a real candidate is worth a timestamp: strptime is expensive and
            # the tail is overwhelmingly tool results, which never reach this line.
            if too_new(rec, cutoff):
                continue
            return found
        if window >= size:
            break
    return ''


def main():
    found = index_transcripts()
    out = []
    for arg in sys.argv[1:]:
        sid, _, cut = arg.partition(':')
        try:
            cutoff = int(cut)
        except ValueError:
            cutoff = 0
        path = found.get(sid)
        out.append('%s\t%s' % (sid, last_prompt(path, cutoff) if path else ''))
    sys.stdout.write('\n'.join(out) + ('\n' if out else ''))


if __name__ == '__main__':
    main()
