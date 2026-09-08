// Linux integration checks for partial messages, backpressure and descriptor
// ownership. Run without a VM decoder: only private socket pairs are used.
#include "../guest/video/wire.hpp"
#include <atomic>
#include <fcntl.h>
#include <iostream>
#include <thread>

using Clock = std::chrono::steady_clock;
static void require(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}
template<typename F> static void rejects(F operation, const char *message) {
    bool threw = false;
    try { operation(); } catch (const std::exception&) { threw = true; }
    require(threw, message);
}
int main() try {
    int pair[2];
    require(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair), "socketpair failed");
    tovd::FD sender(pair[0]), receiver(pair[1]);
    tovd::Message original;
    original.op = 2; original.token = UINT64_MAX; original.payload = {1, 2, 3, 4};
    original.send(sender.get());
    auto received = tovd::Message::receive(receiver.get());
    require(received.token == UINT64_MAX && received.payload == original.payload, "wire roundtrip failed");
    std::array<uint8_t, 40> malformed{};
    memcpy(malformed.data(), "TOVD", 4); tovd::put(malformed.data() + 4, 1, 2);
    tovd::put(malformed.data() + 12, tovd::slot_size + 1, 4);
    tovd::transfer(sender.get(), malformed.data(), malformed.size(), true);
    rejects([&] { tovd::Message::receive(receiver.get()); }, "oversized payload accepted");

    // A peer that supplies occasional bytes must not extend the whole deadline.
    std::atomic<bool> done{false};
    std::thread trickle([&] {
        uint8_t byte = 0;
        while (!done) {
            send(sender.get(), &byte, 1, MSG_NOSIGNAL);
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    });
    std::array<uint8_t, 128> bytes{};
    auto start = Clock::now();
    rejects([&] { tovd::transfer(receiver.get(), bytes.data(), bytes.size(), false, 40); }, "trickle bypassed deadline");
    done = true; trickle.join();
    require(Clock::now() - start < std::chrono::seconds(2), "read did not honor whole-message deadline");
    // Writable readiness is not a guarantee that a large write can complete.
    int send_buffer = 1024;
    setsockopt(sender.get(), SOL_SOCKET, SO_SNDBUF, &send_buffer, sizeof(send_buffer));
    std::vector<uint8_t> large(4 * 1024 * 1024);
    start = Clock::now();
    rejects([&] { tovd::transfer(sender.get(), large.data(), large.size(), true, 40); }, "backpressure bypassed deadline");
    require(Clock::now() - start < std::chrono::seconds(2), "send blocked past its deadline");
    std::cout << "PASS: bounded framing, partial reads, and send backpressure\n";
    return 0;
} catch (const std::exception& error) {
    std::cerr << error.what() << '\n'; return 1;
}
