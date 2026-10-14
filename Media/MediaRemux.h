#ifndef DT_MEDIA_REMUX_H
#define DT_MEDIA_REMUX_H
/* demux is explicitly "hls", "mov", "matroska", "mpegts" or "aac". No network input. */
int DTMediaRemux(const char *input, const char *demux, const char *output, char *error, int capacity);
#endif
