/* Local stream framing fixes for socket_vmnet; see ../README.md. */
#ifndef OMARCHY_VMNET_STREAM_H
#define OMARCHY_VMNET_STREAM_H
#include <errno.h>
#include <poll.h>
#include <sys/uio.h>
#include <unistd.h>

static ssize_t read_exact(int fd, void *buffer, size_t length) {
  size_t received = 0;
  while (received < length) {
    ssize_t count = read(fd, (char *)buffer + received, length - received);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      struct pollfd readable = {.fd = fd, .events = POLLIN};
      int ready;
      do { ready = poll(&readable, 1, -1); } while (ready < 0 && errno == EINTR);
      if (ready < 0 || (readable.revents & POLLNVAL)) return -1;
      continue;
    }
    if (count < 0) return -1;
    if (count == 0) return (ssize_t)received;
    received += (size_t)count;
  }
  return (ssize_t)received;
}

static inline ssize_t write_frame(int fd, struct iovec vectors[2]) {
  struct iovec pending[2] = {vectors[0], vectors[1]};
  size_t written = 0;
  int first = 0;
  while (first < 2) {
    ssize_t count = writev(fd, pending + first, 2 - first);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return -1;
    written += (size_t)count;
    size_t remaining = (size_t)count;
    while (first < 2 && remaining >= pending[first].iov_len) {
      remaining -= pending[first].iov_len;
      ++first;
    }
    if (first < 2) {
      pending[first].iov_base = (char *)pending[first].iov_base + remaining;
      pending[first].iov_len -= remaining;
    }
  }
  return (ssize_t)written;
}
#endif
