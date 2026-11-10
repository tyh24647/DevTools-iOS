#!/usr/bin/env python3
"""Check local-media boundaries and run real file/conversion/cache helpers on macOS.

Use --check-source for the platform-independent boundary checks. The default also
compiles the actual app implementations with Swift Testing on macOS; it does not
replace their file-management logic with a test-only host.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check-source', action='store_true', help='Run source boundary checks without the Apple SDK test suite.')
arguments = parser.parse_args()

sources = {
    name: (root / 'Media' / name).read_text()
    for name in ['MediaModels.swift', 'MediaLibrary.swift', 'MediaExporter.swift', 'DownloadsView.swift', 'MediaHTTP.swift']
}
local_sources = '\n'.join(sources[name] for name in sources if name != 'MediaHTTP.swift')
for obsolete in ['PageMedia', 'MediaChoice', 'MediaTransfer', 'RecordingCheckpoint', 'HLSRecorder',
                 'HLSPlaylist', 'blobMessage', 'recoverInterrupted', 'retryRecovery', 'DTMediaRemux', 'SaveMediaView']:
    assert obsolete not in local_sources, f'Obsolete media acquisition entry point: {obsolete}'
for network_api in ['URLSession', 'MediaHTTP', 'WKWebView', 'URLRequest']:
    assert network_api not in local_sources, f'Network API in the local media layer: {network_api}'
for deleted in ['HLSRecorder.swift', 'HLSPlaylist.swift', 'MediaRemux.c', 'MediaRemux.h']:
    assert not (root / 'Media' / deleted).exists(), f'Obsolete acquisition source remains: {deleted}'
assert 'guard source.isFileURL, destination.isFileURL else' in sources['MediaExporter.swift']
assert 'AVURLAssetReferenceRestrictionsKey: NSNumber(value: AVAssetReferenceRestrictions.forbidAll.rawValue)' in sources['MediaExporter.swift']
assert local_sources.count('AVURLAsset(url:') == 1, 'All local assets must use the restricted asset factory.'
assert 'AVPlayer(url:' not in local_sources
assert 'startAccessingSecurityScopedResource()' in sources['MediaModels.swift']
assert 'stopAccessingSecurityScopedResource()' in sources['MediaModels.swift']
assert 'NSFileCoordinator().coordinate(readingItemAt:' in sources['MediaModels.swift']
assert 'input.read(upToCount: chunkSize)' in sources['MediaModels.swift']
assert 'Data(contentsOf: source)' not in sources['MediaModels.swift']
assert '.fileImporter(' in sources['DownloadsView.swift']
assert 'Import from Files' in sources['DownloadsView.swift']
assert 'Convert a copy' in sources['DownloadsView.swift']
assert 'func data(' in sources['MediaHTTP.swift'], 'Userscript URL importing must stay available.'
assert 'private func download(' in sources['MediaHTTP.swift']
assert 'func playlist(' not in sources['MediaHTTP.swift']
print('Local media source boundaries: passed', flush=True)

if arguments.check_source:
    sys.exit(0)
if sys.platform != 'darwin' or shutil.which('swift') is None:
    sys.exit('File, conversion, and thumbnail execution tests require macOS with Swift and Apple SDKs. Run --check-source here; run the full command in macOS CI.')

with tempfile.TemporaryDirectory(prefix='devtools-local-media-tests-') as temporary:
    package = Path(temporary)
    source = package / 'Sources/DownloadsCore'
    tests = package / 'Tests/DownloadsCoreTests'
    source.mkdir(parents=True)
    tests.mkdir(parents=True)
    (package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DownloadsCore", platforms: [.macOS(.v14)], targets: [
    .target(name: "DownloadsCore"), .testTarget(name: "DownloadsCoreTests", dependencies: ["DownloadsCore"])
], swiftLanguageModes: [.v5])
''')
    for name in ['MediaModels.swift', 'MediaLibrary.swift', 'MediaExporter.swift']:
        (source / name).write_text(sources[name])
    (tests / 'DownloadsTests.swift').write_text((root / 'Tests/DownloadsTests.swift').read_text())
    subprocess.run(['swift', 'test', '--package-path', str(package)], check=True)
