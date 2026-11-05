#!/usr/bin/env python3
"""Merge Kconfig fragments onto a base .config.

Uses the same rules as Gravity's packaging tool (tools/package.py
overlay_kernel_configs): later fragments win, and CONFIG_X=n is written as
"# CONFIG_X is not set". Run `make olddefconfig` on the output afterwards.

usage: overlay-config.py BASE OUTPUT FRAGMENT...
"""
import re
import sys


def parse_fragment(path):
    entries = {}
    with open(path) as fd:
        for raw in fd:
            line = raw.strip()
            m = re.match(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$", line)
            if m:
                key, value = m.groups()
                entries[key] = f"# {key} is not set" if value == "n" else f"{key}={value}"
                continue
            m = re.match(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$", line)
            if m:
                entries[m.group(1)] = line
    return entries


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    base, output, fragments = argv[1], argv[2], argv[3:]
    merged = {}
    for fragment in fragments:
        merged.update(parse_fragment(fragment))

    out = []
    with open(base) as fd:
        for raw in fd:
            m = re.match(r"^(?:(CONFIG_[A-Za-z0-9_]+)=.*|# (CONFIG_[A-Za-z0-9_]+) is not set)$", raw.rstrip("\n"))
            key = m and (m.group(1) or m.group(2))
            if key in merged:
                continue
            out.append(raw if raw.endswith("\n") else raw + "\n")
    out.append("# --- Gravity/Ubuntu overlay ---\n")
    out.extend(line + "\n" for line in merged.values())
    with open(output, "w") as fd:
        fd.writelines(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
