"""Verify distributed bytes without third-party Python dependencies."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import sys


def main():
    root = Path(__file__).resolve().parent
    manifest = json.loads((root / 'MANIFEST.json').read_text(encoding='utf-8'))
    failures = []
    for item in manifest['files']:
        relative = PurePosixPath(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            failures.append([str(relative), 'invalid relative path'])
            continue
        file = root.joinpath(*relative.parts)
        if not file.is_file():
            failures.append([str(relative), 'missing'])
            continue
        if file.stat().st_size != item['bytes']:
            failures.append([str(relative), 'size mismatch'])
            continue
        digest = hashlib.sha256()
        with file.open('rb') as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b''):
                digest.update(block)
        if digest.hexdigest() != item['sha256']:
            failures.append([str(relative), 'SHA256 mismatch'])
    result = {'checked_files': len(manifest['files']), 'failures': failures,
              'passed': not failures}
    print(json.dumps(result, indent=2))
    return 0 if not failures else 1


if __name__ == '__main__':
    sys.exit(main())
