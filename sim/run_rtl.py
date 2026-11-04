"""Replay the frozen 97-packet public AXIS regression with native Verilator."""
import argparse,gzip,json,os,subprocess,time
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--work-dir',required=True,type=Path)
    p.add_argument('--jobs',default=2,type=int)
    a=p.parse_args();root=Path(__file__).resolve().parents[1];work=a.work_dir.resolve()
    if work==root or root in work.parents:p.error('Use a work directory outside this repository')
    if os.name=='nt':p.error('Run in Linux/WSL with Verilator and a C++ compiler; see sim/readme.md')
    work.mkdir(parents=True,exist_ok=True)
    (work/'vectors.txt').write_bytes(gzip.decompress((root/'data/axis_vectors.txt.gz').read_bytes()))
    files=[root/'src/rtl'/n for n in json.loads((root/'src/rtl/files.json').read_text())]
    commands=[['verilator','--cc','--exe','--build','--assert','-Wno-fatal','-j',str(a.jobs),'--top-module','y26_axis_continuous30_top','--prefix','Vaxi_dut','--Mdir',str(work/'obj'),'-o','sim',*map(str,files),str(root/'sim/tb/axis_driver.cpp')],[str(work/'obj/sim'),str(work/'vectors.txt'),str(work/'responses.txt')]]
    rows=[]
    for i,cmd in enumerate(commands):
        start=time.monotonic();v=subprocess.run(cmd,capture_output=True,timeout=1800)
        (work/(str(i)+'.stdout')).write_bytes(v.stdout);(work/(str(i)+'.stderr')).write_bytes(v.stderr)
        rows.append({'command':cmd,'exit_code':v.returncode,'seconds':time.monotonic()-start})
        print((v.stdout+v.stderr).decode(errors='replace')[-1800:],flush=True)
        if v.returncode:break
    result={'passed':len(rows)==2 and all(x['exit_code']==0 for x in rows),'packets':97,'runs':rows,'board_test':False}
    (work/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    return 0 if result['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
