#!/usr/bin/env python3
"""PreToolUse hook: Claude sessions never push to main; work lands through a PR (no branch protection on this plan)."""
import json, re, shlex, subprocess, sys

event = json.load(sys.stdin)
command = event.get('tool_input', {}).get('command', '')
cwd = event.get('cwd') or None

def current_branch():
    try: return subprocess.run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], cwd=cwd, capture_output=True, text=True).stdout.strip()
    except OSError: return ''

def targets_main(args):
    if {'--all', '--mirror'} & set(args): return True
    positional = [a for a in args if not a.startswith('-')]
    refspecs = positional[1:]  # the first is the remote
    if not refspecs: return current_branch() == 'main'
    for spec in refspecs:
        dest = spec.lstrip('+').split(':')[-1] or spec
        if dest in ('main', 'refs/heads/main') or (dest == 'HEAD' and current_branch() == 'main'): return True
    return False

for part in re.split(r'&&|\|\||;|\|', command):
    try: words = shlex.split(part)
    except ValueError: words = part.split()
    for i in range(len(words) - 1):
        if words[i] == 'git' or words[i].endswith('/git'):
            rest = [w for w in words[i + 1:] if w != '-C' and not w.startswith('-c')]
            if 'push' in rest[:3] and targets_main(rest[rest.index('push') + 1:]):
                print('Pushing to main is blocked: push a branch and open a PR into main instead.', file=sys.stderr)
                sys.exit(2)
