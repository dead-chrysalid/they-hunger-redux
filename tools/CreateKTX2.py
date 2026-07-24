# Copyright (c) 2021 Sultim Tsyrendashiev
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.


import argparse
import pathlib
import subprocess
import sys

# This project-level tool compiles content authoring sources during clean releases.
DEFAULT_INPUT_FOLDER_NAME = "mat_dev"
DEFAULT_OUTPUT_FOLDER_NAME = "mat"
DEFAULT_CACHE_FILE_NAME = "CreateKTX2Cache.txt"
INPUT_EXTENSIONS = {".tga", ".png", ".jpg", ".jpeg"}
OUTPUT_EXTENSION = ".ktx2"


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Compile RayTracedGL1 development textures to KTX2. "
            "Directory structure is preserved; normal maps ending in _n use BC5."
        )
    )
    parser.add_argument("--input", default=DEFAULT_INPUT_FOLDER_NAME)
    parser.add_argument("--output", default=DEFAULT_OUTPUT_FOLDER_NAME)
    parser.add_argument("--cache", default=DEFAULT_CACHE_FILE_NAME)
    parser.add_argument("--compressor", default="compressonatorcli.exe")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--encode-with", choices=("GPU", "CPU"), default="GPU")
    return parser.parse_args()


def read_cache(path):
    if not path.exists():
        return {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        if len(lines) % 2:
            return {}
        return {lines[index]: int(lines[index + 1]) for index in range(0, len(lines), 2)}
    except (OSError, ValueError):
        return {}


def write_cache(path, cache):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    lines = []
    for name in sorted(cache):
        lines.extend((name, str(cache[name])))
    temporary.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    temporary.replace(path)


def compression_format(source, relative):
    if source.stat().st_size < 25 * 1024:
        return "ARGB_8888"
    if relative.with_suffix("").name.lower().endswith("_n"):
        return "BC5"
    return "BC7"


def main():
    args = parse_args()
    input_root = pathlib.Path(args.input).resolve()
    output_root = pathlib.Path(args.output).resolve()
    cache_path = pathlib.Path(args.cache).resolve()
    if not input_root.is_dir():
        print(f"Texture input folder does not exist: {input_root}", file=sys.stderr)
        return 2

    cache = read_cache(cache_path)
    converted = 0
    failed = []
    sources = sorted(
        path
        for path in input_root.rglob("*")
        if path.is_file() and path.suffix.lower() in INPUT_EXTENSIONS
    )

    for source in sources:
        relative = source.relative_to(input_root)
        cache_key = relative.as_posix()
        modified = source.stat().st_mtime_ns
        output = output_root / relative.with_suffix(OUTPUT_EXTENSION)
        if not args.force and cache.get(cache_key) == modified and output.is_file():
            continue

        output.parent.mkdir(parents=True, exist_ok=True)
        format_name = compression_format(source, relative)
        print(f"> Converting {cache_key} ({format_name})")
        result = subprocess.run(
            [
                args.compressor,
                "-fd",
                format_name,
                "-miplevels",
                "20",
                "-EncodeWith",
                args.encode_with,
                str(source),
                str(output),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if result.returncode != 0 or not output.is_file():
            failed.append(cache_key)
            print(result.stdout, file=sys.stderr)
            continue

        cache[cache_key] = modified
        converted += 1

    write_cache(cache_path, cache)
    print(f"> KTX2 conversion complete: {converted} converted, {len(sources)} source files")
    if failed:
        print("Failed textures: " + ", ".join(failed), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
