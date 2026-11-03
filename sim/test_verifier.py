"""Known SHA256 vector and path traversal rejection for reusable checker."""
import argparse,importlib.util,json
from pathlib import Path

def main():
    p=argparse.ArgumentParser();p.add_argument('--work-dir',required=True,type=Path);a=p.parse_args()
    root=Path(__file__).resolve().parents[1];work=a.work_dir.resolve()
    if root==work or root in work.parents:p.error('Use external work directory')
    work.mkdir(parents=True,exist_ok=True)
    spec=importlib.util.spec_from_file_location('checks',root/'skill/verify_submission.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    sample=work/'literal.bin';sample.write_bytes(b'abc')
    known={'literal.bin':'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'}
    m.check_hashes(work,known)
    sample.write_bytes(b'abd')
    try:m.check_hashes(work,known)
    except ValueError:pass
    else:raise AssertionError('A changed byte was accepted')
    try:m.check_hashes(work,{'../outside.bin':known['literal.bin']})
    except ValueError:pass
    else:raise AssertionError('A path outside the package was accepted')
    result={'passed':True,'known_literal_sha256':True,'tampered_byte_rejected':True,'outside_path_rejected':True}
    (work/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));return 0
if __name__=='__main__':raise SystemExit(main())
