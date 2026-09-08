// VA-API frontend for Try Omarchy's Mac media-engine bridge.
#include "client.hpp"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <gbm.h>
#include <libdrm/drm_fourcc.h>
#include <libdrm/virtgpu_drm.h>
#include <xf86drm.h>
#include <limits>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_drmcommon.h>
#include <va/va_dec_hevc.h>
#include <va/va_dec_vp9.h>

namespace {
using Bytes = std::vector<uint8_t>;
struct Config { VAProfile profile; };
struct Buffer {
    VABufferType type;
    unsigned size, count;
    std::shared_ptr<Bytes> bytes;
};
struct Surface {
    unsigned width, height, fourcc;
    bool ready = false, dirty = true, submitted = false, cache_valid = true;
    bool host_written = false;
    std::shared_ptr<Bytes> pixels;
    gbm_bo *planes[2]{};
    uint32_t gpu_resources[2]{};
    ~Surface() { for (auto *plane : planes) if (plane) gbm_bo_destroy(plane); }
    unsigned stride() const { return width * (fourcc == VA_FOURCC_P010 ? 2 : 1); }
    size_t size() const { return size_t(stride()) * height * 3 / 2; }
    void allocate() { if (!pixels) pixels = std::make_shared<Bytes>(size()); }
};
struct Context {
    VAProfile profile;
    unsigned width, height;
    VASurfaceID target = VA_INVALID_SURFACE;
    VADecPictureParameterBufferAV1 av1{};
    VAPictureParameterBufferHEVC hevc{};
    VADecPictureParameterBufferVP9 vp9{};
    bool picture = false;
    std::vector<VASliceParameterBufferAV1> slices;
    std::vector<VASliceParameterBufferHEVC> hevc_slices;
    Bytes data, sequence;
    std::unique_ptr<tovd::Client> client;
};
struct Driver {
    std::recursive_mutex mutex;
    uint32_t next = 1;
    gbm_device *gbm = nullptr;
    std::unordered_map<uint32_t, Config> configs;
    std::unordered_map<uint32_t, Buffer> buffers;
    std::unordered_map<uint32_t, std::unique_ptr<Surface>> surfaces;
    std::unordered_map<uint32_t, std::unique_ptr<Context>> contexts;
    std::unordered_map<uint32_t, VAImage> images;
    ~Driver() { contexts.clear(); surfaces.clear(); if (gbm) gbm_device_destroy(gbm); }
    uint32_t id() {
        if (next == VA_INVALID_ID) throw std::runtime_error("video object identifier space exhausted");
        return next++;
    }
};

bool logging() { return getenv("OMARCHY_VIDEO_LOG") != nullptr; }
template<auto F> struct Guard;
template<typename... A, VAStatus (*F)(VADriverContextP, A...)>
struct Guard<F> {
    static VAStatus call(VADriverContextP ctx, A... args) noexcept {
        try {
            if (!ctx || !ctx->pDriverData) return VA_STATUS_ERROR_INVALID_DISPLAY;
            auto *driver = static_cast<Driver *>(ctx->pDriverData);
            std::lock_guard<std::recursive_mutex> lock(driver->mutex);
            return F(ctx, args...);
        } catch (const std::bad_alloc&) { return VA_STATUS_ERROR_ALLOCATION_FAILED; }
        catch (const std::exception& error) {
            if (logging()) fprintf(stderr, "[omarchy-vaapi] %s\n", error.what());
            return VA_STATUS_ERROR_OPERATION_FAILED;
        }
    }
};
Driver& drv(VADriverContextP ctx) { return *static_cast<Driver *>(ctx->pDriverData); }
Surface& surface(VADriverContextP ctx, uint32_t id) { return *drv(ctx).surfaces.at(id); }
Context& context(VADriverContextP ctx, uint32_t id) { return *drv(ctx).contexts.at(id); }

VAStatus terminate(VADriverContextP ctx) {
    delete static_cast<Driver *>(ctx->pDriverData);
    ctx->pDriverData = nullptr;
    return VA_STATUS_SUCCESS;
}
bool supported(VAProfile profile) {
    if (getenv("OMARCHY_VIDEO_VP9_ONLY"))
        return profile == VAProfileVP9Profile0 || profile == VAProfileVP9Profile2;
    return profile == VAProfileAV1Profile0 || profile == VAProfileHEVCMain || profile == VAProfileHEVCMain10 ||
           profile == VAProfileVP9Profile0 || profile == VAProfileVP9Profile2;
}
VAStatus profiles(VADriverContextP, VAProfile *out, int *count) {
    if (!out || !count) return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (getenv("OMARCHY_VIDEO_VP9_ONLY")) {
        out[0] = VAProfileVP9Profile0; out[1] = VAProfileVP9Profile2;
        *count = 2; return VA_STATUS_SUCCESS;
    }
    out[0] = VAProfileAV1Profile0; out[1] = VAProfileHEVCMain; out[2] = VAProfileHEVCMain10;
    out[3] = VAProfileVP9Profile0; out[4] = VAProfileVP9Profile2;
    *count = 5; return VA_STATUS_SUCCESS;
}
VAStatus entrypoints(VADriverContextP, VAProfile profile, VAEntrypoint *out, int *count) {
    if (!out || !count) return VA_STATUS_ERROR_INVALID_PARAMETER;
    *count = 0;
    if (!supported(profile)) return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    out[0] = VAEntrypointVLD; *count = 1; return VA_STATUS_SUCCESS;
}
VAStatus get_attributes(VADriverContextP, VAProfile profile, VAEntrypoint entry,
                        VAConfigAttrib *out, int count) {
    if (!supported(profile)) return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    if (entry != VAEntrypointVLD) return VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT;
    if (count < 0 || (count && !out)) return VA_STATUS_ERROR_INVALID_PARAMETER;
    for (int i = 0; i < count; ++i) {
        switch (out[i].type) {
        case VAConfigAttribRTFormat: out[i].value = VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10; break;
        case VAConfigAttribMaxPictureWidth: out[i].value = 8192; break;
        case VAConfigAttribMaxPictureHeight: out[i].value = 4320; break;
        case VAConfigAttribDecAV1Features: out[i].value = 0; break;
        case VAConfigAttribDecSliceMode: out[i].value = VA_DEC_SLICE_MODE_NORMAL; break;
        default: out[i].value = VA_ATTRIB_NOT_SUPPORTED; break;
        }
    }
    return VA_STATUS_SUCCESS;
}
VAStatus create_config(VADriverContextP ctx, VAProfile profile, VAEntrypoint entry,
                       VAConfigAttrib *attributes, int count, VAConfigID *out) {
    if (!out || count < 0 || (count && !attributes)) return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (!supported(profile)) return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    if (entry != VAEntrypointVLD) return VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT;
    if (drv(ctx).configs.size() >= 16) return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    for (int i = 0; i < count; ++i) {
        if (attributes[i].type == VAConfigAttribRTFormat &&
            (attributes[i].value & ~(VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10)))
            return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
    }
    *out = drv(ctx).id(); drv(ctx).configs.emplace(*out, Config{profile}); return VA_STATUS_SUCCESS;
}
VAStatus destroy_config(VADriverContextP ctx, VAConfigID id) {
    return drv(ctx).configs.erase(id) ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_CONFIG;
}
VAStatus query_config(VADriverContextP ctx, VAConfigID id, VAProfile *profile, VAEntrypoint *entry,
                      VAConfigAttrib *attributes, int *count) {
    auto found = drv(ctx).configs.find(id);
    if (found == drv(ctx).configs.end()) return VA_STATUS_ERROR_INVALID_CONFIG;
    if (!profile || !entry || !count || !attributes) return VA_STATUS_ERROR_INVALID_PARAMETER;
    *profile = found->second.profile; *entry = VAEntrypointVLD; *count = 1;
    attributes[0] = {VAConfigAttribRTFormat, VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10};
    return VA_STATUS_SUCCESS;
}

bool dimensions(unsigned width, unsigned height) {
    return width && height && width <= 8192 && height <= 4352 && !(width & 1) && !(height & 1);
}
VAStatus create_surfaces2(VADriverContextP ctx, unsigned format, unsigned width, unsigned height,
                          VASurfaceID *out, unsigned count, VASurfaceAttrib *attributes, unsigned num_attributes) {
    if (!out || !count || !dimensions(width, height) || (num_attributes && !attributes))
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (count > 128 || drv(ctx).surfaces.size() + count > 128) return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    unsigned fourcc;
    if (format == VA_RT_FORMAT_YUV420) fourcc = VA_FOURCC_NV12;
    else if (format == VA_RT_FORMAT_YUV420_10) fourcc = VA_FOURCC_P010;
    else return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
    for (unsigned i = 0; i < num_attributes; ++i) {
        const auto& a = attributes[i];
        if (a.type == VASurfaceAttribPixelFormat && a.value.type == VAGenericValueTypeInteger) fourcc = a.value.value.i;
        if (a.type == VASurfaceAttribMemoryType && a.value.value.i != VA_SURFACE_ATTRIB_MEM_TYPE_VA)
            return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
    }
    if (fourcc != VA_FOURCC_NV12 && fourcc != VA_FOURCC_P010) return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
    if (size_t(width) * height * 3 / (fourcc == VA_FOURCC_P010 ? 1 : 2) > tovd::slot_size)
        return VA_STATUS_ERROR_RESOLUTION_NOT_SUPPORTED;
    for (unsigned i = 0; i < count; ++i) {
        auto s = std::make_unique<Surface>();
        s->width = width; s->height = height; s->fourcc = fourcc;
        out[i] = drv(ctx).id(); drv(ctx).surfaces.emplace(out[i], std::move(s));
    }
    return VA_STATUS_SUCCESS;
}
VAStatus create_surfaces(VADriverContextP ctx, int width, int height, int format, int count, VASurfaceID *out) {
    if (count < 0 || width < 0 || height < 0) return VA_STATUS_ERROR_INVALID_PARAMETER;
    return create_surfaces2(ctx, format, width, height, out, count, nullptr, 0);
}
VAStatus destroy_surfaces(VADriverContextP ctx, VASurfaceID *ids, int count) {
    if (count < 0 || (count && !ids)) return VA_STATUS_ERROR_INVALID_PARAMETER;
    for (int i = 0; i < count; ++i) if (!drv(ctx).surfaces.count(ids[i])) return VA_STATUS_ERROR_INVALID_SURFACE;
    for (int i = 0; i < count; ++i) drv(ctx).surfaces.erase(ids[i]);
    return VA_STATUS_SUCCESS;
}
VAStatus surface_attributes(VADriverContextP ctx, VAConfigID id, VASurfaceAttrib *out, unsigned *count) {
    if (!drv(ctx).configs.count(id)) return VA_STATUS_ERROR_INVALID_CONFIG;
    if (!count) return VA_STATUS_ERROR_INVALID_PARAMETER;
    constexpr unsigned total = 7;
    if (!out) { *count = total; return VA_STATUS_SUCCESS; }
    if (*count < total) { *count = total; return VA_STATUS_ERROR_MAX_NUM_EXCEEDED; }
    auto set = [&](unsigned i, VASurfaceAttribType type, int value, unsigned flags) {
        out[i] = {}; out[i].type = type; out[i].flags = flags;
        out[i].value.type = VAGenericValueTypeInteger; out[i].value.value.i = value;
    };
    set(0, VASurfaceAttribPixelFormat, VA_FOURCC_NV12, VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE);
    set(1, VASurfaceAttribPixelFormat, VA_FOURCC_P010, VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE);
    set(2, VASurfaceAttribMinWidth, 2, VA_SURFACE_ATTRIB_GETTABLE);
    set(3, VASurfaceAttribMinHeight, 2, VA_SURFACE_ATTRIB_GETTABLE);
    set(4, VASurfaceAttribMaxWidth, 8192, VA_SURFACE_ATTRIB_GETTABLE);
    set(5, VASurfaceAttribMaxHeight, 4320, VA_SURFACE_ATTRIB_GETTABLE);
    set(6, VASurfaceAttribMemoryType, VA_SURFACE_ATTRIB_MEM_TYPE_VA, VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE);
    *count = total; return VA_STATUS_SUCCESS;
}

VAStatus create_context(VADriverContextP ctx, VAConfigID config, int width, int height, int,
                        VASurfaceID *, int, VAContextID *out) {
    if (!out || !dimensions(width, height)) return VA_STATUS_ERROR_INVALID_PARAMETER;
    auto found = drv(ctx).configs.find(config);
    if (found == drv(ctx).configs.end()) return VA_STATUS_ERROR_INVALID_CONFIG;
    if (drv(ctx).contexts.size() >= 8) return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    auto c = std::make_unique<Context>();
    c->profile = found->second.profile; c->width = width; c->height = height;
    *out = drv(ctx).id(); drv(ctx).contexts.emplace(*out, std::move(c));
    return VA_STATUS_SUCCESS;
}
VAStatus destroy_context(VADriverContextP ctx, VAContextID id) {
    return drv(ctx).contexts.erase(id) ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_CONTEXT;
}
VAStatus create_buffer(VADriverContextP ctx, VAContextID id, VABufferType type,
                      unsigned size, unsigned count, void *data, VABufferID *out) {
    if (id != VA_INVALID_ID && !drv(ctx).contexts.count(id)) return VA_STATUS_ERROR_INVALID_CONTEXT;
    if (!out || !size || !count || size_t(size) * count > tovd::slot_size)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (drv(ctx).buffers.size() >= 512) return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    auto bytes = std::make_shared<Bytes>(size_t(size) * count);
    if (data) memcpy(bytes->data(), data, bytes->size());
    *out = drv(ctx).id(); drv(ctx).buffers.emplace(*out, Buffer{type, size, count, std::move(bytes)});
    return VA_STATUS_SUCCESS;
}
VAStatus set_buffer_elements(VADriverContextP ctx, VABufferID id, unsigned count) {
    auto found = drv(ctx).buffers.find(id);
    if (found == drv(ctx).buffers.end()) return VA_STATUS_ERROR_INVALID_BUFFER;
    if (!count || size_t(found->second.size) * count > found->second.bytes->size())
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    found->second.count = count; return VA_STATUS_SUCCESS;
}
VAStatus map_buffer(VADriverContextP ctx, VABufferID id, void **out) {
    auto found = drv(ctx).buffers.find(id);
    if (found == drv(ctx).buffers.end()) return VA_STATUS_ERROR_INVALID_BUFFER;
    if (!out) return VA_STATUS_ERROR_INVALID_PARAMETER;
    *out = found->second.bytes->data(); return VA_STATUS_SUCCESS;
}
VAStatus map_buffer2(VADriverContextP ctx, VABufferID id, void **out, uint32_t) { return map_buffer(ctx, id, out); }
VAStatus unmap_buffer(VADriverContextP ctx, VABufferID id) {
    return drv(ctx).buffers.count(id) ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_BUFFER;
}
VAStatus destroy_buffer(VADriverContextP ctx, VABufferID id) {
    return drv(ctx).buffers.erase(id) ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_INVALID_BUFFER;
}
VAStatus buffer_info(VADriverContextP ctx, VABufferID id, VABufferType *type, unsigned *size, unsigned *count) {
    auto found = drv(ctx).buffers.find(id);
    if (found == drv(ctx).buffers.end()) return VA_STATUS_ERROR_INVALID_BUFFER;
    if (!type || !size || !count) return VA_STATUS_ERROR_INVALID_PARAMETER;
    *type = found->second.type; *size = found->second.size; *count = found->second.count; return VA_STATUS_SUCCESS;
}

VAStatus begin_picture(VADriverContextP ctx, VAContextID id, VASurfaceID target) {
    if (!drv(ctx).contexts.count(id)) return VA_STATUS_ERROR_INVALID_CONTEXT;
    if (!drv(ctx).surfaces.count(target)) return VA_STATUS_ERROR_INVALID_SURFACE;
    auto& c = context(ctx, id);
    c.target = target; c.picture = false; c.slices.clear(); c.hevc_slices.clear(); c.data.clear();
    surface(ctx, target).ready = false;
    surface(ctx, target).submitted = true;
    return VA_STATUS_SUCCESS;
}
VAStatus render_picture(VADriverContextP ctx, VAContextID id, VABufferID *buffers, int count) {
    if (!drv(ctx).contexts.count(id)) return VA_STATUS_ERROR_INVALID_CONTEXT;
    if (count < 0 || (count && !buffers)) return VA_STATUS_ERROR_INVALID_PARAMETER;
    auto& c = context(ctx, id);
    if (c.target == VA_INVALID_SURFACE) return VA_STATUS_ERROR_INVALID_SURFACE;
    for (int i = 0; i < count; ++i) {
        auto found = drv(ctx).buffers.find(buffers[i]);
        if (found == drv(ctx).buffers.end()) return VA_STATUS_ERROR_INVALID_BUFFER;
        auto& b = found->second;
        size_t size = size_t(b.size) * b.count;
        if (c.profile == VAProfileVP9Profile0 || c.profile == VAProfileVP9Profile2) {
            if (b.type == VAPictureParameterBufferType) {
                if (size != sizeof(c.vp9)) return VA_STATUS_ERROR_INVALID_PARAMETER;
                memcpy(&c.vp9, b.bytes->data(), size); c.picture = true;
            } else if (b.type == VASliceDataBufferType) {
                if (!c.data.empty()) return VA_STATUS_ERROR_INVALID_PARAMETER;
                c.data.assign(b.bytes->begin(), b.bytes->begin() + size);
            } else if (b.type != VASliceParameterBufferType) return VA_STATUS_ERROR_UNSUPPORTED_BUFFERTYPE;
            continue;
        }
        if (c.profile != VAProfileAV1Profile0) {
            if (b.type == VAPictureParameterBufferType) {
                if (size != sizeof(c.hevc)) return VA_STATUS_ERROR_INVALID_PARAMETER;
                memcpy(&c.hevc, b.bytes->data(), size); c.picture = true;
            } else if (b.type == VASliceParameterBufferType) {
                if (b.size != sizeof(VASliceParameterBufferHEVC) || b.count > 512 || c.hevc_slices.size() + b.count > 512)
                    return VA_STATUS_ERROR_INVALID_PARAMETER;
                size_t old = c.hevc_slices.size(); c.hevc_slices.resize(old + b.count);
                memcpy(c.hevc_slices.data() + old, b.bytes->data(), size);
            } else if (b.type == VASliceDataBufferType) {
                if (size > tovd::slot_size - c.data.size()) return VA_STATUS_ERROR_INVALID_PARAMETER;
                c.data.insert(c.data.end(), b.bytes->begin(), b.bytes->begin() + size);
            } else if (b.type != VAIQMatrixBufferType) return VA_STATUS_ERROR_UNSUPPORTED_BUFFERTYPE;
            continue;
        }
        if (b.type == VAPictureParameterBufferType) {
            if (size != sizeof(c.av1)) return VA_STATUS_ERROR_INVALID_PARAMETER;
            memcpy(&c.av1, b.bytes->data(), size); c.picture = true;
        } else if (b.type == VASliceParameterBufferType) {
            if (b.size != sizeof(VASliceParameterBufferAV1) || b.count > 512 || c.slices.size() + b.count > 512)
                return VA_STATUS_ERROR_INVALID_PARAMETER;
            size_t old = c.slices.size(); c.slices.resize(old + b.count);
            memcpy(c.slices.data() + old, b.bytes->data(), size);
        } else if (b.type == VASliceDataBufferType) {
            if (c.data.empty()) c.data.assign(b.bytes->begin(), b.bytes->begin() + size);
            else if (c.data.size() != size || memcmp(c.data.data(), b.bytes->data(), size))
                return VA_STATUS_ERROR_INVALID_PARAMETER;
        } else return VA_STATUS_ERROR_UNSUPPORTED_BUFFERTYPE;
    }
    return VA_STATUS_SUCCESS;
}

struct OBU { size_t start, payload, end; unsigned type; };
std::vector<OBU> obus(const Bytes& bytes) {
    std::vector<OBU> result;
    size_t offset = 0;
    while (offset < bytes.size()) {
        size_t start = offset;
        uint8_t h = bytes[offset++];
        if (h & 0x81) throw std::runtime_error("invalid AV1 OBU header");
        if (h & 4) { if (offset == bytes.size()) throw std::runtime_error("truncated AV1 OBU extension"); ++offset; }
        uint64_t size = 0;
        if (h & 2) {
            unsigned shift = 0;
            for (;;) {
                if (offset == bytes.size() || shift >= 56) throw std::runtime_error("invalid AV1 OBU length");
                uint8_t b = bytes[offset++]; size |= uint64_t(b & 127) << shift;
                if (!(b & 128)) break;
                shift += 7;
            }
        } else size = bytes.size() - offset;
        if (size > bytes.size() - offset) throw std::runtime_error("truncated AV1 OBU");
        result.push_back({start, offset, offset + size, unsigned((h >> 3) & 15)});
        offset += size;
    }
    return result;
}

// DMA-BUF consumers may keep their exported handles across many decodes.
// Refresh those same backing buffers when a surface is reused.
void upload_pixels(Surface& s, const uint8_t *pixels, unsigned source_stride, unsigned source_height) {
    for (unsigned plane = 0; plane < 2; ++plane) {
        if (!s.planes[plane]) continue;
        unsigned width = plane ? s.width / 2 : s.width;
        unsigned height = plane ? s.height / 2 : s.height;
        uint32_t stride = 0;
        void *map_data = nullptr;
        auto *mapped = static_cast<uint8_t *>(gbm_bo_map(s.planes[plane], 0, 0, width, height,
                                                       GBM_BO_TRANSFER_WRITE, &stride, &map_data));
        if (!mapped) throw std::runtime_error("cannot map virtio video plane for upload");
        if (stride < s.stride()) {
            gbm_bo_unmap(s.planes[plane], map_data);
            throw std::runtime_error("virtio video plane stride is too small");
        }
        for (unsigned row = 0; row < height; ++row)
            memcpy(mapped + size_t(row) * stride,
                   pixels + (plane ? size_t(source_stride) * source_height : 0) + size_t(row) * source_stride, s.stride());
        gbm_bo_unmap(s.planes[plane], map_data);
    }
    if (s.planes[0] && s.planes[1]) s.dirty = false;
}

void upload_surface(Surface& s) {
    if (s.dirty) upload_pixels(s, s.pixels->data(), s.stride(), s.height);
}

// Browsers retain DMA-BUF handles and rarely request a CPU image. Keep that
// cache lazy after direct uploads, while preserving vaDeriveImage/vaGetImage.
void cache_surface(Surface& s) {
    s.allocate();
    if (s.cache_valid) return;
    for (unsigned plane = 0; plane < 2; ++plane) {
        unsigned width = plane ? s.width / 2 : s.width;
        unsigned height = plane ? s.height / 2 : s.height;
        if (s.host_written) {
            // Mesa did not submit the host's IOSurface blit and considers its
            // old CPU copy clean. Explicitly refresh the backing memory before
            // mapping it. Legacy VirGL resources require zero stride fields.
            int fd = gbm_device_get_fd(gbm_bo_get_device(s.planes[plane]));
            drm_virtgpu_3d_transfer_from_host transfer{};
            transfer.bo_handle = gbm_bo_get_handle(s.planes[plane]).u32;
            transfer.box.w = width; transfer.box.h = height; transfer.box.d = 1;
            drm_virtgpu_3d_wait wait{};wait.handle = transfer.bo_handle;
            if (drmIoctl(fd, DRM_IOCTL_VIRTGPU_TRANSFER_FROM_HOST, &transfer) ||
                drmIoctl(fd, DRM_IOCTL_VIRTGPU_WAIT, &wait))
                throw std::runtime_error("cannot synchronize host video texture for CPU readback");
        }
        uint32_t stride = 0;
        void *map_data = nullptr;
        auto *mapped = static_cast<uint8_t *>(gbm_bo_map(s.planes[plane], 0, 0, width, height,
                                                       GBM_BO_TRANSFER_READ, &stride, &map_data));
        if (!mapped) throw std::runtime_error("cannot map virtio video plane for readback");
        if (stride < s.stride()) {
            gbm_bo_unmap(s.planes[plane], map_data);
            throw std::runtime_error("virtio video plane stride is too small");
        }
        for (unsigned row = 0; row < height; ++row)
            memcpy(s.pixels->data() + (plane ? size_t(s.stride()) * s.height : 0) + size_t(row) * s.stride(),
                   mapped + size_t(row) * stride, s.stride());
        gbm_bo_unmap(s.planes[plane], map_data);
    }
    s.cache_valid = true;
    s.host_written = false;
}

void store_frame(Surface& s, const tovd::Message& m, const uint8_t *pixels, size_t length) {
    unsigned format = m.flags & 0xff;
    unsigned bytes = format == 2 ? 2 : 1;
    if ((format != 1 && format != 2) || !dimensions(m.arg0, m.arg1) ||
        m.arg0 > s.width || m.arg1 > s.height ||
        (s.fourcc == VA_FOURCC_P010) != (format == 2) ||
        ((m.flags & tovd::gpu_flag) ? (length != 0 || pixels != nullptr || !s.planes[0] || !s.planes[1]) :
         (length != size_t(m.arg0) * m.arg1 * 3 / 2 * bytes)))
        throw std::runtime_error("decoded frame does not match its VA surface");
    if (m.flags & tovd::gpu_flag) {
        s.ready = true; s.dirty = false; s.cache_valid = false; s.host_written = true;
        if (s.pixels.use_count() > 1) cache_surface(s);
        return;
    }
    unsigned source_stride = m.arg0 * bytes;
    s.host_written = false;
    if (s.planes[0] && s.planes[1] && s.pixels.use_count() <= 1 &&
        m.arg0 == s.width && m.arg1 == s.height) {
        s.cache_valid = false;
        upload_pixels(s, pixels, source_stride, m.arg1);
        s.ready = true;
        return;
    }
    cache_surface(s);
    for (unsigned plane = 0; plane < 2; ++plane) {
        unsigned rows = plane ? m.arg1 / 2 : m.arg1;
        auto *dst = s.pixels->data() + (plane ? size_t(s.stride()) * s.height : 0);
        auto *src = pixels + (plane ? size_t(source_stride) * m.arg1 : 0);
        for (unsigned row = 0; row < rows; ++row)
            memcpy(dst + size_t(row) * s.stride(), src + size_t(row) * source_stride, source_stride);
    }
    s.ready = true; s.dirty = true;
    upload_surface(s);
}

void attach_gpu_targets(VADriverContextP ctx, Context& c, tovd::Message& request) {
    auto& s = surface(ctx, c.target);
    if (!c.client->supports_gpu() || !s.planes[0] || !s.planes[1] || s.pixels.use_count() > 1) return;
    for (unsigned p = 0; p < 2; ++p) {
        if (s.gpu_resources[p]) continue;
        drm_virtgpu_resource_info info{};
        info.bo_handle = gbm_bo_get_handle(s.planes[p]).u32;
        if (drmIoctl(gbm_device_get_fd(drv(ctx).gbm), DRM_IOCTL_VIRTGPU_RESOURCE_INFO, &info) || !info.res_handle)
            return;
        s.gpu_resources[p] = info.res_handle;
    }
    request.flags = 4; request.arg0 = s.gpu_resources[0]; request.arg1 = s.gpu_resources[1];
}

VAStatus end_hevc_picture(VADriverContextP ctx, Context& c) {
    if (!c.picture || c.data.empty() || c.hevc_slices.empty() || !drv(ctx).surfaces.count(c.target))
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (c.hevc.pic_fields.bits.chroma_format_idc != 1 || c.hevc.pic_fields.bits.separate_colour_plane_flag ||
        (c.hevc.bit_depth_luma_minus8 != 0 && c.hevc.bit_depth_luma_minus8 != 2) ||
        c.hevc.bit_depth_chroma_minus8 != c.hevc.bit_depth_luma_minus8)
        return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    // The private FFmpeg submission preserves original parameter sets and VCL
    // NAL units, each prefixed with its 32-bit network-order length.
    Bytes sets[3], packet;
    for (size_t offset = 0; offset < c.data.size();) {
        if (c.data.size() - offset < 4) throw std::runtime_error("truncated HEVC NAL length");
        auto *p = c.data.data() + offset;
        size_t length = uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
        if (length < 2 || length > c.data.size() - offset - 4) throw std::runtime_error("invalid HEVC NAL length");
        unsigned type = (p[4] >> 1) & 63;
        if (type >= 32 && type <= 34) {
            if (length > 65535) throw std::runtime_error("HEVC parameter set exceeds hvcC limit");
            sets[type - 32].assign(p + 4, p + 4 + length);
        } else if (type < 32) packet.insert(packet.end(), p, p + 4 + length);
        offset += 4 + length;
    }
    if (packet.empty()) return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (!sets[0].empty() && !sets[1].empty() && !sets[2].empty()) {
        Bytes config(23);
        config[0] = 1; config[1] = c.hevc.bit_depth_luma_minus8 ? 2 : 1;
        config[12] = 153; config[13] = 0xf0; config[15] = 0xfc; config[16] = 0xfd;
        config[17] = config[18] = 0xf8 | c.hevc.bit_depth_luma_minus8;
        config[21] = 3; config[22] = 3;
        for (unsigned i = 0; i < 3; ++i) {
            config.insert(config.end(), {uint8_t(0x80 | (32 + i)), 0, 1,
                                        uint8_t(sets[i].size() >> 8), uint8_t(sets[i].size())});
            config.insert(config.end(), sets[i].begin(), sets[i].end());
        }
        if (config != c.sequence) { c.client.reset(); c.sequence = std::move(config); }
    }
    if (!c.client) {
        if (c.sequence.empty()) throw std::runtime_error("HEVC submission is missing VPS/SPS/PPS");
        const char *path = getenv("OMARCHY_VIDEO_SOCKET");
        c.client = std::make_unique<tovd::Client>(path ? path : "/run/omarchy-video.sock");
        tovd::Message open; open.op = 1; open.flags = 1; open.payload = c.sequence;
        c.client->exchange(std::move(open), {});
        if (logging()) fprintf(stderr, "[omarchy-vaapi] HEVC %ux%u %u-bit hardware decoder opened\n",
                               c.hevc.pic_width_in_luma_samples, c.hevc.pic_height_in_luma_samples,
                               8 + c.hevc.bit_depth_luma_minus8);
    }
    tovd::Message decode; decode.op = 2; decode.token = c.target; decode.payload = std::move(packet);
    attach_gpu_targets(ctx, c, decode);
    c.client->exchange(std::move(decode), [&](const tovd::Message& m, const uint8_t *pixels, size_t size) {
        if (!drv(ctx).surfaces.count(m.token)) throw std::runtime_error("decoded HEVC frame refers to a released surface");
        store_frame(surface(ctx, m.token), m, pixels, size);
    });
    if (!surface(ctx, c.target).ready) throw std::runtime_error("hardware decoder produced no VA frame");
    c.target = VA_INVALID_SURFACE;
    return VA_STATUS_SUCCESS;
}

VAStatus end_vp9_picture(VADriverContextP ctx, Context& c) {
    if (!c.picture || c.data.empty() || !drv(ctx).surfaces.count(c.target))
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    unsigned width = c.vp9.frame_width, height = c.vp9.frame_height;
    if (!dimensions(width, height) || !c.vp9.pic_fields.bits.subsampling_x ||
        !c.vp9.pic_fields.bits.subsampling_y ||
        !((c.vp9.profile == 0 && c.vp9.bit_depth == 8) || (c.vp9.profile == 2 && c.vp9.bit_depth == 10)))
        return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    Bytes config = {1, 0, 0, 0, c.vp9.profile, 51, uint8_t(c.vp9.bit_depth << 4), 2, 2, 2, 0, 0};
    if (config != c.sequence || width != c.width || height != c.height) {
        c.client.reset(); c.sequence = config; c.width = width; c.height = height;
    }
    if (!c.client) {
        const char *path = getenv("OMARCHY_VIDEO_SOCKET");
        c.client = std::make_unique<tovd::Client>(path ? path : "/run/omarchy-video.sock");
        tovd::Message open; open.op = 1; open.arg0 = 2; open.arg1 = width | (height << 16);
        open.flags = 1; open.payload = config;
        c.client->exchange(std::move(open), {});
        if (logging()) fprintf(stderr, "[omarchy-vaapi] VP9 %ux%u %u-bit hardware decoder opened\n", width, height, c.vp9.bit_depth);
    }
    tovd::Message decode; decode.op = 2; decode.token = c.target; decode.payload = std::move(c.data);
    attach_gpu_targets(ctx, c, decode);
    c.client->exchange(std::move(decode), [&](const tovd::Message& m, const uint8_t *pixels, size_t size) {
        if (!drv(ctx).surfaces.count(m.token)) throw std::runtime_error("decoded VP9 frame refers to a released surface");
        store_frame(surface(ctx, m.token), m, pixels, size);
    });
    if (!surface(ctx, c.target).ready) throw std::runtime_error("hardware decoder produced no VA frame");
    c.target = VA_INVALID_SURFACE;
    return VA_STATUS_SUCCESS;
}

VAStatus end_picture(VADriverContextP ctx, VAContextID id) {
    if (!drv(ctx).contexts.count(id)) return VA_STATUS_ERROR_INVALID_CONTEXT;
    auto& c = context(ctx, id);
    if (c.profile == VAProfileVP9Profile0 || c.profile == VAProfileVP9Profile2) return end_vp9_picture(ctx, c);
    if (c.profile != VAProfileAV1Profile0) return end_hevc_picture(ctx, c);
    if (!c.picture || c.data.empty() || c.slices.empty() || !drv(ctx).surfaces.count(c.target))
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (c.av1.profile != 0 || c.av1.bit_depth_idx > 1 || c.av1.seq_info_fields.fields.mono_chrome ||
        !c.av1.seq_info_fields.fields.subsampling_x || !c.av1.seq_info_fields.fields.subsampling_y)
        return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    auto units = obus(c.data);
    Bytes sequence;
    for (const auto& unit : units) if (unit.type == 1)
        sequence.assign(c.data.begin() + unit.start, c.data.begin() + unit.end);
    if (!sequence.empty() && c.sequence != sequence) { c.client.reset(); c.sequence = sequence; }
    unsigned width = unsigned(c.av1.frame_width_minus1) + 1;
    unsigned height = unsigned(c.av1.frame_height_minus1) + 1;
    if (!dimensions(width, height)) return VA_STATUS_ERROR_RESOLUTION_NOT_SUPPORTED;
    if (!c.client) {
        if (c.sequence.empty()) throw std::runtime_error("AV1 submission is missing its sequence header");
        const char *path = getenv("OMARCHY_VIDEO_SOCKET");
        c.client = std::make_unique<tovd::Client>(path ? path : "/run/omarchy-video.sock");
        tovd::Message open;
        open.op = 1; open.arg0 = 1; open.arg1 = width | (height << 16); open.flags = 1;
        open.payload = {0x81, 13, uint8_t(c.av1.bit_depth_idx ? 0x4c : 0x0c), 0};
        open.payload.insert(open.payload.end(), c.sequence.begin(), c.sequence.end());
        c.client->exchange(std::move(open), {});
        if (logging()) fprintf(stderr, "[omarchy-vaapi] AV1 %ux%u %u-bit hardware decoder opened\n", width, height, c.av1.bit_depth_idx ? 10 : 8);
    }
    size_t first_tile = c.data.size(), last_tile = 0;
    for (const auto& slice : c.slices) {
        if (slice.slice_data_flag != VA_SLICE_DATA_FLAG_ALL || slice.slice_data_offset > c.data.size() ||
            slice.slice_data_size > c.data.size() - slice.slice_data_offset) return VA_STATUS_ERROR_INVALID_PARAMETER;
        first_tile = std::min(first_tile, size_t(slice.slice_data_offset));
        last_tile = std::max(last_tile, size_t(slice.slice_data_offset) + slice.slice_data_size);
    }
    size_t begin = c.data.size(), end = 0, last_header = c.data.size();
    for (const auto& unit : units) {
        if (unit.type == 3) last_header = unit.start;
        if (first_tile >= unit.payload && first_tile < unit.end)
            begin = unit.type == 4 && last_header != c.data.size() ? last_header : unit.start;
        if (last_tile > unit.payload && last_tile <= unit.end) end = unit.end;
    }
    if (begin >= end || end > c.data.size()) throw std::runtime_error("cannot locate AV1 frame OBUs from tile offsets");
    tovd::Message decode;
    decode.op = 2; decode.token = c.target;
    decode.payload.assign(c.data.begin() + begin, c.data.begin() + end);
    if (c.av1.current_display_picture == VA_INVALID_SURFACE || c.av1.current_display_picture == c.target)
        attach_gpu_targets(ctx, c, decode);
    c.client->exchange(std::move(decode), [&](const tovd::Message& m, const uint8_t *pixels, size_t size) {
        if (!drv(ctx).surfaces.count(m.token)) throw std::runtime_error("decoded AV1 frame refers to a released surface");
        store_frame(surface(ctx, m.token), m, pixels, size);
        auto display = c.av1.current_display_picture;
        if (display != VA_INVALID_SURFACE && display != m.token && drv(ctx).surfaces.count(display))
            store_frame(surface(ctx, display), m, pixels, size);
    });
    if (!surface(ctx, c.target).ready) throw std::runtime_error("hardware decoder produced no VA frame");
    c.target = VA_INVALID_SURFACE;
    return VA_STATUS_SUCCESS;
}

VAStatus sync_surface(VADriverContextP ctx, VASurfaceID id) {
    if (!drv(ctx).surfaces.count(id)) return VA_STATUS_ERROR_INVALID_SURFACE;
    const auto& s = surface(ctx, id);
    return !s.submitted || s.ready ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_DECODING_ERROR;
}
VAStatus sync_surface2(VADriverContextP ctx, VASurfaceID id, uint64_t) { return sync_surface(ctx, id); }
VAStatus query_surface(VADriverContextP ctx, VASurfaceID id, VASurfaceStatus *out) {
    if (!drv(ctx).surfaces.count(id)) return VA_STATUS_ERROR_INVALID_SURFACE;
    if (!out) return VA_STATUS_ERROR_INVALID_PARAMETER;
    *out = VASurfaceReady; return VA_STATUS_SUCCESS;
}
VAStatus query_error(VADriverContextP, VASurfaceID, VAStatus, void **out) {
    if (out) *out = nullptr;
    return VA_STATUS_SUCCESS;
}

VAImageFormat image_format(unsigned fourcc) {
    VAImageFormat f{}; f.fourcc = fourcc; f.byte_order = VA_LSB_FIRST;
    f.bits_per_pixel = fourcc == VA_FOURCC_P010 ? 24 : 12; return f;
}
VAStatus image_formats(VADriverContextP, VAImageFormat *out, int *count) {
    if (!out || !count) return VA_STATUS_ERROR_INVALID_PARAMETER;
    out[0] = image_format(VA_FOURCC_NV12); out[1] = image_format(VA_FOURCC_P010);
    *count = 2; return VA_STATUS_SUCCESS;
}
VAStatus make_image(VADriverContextP ctx, unsigned fourcc, unsigned width, unsigned height,
                   std::shared_ptr<Bytes> bytes, VAImage *out) {
    if (!out || !dimensions(width, height)) return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (drv(ctx).images.size() >= 128 || drv(ctx).buffers.size() >= 512) return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    if (fourcc != VA_FOURCC_NV12 && fourcc != VA_FOURCC_P010) return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
    unsigned stride = width * (fourcc == VA_FOURCC_P010 ? 2 : 1);
    size_t size = size_t(stride) * height * 3 / 2;
    if (size > tovd::slot_size) return VA_STATUS_ERROR_INVALID_PARAMETER;
    if (!bytes) bytes = std::make_shared<Bytes>(size);
    *out = {}; out->image_id = drv(ctx).id(); out->buf = drv(ctx).id();
    out->format = image_format(fourcc); out->width = width; out->height = height;
    out->data_size = size; out->num_planes = 2;
    out->pitches[0] = out->pitches[1] = stride; out->offsets[1] = stride * height;
    drv(ctx).buffers.emplace(out->buf, Buffer{VAImageBufferType, unsigned(size), 1, std::move(bytes)});
    drv(ctx).images.emplace(out->image_id, *out); return VA_STATUS_SUCCESS;
}
VAStatus create_image(VADriverContextP ctx, VAImageFormat *format, int width, int height, VAImage *out) {
    if (!format || width < 0 || height < 0) return VA_STATUS_ERROR_INVALID_PARAMETER;
    return make_image(ctx, format->fourcc, width, height, {}, out);
}
VAStatus derive_image(VADriverContextP ctx, VASurfaceID id, VAImage *out) {
    if (!drv(ctx).surfaces.count(id)) return VA_STATUS_ERROR_INVALID_SURFACE;
    auto& s = surface(ctx, id); cache_surface(s);
    return make_image(ctx, s.fourcc, s.width, s.height, s.pixels, out);
}
VAStatus destroy_image(VADriverContextP ctx, VAImageID id) {
    auto found = drv(ctx).images.find(id);
    if (found == drv(ctx).images.end()) return VA_STATUS_ERROR_INVALID_IMAGE;
    drv(ctx).buffers.erase(found->second.buf); drv(ctx).images.erase(found); return VA_STATUS_SUCCESS;
}
VAStatus get_image(VADriverContextP ctx, VASurfaceID id, int x, int y, unsigned width, unsigned height, VAImageID image) {
    if (!drv(ctx).surfaces.count(id)) return VA_STATUS_ERROR_INVALID_SURFACE;
    auto found = drv(ctx).images.find(image);
    if (found == drv(ctx).images.end()) return VA_STATUS_ERROR_INVALID_IMAGE;
    auto& s = surface(ctx, id); auto& i = found->second;
    if (!s.ready || x || y || width > s.width || height > s.height || i.width < width || i.height < height || i.format.fourcc != s.fourcc)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    auto& buffer = drv(ctx).buffers.at(i.buf);
    cache_surface(s);
    unsigned row_bytes = width * (s.fourcc == VA_FOURCC_P010 ? 2 : 1);
    for (unsigned plane = 0; plane < 2; ++plane) {
        unsigned rows = plane ? height / 2 : height;
        for (unsigned row = 0; row < rows; ++row)
            memcpy(buffer.bytes->data() + i.offsets[plane] + size_t(row) * i.pitches[plane],
                   s.pixels->data() + (plane ? size_t(s.stride()) * s.height : 0) + size_t(row) * s.stride(), row_bytes);
    }
    return VA_STATUS_SUCCESS;
}

VAStatus export_surface(VADriverContextP ctx, VASurfaceID id, uint32_t mem_type, uint32_t flags, void *output) {
    if (!output || mem_type != VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2) return VA_STATUS_ERROR_UNSUPPORTED_MEMORY_TYPE;
    if (!drv(ctx).surfaces.count(id)) return VA_STATUS_ERROR_INVALID_SURFACE;
    auto& s = surface(ctx, id);
    // Clients probe DMA-BUF interoperability immediately after allocating a
    // surface, before decoding into it. Export initialized storage in that case.
    s.allocate();
    if (!drv(ctx).gbm) return VA_STATUS_ERROR_UNIMPLEMENTED;
    uint32_t formats[2] = {s.fourcc == VA_FOURCC_P010 ? DRM_FORMAT_R16 : DRM_FORMAT_R8,
                          s.fourcc == VA_FOURCC_P010 ? DRM_FORMAT_GR1616 : DRM_FORMAT_GR88};
    for (unsigned plane = 0; plane < 2; ++plane) {
        unsigned width = plane ? s.width / 2 : s.width, height = plane ? s.height / 2 : s.height;
        if (!s.planes[plane]) s.planes[plane] = gbm_bo_create(drv(ctx).gbm, width, height, formats[plane],
                                                            GBM_BO_USE_LINEAR | GBM_BO_USE_RENDERING);
        if (!s.planes[plane]) throw std::runtime_error("virtio GPU cannot export the decoded video plane");
    }
    upload_surface(s);
    auto *out = static_cast<VADRMPRIMESurfaceDescriptor *>(output);
    *out = {}; out->fourcc = s.fourcc; out->width = s.width; out->height = s.height; out->num_objects = 2;
    for (unsigned plane = 0; plane < 2; ++plane) {
        out->objects[plane].fd = gbm_bo_get_fd(s.planes[plane]);
        if (out->objects[plane].fd < 0) {
            if (plane) close(out->objects[0].fd);
            throw std::runtime_error("cannot export virtio video plane descriptor");
        }
        out->objects[plane].size = gbm_bo_get_stride(s.planes[plane]) * gbm_bo_get_height(s.planes[plane]);
        out->objects[plane].drm_format_modifier = gbm_bo_get_modifier(s.planes[plane]);
    }
    bool separate = flags & VA_EXPORT_SURFACE_SEPARATE_LAYERS;
    out->num_layers = separate ? 2 : 1;
    if (separate) {
        for (unsigned plane = 0; plane < 2; ++plane) {
            out->layers[plane].drm_format = formats[plane]; out->layers[plane].num_planes = 1;
            out->layers[plane].object_index[0] = plane;
            out->layers[plane].pitch[0] = gbm_bo_get_stride(s.planes[plane]);
        }
    } else {
        out->layers[0].drm_format = s.fourcc; out->layers[0].num_planes = 2;
        for (unsigned plane = 0; plane < 2; ++plane) {
            out->layers[0].object_index[plane] = plane;
            out->layers[0].pitch[plane] = gbm_bo_get_stride(s.planes[plane]);
        }
    }
    return VA_STATUS_SUCCESS;
}

// Mandatory legacy VA hooks. No display, subpicture or processing capabilities
// are advertised; applications receive explicit unsupported-operation results.
VAStatus palette(VADriverContextP, VAImageID, unsigned char *) { return VA_STATUS_ERROR_UNIMPLEMENTED; }
VAStatus put_image(VADriverContextP, VASurfaceID, VAImageID, int, int, unsigned, unsigned, int, int, unsigned, unsigned) { return VA_STATUS_ERROR_UNIMPLEMENTED; }
VAStatus sub_formats(VADriverContextP, VAImageFormat *, unsigned *, unsigned *count) { if (count) *count = 0; return VA_STATUS_SUCCESS; }
VAStatus sub_create(VADriverContextP, VAImageID, VASubpictureID *) { return VA_STATUS_ERROR_UNIMPLEMENTED; }
VAStatus sub_destroy(VADriverContextP, VASubpictureID) { return VA_STATUS_ERROR_UNIMPLEMENTED; }
VAStatus sub_image(VADriverContextP, VASubpictureID, VAImageID) { return VA_STATUS_ERROR_UNIMPLEMENTED; }
VAStatus sub_chroma(VADriverContextP, VASubpictureID, unsigned, unsigned, unsigned) { return VA_STATUS_ERROR_UNIMPLEMENTED; }
VAStatus sub_alpha(VADriverContextP, VASubpictureID, float) { return VA_STATUS_ERROR_UNIMPLEMENTED; }
VAStatus sub_associate(VADriverContextP, VASubpictureID, VASurfaceID *, int, short, short, unsigned short, unsigned short, short, short, unsigned short, unsigned short, unsigned) { return VA_STATUS_ERROR_UNIMPLEMENTED; }
VAStatus sub_deassociate(VADriverContextP, VASubpictureID, VASurfaceID *, int) { return VA_STATUS_ERROR_UNIMPLEMENTED; }
VAStatus display_query(VADriverContextP, VADisplayAttribute *, int *count) { if (count) *count = 0; return VA_STATUS_SUCCESS; }
VAStatus display_attributes(VADriverContextP, VADisplayAttribute *, int count) { return count ? VA_STATUS_ERROR_ATTR_NOT_SUPPORTED : VA_STATUS_SUCCESS; }
}

extern "C" VAStatus __vaDriverInit_1_0(VADriverContextP ctx) noexcept {
    try {
        auto d = std::make_unique<Driver>();
        if (ctx->drm_state) {
            auto *state = static_cast<drm_state *>(ctx->drm_state);
            if (state->fd >= 0) d->gbm = gbm_create_device(state->fd);
        }
        ctx->version_major = VA_MAJOR_VERSION; ctx->version_minor = VA_MINOR_VERSION;
        ctx->max_profiles = 5; ctx->max_entrypoints = 1; ctx->max_attributes = 8;
        ctx->max_image_formats = 2; ctx->max_subpic_formats = 1; ctx->max_display_attributes = 1;
        ctx->str_vendor = "Try Omarchy VideoToolbox hardware decode";
        auto *v = ctx->vtable;
        v->vaTerminate = terminate;
#define BIND(field, fn) v->va##field = Guard<fn>::call
        BIND(QueryConfigProfiles, profiles); BIND(QueryConfigEntrypoints, entrypoints);
        BIND(GetConfigAttributes, get_attributes); BIND(CreateConfig, create_config);
        BIND(DestroyConfig, destroy_config); BIND(QueryConfigAttributes, query_config);
        BIND(CreateSurfaces, create_surfaces); BIND(CreateSurfaces2, create_surfaces2);
        BIND(DestroySurfaces, destroy_surfaces); BIND(QuerySurfaceAttributes, surface_attributes);
        BIND(CreateContext, create_context); BIND(DestroyContext, destroy_context);
        BIND(CreateBuffer, create_buffer); BIND(BufferSetNumElements, set_buffer_elements);
        BIND(MapBuffer, map_buffer); BIND(MapBuffer2, map_buffer2); BIND(UnmapBuffer, unmap_buffer);
        BIND(DestroyBuffer, destroy_buffer); BIND(BufferInfo, buffer_info);
        BIND(BeginPicture, begin_picture); BIND(RenderPicture, render_picture); BIND(EndPicture, end_picture);
        BIND(SyncSurface, sync_surface); BIND(SyncSurface2, sync_surface2);
        BIND(QuerySurfaceStatus, query_surface); BIND(QuerySurfaceError, query_error);
        BIND(QueryImageFormats, image_formats); BIND(CreateImage, create_image); BIND(DeriveImage, derive_image);
        BIND(DestroyImage, destroy_image); BIND(GetImage, get_image); BIND(ExportSurfaceHandle, export_surface);
        BIND(SetImagePalette, palette); BIND(PutImage, put_image); BIND(QuerySubpictureFormats, sub_formats);
        BIND(CreateSubpicture, sub_create); BIND(DestroySubpicture, sub_destroy); BIND(SetSubpictureImage, sub_image);
        BIND(SetSubpictureChromakey, sub_chroma); BIND(SetSubpictureGlobalAlpha, sub_alpha);
        BIND(AssociateSubpicture, sub_associate); BIND(DeassociateSubpicture, sub_deassociate);
        BIND(QueryDisplayAttributes, display_query); BIND(GetDisplayAttributes, display_attributes);
        BIND(SetDisplayAttributes, display_attributes);
#undef BIND
        ctx->pDriverData = d.release();
        return VA_STATUS_SUCCESS;
    } catch (...) { return VA_STATUS_ERROR_ALLOCATION_FAILED; }
}
