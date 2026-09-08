// Linux/virgl integration test: retained DMA-BUF handles and VA CPU images must
// see every reused surface, including direct-upload frames and image aliases.
#include "../guest/video/driver.cpp"
#include <fcntl.h>
#include <iostream>

static void check(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}

int main(int argc, char **argv) {
    try {
        int fd = open(argc > 1 ? argv[1] : "/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
        check(fd >= 0, "cannot open render device");
        Driver driver;
        driver.gbm = gbm_create_device(fd);
        check(driver.gbm != nullptr, "cannot create GBM device");
        VADriverContext ctx{};
        ctx.pDriverData = &driver;
        for (unsigned fourcc : {VA_FOURCC_NV12, VA_FOURCC_P010}) {
            auto s = std::make_unique<Surface>();
            s->width = 256; s->height = 128; s->fourcc = fourcc;
            auto id = driver.id();
            driver.surfaces.emplace(id, std::move(s));
            auto& target = *driver.surfaces.at(id);
            VADRMPRIMESurfaceDescriptor dma{};
            check(export_surface(&ctx, id, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                                 VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS,
                                 &dma) == VA_STATUS_SUCCESS, "DMA-BUF export failed");
            VAImage retained{};
            for (unsigned frame = 0; frame < 20; ++frame) {
                Bytes expected(target.size());
                for (size_t i = 0; i < expected.size(); ++i)
                    expected[i] = uint8_t(i * 17 + frame * 31 + (i >> 8));
                tovd::Message message{};
                message.flags = fourcc == VA_FOURCC_P010 ? 2 : 1;
                message.arg0 = target.width; message.arg1 = target.height;
                store_frame(target, message, expected.data(), expected.size());
                check(sync_surface(&ctx, id) == VA_STATUS_SUCCESS, "surface synchronization failed");
                // Independently inspect the actual persistent GPU allocations.
                for (unsigned plane = 0; plane < 2; ++plane) {
                    uint32_t pitch = 0; void *cookie = nullptr;
                    unsigned rows = plane ? target.height / 2 : target.height;
                    auto *mapped = static_cast<uint8_t *>(gbm_bo_map(target.planes[plane], 0, 0,
                        plane ? target.width / 2 : target.width, rows,
                        GBM_BO_TRANSFER_READ, &pitch, &cookie));
                    check(mapped != nullptr, "GPU readback failed");
                    for (unsigned row = 0; row < rows; ++row)
                        check(!memcmp(mapped + size_t(row) * pitch,
                            expected.data() + (plane ? size_t(target.stride()) * target.height : 0) +
                            size_t(row) * target.stride(), target.stride()), "stale DMA-BUF frame");
                    gbm_bo_unmap(target.planes[plane], cookie);
                }
                VAImage image{};
                check(derive_image(&ctx, id, &image) == VA_STATUS_SUCCESS, "derive image failed");
                check(*driver.buffers.at(image.buf).bytes == expected, "stale derived CPU image");
                destroy_image(&ctx, image.image_id);
                if (frame == 5) check(derive_image(&ctx, id, &retained) == VA_STATUS_SUCCESS, "alias failed");
                if (frame >= 5 && frame <= 10)
                    check(*driver.buffers.at(retained.buf).bytes == expected, "retained image alias is stale");
                if (frame == 10) destroy_image(&ctx, retained.image_id);
                VAImage copy{};
                check(make_image(&ctx, fourcc, target.width, target.height, {}, &copy) == VA_STATUS_SUCCESS,
                      "create image failed");
                check(get_image(&ctx, id, 0, 0, target.width, target.height, copy.image_id) == VA_STATUS_SUCCESS,
                      "get image failed");
                check(*driver.buffers.at(copy.buf).bytes == expected, "stale copied CPU image");
                destroy_image(&ctx, copy.image_id);
            }
            for (unsigned i = 0; i < dma.num_objects; ++i) close(dma.objects[i].fd);
            driver.surfaces.erase(id);
        }
        driver.surfaces.clear();
        gbm_device_destroy(driver.gbm); driver.gbm = nullptr; close(fd);
        std::cout << "PASS: NV12/P010 GPU reuse, CPU readback, and retained VA image aliases\n";
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n'; return 1;
    }
}
