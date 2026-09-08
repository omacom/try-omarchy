// Firefox's RDD sandbox allows existing descriptors but denies new broker
// connections. Open only two decoder capabilities in the RDD process before
// sandbox initialization. No filesystem or syscall sandbox rules are changed.
// The launcher disables the forkserver so the RDD exec runs this constructor.
#include "connection.hpp"
#include <array>
#include <cstdio>
#include <memory>
#include <mutex>

namespace {
struct Slot { std::unique_ptr<tovd::Connection> connection; bool busy = false; };
struct Pool { std::mutex mutex; std::array<Slot, 2> slots; };
Pool& pool() { static Pool instance; return instance; }
__attribute__((constructor)) void initialize(int argc, char **argv, char **) {
    if (argc < 3 || strcmp(argv[1], "-contentproc") || strcmp(argv[argc - 1], "rdd")) return;
    for (auto& slot : pool().slots) {
        try { slot.connection = std::make_unique<tovd::Connection>("/run/omarchy-video.sock"); }
        catch (const std::exception& e) {
            fprintf(stderr, "[omarchy-video] RDD bootstrap: %s\n", e.what());
            break;
        }
    }
}
}
extern "C" int tovd_acquire_preopened_client(int *fd, const uint8_t **pixels) {
    auto& p = pool(); std::lock_guard<std::mutex> lock(p.mutex);
    for (unsigned i = 0; i < p.slots.size(); ++i) {
        auto& s = p.slots[i];
        if (!s.busy && s.connection) {
            s.busy = true; *fd = s.connection->socket_fd(); *pixels = s.connection->pixels();
            return i + 1;
        }
    }
    return 0;
}
extern "C" void tovd_release_preopened_client(int lease, int healthy) {
    auto& p = pool(); std::lock_guard<std::mutex> lock(p.mutex);
    if (lease < 1 || unsigned(lease) > p.slots.size()) return;
    auto& s = p.slots[lease - 1];
    if (!healthy) s.connection.reset();
    s.busy = false;
}
