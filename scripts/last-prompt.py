#!/usr/bin/env python3
"""Last typed prompt for each session id given on argv, as "<sid>\t<text>" lines.

Called once per picker title-cache rebuild with every session id at once. One
interpreter start amortised over the whole list is the point: doing this in the
shell costs a `tail` plus a parser per session, and transcripts run to 86MB so
the file cannot simply be read.

The record test matches web-server.js: a real prompt is type "user", not a
sidechain (subagent) turn, carries a promptSource, and has string content. Tool
results are also type "user" but have list content and no promptSource.
"""
import glob
import json
import os
import sys

SRC = {'typed', 'queued', 'suggestion_accepted'}
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
                continue
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
