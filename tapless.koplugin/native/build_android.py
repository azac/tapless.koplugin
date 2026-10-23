#!/usr/bin/env python3
"""Build Bionic ARMv7/API18 and AArch64/API21 libraries with Android NDK r23c.

Standard use: ANDROID_NDK_HOME=/path/to/ndk python3 native/build_android.py
For cross-compilers outside the NDK, set ANDROID_SYSROOT, TAPLESS_CLANG,
TAPLESS_LLD and TAPLESS_COMPILER_RT. This path uses the same NDK headers,
API-specific import libraries and builtins, and invokes the linker directly.
"""
import argparse,hashlib,json,os,platform,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent
SOURCES=['core.c','scan.c','shape.c','engine.c','store.c']
TARGETS={
 'armeabi-v7a':{'triple':'armv7a-linux-androideabi18','arch':'arm-linux-androideabi','api':18,
   'flags':['-march=armv7-a','-mthumb','-mfpu=vfpv3-d16','-mfloat-abi=softfp'], 'runtime':'arm'},
 'arm64-v8a':{'triple':'aarch64-linux-android21','arch':'aarch64-linux-android','api':21,
   'flags':['-march=armv8-a','-ffixed-x18'],'runtime':'aarch64'},
}
def run(args):
 p=subprocess.run(list(map(str,args)),text=True,capture_output=True)
 if p.returncode:raise RuntimeError(' '.join(map(str,args))+'\n'+p.stdout+p.stderr)
 return p

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--abi',choices=['all',*TARGETS],default='all')
 parser.add_argument('--build-dir',type=Path)
 args=parser.parse_args()
 ndk=os.environ.get('ANDROID_NDK_HOME') or os.environ.get('ANDROID_NDK_ROOT')
 toolchain=None
 if ndk:
  properties=(Path(ndk)/'source.properties').read_text()
  if not any(line.strip()=='Pkg.Revision = 23.2.8568313' for line in properties.splitlines()):
   parser.error('Use NDK r23c (23.2.8568313) to retain Android API 18 support')
  host='darwin-x86_64' if platform.system()=='Darwin' else 'linux-x86_64'
  toolchain=Path(ndk)/'toolchains/llvm/prebuilt'/host
 sysroot=Path(os.environ['ANDROID_SYSROOT']) if os.environ.get('ANDROID_SYSROOT') else toolchain/'sysroot' if toolchain else None
 cc=os.environ.get('TAPLESS_CLANG')
 lld=os.environ.get('TAPLESS_LLD')
 if toolchain:
  cc=cc or str(toolchain/'bin/clang')
  lld=lld or str(toolchain/'bin/ld.lld')
 runtime=Path(os.environ['TAPLESS_COMPILER_RT']) if os.environ.get('TAPLESS_COMPILER_RT') else None
 if toolchain and not runtime:
  found=list((toolchain/'lib64/clang').glob('*/lib/linux'))
  if len(found)!=1:parser.error('Cannot identify NDK compiler-rt directory')
  runtime=found[0]
 if not sysroot or not sysroot.is_dir() or not cc or not lld or not runtime:
  parser.error('Set ANDROID_NDK_HOME, or all four explicit toolchain variables')
 build=(args.build_dir or Path(tempfile.mkdtemp(prefix='tapless-android-build-'))).resolve();build.mkdir(parents=True,exist_ok=True)
 manifest={'ndk':'23.2.8568313','compiler':run([cc,'--version']).stdout.strip(),
  'source_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in ROOT.iterdir() if p.suffix in ('.c','.h')},'variants':[]}
 for abi in TARGETS if args.abi=='all' else [args.abi]:
  spec=TARGETS[abi];folder=build/abi;folder.mkdir(exist_ok=True);objects=[];commands=[]
  for source in SOURCES:
   obj=folder/(Path(source).stem+'.o')
   cmd=[cc,'--target='+spec['triple'],'--sysroot='+str(sysroot),'-isystem',sysroot/'usr/include'/spec['arch'],
      *spec['flags'],'-std=c99','-O3','-fPIC','-fno-fast-math','-ffp-contract=off',
      '-fno-unwind-tables','-fno-asynchronous-unwind-tables','-fno-stack-protector',
      '-c',ROOT/source,'-o',obj]
   run(cmd);objects.append(obj);commands.append(list(map(str,cmd)))
  output=ROOT/('libtapless-core-android-'+abi+'.so');temporary=folder/output.name
  imports=sysroot/'usr/lib'/spec['arch']/str(spec['api'])
  cmd=[lld,'-shared','--hash-style=both','-z','now','-z','relro','-z','noexecstack',
       '-z','max-page-size=16384','--no-undefined','-soname',output.name,'-o',temporary,
       *objects,'--as-needed',imports/'libm.so',imports/'libc.so',
       runtime/('libclang_rt.builtins-'+spec['runtime']+'-android.a')]
  run(cmd);commands.append(list(map(str,cmd)))
  (folder/'commands.json').write_text(json.dumps(commands,indent=2)+'\n')
  staging=output.with_suffix('.so.new');staging.write_bytes(temporary.read_bytes());staging.chmod(0o755);staging.replace(output)
  item={'abi':abi,'api':spec['api'],'file':output.name,'target':spec['triple'],'bytes':output.stat().st_size,
        'sha256':hashlib.sha256(output.read_bytes()).hexdigest()}
  manifest['variants'].append(item);print(json.dumps(item),flush=True)
 (build/'android-build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
if __name__=='__main__':main()
