#pragma once
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

namespace tovd {
constexpr size_t header_size = 40;
constexpr size_t slot_size = 64u * 1024 * 1024;
constexpr size_t aperture_size = 8 * slot_size;
constexpr uint32_t hardware_flag = 0x100, shared_flag = 0x200, gpu_flag = 0x400;

inline uint64_t get(const uint8_t *p, unsigned n) {
    uint64_t v = 0;
    for (unsigned i = 0; i < n; ++i) v |= uint64_t(p[i]) << (8 * i);
    return v;
}
inline void put(uint8_t *p, uint64_t v, unsigned n) {
    for (unsigned i = 0; i < n; ++i) p[i] = uint8_t(v >> (8 * i));
}

inline void transfer(int fd, void *data, size_t size, bool sending, int timeout_ms = 5000) {
    auto *p = static_cast<uint8_t *>(data);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (size) {
        pollfd wait{fd, short(sending ? POLLOUT : POLLIN), 0};
        int remaining = -1;
        if (timeout_ms >= 0) {
            auto duration = deadline - std::chrono::steady_clock::now();
            if (duration <= decltype(duration)::zero()) throw std::runtime_error("video transport timed out");
            remaining = std::chrono::duration_cast<std::chrono::milliseconds>(duration).count() + 1;
        }
        int ready = poll(&wait, 1, remaining);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) throw std::runtime_error("video transport timed out");
        ssize_t count;
        if (sending) {
            count = send(fd, p, size, MSG_NOSIGNAL | MSG_DONTWAIT);
            if (count < 0 && errno == ENOTSOCK) count = write(fd, p, size);
        } else {
            count = recv(fd, p, size, MSG_DONTWAIT);
            if (count < 0 && errno == ENOTSOCK) count = read(fd, p, size);
        }
        if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (count <= 0) throw std::runtime_error("video transport closed");
        p += count;
        size -= count;
    }
}

struct Message {
    uint16_t op = 0;
    uint32_t session = 1;
    uint64_t token = 0;
    uint32_t arg0 = 0, arg1 = 0, flags = 0;
    std::vector<uint8_t> payload;

    void send(int fd) const {
        if (payload.size() > slot_size) throw std::runtime_error("video payload too large");
        std::array<uint8_t, header_size> h{};
        memcpy(h.data(), "TOVD", 4);
        put(h.data() + 4, 1, 2); put(h.data() + 6, op, 2);
        put(h.data() + 8, session, 4); put(h.data() + 12, payload.size(), 4);
        put(h.data() + 16, token, 8); put(h.data() + 24, arg0, 4);
        put(h.data() + 28, arg1, 4); put(h.data() + 32, flags, 4);
        transfer(fd, h.data(), h.size(), true);
        transfer(fd, const_cast<uint8_t *>(payload.data()), payload.size(), true);
    }

    static Message receive(int fd, bool idle = false) {
        std::array<uint8_t, header_size> h{};
        // Idle clients can remain paused indefinitely. Once a message starts,
        // bound every remaining read so one client cannot stall other decoders.
        transfer(fd, h.data(), 1, false, idle ? -1 : 5000);
        transfer(fd, h.data() + 1, h.size() - 1, false);
        if (memcmp(h.data(), "TOVD", 4) || get(h.data() + 4, 2) != 1 || get(h.data() + 36, 4))
            throw std::runtime_error("invalid video message header");
        size_t size = get(h.data() + 12, 4);
        if (size > slot_size) throw std::runtime_error("video payload too large");
        Message m;
        m.op = get(h.data() + 6, 2); m.session = get(h.data() + 8, 4);
        m.token = get(h.data() + 16, 8); m.arg0 = get(h.data() + 24, 4);
        m.arg1 = get(h.data() + 28, 4); m.flags = get(h.data() + 32, 4);
        m.payload.resize(size);
        transfer(fd, m.payload.data(), size, false);
        return m;
    }
};

class FD {
    int fd_ = -1;
public:
    explicit FD(int fd = -1) : fd_(fd) {}
    ~FD() { if (fd_ >= 0) close(fd_); }
    FD(const FD&) = delete;
    FD& operator=(const FD&) = delete;
    int get() const { return fd_; }
};
}
