#!/usr/bin/env python3
"""Extract one slice of a NIfTI-1 volume into a tiny single-slice NIfTI.

The Settings window's live previews render bundled samples through MIQCore.
Shipping a whole MRI volume would add megabytes to the app and to the
repository, so each sample is cut down to the one slice the preview shows.

Usage:
    scripts/dev/make_settings_sample.py INPUT.nii[.gz] OUTPUT.nii.gz [--slice K] [--flip-rows] [--flip-cols]

K indexes the third *storage* axis (default: its centre), which is the axial
plane for an axially stored volume. Only volume 0 is kept, extensions are
dropped, and the qform/sform origins are shifted so the slice keeps its
position in world space. --flip-rows stores the rows in reverse order (with
the sform adjusted to match, and the qform cleared), so the sample's "As
Stored" view genuinely differs from the neurological and radiological ones.
--flip-cols does the same for the columns (both together: an LPS sample from
an RAS volume).
Check the result by pressing Space on it in Finder.

It also writes OUTPUT's window table (SampleX.nii.gz -> SampleX.window.json):
the exact intensity-window bounds Quick Look derives from the *full* volume's
three centre planes, for every percentile setting and orientation mode, so the
Settings preview of the single slice matches the real preview. That step runs
scripts/dev/settings_sample_window.swift against this repository's MIQCore.
Standard library only, so it runs without numpy/nibabel.
"""

import argparse
import gzip
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def write_window_table(volume_path, table_path):
    """Build settings_sample_window.swift as a throwaway package and run it."""
    package = tempfile.mkdtemp(prefix="miq-sample-window-")
    try:
        os.makedirs(os.path.join(package, "Sources", "SampleWindow"))
        shutil.copy(os.path.join(REPO, "scripts", "dev", "settings_sample_window.swift"),
                    os.path.join(package, "Sources", "SampleWindow", "main.swift"))
        with open(os.path.join(package, "Package.swift"), "w") as f:
            f.write(f"""// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "SampleWindow",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: {REPO!r})],
    targets: [.executableTarget(name: "SampleWindow",
                                dependencies: [.product(name: "MIQCore", package: {os.path.basename(REPO)!r})])]
)
""".replace("'", '"'))
        # Run from the temp dir with an explicit scratch path, so the toolchain
        # never scatters build products into the repository.
        subprocess.run(["swift", "run", "-c", "release", "--package-path", package,
                        "--scratch-path", os.path.join(tempfile.gettempdir(), "miq-sample-window-build"),
                        "SampleWindow", os.path.abspath(volume_path), os.path.abspath(table_path)],
                       cwd=package, check=True)
    finally:
        shutil.rmtree(package, ignore_errors=True)


def open_any(path, mode):
    return gzip.open(path, mode) if path.endswith(".gz") else open(path, mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input")
    parser.add_argument("output")
    parser.add_argument("--slice", type=int, help="index along the third storage axis (default: centre)")
    parser.add_argument("--flip-rows", action="store_true", help="store the rows in reverse order")
    parser.add_argument("--flip-cols", action="store_true", help="store the columns in reverse order")
    args = parser.parse_args()

    with open_any(args.input, "rb") as f:
        data = f.read()

    if struct.unpack("<i", data[:4])[0] == 348:
        e = "<"
    elif struct.unpack(">i", data[:4])[0] == 348:
        e = ">"
    else:
        sys.exit("Not a NIfTI-1 file (sizeof_hdr != 348).")

    hdr = bytearray(data[:348])
    dim = list(struct.unpack(e + "8h", hdr[40:56]))
    bitpix = struct.unpack(e + "h", hdr[72:74])[0]
    pixdim = list(struct.unpack(e + "8f", hdr[76:108]))
    vox_offset = int(struct.unpack(e + "f", hdr[108:112])[0])
    nx, ny, nz = dim[1], dim[2], max(dim[3], 1)

    k = nz // 2 if args.slice is None else args.slice
    if not 0 <= k < nz:
        sys.exit(f"--slice must be in 0..{nz - 1}")

    slice_bytes = nx * ny * bitpix // 8
    start = vox_offset + k * slice_bytes
    payload = data[start:start + slice_bytes]
    if len(payload) != slice_bytes:
        sys.exit("File appears truncated.")

    # Shift the sform origin by k steps along the third axis.
    if struct.unpack(e + "h", hdr[254:256])[0] > 0:
        for row in (280, 296, 312):
            srow = list(struct.unpack(e + "4f", hdr[row:row + 16]))
            srow[3] += k * srow[2]
            hdr[row:row + 16] = struct.pack(e + "4f", *srow)

    # Shift the qform origin the same way: the third rotation column, scaled.
    if struct.unpack(e + "h", hdr[252:254])[0] > 0:
        b, c, d = struct.unpack(e + "3f", hdr[256:268])
        a = math.sqrt(max(0.0, 1.0 - (b * b + c * c + d * d)))
        qfac = -1.0 if pixdim[0] < 0 else 1.0
        column = (2 * (b * d + a * c), 2 * (c * d - a * b), a * a + d * d - b * b - c * c)
        offsets = list(struct.unpack(e + "3f", hdr[268:280]))
        for i in range(3):
            offsets[i] += k * pixdim[3] * qfac * column[i]
        hdr[268:280] = struct.pack(e + "3f", *offsets)

    if args.flip_rows:
        if struct.unpack(e + "h", hdr[254:256])[0] <= 0:
            sys.exit("--flip-rows needs an sform (sform_code > 0).")
        row_bytes = nx * bitpix // 8
        payload = b"".join(payload[r * row_bytes:(r + 1) * row_bytes] for r in reversed(range(ny)))
        # Voxel row j now holds former row ny-1-j: negate the second column
        # and move the origin to the former last row.
        for row in (280, 296, 312):
            srow = list(struct.unpack(e + "4f", hdr[row:row + 16]))
            srow[3] += (ny - 1) * srow[1]
            srow[1] = -srow[1]
            hdr[row:row + 16] = struct.pack(e + "4f", *srow)
        hdr[252:254] = struct.pack(e + "h", 0)

    if args.flip_cols:
        if struct.unpack(e + "h", hdr[254:256])[0] <= 0:
            sys.exit("--flip-cols needs an sform (sform_code > 0).")
        vb = bitpix // 8
        rows = [payload[r * nx * vb:(r + 1) * nx * vb] for r in range(ny)]
        payload = b"".join(b"".join(row[i * vb:(i + 1) * vb] for i in reversed(range(nx))) for row in rows)
        # Voxel column i now holds former column nx-1-i: negate the first
        # column and move the origin to the former last column.
        for row in (280, 296, 312):
            srow = list(struct.unpack(e + "4f", hdr[row:row + 16]))
            srow[3] += (nx - 1) * srow[0]
            srow[0] = -srow[0]
            hdr[row:row + 16] = struct.pack(e + "4f", *srow)
        hdr[252:254] = struct.pack(e + "h", 0)

    dim[0], dim[3], dim[4] = 3, 1, 1
    hdr[40:56] = struct.pack(e + "8h", *dim)
    hdr[108:112] = struct.pack(e + "f", 352.0)

    with gzip.open(args.output, "wb") as f:
        f.write(bytes(hdr) + b"\x00\x00\x00\x00" + payload)

    print(f"Wrote slice {k} of {nz} ({nx}x{ny}) to {args.output}")

    stem = args.output[:-len(".nii.gz")] if args.output.endswith(".nii.gz") else os.path.splitext(args.output)[0]
    write_window_table(args.input, stem + ".window.json")


if __name__ == "__main__":
    main()
