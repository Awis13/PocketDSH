#!/usr/bin/env python3
"""Package an already-built device app without macOS AppleDouble metadata."""
import argparse
import plistlib
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
app = args.app.resolve()
if not app.is_dir() or app.suffix != '.app':
    parser.error('Expected an existing device .app bundle')
with (app / 'Info.plist').open('rb') as source:
    info = plistlib.load(source)
if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
    parser.error('Build for an iOS device, not Simulator or Mac Catalyst')
args.output.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(args.output, 'w', ZIP_DEFLATED) as archive:
    for path in sorted(app.rglob('*')):
        if any(part.startswith('._') or part in ('.DS_Store', '__MACOSX') for part in path.parts):
            continue
        if path.is_symlink():
            parser.error(f'Unexpected symlink: {path.name}')
        if path.is_file():
            archive.write(path, Path('Payload') / app.name / path.relative_to(app))
with ZipFile(args.output) as archive:
    assert archive.testzip() is None, 'Archive integrity check failed'
print(f'Packaged {info["CFBundleDisplayName"] if "CFBundleDisplayName" in info else app.stem}: {args.output}')
