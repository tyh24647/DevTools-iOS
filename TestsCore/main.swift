import Foundation

let base = URL(string: "https://example.com/path/index.m3u8?token=secret")!
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ description: String) {
    precondition(value(), description)
    checks += 1
}
func rejected(_ text: String) {
    do {
        _ = try HLSPlaylist.parse(text, base: base)
        fatalError("Expected playlist rejection")
    } catch { checks += 1 }
}
let master = try HLSPlaylist.parse("""
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English, Main",DEFAULT=YES,URI="audio/list.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,AUDIO="a"
video/list.m3u8
""", base: base)
check(master.variants[0].height == 1080, "resolution")
check(master.audio["a"]?.path == "/path/audio/list.m3u8", "relative audio")
let playlist = try HLSPlaylist.parse("""
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:42
#EXT-X-KEY:METHOD=AES-128,URI="key",IV=0x01
#EXT-X-MAP:URI="init.mp4",BYTERANGE="50@10"
#EXTINF:5.5,
#EXT-X-BYTERANGE:100@50
stream.mp4
#EXT-X-DISCONTINUITY
#EXTINF:6,
#EXT-X-BYTERANGE:100
stream.mp4
#EXT-X-KEY:METHOD=NONE
#EXTINF:2,
third.ts
#EXT-X-ENDLIST
""", base: base)
check(playlist.ended, "endlist")
check(playlist.segments.map(\.sequence) == [42, 43, 44], "sequence")
check(playlist.segments[1].range?.offset == 150, "implicit range")
check(playlist.segments[1].discontinuity, "discontinuity")
check(playlist.segments[0].initialization?.range?.offset == 10, "init range")
check(playlist.segments[0].key?.iv == "0x01", "AES key")
check(playlist.segments[2].key == nil, "key reset")
check(!playlist.segments[2].discontinuity, "discontinuity reset")
rejected("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n")
rejected("#EXTM3U\n#EXTINF:1,\nfile:///etc/passwd\n")
rejected("#EXTM3U\n#EXTINF:1,\nhttps://user:pass@example.com/a\n")
rejected("#EXTM3U\n#EXTINF:nan,\na.ts\n")
rejected("#EXTM3U\n#EXTINF:1,\n#EXT-X-BYTERANGE:10\na.ts\n")
rejected("#EXTM3U\n#EXTINF:1,\n#EXT-X-BYTERANGE:100@9223372036854775807\na.ts\n")
rejected("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:9223372036854775807\n#EXTINF:1,\na.ts\n")
let live = try HLSPlaylist.parse("#EXTM3U\n#EXTINF:1,\na.ts\n", base: base)
check(!live.ended, "unknown duration live")
print("HLS parser: \(checks) checks passed")
