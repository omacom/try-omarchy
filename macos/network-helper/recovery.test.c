/* Exercise the actual packet/lifecycle code with a fake vmnet provider. */
#define main socket_vmnet_main
#include "vendor/main.c"
#undef main

static atomic_int writes, reads, starts;
static atomic_bool inject_write_failure, inject_start_failure;
static struct fake_interface { atomic_bool stopped; } fake_interfaces[64];

interface_ref vmnet_start_interface(xpc_object_t options, dispatch_queue_t queue,
                                   vmnet_start_interface_completion_handler_t completion) {
  (void)options;
  int slot = atomic_fetch_add(&starts, 1);
  assert(slot < 64);
  struct fake_interface *fake = &fake_interfaces[slot];
  atomic_store(&fake->stopped, false);
  bool fail = atomic_exchange(&inject_start_failure, false);
  dispatch_async(queue, ^{
    xpc_object_t values = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(values, vmnet_max_packet_size_key, 1514);
    completion(fail ? VMNET_FAILURE : VMNET_SUCCESS, values);
    xpc_release(values);
  });
  return (interface_ref)fake;
}
vmnet_return_t vmnet_stop_interface(interface_ref interface, dispatch_queue_t queue,
                                   vmnet_interface_completion_handler_t completion) {
  struct fake_interface *fake = (void *)interface;
  assert(!atomic_exchange(&fake->stopped, true));
  dispatch_async(queue, ^{ completion(VMNET_SUCCESS); });
  return VMNET_SUCCESS;
}
vmnet_return_t vmnet_interface_set_event_callback(interface_ref interface, interface_event_t events,
    dispatch_queue_t queue, vmnet_interface_event_callback_t callback) {
  (void)interface; (void)events; (void)queue; (void)callback;
  return VMNET_SUCCESS;
}
vmnet_return_t vmnet_write(interface_ref interface, struct vmpktdesc *packets, int *count) {
  assert(!atomic_load(&((struct fake_interface *)(void *)interface)->stopped));
  assert(*count == 1 && packets->vm_pkt_size == 64);
  atomic_fetch_add(&writes, 1);
  return atomic_exchange(&inject_write_failure, false) ? VMNET_FAILURE : VMNET_SUCCESS;
}
vmnet_return_t vmnet_read(interface_ref interface, struct vmpktdesc *packets, int *count) {
  (void)packets;
  assert(!atomic_load(&((struct fake_interface *)(void *)interface)->stopped));
  atomic_fetch_add(&reads, 1);
  *count = 0;
  return VMNET_SUCCESS;
}
static void frame(int fd) {
  uint32_t size = htonl(64);
  unsigned char bytes[64] = {0};
  struct iovec vectors[2] = {{&size, 4}, {bytes, sizeof(bytes)}};
  assert(write_frame(fd, vectors) == 68);
}
static void await_writes(int count) {
  for (int i = 0; i < 200 && atomic_load(&writes) < count; ++i) usleep(1000);
  assert(atomic_load(&writes) >= count);
}

static double monotonic_seconds(void) {
  struct timespec now;
  assert(!clock_gettime(CLOCK_MONOTONIC, &now));
  return now.tv_sec + now.tv_nsec / 1e9;
}
static void append_expected(unsigned char *expected, size_t *length,
                            const unsigned char *packet, size_t size) {
  uint32_t header = htonl((uint32_t)size);
  memcpy(expected + *length, &header, 4);
  memcpy(expected + *length + 4, packet, size);
  *length += size + 4;
}
static void drain_output(struct state *state, struct conn *conn, int peer,
                         const unsigned char *expected, size_t expected_size) {
  unsigned char received[2048];
  size_t total = 0;
  double deadline = monotonic_seconds() + 3;
  while (total < expected_size || conn->output_length) {
    assert(monotonic_seconds() < deadline);
    ssize_t count = recv(peer, received, sizeof(received), MSG_DONTWAIT);
    if (count > 0) {
      assert(total + (size_t)count <= expected_size);
      assert(!memcmp(received, expected + total, (size_t)count));
      total += (size_t)count;
    } else {
      assert(count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));
    }
    struct kevent event;
    struct timespec timeout = {0, 1000000};
    int events = kevent(state->kq, NULL, 0, &event, 1, &timeout);
    assert(events >= 0);
    if (events) {
      assert(event.filter == EVFILT_WRITE && event.ident == (uintptr_t)conn->socket_fd);
      assert(!(event.flags & EV_ERROR));
      assert(flush_connection(state, conn));
    }
    assert(conn->output_offset + conn->output_length <= sizeof(conn->output));
  }
  assert(total == expected_size && !conn->output_watched);
  assert(conn->output_offset == 0);
}
static void test_output_backpressure(void) {
  struct state state = {.kq = kqueue()};
  assert(state.kq >= 0);
  state.sem = dispatch_semaphore_create(1);
  int sockets[2];
  assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, sockets));
  int buffer_size = 4096;
  assert(!setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &buffer_size, sizeof(buffer_size)));
  assert(!setsockopt(sockets[1], SOL_SOCKET, SO_RCVBUF, &buffer_size, sizeof(buffer_size)));
  assert(!fcntl(sockets[1], F_SETFL, fcntl(sockets[1], F_GETFL) | O_NONBLOCK));
  assert(state_add_socket_fd(&state, sockets[0]));
  dispatch_semaphore_wait(state.sem, DISPATCH_TIME_FOREVER);
  struct conn *conn = state.conns;
  unsigned char *expected = malloc(1024 * 1024);
  assert(expected);
  size_t expected_size = 0;
  unsigned char packet[32768];
  for (size_t i = 0; i < sizeof(packet); ++i) packet[i] = (unsigned char)(i % 251);
  assert(queue_frame(&state, conn, packet, sizeof(packet)) == 1);
  append_expected(expected, &expected_size, packet, sizeof(packet));
  assert(conn->output_offset > 0 && conn->output_length > 0); // forced partial head frame
  assert(conn->output_watched);
  int dropped = 0;
  for (int sequence = 1; sequence <= 512; ++sequence) {
    for (size_t i = 0; i < 1514; ++i) packet[i] = (unsigned char)((sequence + i * 7) % 251);
    int accepted = queue_frame(&state, conn, packet, 1514);
    assert(accepted >= 0);
    if (accepted) append_expected(expected, &expected_size, packet, 1514);
    else ++dropped;
    assert(conn->output_offset + conn->output_length <= sizeof(conn->output));
  }
  assert(dropped > 0 && conn->output_length > 0);
  // Backpressure must not close the stream; read_exact handles nonblocking input.
  assert(fcntl(sockets[0], F_GETFL) & O_NONBLOCK);
  assert(send(sockets[1], "x", 1, MSG_DONTWAIT) == 1);
  unsigned char probe = 0;
  assert(recv(sockets[0], &probe, 1, MSG_DONTWAIT) == 1 && probe == 'x');
  drain_output(&state, conn, sockets[1], expected, expected_size);
  // A new packet is delivered on the same connection after the peer resumes.
  memset(packet, 0xa5, 64);
  expected_size = 0;
  assert(queue_frame(&state, conn, packet, 64) == 1);
  append_expected(expected, &expected_size, packet, 64);
  drain_output(&state, conn, sockets[1], expected, expected_size);
  free(expected);
  dispatch_semaphore_signal(state.sem);
  state_remove_socket_fd(&state, sockets[0]);
  close(sockets[1]);
  close(state.kq);
  dispatch_release(state.sem);
}
int main(void) {
  alarm(15); // Also bound a regression that blocks inside a supposedly nonblocking syscall.
  test_output_backpressure();
  struct link_recovery policy = {.attached_index = 5};
  assert(link_recovery_step(&policy, 5, true, false) == LINK_WAIT);
  assert(link_recovery_step(&policy, 0, true, false) == LINK_DETACH);
  assert(link_recovery_step(&policy, 0, false, false) == LINK_WAIT);
  assert(link_recovery_step(&policy, 6, false, false) == LINK_WAIT);
  assert(link_recovery_step(&policy, 6, false, false) == LINK_ATTACH);
  assert(link_recovery_step(&policy, 6, true, false) == LINK_DETACH); // missed unplug, changed index
  policy.attached_index = 6;
  assert(link_recovery_step(&policy, 6, true, true) == LINK_DETACH);
  policy.retry_ticks = 5;
  for (int i = 0; i < 4; ++i) assert(link_recovery_step(&policy, 6, false, false) == LINK_WAIT);
  assert(link_recovery_step(&policy, 6, false, false) == LINK_WAIT);
  assert(link_recovery_step(&policy, 6, false, false) == LINK_ATTACH);

  struct state state = {.status_directory = -1};
  pthread_rwlock_init(&state.interface_lock, NULL);
  atomic_init(&state.restart_requested, false);
  state.sem = dispatch_semaphore_create(1);
  state.host_queue = dispatch_queue_create("test.vmnet", DISPATCH_QUEUE_SERIAL);
  struct cli_options options = {.vmnet_mode = VMNET_BRIDGED_MODE, .vmnet_interface = "en-test"};
  int sockets[2];
  assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, sockets));
  struct state *shared = &state;
  dispatch_group_t group = dispatch_group_create();
  int server_socket = sockets[1];
  dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ on_accept(shared, server_socket); });
  struct link_recovery initial = {0};
  for (int i = 0; i < 100; ++i) {
    assert(link_recovery_step(&initial, 0, false, false) == LINK_WAIT);
    frame(sockets[0]);
  }
  usleep(50000);
  assert(atomic_load(&writes) == 0);
  assert(state.active_interface == NULL);
  assert(link_recovery_step(&initial, 7, false, false) == LINK_WAIT);
  assert(link_recovery_step(&initial, 7, false, false) == LINK_ATTACH);
  interface_ref first = start(&state, &options);
  assert(first);
  uint64_t old_generation = state.generation;
  frame(sockets[0]); await_writes(1);
  stop(&state, first);
  for (int i = 0; i < 100; ++i) frame(sockets[0]); // drained while disconnected, socket remains open
  usleep(50000);
  assert(atomic_load(&writes) == 1);
  _on_vmnet_packets_available(first, 1, 1514, &state, old_generation);
  assert(atomic_load(&reads) == 0); // stale callback never reads a stopped handle
  atomic_store(&inject_start_failure, true);
  assert(start(&state, &options) == NULL);
  assert(state.active_interface == NULL);
  interface_ref current = start(&state, &options);
  assert(current);
  // Also reject an old generation if an allocator reuses the handle address.
  _on_vmnet_packets_available(current, 1, 1514, &state, old_generation);
  assert(atomic_load(&reads) == 0);
  frame(sockets[0]); await_writes(2);
  atomic_store(&inject_write_failure, true);
  frame(sockets[0]); await_writes(3);
  assert(atomic_load(&state.restart_requested));
  frame(sockets[0]); // failed generation drains packets until the lifecycle owner reconnects
  usleep(20000);
  assert(atomic_load(&writes) == 3);
  stop(&state, current);
  current = start(&state, &options);
  frame(sockets[0]); await_writes(4); // recoverable write error did not close the socket
  for (int i = 0; i < 20; ++i) {
    frame(sockets[0]);
    stop(&state, current);
    frame(sockets[0]);
    current = start(&state, &options);
    assert(current);
  }
  shutdown(sockets[0], SHUT_WR);
  assert(!dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)));
  close(sockets[0]);
  stop(&state, current);
  alarm(0);
  puts("recovery.test: bounded backpressure, intact framing, packet stream, stale callback, failure retry, and repeated lifecycle: PASS");
}
