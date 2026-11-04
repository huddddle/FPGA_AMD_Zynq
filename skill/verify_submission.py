"""Read-only checks for names, frozen inputs, hardware binding and evidence."""
import argparse,gzip,hashlib,json,re,sys,zipfile
from pathlib import Path

STANDARD_NAMES={'README.md','LICENSE','LICENSE.txt','MODEL.md','REPORT.md','AGENTS.md','HANDOFF.md','CMakeLists.txt','Makefile','Dockerfile','SHA256SUMS','zImage'}

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def check_hashes(root,entries):
    for name,digest in entries.items():
        p=(root/name).resolve()
        if not p.is_relative_to(root.resolve()):raise ValueError('Path escapes package: '+name)
        if not p.is_file() or sha(p)!=digest:raise ValueError('SHA256 mismatch or missing file: '+name)

def verify(root):
    root=root.resolve()
    for directory in ['src','sim','build','board','data','skill','report']:
        if not (root/directory).is_dir():raise ValueError('Missing required directory: '+directory)
    for name in ['LICENSE','README.md','skill/README.md','report/design_report.md','report/provenance.json']:
        if not (root/name).is_file():raise ValueError('Missing required file: '+name)
    names=[]
    for p in root.rglob('*'):
        parts=p.relative_to(root).parts
        if '.git' in parts or '__pycache__' in parts:continue
        for part in parts:
            if part not in STANDARD_NAMES and not re.fullmatch(r'[a-z0-9_.-]+',part):raise ValueError('Nonconforming custom path: '+p.relative_to(root).as_posix())
        if p.is_file():names.append(p.relative_to(root).as_posix())
    manifest=json.loads((root/'report/submission_manifest.json').read_text())
    check_hashes(root,manifest['files'])
    if set(names)-{'report/submission_manifest.json'}!=set(manifest['files']):raise ValueError('Unrecorded or extra submission file')
    prov=json.loads((root/'report/provenance.json').read_text())
    for row in prov['files']:
        if not row.get('modified_for_submission') and sha(root/row['path'])!=row['sha256']:raise ValueError('Frozen input changed: '+row['path'])
    for name,digest in prov['frozen_rtl_sha256'].items():
        if sha(root/'src/rtl'/name)!=digest:raise ValueError('RTL no longer matches the signed baseline: '+name)
    bit=root/'board/pl30/sys_wrapper.bit'
    if sha(bit)!='d4c8b7f9426ecddc3c4d344bd0920a61a1acc7d9a99d48fbf275665d2f463a2e':raise ValueError('Unexpected signed baseline bit')
    with zipfile.ZipFile(root/'board/pl30/sys_resident.xsa') as z:
        if z.read(next(n for n in z.namelist() if n.endswith('.bit')))!=bit.read_bytes():raise ValueError('XSA and bit disagree')
    external=json.loads((root/'board/external_assets.json').read_text())
    for line in (root/'board/pl30/SHA256SUMS').read_text().splitlines():
        digest,name=line.split('  ',1)
        if name in external:
            if digest!=external[name]['sha256']:raise ValueError('External kernel identity disagrees with frozen package')
        else:check_hashes(root/'board/pl30',{name:digest})
    layout=json.loads((root/'board/deployment_layout.json').read_text())
    service=json.loads((root/'board/app/pl30_manifest.json').read_text())
    for target,digest in service['sha256'].items():check_hashes(root,{layout['service_files'][target]:digest})
    expected=['convrelu_'+str(i) for i in range(31)]
    if service['accelerated_layers']!=expected:raise ValueError('Wrong offloaded graph')
    signoff=json.loads((root/'build/reports/result.json').read_text())
    if not (signoff['timing_pass'] and signoff['wns_ns']>=0 and signoff['whs_ns']>=0 and signoff['drc_errors']==0 and signoff['timing_categories_checked']==12):raise ValueError('Baseline STA evidence is not passing')
    measured=json.loads((root/'report/evidence/results.json').read_text())
    if not (measured['passed'] and measured['records_per_mode']==7 and measured['same_bit_and_boot'] and not measured['map_evaluated']):raise ValueError('Benchmark scope mismatch')
    vectors=gzip.decompress((root/'data/axis_vectors.txt.gz').read_bytes())
    if int(vectors.splitlines()[0])!=97 or hashlib.sha256(vectors).hexdigest()!=prov['rtl_vectors_uncompressed_sha256']:raise ValueError('RTL vectors changed')
    return {'passed':True,'files_checked':len(names),'frozen_rtl_files':len(prov['frozen_rtl_sha256']),'source_commit':prov['source_commit'],'bit_sha256':sha(bit),'original_service_binding_verified':True,'signed_hardware_evidence_verified':True,'rtl_vector_packets':97,'external_vendor_kernel_required':True,'external_kernel_bytes_verified_by_this_check':False,'new_hardware_build_performed':False,'new_board_test_performed':False,'map_evaluated':False}

def verify_results(root, results, backend):
    """Compare downloaded inference files with the independently frozen oracle."""
    reference=root/'data/reference'
    expected={'output.f32':sha(reference/('output_cpu.f32' if backend=='cpu' else 'output.f32'))}
    if backend=='pl30':
        expected.update({name:sha(reference/name) for name in ['conv10.i8','conv20.i8','conv30.i8']})
    check_hashes(results,expected)
    report=json.loads((results/'report.json').read_text())
    if report['backend']!=backend:raise ValueError('Inference report backend does not match requested oracle')
    if backend=='pl30':
        profile=report['profile']
        if (profile['transactions'],profile['tx_bytes'],profile['rx_bytes'],profile['hardware_errors'],profile['feature_ddr_reimports'])!=(47,2911888,289792,0,0):
            raise ValueError('Inference report disagrees with the frozen PL30 boundary')
    return {'passed':True,'backend':backend,'files_checked':len(expected),'sha256':expected,'dataset_accuracy_evaluated':False}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[1])
    p.add_argument('--results',type=Path,help='Read-only comparison of downloaded fixed-input inference results')
    p.add_argument('--backend',choices=['cpu','pl30'],default='pl30',help='Select the corresponding frozen oracle')
    a=p.parse_args()
    try:
        result=verify(a.root)
        if a.results is not None:result['inference_results']=verify_results(a.root.resolve(),a.results.resolve(),a.backend)
        print(json.dumps(result,ensure_ascii=False,indent=2));return 0
    except (OSError,ValueError,KeyError,StopIteration,zipfile.BadZipFile) as e:print('SUBMISSION CHECK FAILED: '+str(e),file=sys.stderr);return 1
if __name__=='__main__':raise SystemExit(main())
