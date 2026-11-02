#!/usr/bin/env python3
"""Run the app's Foundation file operations and thumbnail cache with Swift Testing on macOS.

UIKit views and FFmpeg remuxing require iOS validation. This harness extracts the
unchanged helper implementations into a temporary package; only app ownership and
transfer observation are replaced by minimal test hosts.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='devtools-download-tests-') as temporary:
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
    library = (root / 'Media/MediaLibrary.swift').read_text()
    exporter = (root / 'Media/MediaExporter.swift').read_text()
    models = (root / 'Media/MediaModels.swift').read_text()
    playlist = (root / 'Media/HLSPlaylist.swift').read_text()
    helpers = library[library.index('    func directory('):library.index('    func choices(')]
    cache = exporter[exporter.index('actor MediaThumbnailCache {'):exporter.index('    func segmentThumbnail(')] + '}\n'
    validator = exporter[exporter.index('    static func validateName('):exporter.index('// Thumbnails live')].strip()
    settings = models[models.index('struct MediaSettings:'):models.index('struct PageMedia:')]
    segment = models[models.index('struct CapturedSegment:'):models.index('struct RecordingCheckpoint:')]
    failure = playlist[playlist.index('enum MediaFailure:'):]
    (source / 'DownloadsCore.swift').write_text('''import Foundation
import AVFoundation
import CryptoKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
''' + settings + segment + failure + '\nenum MediaExporter {\n' + validator + '''
@MainActor final class MediaTransfer {
    var settings = MediaSettings()
    var outputs: [URL] = []
    var finished = false
}
@MainActor final class MediaLibrary {
    let root: URL
    var settings = MediaSettings()
    var transfers: [MediaTransfer] = []
    var revision = 0
    init(root: URL) { self.root = root }
''' + helpers + '}\n' + cache)
    (tests / 'DownloadsTests.swift').write_text((root / 'Tests/DownloadsTests.swift').read_text())
    subprocess.run(['swift', 'test', '--package-path', str(package)], check=True)
