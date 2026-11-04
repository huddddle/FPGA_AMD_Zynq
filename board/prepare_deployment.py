"""Assemble the original verified Linux layout without accessing the board."""
import argparse,hashlib,json,shutil
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',required=True,type=Path)
    p.add_argument('--kernel',required=True,type=Path,help='Existing vendor zImage matching external_assets.json');a=p.parse_args()
    root=Path(__file__).resolve().parents[1];out=a.output.resolve()
    if out==root or root in out.parents:p.error('Output must be outside the checkout')
    if out.exists():p.error('Output exists; choose a new directory to preserve its contents')
    external=json.loads((root/'board/external_assets.json').read_text())['zImage']
    if not a.kernel.is_file() or hashlib.sha256(a.kernel.read_bytes()).hexdigest()!=external['sha256']:p.error('Vendor kernel missing or mismatched; no output created')
    layout=json.loads((root/'board/deployment_layout.json').read_text())
    service=out/'Zynq7020_deploy';experiment=out/'y26_continuous30'
    service.mkdir(parents=True);experiment.mkdir()
    for target,source in layout['service_files'].items():
        dest=service/target;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(root/source,dest)
    shutil.copyfile(root/'board/app/pl30_manifest.json',service/'pl30_manifest.json')
    for f in (root/'board/pl30').iterdir():
        if f.is_file():shutil.copyfile(f,experiment/('SHA256SUMS' if f.name=='sha256sums' else f.name))
    shutil.copyfile(a.kernel,experiment/'zImage')
    manifest=json.loads((service/'pl30_manifest.json').read_text())
    for target,h in manifest['sha256'].items():
        if hashlib.sha256((service/target).read_bytes()).hexdigest()!=h:raise ValueError('Original service hash mismatch: '+target)
    for line in (experiment/'SHA256SUMS').read_text().splitlines():
        h,n=line.split('  ',1)
        if hashlib.sha256((experiment/n).read_bytes()).hexdigest()!=h:raise ValueError('Boot package hash mismatch: '+n)
    for n in ['Zynq7020.sh','yolo26_detect']:(service/n).chmod(0o755)
    (experiment/'y26-continuous30-check').chmod(0o755)
    print('DEPLOYMENT_PREPARED_AND_HASH_VERIFIED',out)
    print('No SSH, upload, service start, module load or PL configuration was performed.')
if __name__=='__main__':main()
