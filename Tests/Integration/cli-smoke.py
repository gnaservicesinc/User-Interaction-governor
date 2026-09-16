"""Optional native smoke: python3 Tests/Integration/cli-smoke.py [binary-directory].

Requires an active macOS desktop; briefly shows automatically closing image windows.
All service state and wrapper fixtures are isolated and removed on completion.
"""
import json, os, pathlib, shutil, subprocess, sys, tempfile, time
repo=pathlib.Path(__file__).resolve().parents[2]
bin_dir=pathlib.Path(sys.argv[1]).resolve() if len(sys.argv)>1 else repo/'.build/debug'
with tempfile.TemporaryDirectory(prefix='uig-smoke-', dir='/tmp') as td:
    env={k:os.environ[k] for k in ['HOME','USER','LOGNAME','TMPDIR','SECURITYSESSIONID'] if k in os.environ}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin',UIG_RUNTIME_DIRECTORY=td+'/runtime')
    service=subprocess.Popen([str(bin_dir/'uigd'),'--foreground'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    ids=[]
    def cli(*args, expected=0):
        r=subprocess.run([str(bin_dir/'uig'),*args],env=env,capture_output=True,text=True,timeout=15)
        assert r.returncode==expected,(args,r.returncode,r.stderr)
        return r.stdout.strip()
    try:
        for _ in range(100):
            if pathlib.Path(td+'/runtime/uigd.sock').exists():break
            if service.poll() is not None:raise RuntimeError(service.stderr.read().decode())
            time.sleep(.02)
        image=str(repo/'Tests/Fixtures/smoke.svg')
        uuid=cli('--new','--ui-type','media','--media-type','image','--path',image,'--auto-close','0.15');ids.append(uuid)
        cli('--stack','--uuid',uuid,'--ui-type','media','--media-type','image','--path',image,'--auto-close','0.15')
        cli('--trigger','--uuid',uuid.upper(),'--wait','--timeout','10')
        result=json.loads(cli('--dump','--uuid',uuid))
        assert result['outcome']=='completed' and len(result['steps'])==2,result
        assert all(step['outcome']=='completed' for step in result['steps']),result
        cli('--rearm','--uuid',uuid)
        cli('--trigger','--uuid',uuid,'--wait','--timeout','10')
        assert json.loads(cli('--dump','--uuid',uuid))['run_number']==2
        cli('--status','--uuid',uuid,'--reset','title',expected=2)
        cli('--end','--uuid',uuid)
        assert cli('--status','--uuid',uuid)=='3'
        wrapped=subprocess.run([str(bin_dir/'ui-media'),'--media-type','image','--path',image,'--auto-close','0.15','--start_timeout=5'],env=env,capture_output=True,text=True,timeout=15)
        assert wrapped.returncode==0,wrapped.stderr
        assert json.loads(wrapped.stdout)['outcome']=='completed'
        print('Real renderer: two-step image flow, rearm, uppercase UUID, wrapper alias, result and cleanup passed.')
    finally:
        for uuid in ids:
            try:cli('--end','--uuid',uuid)
            except Exception:pass
        service.terminate()
        service.wait(timeout=5)
with tempfile.TemporaryDirectory(prefix='uig-wrapper-',dir='/tmp') as td:
    target=pathlib.Path(td)
    shutil.copy2(bin_dir/'ui-entry',target/'ui-entry')
    stub=target/'uig'
    stub.write_text('''#!/bin/sh
case $1 in
 --new) echo 00000000-0000-0000-0000-000000000001;;
 --dump) /bin/dd if=/dev/zero bs=1024 count=256 2>/dev/null;;
 --trigger|--end) exit 0;;
 *) exit 2;;
esac
''')
    stub.chmod(0o755)
    result=subprocess.run([str(target/'ui-entry'),'Test','--title','timeout'],capture_output=True,timeout=10)
    assert result.returncode==0,(result.returncode,result.stderr)
    assert len(result.stdout)==262144,len(result.stdout)
    print('One-shot wrapper: 256 KiB output drained without deadlock.')
