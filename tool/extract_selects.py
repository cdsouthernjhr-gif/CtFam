#!/usr/bin/env python3
"""Extracts every PostgREST read the app makes: (table, select) pairs from
`.from('table') ... .select(...)` in lib/, resolving `Class.select` /
`Class.columns` constants. Prints JSON. Used by scripts/api_contract.sh."""
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.') / 'lib'
src = {p: p.read_text() for p in root.rglob('*.dart') if '/generated/' not in str(p) and not p.name.endswith('.g.dart')}


def string_literal(expr: str) -> str:
    # adjacent Dart string literals, possibly across lines
    parts = re.findall(r"'((?:[^'\\]|\\.)*)'", expr)
    return ''.join(parts)


consts = {}
for text in src.values():
    for cls, body in re.findall(r'class (\w+)[^{]*\{(.*?)\n\}', text, re.S):
        for name, expr in re.findall(r'static const (select|columns)\s*=\s*((?:\s*\'(?:[^\'\\]|\\.)*\'\s*)+);', body):
            consts[f'{cls}.{name}'] = string_literal(expr)

pairs = set()
for path, text in src.items():
    for m in re.finditer(r"\.from\('(\w+)'\)", text):
        tail = text[m.end():m.end() + 400]
        stop = tail.find(';')
        tail = tail if stop < 0 else tail[:stop]
        s = re.match(r"\s*\.select\(\s*((?:'(?:[^'\\]|\\.)*'\s*)+|\w+\.\w+)?\s*,?\s*\)", tail)
        if not s:
            continue
        arg = s.group(1)
        if arg is None:
            sel = '*'
        elif arg.startswith("'"):
            sel = string_literal(arg)
        else:
            sel = consts.get(arg)
            if sel is None:
                sys.exit(f'unresolved constant {arg} in {path}')
        pairs.add((m.group(1), re.sub(r'\s+', '', sel)))

# RPC calls and the parameter names the app sends
def map_keys(body: str) -> list:
    return sorted(set(re.findall(r"'(p_\w+)'\s*:", body)))


builders = {}
for text in src.values():
    for name, body in re.findall(r'static Map<String, dynamic> (\w+)\((.*?)\n  \};', text, re.S):
        builders[name] = map_keys(body)
    for name, body in re.findall(r'static Map<String, dynamic> (\w+)\(([^;]*?)\};', text, re.S):
        builders.setdefault(name, map_keys(body))

rpcs = {}
for path, text in src.items():
    calls = list(re.finditer(r"\.rpc(?:<[^(]*?>)?\(\s*'(\w+)'(\s*,\s*params:\s*)?", text))
    calls += list(re.finditer(r"\b_rpc\(\s*'(\w+)'(\s*,\s*)", text))  # FamilyRepository helper
    for m in calls:
        name = m.group(1)
        keys = []
        if m.group(2):
            rest = text[m.end():m.end() + 1500]
            if rest.lstrip().startswith('{'):
                depth, end = 0, 0
                for i, ch in enumerate(rest):
                    depth += ch == '{'
                    depth -= ch == '}'
                    if depth == 0 and ch == '}':
                        end = i
                        break
                keys = map_keys(rest[:end + 1])
            else:
                call = re.match(r'\s*(?:\w+\.)?(\w+)\(', rest)
                if not call or call.group(1) not in builders:
                    sys.exit(f'unresolved params for rpc {name} in {path}')
                keys = builders[call.group(1)]
        rpcs.setdefault(name, set()).add(tuple(keys))
# outbox replays (OutboxKind enum) use the same builders: rpc names only
for name in re.findall(r"\('[\w.]+', '(\w+)'\)", src[root / 'core/offline/sync_engine.dart']):
    rpcs.setdefault(name, set())

json.dump({'selects': sorted(pairs), 'rpcs': {k: sorted(list(v)) for k, v in sorted(rpcs.items())}},
          sys.stdout, indent=1)
