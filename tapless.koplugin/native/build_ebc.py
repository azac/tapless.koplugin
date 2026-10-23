"""Rebuild the ARM32 EBC pixel helper and its Android UI-thread input helper."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile


def run(command):
    subprocess.run([str(arg) for arg in command], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ndk", default=os.environ.get("ANDROID_NDK_HOME"))
    parser.add_argument("--d8", default=os.environ.get("D8", "d8"))
    parser.add_argument("--javac", default=os.environ.get("JAVAC", "javac"))
    options = parser.parse_args()
    if not options.ndk:
        parser.error("Set ANDROID_NDK_HOME or pass --ndk (NDK r23c).")
    root = Path(__file__).resolve().parent
    compilers = list((Path(options.ndk) / "toolchains/llvm/prebuilt").glob(
        "*/bin/armv7a-linux-androideabi27-clang"))
    if len(compilers) != 1:
        parser.error("Expected one host-compatible API27 ARM compiler in the NDK.")
    with tempfile.TemporaryDirectory(prefix="tapless-ebc-") as folder:
        build = Path(folder)
        library = build / "pixels.so"
        run([compilers[0], "-O3", "-shared", "-fPIC", "-fno-fast-math",
             "-ffp-contract=off", "-Wall", "-Wextra", "-Werror",
             "-Wl,--no-undefined", "-Wl,-z,relro", "-Wl,-z,now",
             "-Wl,-z,noexecstack", "-Wl,-z,max-page-size=16384",
             root / "trace_pixels.c", "-o", library])
        content = library.read_bytes()
        digest = hashlib.sha256(content).hexdigest()
        name = "libtapless-trace-pixels-" + digest[:16] + ".so"
        (root / name).write_bytes(content)
        classes, dex = build / "classes", build / "dex"
        classes.mkdir()
        dex.mkdir()
        run([options.javac, "-source", "8", "-target", "8", "-d", classes,
             root / "UnbufferedProbe.java"])
        run([options.d8, "--min-api", "27", "--output", dex,
             *sorted(classes.rglob("*.class"))])
        jar = root / "ebc-input.jar"
        with zipfile.ZipFile(jar, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.write(dex / "classes.dex", "classes.dex")
        jar_digest = hashlib.sha256(jar.read_bytes()).hexdigest()
        (root.parent / "ebc_assets.lua").write_text(
            "return {\n"
            f'    name = "{name}",\n'
            f'    library = "native/{name}",\n'
            f'    sha256 = "{digest}",\n'
            '    input_jar = "native/ebc-input.jar",\n'
            f'    input_sha256 = "{jar_digest}",\n'
            "}\n", encoding="ascii")
        print(name)
        print(jar.name)


if __name__ == "__main__":
    main()
