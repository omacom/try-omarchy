/* Identical demux/hash work for software and the real Mac decoder bridge.
 * Build in the guest:
 * cc -O2 native-video-benchmark.c -lavformat -lavcodec -lavutil -lswscale -o video-benchmark
 * Run: video-benchmark software|hardware INPUT.mp4 [PORT]
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libavutil/sha.h>
#include <libavutil/time.h>
#include <libswscale/swscale.h>

#define MAX_PAYLOAD (64u * 1024 * 1024)
static unsigned frames;
static struct AVSHA *sha;
static uint8_t *pixels;
static size_t pixel_capacity;
static int width, height, hardware_confirmed;
static unsigned video_codec;
static enum AVPixelFormat output_format;
static struct SwsContext *scale;
static const char *frame_resource;
static uint8_t *shared_pixels;
static const size_t shared_size = 512u * 1024 * 1024;
static int frame_fd = -1;

static void die(const char *message) { fprintf(stderr, "%s\n", message); exit(1); }
static void check(int result) { if (result < 0) { char error[AV_ERROR_MAX_STRING_SIZE]; av_strerror(result, error, sizeof(error)); die(error); } }
static void io_all(int fd, void *buffer, size_t length, int sending) {
    uint8_t *cursor = buffer;
    while (length) {
        ssize_t count = sending ? write(fd, cursor, length) : read(fd, cursor, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) die("video transport closed");
        cursor += count; length -= count;
    }
}
static uint64_t get(const uint8_t *p, unsigned bytes) {
    uint64_t value = 0;
    for (unsigned i = 0; i < bytes; ++i) value |= (uint64_t)p[i] << (i * 8);
    return value;
}
static void put(uint8_t *p, uint64_t value, unsigned bytes) {
    for (unsigned i = 0; i < bytes; ++i) p[i] = value >> (i * 8);
}
static void reserve(size_t length) {
    if (length > MAX_PAYLOAD) die("oversized video frame");
    if (length > pixel_capacity) {
        uint8_t *new_pixels = realloc(pixels, length);
        if (!new_pixels) die("out of memory");
        pixels = new_pixels; pixel_capacity = length;
    }
}
static void hash(int64_t token, size_t length) {
    if (getenv("OMARCHY_VIDEO_BENCH_NO_HASH")) { ++frames; return; }
    uint8_t digest[32];
    av_sha_init(sha, 256);
    av_sha_update(sha, pixels, length);
    av_sha_final(sha, digest);
    printf("%" PRId64 " ", token);
    for (unsigned i = 0; i < 32; ++i) printf("%02x", digest[i]);
    putchar('\n');
    ++frames;
}
static void request(int fd, unsigned operation, int64_t token, const void *payload, size_t length) {
    if (length > MAX_PAYLOAD) die("oversized compressed packet");
    uint8_t header[40] = {0};
    memcpy(header, "TOVD", 4); put(header + 4, 1, 2); put(header + 6, operation, 2);
    put(header + 8, 1, 4); put(header + 12, length, 4); put(header + 16, token, 8);
    if (operation == 1) {
        if (frame_resource) put(header + 32, 1, 4);
        put(header + 24, video_codec, 4);
        if (video_codec) put(header + 28, (unsigned)width | ((unsigned)height << 16), 4);
    }
    io_all(fd, header, sizeof(header), 1);
    io_all(fd, (void *)payload, length, 1);
    for (;;) {
        io_all(fd, header, sizeof(header), 0);
        size_t size = get(header + 12, 4);
        unsigned op = get(header + 6, 2), flags = get(header + 32, 4);
        if (memcmp(header, "TOVD", 4) || get(header + 4, 2) != 1 || get(header + 8, 4) != 1 ||
            get(header + 36, 4) || size > MAX_PAYLOAD) die("invalid bridge response");
        reserve(size + (size < MAX_PAYLOAD));
        io_all(fd, pixels, size, 0);
        if (op == 0xffff) { fwrite(pixels, 1, size, stderr); die("\nbridge rejected request"); }
        if (op == 0x8100) {
            unsigned fmt = flags & 0xff;
            if (flags & 0x200) {
                if (!shared_pixels || size != 16) die("unexpected shared video frame");
                uint64_t offset = get(pixels, 8);
                size = get(pixels + 8, 4);
                if (get(pixels + 12, 4) || offset > shared_size || size > shared_size - offset) die("invalid shared frame bounds");
                reserve(size);
                memcpy(pixels, shared_pixels + offset, size);
            }
            if (get(header + 24, 4) != (unsigned)width || get(header + 28, 4) != (unsigned)height ||
                (fmt != 1 && fmt != 2) ||
                size != (size_t)width * height * 3 / 2 * (fmt == 2 ? 2 : 1)) die("invalid frame layout");
            hash((int64_t)get(header + 16, 8), size);
            if (flags & 0x200) {
                put(header + 6, 5, 2); put(header + 12, 0, 4);
                memset(header + 24, 0, 16);
                io_all(fd, header, sizeof(header), 1);
            }
        } else if (op == (operation | 0x8000)) {
            if (get(header + 16, 8) != (uint64_t)token || size) die("invalid bridge acknowledgement");
            if (op == 0x8001) {
                width = get(header + 24, 4); height = get(header + 28, 4);
                hardware_confirmed = !!(flags & 0x100);
                if (!hardware_confirmed) die("decoder did not confirm hardware use");
            }
            return;
        } else die("unexpected bridge response");
    }
}
static void software_frames(AVCodecContext *decoder, AVFrame *frame) {
    int status;
    while ((status = avcodec_receive_frame(decoder, frame)) >= 0) {
        width = frame->width; height = frame->height;
        enum AVPixelFormat fmt = output_format;
        int length = av_image_get_buffer_size(fmt, width, height, 1);
        check(length); reserve(length);
        uint8_t *planes[4]; int strides[4];
        check(av_image_fill_arrays(planes, strides, pixels, fmt, width, height, 1));
        scale = sws_getCachedContext(scale, width, height, frame->format, width, height, fmt,
                                     SWS_POINT, NULL, NULL, NULL);
        if (!scale) die("cannot create pixel converter");
        if (sws_scale(scale, (const uint8_t *const *)frame->data, frame->linesize, 0, height,
                      planes, strides) != height) die("incomplete pixel conversion");
        hash(frame->pts, length);
        av_frame_unref(frame);
    }
    if (status != AVERROR(EAGAIN) && status != AVERROR_EOF) check(status);
}
int main(int argc, char **argv) {
    if (argc < 3) die("usage: video-benchmark software|hardware INPUT [PORT]");
    int hardware = !strcmp(argv[1], "hardware");
    frame_resource = getenv("OMARCHY_VIDEO_RESOURCE");
    if (!hardware && strcmp(argv[1], "software")) die("invalid mode");
    AVFormatContext *input = NULL;
    AVDictionary *demux_options = NULL;
    av_dict_set(&demux_options, "ignore_editlist", "1", 0);
    check(avformat_open_input(&input, argv[2], NULL, &demux_options));
    av_dict_free(&demux_options);
    check(avformat_find_stream_info(input, NULL));
    int stream = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    check(stream);
    AVCodecParameters *parameters = input->streams[stream]->codecpar;
    width = parameters->width; height = parameters->height;
    if (parameters->codec_id == AV_CODEC_ID_HEVC) {
        if (parameters->extradata_size < 23 || parameters->extradata[0] != 1) die("HEVC requires hvcC");
        output_format = (parameters->extradata[17] & 7) ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
    } else if (parameters->codec_id == AV_CODEC_ID_AV1) {
        video_codec = 1;
        if (parameters->extradata_size < 4 || parameters->extradata[0] != 0x81) die("AV1 requires av1C");
        output_format = (parameters->extradata[2] & 0x40) ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
    } else die("benchmark requires HEVC or AV1");
    AVCodecContext *decoder = NULL;
    AVFrame *frame = av_frame_alloc(); AVPacket *packet = av_packet_alloc();
    sha = av_sha_alloc(); if (!frame || !packet || !sha) die("out of memory");
    int fd = -1;
    struct timespec cpu_start, cpu_end;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu_start);
    int64_t start = av_gettime_relative();
    if (hardware) {
        fd = open(argc > 3 ? argv[3] : "/dev/virtio-ports/dev.tryomarchy.video", O_RDWR | O_CLOEXEC);
        if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) < 0) die("cannot acquire video transport");
        if (frame_resource) {
            frame_fd = open(frame_resource, O_RDONLY | O_CLOEXEC);
            if (frame_fd < 0) die("cannot open video memory PCI resource");
            shared_pixels = mmap(NULL, shared_size, PROT_READ, MAP_SHARED, frame_fd, 0);
            if (shared_pixels == MAP_FAILED) die("cannot map video memory PCI resource");
        }
        request(fd, 1, 0, parameters->extradata, parameters->extradata_size);
    } else {
        const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
        decoder = avcodec_alloc_context3(codec);
        if (!decoder) die("out of memory");
        check(avcodec_parameters_to_context(decoder, parameters));
        decoder->thread_count = 4;
        check(avcodec_open2(decoder, codec, NULL));
    }
    unsigned packets = 0;
    int status;
    while ((status = av_read_frame(input, packet)) >= 0) {
        if (packet->stream_index == stream) {
            if (hardware) request(fd, 2, packet->pts, packet->data, packet->size);
            else { check(avcodec_send_packet(decoder, packet)); software_frames(decoder, frame); }
            ++packets;
        }
        av_packet_unref(packet);
    }
    if (status != AVERROR_EOF) check(status);
    if (hardware) { request(fd, 3, 0, NULL, 0); request(fd, 4, 0, NULL, 0); close(fd); }
    else { check(avcodec_send_packet(decoder, NULL)); software_frames(decoder, frame); }
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu_end);
    double seconds = (av_gettime_relative() - start) / 1000000.0;
    double cpu = cpu_end.tv_sec - cpu_start.tv_sec + (cpu_end.tv_nsec - cpu_start.tv_nsec) / 1e9;
    fprintf(stderr, "{\"mode\":\"%s\",\"hardware\":%s,\"packets\":%u,\"frames\":%u,"
                    "\"seconds\":%.6f,\"cpu_seconds\":%.6f,\"fps\":%.3f}\n",
            argv[1], hardware_confirmed ? "true" : "false", packets, frames, seconds, cpu, frames / seconds);
    avcodec_free_context(&decoder); av_frame_free(&frame); av_packet_free(&packet);
    avformat_close_input(&input); sws_freeContext(scale); av_free(sha); free(pixels);
    if (shared_pixels) munmap(shared_pixels, shared_size);
    if (frame_fd >= 0) close(frame_fd);
    return packets != frames;
}
