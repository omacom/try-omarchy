// Run with LD_PRELOAD=firefox-video-bootstrap.so and arguments -contentproc rdd
// against the test VM's broker. No hardware decoder is opened by this test.
#include <cstdint>
#include <cstdio>
#include <fcntl.h>
extern "C" int tovd_acquire_preopened_client(int *, const uint8_t **) __attribute__((weak));
extern "C" void tovd_release_preopened_client(int, int) __attribute__((weak));
int main() {
    if (!tovd_acquire_preopened_client || !tovd_release_preopened_client) return 1;
    int a = -1, b = -1, extra = -1; const uint8_t *pixels = nullptr;
    int one = tovd_acquire_preopened_client(&a, &pixels);
    int two = tovd_acquire_preopened_client(&b, &pixels);
    if (!one || !two || one == two || a == b || !pixels ||
        tovd_acquire_preopened_client(&extra, &pixels)) return 2;
    for (unsigned i = 0; i < 100; ++i) {
        tovd_release_preopened_client(one, 1);
        if (tovd_acquire_preopened_client(&extra, &pixels) != one || extra != a) return 3;
    }
    tovd_release_preopened_client(one, 0);
    if (fcntl(a, F_GETFD) != -1 || tovd_acquire_preopened_client(&extra, &pixels)) return 4;
    tovd_release_preopened_client(two, 1);
    if (tovd_acquire_preopened_client(&extra, &pixels) != two || extra != b) return 5;
    tovd_release_preopened_client(two, 0);
    std::puts("PASS: bounded RDD capabilities, healthy reuse, and corrupt-connection retirement");
}
