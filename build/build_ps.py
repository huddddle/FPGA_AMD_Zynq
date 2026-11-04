#!/usr/bin/env python3
"""Build ARM programs with the same compiler/sysroot as the supplied NCNN SDK."""
import argparse
from pathlib import Path
import subprocess
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", required=True, type=Path, help="Matching ARM Linux C++ compiler")
    parser.add_argument("--ncnn-dir", required=True, type=Path, help="NCNN installation containing include/ncnn and lib/libncnn.a")
    parser.add_argument("--build-dir", required=True, type=Path, help="Absolute output directory outside the repository")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    original = repo / "src/ps_software"
    if not args.build_dir.is_absolute():
        parser.error("--build-dir must be absolute")
    build = args.build_dir.resolve()
    if build == repo or repo in build.parents:
        parser.error("--build-dir must be outside the repository")
    compiler = args.compiler.resolve()
    ncnn = args.ncnn_dir.resolve()
    for required in [compiler, ncnn / "include/ncnn/net.h", ncnn / "lib/libncnn.a"]:
        if not required.is_file():
            parser.error(f"Missing build dependency: {required}")
    build.mkdir(parents=True, exist_ok=True)
    # The verified SDK 2018.3 Windows compiler needs an ASCII source path.
    # Preserve source bytes, includes and relative UAPI paths in the work area.
    mirror = build / "source"
    for part in ("app/native", "conv_accel/native", "loopback"):
        shutil.copytree(original / part, mirror / part, dirs_exist_ok=True)
    source = mirror / "app/native"
    flags = [str(compiler), "-O3", "-std=c++11", "-mcpu=cortex-a9", "-mfpu=neon", "-mfloat-abi=hard",
             "-D_FILE_OFFSET_BITS=64", "-static-libstdc++", "-static-libgcc",
             "-I", str(ncnn / "include/ncnn"), "-I", str(source / "third_party/stb")]
    accel = mirror / "conv_accel/native"
    flags += ["-I", str(accel), "-ffp-contract=off"]
    for name, entry in [("yolo26_detect", source / "yolo26_detect.cpp"),
                        ("detection_custom_test", source / "tests/detection_custom_test.cpp"),
                        ("y26-continuous30-check", accel / "continuous30_check.cpp")]:
        extra = [str(accel / n) for n in ("raw_frame.cpp", "two_layer.cpp", "channel_conv.cpp", "fusion.cpp", "tile_transport.cpp", "resident_prefix.cpp")] if name != "detection_custom_test" else []
        subprocess.run(flags + [str(entry), *extra, str(ncnn / "lib/libncnn.a"), "-lpthread", "-lm",
                                "-o", str(build / name)], check=True)
        print(f"Built {build / name}", flush=True)
    print("ARM binaries built; execute with a compatible target runtime or QEMU before deployment.")


if __name__ == "__main__":
    main()
