#!/usr/bin/env python3
"""PGO training driver for scripts/pgo-build.sh: no profile runtime, no hook in the engine.

Runs a CS-PGO instrumented relink of the normal LTO bitcode over a fixed UCI workload, reads the
counter section out of the live engine once the last search is done, then writes the LLVM 20 raw
profile (version 10 with the IR and context-sensitive variant bits) itself, laid out as the
runtime's buffer writer does: header, profile data records, counters, names, padding.

- Linux (static, non-PIE): `__llvm_prf_cnts` is read from /proc/PID/mem (the driver is the
  parent, so Yama ptrace_scope 1 allows it). Data and names come from the ELF file.
- Windows (BIN = *.exe, run through WSL interop): `.lprfc` is read with ReadProcessMemory from
  powershell.exe at the module base + RVA. The data records hold 32-bit label differences there,
  so the deltas are truncated as the runtime does on WIN64. Zero marker records/bytes, present
  only when the runtime is linked, are skipped.

The counters are deterministic for the search itself; only time-dependent output paths (info
lines) differ between two runs.

usage: profsnap.py BIN OUT.profraw [--pos POS.json] [--nodes N] [--depth16] [--tb PATH] [--hash MB]
         --depth16: `position startpos` + `go depth 16` first (the bench 16 search)
       profsnap.py --selftest BIN REF.profraw
         rebuild REF (a profile the runtime wrote for Linux BIN) from BIN plus REF's counters
"""
import base64, json, os, struct, subprocess, sys

MAGIC = 0xff6c70726f667281
VERSION = 10 | (1 << 56) | (1 << 57)  # INSTR_PROF_RAW_VERSION, VARIANT_MASK_IR_PROF, VARIANT_MASK_CSIR_PROF
IPVK_LAST = 2
M32, M64 = (1 << 32) - 1, (1 << 64) - 1


def pad8(n):
    return (8 - n % 8) % 8


def elf_sections(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'\x7fELF' and d[4] == 2 and d[5] == 1, 'expected ELF64 little-endian'
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    hdrs = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    stroff = hdrs[shstrndx][4]
    out = {}
    for h in hdrs:
        name = d[stroff + h[0]:d.index(b'\0', stroff + h[0])].decode()
        out[name] = {'addr': h[3], 'off': h[4], 'size': h[5]}
    return d, out


def pe_sections(path):
    d = open(path, 'rb').read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    assert d[pe:pe + 4] == b'PE\0\0', 'expected PE'
    nsec, = struct.unpack_from('<H', d, pe + 6)
    optsz, = struct.unpack_from('<H', d, pe + 20)
    sh = pe + 24 + optsz
    out = {}
    for i in range(nsec):
        name, vsize, rva, _, off = struct.unpack_from('<8sIIII', d, sh + 40 * i)
        out[name.rstrip(b'\0').decode()] = {'rva': rva, 'vsize': vsize, 'off': off}
    return d, out


def elf_rawprof(path, counters):
    d, s = elf_sections(path)
    data, cnts, names = s['__llvm_prf_data'], s['__llvm_prf_cnts'], s['__llvm_prf_names']
    assert not {'__llvm_prf_bits', '__llvm_prf_vtab', '__llvm_prf_vns'} & set(s), 'unexpected profile sections'
    assert len(counters) == cnts['size'] and cnts['size'] % 8 == 0
    hdr = struct.pack('<16Q', MAGIC, VERSION, 0, data['size'] // 64, 0, cnts['size'] // 8, pad8(cnts['size']),
                      0, 0, names['size'], (cnts['addr'] - data['addr']) & M64, (0 - data['addr']) & M64,
                      names['addr'], 0, 0, IPVK_LAST)
    body = d[data['off']:data['off'] + data['size']] + counters + b'\0' * pad8(cnts['size'])
    body += d[names['off']:names['off'] + names['size']] + b'\0' * pad8(names['size'])
    return hdr + body


def elf_snapshot(pid, path):
    _, s = elf_sections(path)
    c = s['__llvm_prf_cnts']
    with open(f'/proc/{pid}/mem', 'rb') as f:
        f.seek(c['addr'])
        return f.read(c['size'])


PS_READ = r"""$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class ZqMem {
  [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(int a, bool i, int p);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, IntPtr n, out IntPtr r);
}
'@
$p = @(Get-Process -Name 'NAME')
if ($p.Count -ne 1) { throw "matching processes: $($p.Count)" }
$base = $p[0].MainModule.BaseAddress.ToInt64()
$h = [ZqMem]::OpenProcess(0x0410, $false, $p[0].Id)
$buf = New-Object byte[] SIZE
$r = [IntPtr]::Zero
if (-not [ZqMem]::ReadProcessMemory($h, [IntPtr]($base + RVA), $buf, [IntPtr]SIZE, [ref]$r)) { throw 'ReadProcessMemory failed' }
Write-Output ('{0} {1}' -f $base, [Convert]::ToBase64String($buf))
"""


def pe_snapshot(path):
    _, s = pe_sections(path)
    c = s['.lprfc']
    script = PS_READ.replace('NAME', os.path.basename(path)[:-4]).replace('SIZE', str(c['vsize'])).replace('RVA', str(c['rva']))
    out = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-EncodedCommand',
                          base64.b64encode(script.encode('utf-16-le')).decode()], capture_output=True, text=True)
    base, b64 = out.stdout.split()
    return int(base), base64.b64decode(b64)


def pe_rawprof(path, base, counters):
    d, s = pe_sections(path)
    c, dd, n = s['.lprfc'], s['.lprfd'], s['.lprfn']
    assert len(counters) == c['vsize'] and not {'.lprfb', '.lprfvt', '.lprfvn'} & set(s), 'unexpected profile sections'
    data, data_rva = d[dd['off']:dd['off'] + dd['vsize']], dd['rva']
    while data[:64] == bytes(64):
        data, data_rva = data[64:], data_rva + 64
    while data[-64:] == bytes(64):
        data = data[:-64]
    assert len(data) % 64 == 0
    names, names_rva = d[n['off']:n['off'] + n['vsize']], n['rva']
    while names[:1] == b'\0':
        names, names_rva = names[1:], names_rva + 1
    names = names.rstrip(b'\0')
    ncnt = len(counters) // 8
    hdr = struct.pack('<16Q', MAGIC, VERSION, 0, len(data) // 64, 0, ncnt, 0, 0, 0, len(names),
                      (c['rva'] - data_rva) & M32, (0 - (base + data_rva)) & M32, (base + names_rva) & M64,
                      0, 0, IPVK_LAST)
    return hdr + data + counters[:ncnt * 8] + names + b'\0' * pad8(len(names))


def selftest(binp, ref):
    r = open(ref, 'rb').read()
    _, s = elf_sections(binp)
    o = 128 + s['__llvm_prf_data']['size']
    mine = elf_rawprof(binp, r[o:o + s['__llvm_prf_cnts']['size']])
    print('selftest', 'identical' if mine == r else f'DIFF ({len(mine)} vs {len(r)} bytes)')
    return mine == r


def train(binp, out, opt, depth16):
    win = binp.endswith('.exe')
    p = subprocess.Popen([binp], cwd=os.path.dirname(os.path.abspath(out)), stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, text=True, bufsize=1)

    def send(x):
        p.stdin.write(x + '\n')
        p.stdin.flush()

    def until(t):
        lines = []
        for l in p.stdout:
            lines.append(l.rstrip())
            if l.startswith(t):
                return lines
        raise SystemExit('engine exited early')

    send('uci'); until('uciok')
    send(f"setoption name Hash value {opt['--hash']}")
    if opt['--tb']:
        send(f"setoption name SyzygyPath value {opt['--tb']}")
    send('isready'); until('readyok')
    moves = []
    if depth16:
        send('ucinewgame'); send('position startpos'); send('isready'); until('readyok')
        send('go depth 16'); moves.append(until('bestmove')[-1].split()[1])
    if opt['--pos']:
        send('ucinewgame'); send('isready'); until('readyok')
        for r in json.load(open(opt['--pos'])):
            fen = r['fen'] if isinstance(r, dict) else r
            send(f'position fen {fen}'); send('isready'); until('readyok')
            send(f"go nodes {opt['--nodes']}"); moves.append(until('bestmove')[-1].split()[1])
    send('isready'); until('readyok')
    if win:
        base, counters = pe_snapshot(binp)
    else:
        counters = elf_snapshot(p.pid, binp)
    send('quit')
    p.wait(timeout=60)
    open(out, 'wb').write(pe_rawprof(binp, base, counters) if win else elf_rawprof(binp, counters))
    print(out, len(counters) // 8, 'counters; bestmoves', ' '.join(moves))


def main():
    a = sys.argv[1:]
    if a and a[0] == '--selftest':
        sys.exit(0 if selftest(a[1], a[2]) else 1)
    binp, out = os.path.abspath(a[0]), a[1]
    opt = {'--pos': None, '--nodes': '1000000', '--tb': '', '--hash': '256'}
    depth16 = False
    i = 2
    while i < len(a):
        if a[i] == '--depth16':
            depth16, i = True, i + 1
        else:
            opt[a[i]], i = a[i + 1], i + 2
    train(binp, out, opt, depth16)


main()
