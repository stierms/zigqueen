#!/usr/bin/env python3
"""Union of LLVM CS text profiles (`llvm-profdata merge --text`) without summing: all records of
the first file, plus each later record whose (name, hash) is new. Used to build one profile for
both OS links (scripts/pgo-build.sh merge): a summed merge would double the functions whose name
and CFG hash agree between the OS builds, against the OS-specific ones (Zig's __anon_N names).

usage: profunion.py OUT.proftext A.proftext B.proftext...
"""
import sys


def load(path):
    lines = open(path).read().split('\n')
    head = []
    while lines and (lines[0].startswith('#') or lines[0].startswith(':')):
        head.append(lines.pop(0))
    recs, cur = [], []
    for line in lines + ['']:
        if line:
            cur.append(line)
        elif cur:
            recs.append(cur)
            cur = []
    return head, recs


out, files = sys.argv[1], sys.argv[2:]
head, recs = load(files[0])
seen = {(r[0], r[2]): r for r in recs}
same = differ = 0
for path in files[1:]:
    h, rs = load(path)
    assert h == head, f'{path}: header {h} != {head}'
    for r in rs:
        k = (r[0], r[2])
        if k in seen:
            same += seen[k] == r
            differ += seen[k] != r
        else:
            seen[k] = r
            recs.append(r)
open(out, 'w').write('\n'.join(head) + '\n' + '\n\n'.join('\n'.join(r) for r in recs) + '\n')
print(f'{out}: {len(recs)} records; shared (name, hash): {same} with identical counts, {differ} differing (first file kept)')
