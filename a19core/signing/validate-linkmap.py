#!/usr/bin/env python3
import re, sys
from pathlib import Path

REQUIRED = {b'clearsign_refresh', b'clearsign_setup_auth', b'clearsign_setup_code', b'clearsign_setup_pair', b'clearsign_setup_verify', b'clearsign_setup_poll', b'clearsign_setup_cancel', b'clearsign_cancel_refresh', b'clearsign_free'}
ROW = re.compile(rb'^[ \t]*(0x[0-9A-Fa-f]+)[ \t]+(0x[0-9A-Fa-f]+)[ \t]+\[[ \t]*\d+[ \t]*\][ \t]+_(\w+)[ \t]*\r?$')

def validate(data):
    if not re.search(rb'^# Arch:[ \t]*arm64[ \t]*\r?$',data,re.M):
        raise ValueError('Expected arm64 link map')
    if not re.search(rb'^# Path:[^\r\n]*MeloNX\.app/MeloNX[ \t]*\r?$',data,re.M):
        raise ValueError('Expected host executable link map')
    if b'libclearsign.a' not in data:
        raise ValueError('ClearSign archive missing from link map')
    if b'# Symbols:' not in data:
        raise ValueError('Live symbol section missing')
    live=data.split(b'# Symbols:',1)[1].split(b'# Dead Stripped Symbols:',1)[0]
    found=set()
    for line in live.split(b'\n'):
        m=ROW.fullmatch(line)
        if m and int(m[1],16)>0 and int(m[2],16)>0:
            found.add(m[3])
    missing=REQUIRED-found
    if missing:
        raise ValueError('Missing live ClearSign symbols: '+', '.join(x.decode('ascii') for x in sorted(missing)))
    return len(REQUIRED)

def selftest():
    header=b'# Path: /tmp/MeloNX.app/MeloNX\n# Arch: arm64\n# Object files:\n[  1] /tmp/libclearsign.a(test.o)\n# Symbols:\n'
    names=sorted(REQUIRED)
    rows=[f'0x10000{i:03X}\t0x00000040\t[  1]\t_'.encode('ascii')+name+b'\n' for i,name in enumerate(names)]
    dead=b'# Dead Stripped Symbols:\n'
    good=header+b''.join(rows)+dead
    noisy=b'0x100000FF\t0x00000040\t[  2]\t_other\xc0\xff\x85\n'
    assert validate(good)==len(REQUIRED)
    assert validate(header+noisy+b''.join(rows)+dead)==len(REQUIRED)
    assert validate((header+noisy+b''.join(rows)+dead).replace(b'\n',b'\r\n'))==len(REQUIRED)
    assert validate(header+noisy*150000+b''.join(rows)+dead)==len(REQUIRED)
    bad=[header+b''.join(rows[1:])+dead+rows[0], header.replace(b'arm64',b'x86_64')+b''.join(rows),header.replace(b'libclearsign.a',b'other.a')+b''.join(rows),header+b''.join(rows[1:])+rows[0].replace(b'0x00000040',b'0x00000000'),header.replace(b'MeloNX.app/MeloNX',b'Helper.appex/Helper')+b''.join(rows),header+noisy+b''.join(rows[1:])+dead+rows[0],header+b''.join(rows[1:])+rows[0].replace(names[0],names[0]+b'\xc0')]
    for case in bad:
        try: validate(case)
        except ValueError: pass
        else: raise AssertionError('Accepted invalid fixture')
    print('Link map checker: 4 positive + 7 rejection cases passed, including non-UTF-8 and large inputs')

if __name__=='__main__':
    if sys.argv[1:] == ['--self-test']:
        selftest()
    else:
        print(f'Verified {validate(Path(sys.argv[1]).read_bytes())} live ClearSign host symbols')
