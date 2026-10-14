#include "MediaRemux.h"
#if defined(__APPLE__)
#include <AetherLibavformat/avformat.h>
#include <AetherLibavcodec/avcodec.h>
#include <AetherLibavutil/avutil.h>
#include <AetherLibavutil/mathematics.h>
#else
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/mathematics.h>
#endif
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

/* Remux complete local captures; normalize timestamps across HLS discontinuities without
   claiming that concatenating segment bytes alone creates a finished MP4 container. */
int DTMediaRemux(const char *input, const char *demux, const char *output, char *error, int capacity) {
    AVFormatContext *source = NULL, *destination = NULL;
    AVPacket *packet = NULL;
    AVDictionary *options = NULL;
    int *mapping = NULL;
    int64_t *last = NULL, *shift = NULL;
    int result = 0, header = 0, samples = 0;
    int64_t origin = AV_NOPTS_VALUE;
    const AVInputFormat *format = av_find_input_format(demux);
    if (!format || !(strcmp(demux, "hls") == 0 || strcmp(demux, "mov") == 0 ||
                     strcmp(demux, "matroska") == 0 || strcmp(demux, "mpegts") == 0 || strcmp(demux, "aac") == 0)) {
        result = AVERROR(EINVAL);
        goto cleanup;
    }
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    av_dict_set(&options, "allowed_extensions", "ALL", 0);
    result = avformat_open_input(&source, input, format, &options);
    av_dict_free(&options);
    if (result < 0) {
        goto cleanup;
    }
    result = avformat_find_stream_info(source, NULL);
    if (result < 0) {
        goto cleanup;
    }
    result = avformat_alloc_output_context2(&destination, NULL, "mp4", output);
    if (result < 0 || !destination) {
        if (result >= 0) { result = AVERROR(ENOMEM); }
        goto cleanup;
    }
    mapping = calloc(source->nb_streams, sizeof(int));
    last = calloc(source->nb_streams, sizeof(int64_t));
    shift = calloc(source->nb_streams, sizeof(int64_t));
    if (!mapping || !last || !shift) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    for (unsigned i = 0; i < source->nb_streams; i++) {
        AVStream *in = source->streams[i];
        mapping[i] = -1;
        last[i] = AV_NOPTS_VALUE;
        if (in->codecpar->codec_type != AVMEDIA_TYPE_AUDIO && in->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) {
            continue;
        }
        AVStream *out = avformat_new_stream(destination, NULL);
        if (!out) {
            result = AVERROR(ENOMEM);
            goto cleanup;
        }
        mapping[i] = out->index;
        result = avcodec_parameters_copy(out->codecpar, in->codecpar);
        if (result < 0) {
            goto cleanup;
        }
        out->codecpar->codec_tag = 0;
        out->time_base = in->time_base;
        if (in->start_time != AV_NOPTS_VALUE) {
            int64_t start = av_rescale_q(in->start_time, in->time_base, AV_TIME_BASE_Q);
            origin = origin == AV_NOPTS_VALUE ? start : (start < origin ? start : origin);
        }
    }
    if (!destination->nb_streams) {
        result = AVERROR_STREAM_NOT_FOUND;
        goto cleanup;
    }
    result = avio_open(&destination->pb, output, AVIO_FLAG_WRITE);
    if (result < 0) {
        goto cleanup;
    }
    av_dict_set(&options, "movflags", "+faststart", 0);
    result = avformat_write_header(destination, &options);
    av_dict_free(&options);
    if (result < 0) {
        goto cleanup;
    }
    header = 1;
    packet = av_packet_alloc();
    if (!packet) {
        result = AVERROR(ENOMEM);
        goto cleanup;
    }
    while ((result = av_read_frame(source, packet)) >= 0) {
        unsigned index = packet->stream_index;
        if (index >= source->nb_streams || mapping[index] < 0 || (packet->flags & AV_PKT_FLAG_CORRUPT)) {
            av_packet_unref(packet);
            continue;
        }
        AVStream *in = source->streams[index], *out = destination->streams[mapping[index]];
        if (origin == AV_NOPTS_VALUE && packet->dts != AV_NOPTS_VALUE) {
            origin = av_rescale_q(packet->dts, in->time_base, AV_TIME_BASE_Q);
        }
        int64_t base = origin == AV_NOPTS_VALUE ? 0 : av_rescale_q(origin, AV_TIME_BASE_Q, in->time_base);
        if (packet->dts != AV_NOPTS_VALUE) {
            packet->dts -= base;
        }
        if (packet->pts != AV_NOPTS_VALUE) {
            packet->pts -= base;
        }
        av_packet_rescale_ts(packet, in->time_base, out->time_base);
        if (packet->dts != AV_NOPTS_VALUE) {
            packet->dts += shift[index];
            if (last[index] != AV_NOPTS_VALUE && packet->dts <= last[index]) {
                int64_t correction = last[index] + (packet->duration > 0 ? packet->duration : 1) - packet->dts;
                shift[index] += correction;
                packet->dts += correction;
            }
            last[index] = packet->dts;
        }
        if (packet->pts != AV_NOPTS_VALUE) {
            packet->pts += shift[index];
        }
        packet->pos = -1;
        packet->stream_index = mapping[index];
        result = av_interleaved_write_frame(destination, packet);
        av_packet_unref(packet);
        if (result < 0) {
            goto cleanup;
        }
        samples++;
    }
    /* A truncated final fragment can still yield a valid partial movie. Prior packets
       are retained; the trailer closes the container. Zero-sample outputs are rejected. */
    result = samples > 0 ? av_write_trailer(destination) : AVERROR_INVALIDDATA;
    header = 0;
cleanup:
    if (header && destination) {
        av_write_trailer(destination);
    }
    if (result < 0 && error && capacity > 0) {
        av_strerror(result, error, (size_t)capacity);
    }
    av_packet_free(&packet);
    free(mapping);
    free(last);
    free(shift);
    av_dict_free(&options);
    avformat_close_input(&source);
    if (destination) {
        if (destination->pb) {
            avio_closep(&destination->pb);
        }
        avformat_free_context(destination);
    }
    if (result < 0) {
        remove(output);
    }
    return result;
}
