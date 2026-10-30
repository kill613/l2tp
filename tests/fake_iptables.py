"""Small stateful command double; real syntax is checked separately in CI."""
import json
from pathlib import Path
import shlex
import sys

path = Path(sys.argv[1])
state = json.loads(path.read_text())


def command(args, table="filter"):
    while args and args[0] in ("-w", "-t"):
        flag, value, *args = args
        if flag == "-t":
            table = value
    action, chain, *rest = args
    chains = state.setdefault(table, {})
    rule = " ".join(rest)
    if action == "-S":
        return chain in chains
    if action == "-C":
        return rule in chains.get(chain, [])
    if action == "-N":
        if chain in chains:
            return False
        chains[chain] = []
    elif action == "-F":
        chains[chain] = []
    elif action == "-X":
        del chains[chain]
    elif action == "-D":
        chains[chain].remove(rule)
    elif action == "-I":
        chains[chain].insert(int(rest[0]) - 1, " ".join(rest[1:]))
    elif action == "-A":
        chains[chain].append(rule)
    elif action != "-N":
        raise AssertionError(args)
    return True


if sys.argv[2] == "restore":
    table = None
    for line in sys.stdin:
        line = line.strip()
        if line.startswith("*"):
            table = line[1:]
        elif line and line != "COMMIT":
            assert command(shlex.split(line), table)
    ok = True
else:
    ok = command(sys.argv[3:])
path.write_text(json.dumps(state))
sys.exit(0 if ok else 1)
