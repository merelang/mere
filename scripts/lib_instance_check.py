#!/usr/bin/env python3
"""Exercise the experimental C library instance lifetime with a real host."""
import argparse
import json
import os
import platform
from pathlib import Path
import shlex
import subprocess

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--base',type=Path,help='optional baseline compiler for byte-identical ordinary output')
opts=parser.parse_args()
root=Path(__file__).resolve().parents[1]
compiler=root/'_build/default/bin/mere.exe'
fixtures=root/'scripts/lib_instance'
out=opts.output.resolve();out.mkdir(parents=True,exist_ok=False)
results={}
def run(name,command,success=True):
 r=subprocess.run(list(map(str,command)),capture_output=True,text=True,timeout=90)
 (out/(name+'.out')).write_text(r.stdout+r.stderr)
 results[name]={'exit':r.returncode,'command':list(map(str,command))}
 (out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
 assert (r.returncode==0)==success,(name,r.stdout,r.stderr)
 return r.stdout+r.stderr
run('reject-other-backend',[compiler,'--lib-instance','-ll',fixtures/'queue_pool.mere'],False)
for name in ['queue_pool','recursive_state']:
 text=run(name+'-ordinary',[compiler,'--header',fixtures/(name+'.mere')],False)
 assert 'region escape across the library boundary' in text
 text=run(name+'-instance',[compiler,'--lib-instance','--header',fixtures/(name+'.mere')])
 (out/(name+'.h')).write_text(text)
text=run('explicit-escape',[compiler,'--lib-instance','--header',fixtures/'explicit_escape.mere'],False)
assert 'region escape' in text
run('temporary-argument',[compiler,'--lib-instance','--header',fixtures/'temporary_argument.mere'])
if opts.base:
 scalar=out/'scalar.mere';scalar.write_text('let state = map_new ();\nlet set = fn (n: int) -> map_set state "n" n;\n()\n')
 assert run('base-ordinary',[opts.base,'-c','--lib',scalar])==run('candidate-ordinary',[compiler,'-c','--lib',scalar])
(out/'queue_pool.c').write_text(run('emit',[compiler,'-c','--lib-instance',fixtures/'queue_pool.mere']))
cc=shlex.split(os.environ.get('CC','clang'))
flags=cc+['-O2','-g','-fsanitize=address,undefined','-fno-sanitize-recover=all']
run('compile',flags+['-c',out/'queue_pool.c','-o',out/'queue_pool.o'])
run('archive',['ar','rcs',out/'libqueue_pool.a',out/'queue_pool.o'])
run('link',flags+['-I',out,fixtures/'queue_host.c',out/'libqueue_pool.a','-pthread','-o',out/'queue_host'])
text=run('host',[out/'queue_host'])
assert text=='1000 lifecycles, 100000 queue reuses, failure recovery and overlap rejection passed\n'
(out/'stateless.h').write_text(run('stateless-header',[compiler,'--lib-instance','--header',fixtures/'stateless.mere']))
(out/'stateless.c').write_text(run('stateless-emit',[compiler,'-c','--lib-instance',fixtures/'stateless.mere']))
run('stateless-build',flags+['-I',out,fixtures/'stateless_host.c',out/'stateless.c','-pthread','-o',out/'stateless_host'])
assert run('stateless-host',[out/'stateless_host'])=='stateless overlap rejection and same-thread reentry passed\n'
(out/'retained_strings.c').write_text(run('strings-emit',[compiler,'-c','--lib-instance',fixtures/'retained_strings.mere']))
run('strings-build',flags+['-I',out,fixtures/'retained_strings_host.c','-pthread','-o',out/'strings_host'])
assert run('strings-host',[out/'strings_host'])=='temporary string inputs, retained copies, failure and reentry passed\n'
(out/'coroutine_roots.h').write_text(run('coroutine-roots-header',[compiler,'--lib-instance','--header',fixtures/'coroutine_roots.mere']))
(out/'coroutine_roots.c').write_text(run('coroutine-roots-emit',[compiler,'-c','--lib-instance',fixtures/'coroutine_roots.mere']))
run('coroutine-roots-build',flags+['-I',out,fixtures/'coroutine_roots_host.c',out/'coroutine_roots.c','-pthread','-o',out/'coroutine_roots_host'])
for mode in ['main','worker']:
 assert run('coroutine-roots-'+mode,[out/'coroutine_roots_host',mode])=='host root handles survive coroutine scans\n'
shared_flag='-dynamiclib' if platform.system()=='Darwin' else '-shared'
shared=out/'libcoroutine_roots.so'
run('coroutine-roots-shared',flags+['-fPIC',shared_flag,out/'coroutine_roots.c','-pthread','-o',shared])
run('coroutine-roots-dynamic-build',flags+['-I',out,fixtures/'coroutine_roots_dynamic.c','-pthread','-ldl','-o',out/'coroutine_roots_dynamic'])
assert run('coroutine-roots-dynamic',[out/'coroutine_roots_dynamic',shared])=='host roots can shut down and unload before worker exit\n'
print('instance-lifetime library checks passed')
