// Linux + running native-video VM integration test. Compare the host GPU path
// against the existing memory path for the same compressed HEVC/AV1 packets.
#include "../guest/video/driver.cpp"
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
}
#include <fcntl.h>
#include <gbm.h>
#include <libdrm/drm_fourcc.h>
#include <libdrm/virtgpu_drm.h>
#include <xf86drm.h>
#include <iostream>
#include <map>

static void check(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}
int main(int argc, char **argv) try {
    check(argc == 2, "usage: native-video-gpu INPUT.mp4");
    AVFormatContext *input = nullptr;
    check(avformat_open_input(&input, argv[1], nullptr, nullptr) >= 0 &&
          avformat_find_stream_info(input, nullptr) >= 0, "cannot open video");
    int stream = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    check(stream >= 0, "missing video stream");
    auto *codec = input->streams[stream]->codecpar;
    check(codec->codec_id == AV_CODEC_ID_HEVC || codec->codec_id == AV_CODEC_ID_AV1,
          "test supports HEVC and AV1");
    check(codec->extradata_size >= 23 || (codec->codec_id == AV_CODEC_ID_AV1 && codec->extradata_size >= 4),
          "missing codec configuration");
    bool ten_bit = codec->codec_id == AV_CODEC_ID_HEVC ? (codec->extradata[17] & 7) == 2 : codec->extradata[2] & 0x40;
    unsigned width = codec->width, height = codec->height, row_bytes = width * (ten_bit ? 2 : 1);
    int fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    check(fd >= 0, "cannot open render device");
    auto *device = gbm_create_device(fd);
    check(device != nullptr, "cannot create GBM device");
    gbm_bo *planes[2]{};
    Surface surface;
    surface.width = width;surface.height = height;
    surface.fourcc = ten_bit ? VA_FOURCC_P010 : VA_FOURCC_NV12;
    std::shared_ptr<Bytes> retained_image;
    uint32_t resources[2]{};
    for (unsigned p = 0; p < 2; ++p) {
        planes[p] = gbm_bo_create(device, width >> p, height >> p,
            ten_bit ? (p ? DRM_FORMAT_GR1616 : DRM_FORMAT_R16) : (p ? DRM_FORMAT_GR88 : DRM_FORMAT_R8),
            GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR);
        check(planes[p] != nullptr, "cannot allocate video texture");
        uint32_t pitch; void *cookie = nullptr;
        void *data = gbm_bo_map(planes[p], 0, 0, width >> p, height >> p, GBM_BO_TRANSFER_WRITE, &pitch, &cookie);
        check(data != nullptr, "cannot initialize video texture");
        memset(data, 0, size_t(pitch) * (height >> p));gbm_bo_unmap(planes[p], cookie);
        drm_virtgpu_resource_info info{};info.bo_handle = gbm_bo_get_handle(planes[p]).u32;
        check(drmIoctl(fd, DRM_IOCTL_VIRTGPU_RESOURCE_INFO, &info) == 0 && info.res_handle,
              "cannot resolve VirGL resource");
        resources[p] = info.res_handle;
        surface.planes[p] = planes[p];
        int exported = gbm_bo_get_fd(planes[p]);
        check(exported >= 0, "cannot export video texture");close(exported);
        drm_virtgpu_3d_wait wait{};wait.handle = info.bo_handle;
        check(drmIoctl(fd, DRM_IOCTL_VIRTGPU_WAIT, &wait) == 0, "cannot wait for texture initialization");
    }
    tovd::Client cpu, gpu;
    tovd::Message open;open.op = 1;open.flags = 1;
    open.arg0 = codec->codec_id == AV_CODEC_ID_HEVC ? 0 : 1;
    open.arg1 = open.arg0 ? width | (height << 16) : 0;
    open.payload.assign(codec->extradata, codec->extradata + codec->extradata_size);
    cpu.exchange(open, {});gpu.exchange(open, {});
    check(gpu.supports_gpu(), "host did not advertise GPU transfer");
    std::map<uint64_t, std::vector<uint8_t>> reference;
    unsigned compared = 0, copied_on_gpu = 0;
    auto expected = [&](const tovd::Message& m, const uint8_t *pixels, size_t size) {
        check(pixels && size == size_t(row_bytes) * height * 3 / 2, "invalid reference frame");
        reference[m.token] = {pixels, pixels + size};
    };
    auto actual = [&](const tovd::Message& m, const uint8_t *pixels, size_t size) {
        auto found = reference.find(m.token);check(found != reference.end(), "missing reference token");
        store_frame(surface, m, pixels, size);
        cache_surface(surface);
        check(*surface.pixels == found->second, "VA surface CPU cache differs from decoded pixels");
        if (compared == 5) retained_image = surface.pixels;
        if (retained_image) check(*retained_image == found->second, "retained VA image is stale");
        if (compared == 10) retained_image.reset();
        if (m.flags & tovd::gpu_flag) {
            check(pixels == nullptr && size == 0, "GPU frame unexpectedly contains CPU pixels");
            ++copied_on_gpu;
            for (unsigned p = 0; p < 2; ++p) {
                drm_virtgpu_3d_transfer_from_host transfer{};
                transfer.bo_handle = gbm_bo_get_handle(planes[p]).u32;
                transfer.box.w = width >> p; transfer.box.h = height >> p;transfer.box.d = 1;
                if (drmIoctl(fd, DRM_IOCTL_VIRTGPU_TRANSFER_FROM_HOST, &transfer) != 0) {
                    std::cerr << "readback errno=" << errno << ' ' << strerror(errno) << '\n';
                    throw std::runtime_error("cannot request GPU readback");
                }
                drm_virtgpu_3d_wait wait{};wait.handle = transfer.bo_handle;
                check(drmIoctl(fd, DRM_IOCTL_VIRTGPU_WAIT, &wait) == 0, "cannot wait for GPU readback");
                uint32_t pitch;void *cookie = nullptr;
                auto *data = static_cast<uint8_t *>(gbm_bo_map(planes[p], 0, 0, width >> p, height >> p,
                    GBM_BO_TRANSFER_READ, &pitch, &cookie));
                check(data != nullptr, "cannot read back imported texture");
                bool match = true;
                for (unsigned y = 0; y < (height >> p); ++y)
                    match &= !memcmp(data + size_t(y) * pitch,
                        found->second.data() + (p ? size_t(row_bytes) * height : 0) + size_t(y) * row_bytes, row_bytes);
                if (!match) {
                    for (unsigned x = 0; x < 16; ++x)
                        std::cerr << unsigned(data[x]) << '/' << unsigned(found->second[(p ? size_t(row_bytes) * height : 0) + x]) << ' ';
                    std::cerr << " plane=" << p << " frame=" << compared << '\n';
                }
                gbm_bo_unmap(planes[p], cookie);check(match, "GPU imported pixels differ from decoder output");
            }
        } else check(pixels && size == found->second.size() && !memcmp(pixels, found->second.data(), size),
                     "fallback pixels differ from decoder output");
        reference.erase(found);++compared;
    };
    AVPacket *packet = av_packet_alloc();uint64_t token = 0;
    while (compared < 60 && av_read_frame(input, packet) >= 0) {
        if (packet->stream_index == stream) {
            tovd::Message decode;decode.op = 2;decode.token = ++token;
            decode.payload.assign(packet->data, packet->data + packet->size);
            cpu.exchange(decode, expected);
            decode.flags = 4;decode.arg0 = resources[0];decode.arg1 = resources[1];
            gpu.exchange(decode, actual);
        }
        av_packet_unref(packet);
    }
    tovd::Message drain;drain.op = 3;cpu.exchange(drain, expected);gpu.exchange(drain, actual);
    check(reference.empty() && compared >= 30 && copied_on_gpu >= compared - 2, "GPU path was not exercised consistently");
    av_packet_free(&packet);avformat_close_input(&input);
    for (unsigned p = 0; p < 2; ++p) { surface.planes[p] = nullptr;gbm_bo_destroy(planes[p]); }
    gbm_device_destroy(device);close(fd);
    std::cout << "PASS: " << compared << " exact frames, " << copied_on_gpu << " via IOSurface GPU import, "
              << (ten_bit ? "10" : "8") << " bit\n";
    return 0;
} catch (const std::exception& e) { std::cerr << e.what() << '\n';return 1; }
