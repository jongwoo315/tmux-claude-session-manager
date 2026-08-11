#!/usr/bin/env python3
"""Last thing the user typed in each session id given on argv, as "<sid>\t<text>".

Called once per picker title-cache rebuild with every session id at once. One
interpreter start amortised over the whole list is the point: doing this in the
shell costs a `tail` plus a parser per session, and transcripts run to 86MB so
the file cannot simply be read.

The record test matches web-server.js. Two things count as typed:

  * a prompt — type "user", not a sidechain (subagent) turn, string content, and
    a promptSource of typed/queued/suggestion_accepted.
  * a `!` shell command — same but promptSource is null and the content is
    wrapped in <bash-input>. Reported with a leading "! ".

Everything else that arrives as type "user" is machinery: tool results (list
content), system-reminders, slash-command expansions, task notifications. In one
17-session sample those were 1440 of 1633 user records, which is what the filter
is really for.

`!` was excluded at first on the theory that a stray `! ls` would bury the last
real instruction. Measured across the live list, exactly one session of 17 had a
`!` as its newest input — and it was `arp -n … && curl -sS …`, which said more
about what that session was doing than its last prose prompt did.
"""
import glob
import json
import os
import sys

SRC = {'typed', 'queued', 'suggestion_accepted'}
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


def last_prompt(path):
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
            if rec.get('type') != 'user' or rec.get('isSidechain'):
                continue
            if rec.get('promptSource') not in SRC:
                # A `!` command has no promptSource, so it has to be recognised by
                # its wrapper. The tags hold only the command — its output lands
                # in a separate record — so stripping them leaves exactly what was
                # typed.
                text = (rec.get('message') or {}).get('content')
                if not isinstance(text, str):
                    continue
                text = text.strip()
                if not (text.startswith(BANG_OPEN) and text.endswith(BANG_CLOSE)):
                    continue
                text = text[len(BANG_OPEN):-len(BANG_CLOSE)].strip()
                if not text:
                    continue
                return ('! ' + ' '.join(text.split()))[:MAX]
            text = (rec.get('message') or {}).get('content')
            if isinstance(text, str) and text.strip():
                return ' '.join(text.split())[:MAX]
        if window >= size:
            break
    return ''


def main():
    found = index_transcripts()
    out = []
    for sid in sys.argv[1:]:
        path = found.get(sid)
        out.append('%s\t%s' % (sid, last_prompt(path) if path else ''))
    sys.stdout.write('\n'.join(out) + ('\n' if out else ''))


if __name__ == '__main__':
    main()
