#include "wire.hpp"
#include <atomic>
#include <csignal>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <grp.h>
#include <iostream>
#include <mutex>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <thread>

namespace {
std::mutex transport_lock;
std::array<std::atomic<bool>, 8> used{};
int transport = -1;
uint8_t *aperture = nullptr;

std::string read_attribute(const std::filesystem::path& path) {
    std::ifstream input(path);
    std::string value;
    input >> value;
    return value;
}

std::string video_resource() {
    for (const auto& entry : std::filesystem::directory_iterator("/sys/bus/pci/devices")) {
        auto p = entry.path();
        if (read_attribute(p / "vendor") == "0x1af4" &&
            read_attribute(p / "device") == "0x1110" &&
            read_attribute(p / "subsystem_device") == "0x5654") return (p / "resource2_wc").string();
    }
    throw std::runtime_error("native video PCI frame device is unavailable");
}

void greeting(int client, int memory) {
    // A read-only descriptor prevents clients from writing a decoded frame or
    // creating another writable mapping of the broker's per-client buffer.
    std::string path = "/proc/self/fd/" + std::to_string(memory);
    tovd::FD readonly(open(path.c_str(), O_RDONLY | O_CLOEXEC));
    if (readonly.get() < 0) throw std::runtime_error("cannot share frame buffer read-only");
    std::array<uint8_t, 16> hello{};
    memcpy(hello.data(), "TOVM", 4);
    tovd::put(hello.data() + 4, 1, 4); tovd::put(hello.data() + 8, tovd::slot_size, 8);
    alignas(cmsghdr) std::array<char, CMSG_SPACE(sizeof(int))> control{};
    iovec io{hello.data(), hello.size()};
    msghdr msg{};
    msg.msg_iov = &io; msg.msg_iovlen = 1;
    msg.msg_control = control.data(); msg.msg_controllen = control.size();
    auto *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET; cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    int fd = readonly.get();
    memcpy(CMSG_DATA(cmsg), &fd, sizeof(fd));
    if (sendmsg(client, &msg, MSG_NOSIGNAL) != ssize_t(hello.size()))
        throw std::runtime_error("cannot send video service greeting");
}

void serve(int client_fd, unsigned index) {
    tovd::FD client(client_fd);
    tovd::FD memory(memfd_create("omarchy-video-frame", MFD_CLOEXEC | MFD_ALLOW_SEALING));
    uint8_t *frame = nullptr;
    bool open = false;
    uint32_t session = index + 1;
    try {
        if (memory.get() < 0 || ftruncate(memory.get(), tovd::slot_size))
            throw std::runtime_error("cannot allocate video frame buffer");
        frame = static_cast<uint8_t *>(mmap(nullptr, tovd::slot_size, PROT_READ | PROT_WRITE,
                                           MAP_SHARED, memory.get(), 0));
        if (frame == MAP_FAILED) { frame = nullptr; throw std::runtime_error("cannot map video frame buffer"); }
        if (fcntl(memory.get(), F_ADD_SEALS, F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_FUTURE_WRITE | F_SEAL_SEAL))
            throw std::runtime_error("cannot seal video frame buffer");
        greeting(client.get(), memory.get());
        for (;;) {
            auto request = tovd::Message::receive(client.get(), true);
            if (request.session != 1 || request.op < 1 || request.op > 4 ||
                (request.op == 1 ? (request.flags != 1 || request.arg0 > 2) :
                 request.op == 2 && request.flags == 4 ? (!request.arg0 || !request.arg1 || request.arg0 == request.arg1) :
                                  (request.flags || request.arg0 || request.arg1)) ||
                ((request.op == 3 || request.op == 4) && !request.payload.empty()))
                throw std::runtime_error("invalid native video client request");
            request.session = session;
            std::lock_guard<std::mutex> lock(transport_lock);
            request.send(transport);
            bool client_gone = false;
            for (;;) {
                auto response = tovd::Message::receive(transport);
                if (response.session != session) throw std::runtime_error("native video transport lost session ordering");
                if (response.op == 0x8100) {
                    if (!(response.flags & tovd::shared_flag) || response.payload.size() != 16)
                        throw std::runtime_error("invalid host video frame descriptor");
                    uint64_t offset = tovd::get(response.payload.data(), 8);
                    size_t size = tovd::get(response.payload.data() + 8, 4);
                    bool gpu = response.flags & tovd::gpu_flag;
                    if (tovd::get(response.payload.data() + 12, 4) ||
                        (gpu ? (size != 0 || offset != 0) :
                         (!size || size > tovd::slot_size || offset > tovd::aperture_size || size > tovd::aperture_size - offset)))
                        throw std::runtime_error("host video frame is outside shared memory");
                    if (!client_gone) {
                        try {
                            if (!gpu) memcpy(frame, aperture + offset, size);
                            std::atomic_thread_fence(std::memory_order_release);
                            tovd::put(response.payload.data(), 0, 8);
                            response.session = 1;
                            response.send(client.get());
                            auto release = tovd::Message::receive(client.get());
                            if (release.op != 5 || release.session != 1 || release.token != response.token ||
                                release.flags || release.arg0 || release.arg1 || !release.payload.empty())
                                throw std::runtime_error("client did not release its video frame");
                        } catch (...) { client_gone = true; }
                    }
                    // Closing a player can race any frame. Always finish the
                    // host transaction, even when its client has disappeared,
                    // so another player's decoder and the broker stay alive.
                    tovd::Message release;
                    release.op = 5; release.session = session; release.token = response.token;
                    release.send(transport);
                } else {
                    if (response.op != 0xffff &&
                        (response.op != (request.op | 0x8000) || response.token != request.token))
                        throw std::runtime_error("unexpected host video acknowledgement");
                    if (response.op == 0x8001) open = true;
                    if (response.op == 0x8004 || response.op == 0xffff) open = false;
                    response.session = 1;
                    if (client_gone) throw std::runtime_error("client disconnected during frame delivery");
                    response.send(client.get());
                    break;
                }
            }
        }
    } catch (const std::exception& error) {
        std::cerr << "[video-broker] session " << session << ": " << error.what() << '\n';
    }
    if (open) {
        try {
            std::lock_guard<std::mutex> lock(transport_lock);
            tovd::Message close;
            close.op = 4; close.session = session; close.send(transport);
            auto ack = tovd::Message::receive(transport);
            if (ack.op != 0x8004 || ack.session != session) throw std::runtime_error("cannot close host decoder");
        } catch (...) {
            // A interrupted frame transaction cannot be reused safely. Let
            // systemd restart the broker and reset every host decoder session.
            _exit(1);
        }
    }
    if (frame) munmap(frame, tovd::slot_size);
    used[index] = false;
}
}

int main(int argc, char **argv) try {
    if (geteuid() != 0) throw std::runtime_error("native video broker requires root for its PCI aperture");
    if (argc > 2) throw std::runtime_error("usage: omarchy-video-broker [SOCKET]");
    const char *socket_path = argc == 2 ? argv[1] : "/run/omarchy-video.sock";
    tovd::FD port(open("/dev/virtio-ports/dev.tryomarchy.video", O_RDWR | O_CLOEXEC | O_NONBLOCK));
    if (port.get() < 0 || flock(port.get(), LOCK_EX | LOCK_NB))
        throw std::runtime_error("cannot acquire native video virtio port");
    transport = port.get();
    tovd::FD resource(open(video_resource().c_str(), O_RDONLY | O_CLOEXEC));
    if (resource.get() < 0) throw std::runtime_error("cannot open native video frame aperture");
    aperture = static_cast<uint8_t *>(mmap(nullptr, tovd::aperture_size, PROT_READ, MAP_SHARED, resource.get(), 0));
    if (aperture == MAP_FAILED) throw std::runtime_error("cannot map native video frame aperture");
    tovd::Message reset;
    reset.op = 6; reset.session = 0; reset.send(transport);
    auto reset_ack = tovd::Message::receive(transport);
    if (reset_ack.op != 0x8006 || reset_ack.session) throw std::runtime_error("cannot reset native video sessions");

    tovd::FD listener(socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0));
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (strlen(socket_path) >= sizeof(address.sun_path)) throw std::runtime_error("video socket path too long");
    strcpy(address.sun_path, socket_path);
    struct stat existing{};
    if (lstat(socket_path, &existing) == 0) {
        if (!S_ISSOCK(existing.st_mode) || existing.st_uid != 0) throw std::runtime_error("unsafe existing video service path");
        if (unlink(socket_path)) throw std::runtime_error("cannot replace video service socket");
    }
    umask(0077);
    if (listener.get() < 0 || bind(listener.get(), reinterpret_cast<sockaddr *>(&address), sizeof(address)) ||
        listen(listener.get(), 8)) throw std::runtime_error("cannot listen for native video clients");
    auto *group = getgrnam("video");
    if (!group || chown(socket_path, 0, group->gr_gid) || chmod(socket_path, 0660))
        throw std::runtime_error("cannot grant the video group access to the decoder");
    signal(SIGTERM, [](int) { _exit(0); });
    signal(SIGINT, [](int) { _exit(0); });
    std::cerr << "[video-broker] Ready: private frame buffers, 8 hardware sessions\n";
    for (;;) {
        int fd = accept4(listener.get(), nullptr, nullptr, SOCK_CLOEXEC);
        if (fd < 0 && errno == EINTR) continue;
        if (fd < 0) throw std::runtime_error("cannot accept native video client");
        unsigned index = 0;
        for (; index < used.size(); ++index) {
            bool available = false;
            if (used[index].compare_exchange_strong(available, true)) break;
        }
        if (index == used.size()) close(fd);
        else std::thread(serve, fd, index).detach();
    }
} catch (const std::exception& error) {
    std::cerr << "[video-broker] " << error.what() << '\n';
    return 1;
}
