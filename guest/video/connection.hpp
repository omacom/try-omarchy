#pragma once
#include "wire.hpp"
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

namespace tovd {
class Connection {
    FD socket_;
    uint8_t *pixels_ = nullptr;
public:
    explicit Connection(const char *path)
        : socket_(socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0)) {
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        if (strlen(path) >= sizeof(address.sun_path)) throw std::runtime_error("video socket path too long");
        strcpy(address.sun_path, path);
        if (socket_.get() < 0 || connect(socket_.get(), reinterpret_cast<sockaddr *>(&address), sizeof(address)))
            throw std::runtime_error(std::string("native video service unavailable: ") + strerror(errno));
        std::array<uint8_t, 16> hello{};
        alignas(cmsghdr) std::array<char, CMSG_SPACE(sizeof(int))> control{};
        iovec io{hello.data(), hello.size()};
        msghdr msg{};
        msg.msg_iov = &io; msg.msg_iovlen = 1;
        msg.msg_control = control.data(); msg.msg_controllen = control.size();
        pollfd pending{socket_.get(), POLLIN, 0};
        int ready;
        do { ready = poll(&pending, 1, 2000); } while (ready < 0 && errno == EINTR);
        if (ready <= 0) throw std::runtime_error("native video greeting timed out");
        ssize_t received = recvmsg(socket_.get(), &msg, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
        int frame_fd = -1;
        unsigned descriptors = 0;
        for (auto *cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
            if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS) continue;
            for (size_t offset = CMSG_LEN(0); offset + sizeof(int) <= cmsg->cmsg_len; offset += sizeof(int)) {
                int fd; memcpy(&fd, reinterpret_cast<const uint8_t *>(cmsg) + offset, sizeof(fd));
                if (descriptors++ == 0) frame_fd = fd;
                else close(fd);
            }
        }
        FD owned(frame_fd);
        if (received <= 0 || descriptors != 1 || (msg.msg_flags & (MSG_CTRUNC | MSG_TRUNC)))
            throw std::runtime_error("invalid native video service greeting");
        // SCM_RIGHTS accompanies the first byte. Stream sockets may split the
        // remaining greeting; bound that read instead of blocking in MSG_WAITALL.
        transfer(socket_.get(), hello.data() + received, hello.size() - received, false, 2000);
        struct stat info{};
        if (fstat(frame_fd, &info) || !S_ISREG(info.st_mode) || info.st_size != slot_size ||
            (fcntl(frame_fd, F_GETFL) & O_ACCMODE) != O_RDONLY ||
            memcmp(hello.data(), "TOVM", 4) || get(hello.data() + 4, 4) != 1 ||
            get(hello.data() + 8, 8) != slot_size || frame_fd < 0)
            throw std::runtime_error("invalid native video service greeting");
        pixels_ = static_cast<uint8_t *>(mmap(nullptr, slot_size, PROT_READ, MAP_SHARED, frame_fd, 0));
        if (pixels_ == MAP_FAILED) { pixels_ = nullptr; throw std::runtime_error("cannot map decoded video frames"); }
    }
    ~Connection() { if (pixels_) munmap(pixels_, slot_size); }
    int socket_fd() const { return socket_.get(); }
    const uint8_t *pixels() const { return pixels_; }
};
}
