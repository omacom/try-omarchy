#pragma once
#include "connection.hpp"
#include <functional>
#include <memory>

// Optional capability pool populated by the Firefox launcher before its RDD
// sandbox starts. Other applications use the regular broker connection.
extern "C" int tovd_acquire_preopened_client(int *, const uint8_t **) __attribute__((weak));
extern "C" void tovd_release_preopened_client(int, int) __attribute__((weak));

namespace tovd {
class Client {
    std::unique_ptr<Connection> connection_;
    int socket_ = -1;
    const uint8_t *pixels_ = nullptr;
    int pool_lease_ = 0;
    bool opened_ = false, healthy_ = true;
    bool gpu_ = false;
public:
    explicit Client(const char *path = "/run/omarchy-video.sock") {
        if (!strcmp(path, "/run/omarchy-video.sock") && tovd_acquire_preopened_client &&
            tovd_release_preopened_client) {
            pool_lease_ = tovd_acquire_preopened_client(&socket_, &pixels_);
            if (pool_lease_) return;
        }
        connection_ = std::make_unique<Connection>(path);
        socket_ = connection_->socket_fd(); pixels_ = connection_->pixels();
    }
    ~Client() {
        if (opened_ && healthy_) { try { Message m; m.op = 4; exchange(m, {}); } catch (...) {} }
        if (pool_lease_) tovd_release_preopened_client(pool_lease_, healthy_);
    }
    using Frame = std::function<void(const Message&, const uint8_t *, size_t)>;
    bool supports_gpu() const { return gpu_; }
    Message exchange(Message request, const Frame& frame) try {
        request.send(socket_);
        for (;;) {
            Message m = Message::receive(socket_);
            if (m.session != 1) throw std::runtime_error("invalid native video session");
            if (m.op == 0xffff) throw std::runtime_error(std::string(m.payload.begin(), m.payload.end()));
            if (m.op == 0x8100) {
                if (!(m.flags & shared_flag) || m.payload.size() != 16 || get(m.payload.data(), 8) != 0 ||
                    get(m.payload.data() + 12, 4)) throw std::runtime_error("invalid shared video frame");
                size_t size = get(m.payload.data() + 8, 4);
                bool gpu = m.flags & gpu_flag;
                if ((gpu ? (!gpu_ || size != 0) : (!size || size > slot_size)) || !frame)
                    throw std::runtime_error("unexpected decoded frame");
                frame(m, gpu ? nullptr : pixels_, size);
                Message release;
                release.op = 5; release.token = m.token;
                release.send(socket_);
            } else if (m.op == (request.op | 0x8000) && m.token == request.token && m.payload.empty()) {
                if (m.op == 0x8001) {
                    if ((m.flags & (hardware_flag | shared_flag)) != (hardware_flag | shared_flag))
                        throw std::runtime_error("native video did not confirm hardware decoding");
                    opened_ = true;
                    gpu_ = m.flags & gpu_flag;
                }
                if (m.op == 0x8004) opened_ = false;
                return m;
            } else throw std::runtime_error("unexpected native video response");
        }
    } catch (...) { healthy_ = false; throw; }
};
}
