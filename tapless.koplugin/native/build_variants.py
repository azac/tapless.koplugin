#!/usr/bin/env python3
"""Cross-build with verified Zig 0.13.0; explicit old-glibc imports, no CRT.

Zig's driver supplies versioned glibc import libraries. Relink the C objects
against those same libraries with ld.lld, omitting CRT/init/fini objects. This
avoids generated startup code on older e-reader dynamic loaders, while keeping
explicit libc/libm/librt DT_NEEDED dependencies (clock_gettime was in librt).
No stub or toolchain library is shipped in the plugin.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
TARGETS = {
    'kindle-softfp': ('arm-linux-gnueabi.2.12', 'softfp', 'armv7-softfp-glibc212'),
    'kobo-hf': ('arm-linux-gnueabihf.2.15', 'hard', 'armv7-hf-glibc215'),
    'pocketbook-softfp': ('arm-linux-gnueabi.2.5', 'softfp', 'armv7-softfp-glibc25'),
}
SOURCES = ['core.c', 'scan.c', 'shape.c', 'engine.c', 'store.c']

def run(args):
    p = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode:
        raise RuntimeError(shlex.join(map(str, args)) + '\n' + p.stdout + p.stderr)
    return p

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['all', *TARGETS], default='all')
    parser.add_argument('--build-dir', type=Path)
    args = parser.parse_args()
    zig = os.environ.get('ZIG')
    if not zig or run([zig, 'version']).stdout.strip() != '0.13.0':
        parser.error('Set ZIG to the verified Zig 0.13.0 executable')
    build = (args.build_dir or Path(tempfile.mkdtemp(prefix='tapless-multi-native-'))).resolve()
    build.mkdir(parents=True, exist_ok=True)
    manifest = {'zig': '0.13.0', 'cpu': 'cortex_a8', 'variants': []}
    names = TARGETS if args.target == 'all' else [args.target]
    for name in names:
        target, float_abi, variant = TARGETS[name]
        folder = build / name
        folder.mkdir(exist_ok=True)
        common = [zig, 'cc', '-target', target, '-mcpu=cortex_a8',
                  '-mfloat-abi=' + float_abi, '-O3', '-fPIC', '-fno-fast-math',
                  '-ffp-contract=off', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables']
        objects = []
        for source in SOURCES:
            obj = folder / (Path(source).stem + '.o')
            run([*common, '-c', str(ROOT / source), '-o', str(obj)])
            objects.append(str(obj))
        # Materialize the target/version-specific import libraries, using Zig's
        # own link command rather than guessing paths inside its cache.
        seed = run([zig, 'cc', '-target', target, '-mcpu=cortex_a8',
                    '-mfloat-abi=' + float_abi, '-shared', '-v', *objects,
                    '-lm', '-lrt', '-o', str(folder / 'driver-only.so')])
        (folder / 'driver-link.txt').write_text(seed.stdout + seed.stderr)
        links = [shlex.split(line) for line in seed.stderr.splitlines()
                 if line.startswith('ld.lld ') and ' -shared ' in line
                 and str(folder / 'driver-only.so') in line]
        if len(links) != 1:
            raise RuntimeError('Cannot identify Zig 0.13.0 shared linker command')
        imports = {}
        for value in links[0]:
            if Path(value).name in ('libc.so.6', 'libm.so.6', 'librt.so.1', 'libcompiler_rt.a'):
                imports[Path(value).name] = value
        if set(imports) != {'libc.so.6', 'libm.so.6', 'librt.so.1', 'libcompiler_rt.a'}:
            raise RuntimeError('Missing target import libraries')
        output = ROOT / ('libtapless-core-' + variant + '.so')
        temporary = folder / output.name
        command = [zig, 'ld.lld', '-shared', '-m', 'armelf_linux_eabi',
                   '--hash-style=sysv', '-z', 'now', '-z', 'max-page-size=4096',
                   '--no-undefined', '-soname', output.name, '-o', str(temporary),
                   *objects, '--as-needed', imports['libm.so.6'], imports['libc.so.6'],
                   imports['librt.so.1'], imports['libcompiler_rt.a']]
        run(command)
        (folder / 'final-link.json').write_text(json.dumps(command, indent=2) + '\n')
        # Atomic replacement also avoids modifying the inode of a mapped .so.
        staged = output.with_suffix('.so.new')
        staged.write_bytes(temporary.read_bytes())
        staged.chmod(0o755)
        staged.replace(output)
        item = {'name': name, 'file': output.name, 'target': target,
                'float_abi': float_abi, 'bytes': output.stat().st_size,
                'sha256': hashlib.sha256(output.read_bytes()).hexdigest()}
        manifest['variants'].append(item)
        print(json.dumps(item), flush=True)
    (build / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

if __name__ == '__main__':
    main()
