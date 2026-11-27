#!/usr/bin/env python3
import re, sys
from pathlib import Path

REQUIRED = {'clearsign_refresh', 'clearsign_setup_auth', 'clearsign_setup_code', 'clearsign_setup_pair', 'clearsign_setup_verify', 'clearsign_setup_poll', 'clearsign_setup_cancel', 'clearsign_cancel_refresh', 'clearsign_free'}
ROW = re.compile(r'^\s*(0x[0-9A-Fa-f]+)\s+(0x[0-9A-Fa-f]+)\s+\[\s*\d+\s*\]\s+_(\w+)\s*$')

def validate(text):
    if not re.search(r'^# Arch:\s*arm64\s*$',text,re.M):
        raise ValueError('Expected arm64 link map')
    if not re.search(r'^# Path:.*MeloNX\.app/MeloNX\s*$',text,re.M):
        raise ValueError('Expected host executable link map')
    if 'libclearsign.a' not in text:
        raise ValueError('ClearSign archive missing from link map')
    if '# Symbols:' not in text:
        raise ValueError('Live symbol section missing')
    live=text.split('# Symbols:',1)[1].split('# Dead Stripped Symbols:',1)[0]
    found=set()
    for line in live.splitlines():
        m=ROW.match(line)
        if m and int(m[1],16)>0 and int(m[2],16)>0:
            found.add(m[3])
    missing=REQUIRED-found
    if missing:
        raise ValueError('Missing live ClearSign symbols: '+', '.join(sorted(missing)))
    return len(REQUIRED)

def selftest():
    header='# Path: /tmp/MeloNX.app/MeloNX\n# Arch: arm64\n# Object files:\n[  1] /tmp/libclearsign.a(test.o)\n# Symbols:\n'
    names=sorted(REQUIRED)
    rows=[f'0x10000{i:03X}\t0x00000040\t[  1]\t_{name}\n' for i,name in enumerate(names)]
    dead='# Dead Stripped Symbols:\n'
    assert validate(header+''.join(rows)+dead)==len(REQUIRED)
    bad=[header+''.join(rows[1:])+dead+rows[0], header.replace('arm64','x86_64')+''.join(rows),header.replace('libclearsign.a','other.a')+''.join(rows),header+''.join(rows[1:])+rows[0].replace('0x00000040','0x00000000'),header.replace('MeloNX.app/MeloNX','Helper.appex/Helper')+''.join(rows)]
    for case in bad:
        try: validate(case)
        except ValueError: pass
        else: raise AssertionError('Accepted invalid fixture')
    print('Link map checker: valid fixture + 5 rejection cases passed')

if __name__=='__main__':
    if sys.argv[1:] == ['--self-test']:
        selftest()
    else:
        print(f'Verified {validate(Path(sys.argv[1]).read_text())} live ClearSign host symbols')
