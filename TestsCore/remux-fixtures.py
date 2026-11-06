#!/usr/bin/env python3
"""Exercise the app's C remuxer with stopped TS/fMP4, separate audio, and truncated tail.
Usage: python3 TestsCore/remux-fixtures.py /path/to/remux.so
Build with host FFmpeg development headers/libraries; this does not test Apple encoding.
"""
import ctypes
import json
from pathlib import Path
import subprocess
import sys
import tempfile

lib = ctypes.CDLL(str(Path(sys.argv[1]).resolve()))
lib.DTMediaRemux.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]

def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

def remux(folder, manifest, expected_min, expected_max):
    output = folder / (manifest.stem + '-out.mp4')
    error = ctypes.create_string_buffer(1024)
    result = lib.DTMediaRemux(str(manifest).encode(), b'hls', str(output).encode(), error, len(error))
    assert result >= 0, error.value
    info = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(output)]))
    duration = float(info['format']['duration'])
    assert expected_min <= duration <= expected_max, (manifest.name, duration)
    assert any(s['codec_type'] == 'video' for s in info['streams'])
    run('ffmpeg', '-v', 'error', '-i', str(output), '-f', 'null', '-')
    return info

with tempfile.TemporaryDirectory(prefix='devtools-media-tests-') as temp:
    root = Path(temp)
    for kind in ['mpegts', 'fmp4']:
        folder = root / kind
        folder.mkdir()
        manifest = folder / 'full.m3u8'
        run('ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=160x90:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-g', '48', '-c:a', 'aac', '-f', 'hls', '-hls_time', '2', '-hls_list_size', '0', '-hls_segment_type', kind, str(manifest))
        text = manifest.read_text()
        lines = text.splitlines()
        segment_indexes = [i for i, line in enumerate(lines) if line and not line.startswith('#')]
        partial = folder / 'stopped.m3u8'
        partial.write_text('\n'.join(lines[:segment_indexes[1] + 1]) + '\n#EXT-X-ENDLIST\n')
        info = remux(folder, partial, 3.8, 4.3)
        assert any(s['codec_type'] == 'audio' for s in info['streams'])
        remux(folder, manifest, 5.8, 6.3)
        # A complete earlier prefix survives a torn final segment.
        last = folder / lines[segment_indexes[-1]]
        data = last.read_bytes()
        last.write_bytes(data[:len(data)//2])
        remux(folder, manifest, 3.8, 6.3)
    # Native-generated master playlist joins independently captured video/audio.
    folder = root / 'separate'
    folder.mkdir()
    for name, source, codec in [('video', 'testsrc2=size=160x90:rate=24', ['-c:v','libx264','-preset','ultrafast','-g','48']), ('audio', 'sine=frequency=440:sample_rate=48000', ['-c:a','aac'])]:
        run('ffmpeg','-v','error','-f','lavfi','-i',source,'-t','6',*codec,'-f','hls','-hls_time','2','-hls_list_size','0',str(folder / (name + '.m3u8')))
    master = folder / 'master.m3u8'
    master.write_text('#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=10000000,AUDIO="audio"\nvideo.m3u8\n')
    info = remux(folder, master, 5.8, 6.5)
    assert len(info['streams']) == 2
print('Native remux: 7 fixtures passed (TS, fMP4, stopped prefixes, torn tails, separate audio)')
