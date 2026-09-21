#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include "vendor/stream.h"

int main(void) {
    int pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        close(pair[0]);
        for (size_t i = 0; i < 4; ++i) {
            assert(write(pair[1], &"head"[i], 1) == 1);
            usleep(10000);
        }
        assert(write(pair[1], "abc", 3) == 3);
        close(pair[1]);
        _exit(0);
    }
    close(pair[1]);
    char header[4], body[5];
    assert(read_exact(pair[0], header, sizeof(header)) == 4);
    assert(memcmp(header, "head", 4) == 0);
    assert(read_exact(pair[0], body, sizeof(body)) == 3);
    assert(memcmp(body, "abc", 3) == 0);
    close(pair[0]);
    int status;
    assert(waitpid(child, &status, 0) == child && status == 0);

    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    int size = 1024;
    assert(setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0);
    child = fork();
    assert(child >= 0);
    if (!child) {
        close(pair[0]);
        size_t received = 0;
        char buffer[97];
        ssize_t count;
        while ((count = read(pair[1], buffer, sizeof(buffer))) > 0) {
            for (ssize_t i = 0; i < count; ++i) assert(buffer[i] == 'x');
            received += (size_t)count;
        }
        assert(count == 0 && received == 200004);
        close(pair[1]);
        _exit(0);
    }
    close(pair[1]);
    char *payload = malloc(200000);
    assert(payload);
    memset(payload, 'x', 200000);
    struct iovec vectors[2] = {{.iov_base = "xxxx", .iov_len = 4}, {.iov_base = payload, .iov_len = 200000}};
    assert(write_frame(pair[0], vectors) == 200004);
    close(pair[0]);
    free(payload);
    assert(waitpid(child, &status, 0) == child && status == 0);
    return 0;
}
