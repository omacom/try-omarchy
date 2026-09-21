/* Local changes: framed packet I/O and bridge recovery; see ../README.md. */
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <grp.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_media.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/ioctl.h>
#include <sys/sockio.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>
#include <vmnet/vmnet.h>

#include "cli.h"
#include "log.h"
#include "stream.h"
#include "link-recovery.h"

#if __MAC_OS_X_VERSION_MAX_ALLOWED < 101500
#error "Requires macOS 10.15 or later"
#endif

#define ARRAY_SIZE(a) (sizeof(a) / sizeof(a[0]))

bool debug = false;

static const char *vmnet_strerror(vmnet_return_t v) {
  switch (v) {
  case VMNET_SUCCESS:
    return "VMNET_SUCCESS";
  case VMNET_FAILURE:
    return "VMNET_FAILURE";
  case VMNET_MEM_FAILURE:
    return "VMNET_MEM_FAILURE";
  case VMNET_INVALID_ARGUMENT:
    return "VMNET_INVALID_ARGUMENT";
  case VMNET_SETUP_INCOMPLETE:
    return "VMNET_SETUP_INCOMPLETE";
  case VMNET_INVALID_ACCESS:
    return "VMNET_INVALID_ACCESS";
  case VMNET_PACKET_TOO_BIG:
    return "VMNET_PACKET_TOO_BIG";
  case VMNET_BUFFER_EXHAUSTED:
    return "VMNET_BUFFER_EXHAUSTED";
  case VMNET_TOO_MANY_PACKETS:
    return "VMNET_TOO_MANY_PACKETS";
  default:
    return "(unknown status)";
  }
}

static void print_vmnet_start_param(xpc_object_t param) {
  if (param == NULL)
    return;
  xpc_dictionary_apply(param, ^bool(const char *key, xpc_object_t value) {
    xpc_type_t t = xpc_get_type(value);
    if (t == XPC_TYPE_UINT64)
      INFOF("* %s: %lld", key, xpc_uint64_get_value(value));
    else if (t == XPC_TYPE_INT64)
      INFOF("* %s: %lld", key, xpc_int64_get_value(value));
    else if (t == XPC_TYPE_STRING)
      INFOF("* %s: %s", key, xpc_string_get_string_ptr(value));
    else if (t == XPC_TYPE_UUID) {
      char uuid_str[36 + 1];
      uuid_unparse(xpc_uuid_get_bytes(value), uuid_str);
      INFOF("* %s: %s", key, uuid_str);
    } else
      INFOF("* %s: (unknown type)", key);
    return true;
  });
}

struct conn {
  // TODO: uint8_t mac[6];
  int socket_fd;
  struct conn *next;
  unsigned char output[256 * 1024];
  size_t output_offset;
  size_t output_length;
  bool output_watched;
} _conn;

struct state {
  dispatch_semaphore_t sem;
  dispatch_queue_t vms_queue;
  dispatch_queue_t host_queue;
  struct conn *conns; // TODO: avoid O(N) lookup
  pthread_rwlock_t interface_lock;
  interface_ref active_interface;
  uint64_t generation;
  atomic_bool restart_requested;
  int status_directory;
  int kq;
  uint64_t status_generation;
} _state;

static bool state_add_socket_fd(struct state *state, int socket_fd) {
  struct conn *conn = calloc(1, sizeof(*conn));
  if (!conn) return false;
  int flags = fcntl(socket_fd, F_GETFL);
  int no_sigpipe = 1;
  if (flags < 0 || fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) ||
      setsockopt(socket_fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe))) {
    free(conn);
    return false;
  }
  conn->socket_fd = socket_fd;
  dispatch_semaphore_wait(state->sem, DISPATCH_TIME_FOREVER);
  if (state->conns == NULL) {
    state->conns = conn;
  } else {
    struct conn *last;
    for (last = state->conns; last->next != NULL; last = last->next)
      ;
    last->next = conn;
  }
  dispatch_semaphore_signal(state->sem);
  return true;
}

static void state_remove_socket_fd(struct state *state, int socket_fd) {
  dispatch_semaphore_wait(state->sem, DISPATCH_TIME_FOREVER);
  struct conn **next = &state->conns;
  while (*next && (*next)->socket_fd != socket_fd) next = &(*next)->next;
  if (*next) {
    struct conn *removed = *next;
    *next = removed->next;
    if (removed->output_watched) {
      struct kevent event;
      EV_SET(&event, socket_fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
      kevent(state->kq, &event, 1, NULL, 0, NULL);
    }
    close(removed->socket_fd);
    free(removed);
  }
  dispatch_semaphore_signal(state->sem);
}

/* The connection-list semaphore also serializes each framed output stream.
 * Never block a vmnet callback on a guest that has not enabled its NIC yet. */
static bool flush_connection(struct state *state, struct conn *conn) {
  while (conn->output_length) {
    ssize_t count = send(conn->socket_fd, conn->output + conn->output_offset,
                         conn->output_length, MSG_DONTWAIT);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
    if (count <= 0) {
      shutdown(conn->socket_fd, SHUT_RDWR);
      return false;
    }
    conn->output_offset += (size_t)count;
    conn->output_length -= (size_t)count;
  }
  if (!conn->output_length) conn->output_offset = 0;
  bool watch = conn->output_length != 0;
  if (watch != conn->output_watched) {
    struct kevent event;
    EV_SET(&event, conn->socket_fd, EVFILT_WRITE,
           watch ? EV_ADD | EV_ENABLE | EV_CLEAR : EV_DELETE, 0, 0, NULL);
    if (kevent(state->kq, &event, 1, NULL, 0, NULL) && (watch || errno != ENOENT)) {
      shutdown(conn->socket_fd, SHUT_RDWR);
      return false;
    }
    conn->output_watched = watch;
  }
  return true;
}

static int queue_frame(struct state *state, struct conn *conn, const void *packet, size_t size) {
  if (!flush_connection(state, conn)) return -1;
  // Drop a whole Ethernet packet under backpressure, never a partial stream frame.
  if (size > sizeof(conn->output) - 4 || size + 4 > sizeof(conn->output) - conn->output_length) return 0;
  if (conn->output_offset + conn->output_length + size + 4 > sizeof(conn->output)) {
    memmove(conn->output, conn->output + conn->output_offset, conn->output_length);
    conn->output_offset = 0;
  }
  uint32_t header = htonl((uint32_t)size);
  unsigned char *end = conn->output + conn->output_offset + conn->output_length;
  memcpy(end, &header, 4);
  memcpy(end + 4, packet, size);
  conn->output_length += size + 4;
  return flush_connection(state, conn) ? 1 : -1;
}

static void _on_vmnet_packets_available(interface_ref iface, int64_t buf_count, int64_t max_bytes,
                                        struct state *state, uint64_t generation) {
  DEBUGF("Receiving from VMNET (buffer for %lld packets, max: %lld "
         "bytes)",
         buf_count, max_bytes);
  // TODO: use prealloced pool
  struct vmpktdesc *pdv = calloc(buf_count, sizeof(struct vmpktdesc));
  if (pdv == NULL) {
    ERRORN("calloc(estim_count, sizeof(struct vmpktdesc)");
    goto done;
  }
  for (int i = 0; i < buf_count; i++) {
    pdv[i].vm_flags = 0;
    pdv[i].vm_pkt_size = max_bytes;
    pdv[i].vm_pkt_iovcnt = 1, pdv[i].vm_pkt_iov = malloc(sizeof(struct iovec));
    if (pdv[i].vm_pkt_iov == NULL) {
      ERRORN("malloc(sizeof(struct iovec))");
      goto done;
    }
    pdv[i].vm_pkt_iov->iov_base = malloc(max_bytes);
    if (pdv[i].vm_pkt_iov->iov_base == NULL) {
      ERRORN("malloc(max_bytes)");
      goto done;
    }
    pdv[i].vm_pkt_iov->iov_len = max_bytes;
  }
  int received_count = buf_count;
  pthread_rwlock_rdlock(&state->interface_lock);
  if (state->active_interface != iface || state->generation != generation ||
      atomic_load(&state->restart_requested)) {
    pthread_rwlock_unlock(&state->interface_lock);
    goto done;
  }
  vmnet_return_t read_status = vmnet_read(iface, pdv, &received_count);
  if (read_status != VMNET_SUCCESS) atomic_store(&state->restart_requested, true);
  pthread_rwlock_unlock(&state->interface_lock);
  if (read_status != VMNET_SUCCESS) {
    ERRORF("vmnet_read: [%d] %s", read_status, vmnet_strerror(read_status));
    goto done;
  }

  DEBUGF("Received from VMNET: %d packets (buffer was prepared for %lld packets)", received_count,
         buf_count);
  for (int i = 0; i < received_count; i++) {
    uint8_t dest_mac[6], src_mac[6];
    assert(pdv[i].vm_pkt_iov[0].iov_len > 12);
    const char *packet = (const char *)pdv[i].vm_pkt_iov[0].iov_base;
    memcpy(dest_mac, packet, sizeof(dest_mac));
    memcpy(src_mac, packet + 6, sizeof(src_mac));
    DEBUGF("[Handler i=%d] Dest %02X:%02X:%02X:%02X:%02X:%02X, Src "
           "%02X:%02X:%02X:%02X:%02X:%02X,",
           i, dest_mac[0], dest_mac[1], dest_mac[2], dest_mac[3], dest_mac[4], dest_mac[5],
           src_mac[0], src_mac[1], src_mac[2], src_mac[3], src_mac[4], src_mac[5]);
    dispatch_semaphore_wait(state->sem, DISPATCH_TIME_FOREVER);
    struct conn *conns = state->conns;
    for (struct conn *conn = conns; conn != NULL; conn = conn->next) {
      // FIXME: avoid flooding
      DEBUGF("[Handler i=%d] Sending to the socket %d: 4 + %ld bytes [Dest "
             "%02X:%02X:%02X:%02X:%02X:%02X]",
             i, conn->socket_fd, pdv[i].vm_pkt_size, dest_mac[0], dest_mac[1], dest_mac[2],
             dest_mac[3], dest_mac[4], dest_mac[5]);
      if (queue_frame(state, conn, pdv[i].vm_pkt_iov[0].iov_base, pdv[i].vm_pkt_size) < 0) {
        dispatch_semaphore_signal(state->sem);
        goto done;
      }
    }
    dispatch_semaphore_signal(state->sem);
  }
done:
  if (pdv != NULL) {
    for (int i = 0; i < buf_count; i++) {
      if (pdv[i].vm_pkt_iov != NULL) {
        if (pdv[i].vm_pkt_iov->iov_base != NULL) {
          free(pdv[i].vm_pkt_iov->iov_base);
        }
        free(pdv[i].vm_pkt_iov);
      }
    }
    free(pdv);
  }
}

#define MAX_PACKET_COUNT_AT_ONCE 32
static void on_vmnet_packets_available(interface_ref iface, int64_t estim_count, int64_t max_bytes,
                                       struct state *state, uint64_t generation) {
  int64_t q = estim_count / MAX_PACKET_COUNT_AT_ONCE;
  int64_t r = estim_count % MAX_PACKET_COUNT_AT_ONCE;
  DEBUGF("estim_count=%lld, dividing by MAX_PACKET_COUNT_AT_ONCE=%d; q=%lld, "
         "r=%lld",
         estim_count, MAX_PACKET_COUNT_AT_ONCE, q, r);
  for (int i = 0; i < q; i++) {
    _on_vmnet_packets_available(iface, MAX_PACKET_COUNT_AT_ONCE, max_bytes, state, generation);
  }
  if (r > 0)
    _on_vmnet_packets_available(iface, r, max_bytes, state, generation);
}

static void stop(struct state *state, interface_ref iface);

static interface_ref start(struct state *state, struct cli_options *cliopt) {
  INFOF("Initializing vmnet.framework (mode %d)", cliopt->vmnet_mode);
  xpc_object_t dict = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(dict, vmnet_operation_mode_key, cliopt->vmnet_mode);
  if (cliopt->vmnet_interface != NULL) {
    INFOF("Using network interface \"%s\"", cliopt->vmnet_interface);
    xpc_dictionary_set_string(dict, vmnet_shared_interface_name_key, cliopt->vmnet_interface);
  }

  if (!uuid_is_null(cliopt->vmnet_network_identifier)) {
    xpc_dictionary_set_uuid(dict, vmnet_network_identifier_key, cliopt->vmnet_network_identifier);
  }

  if (cliopt->vmnet_gateway != NULL) {
    xpc_dictionary_set_string(dict, vmnet_start_address_key, cliopt->vmnet_gateway);
    xpc_dictionary_set_string(dict, vmnet_end_address_key, cliopt->vmnet_dhcp_end);
    xpc_dictionary_set_string(dict, vmnet_subnet_mask_key, cliopt->vmnet_mask);
  }

  xpc_dictionary_set_uuid(dict, vmnet_interface_id_key, cliopt->vmnet_interface_id);

  if (cliopt->vmnet_nat66_prefix != NULL) {
    xpc_dictionary_set_string(dict, vmnet_nat66_prefix_key, cliopt->vmnet_nat66_prefix);
  }

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);

  __block interface_ref iface;
  __block vmnet_return_t status;

  __block uint64_t max_bytes = 0;
  iface = vmnet_start_interface(
      dict, state->host_queue, ^(vmnet_return_t x_status, xpc_object_t x_param) {
        status = x_status;
        if (x_status == VMNET_SUCCESS) {
          print_vmnet_start_param(x_param);
          max_bytes = xpc_dictionary_get_uint64(x_param, vmnet_max_packet_size_key);
        }
        dispatch_semaphore_signal(sem);
      });
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
    ERRORF("%s", "vmnet start timed out; ending this network session");
    exit(1);
  }
  dispatch_release(sem);
  xpc_release(dict);
  if (status != VMNET_SUCCESS) {
    ERRORF("vmnet_start_interface: [%d] %s", status, vmnet_strerror(status));
    return NULL;
  }

  pthread_rwlock_wrlock(&state->interface_lock);
  uint64_t generation = ++state->generation;
  state->active_interface = iface;
  pthread_rwlock_unlock(&state->interface_lock);
  vmnet_return_t event_status = vmnet_interface_set_event_callback(
      iface, VMNET_INTERFACE_PACKETS_AVAILABLE, state->host_queue,
      ^(interface_event_t __attribute__((unused)) x_event_id, xpc_object_t x_event) {
        uint64_t estim_count =
            xpc_dictionary_get_uint64(x_event, vmnet_estimated_packets_available_key);
        on_vmnet_packets_available(iface, estim_count, max_bytes, state, generation);
      });

  if (event_status != VMNET_SUCCESS) {
    ERRORF("Cannot monitor vmnet packets: %d", event_status);
    stop(state, iface);
    return NULL;
  }
  return iface;
}

static void stop(struct state *state, interface_ref iface) {
  if (iface == NULL) {
    return;
  }
  pthread_rwlock_wrlock(&state->interface_lock);
  state->active_interface = NULL;
  atomic_store(&state->restart_requested, false);
  ++state->generation;
  pthread_rwlock_unlock(&state->interface_lock);
  vmnet_interface_set_event_callback(iface, VMNET_INTERFACE_PACKETS_AVAILABLE, NULL, NULL);
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block vmnet_return_t status;
  vmnet_return_t scheduled = vmnet_stop_interface(iface, state->host_queue, ^(vmnet_return_t x_status) {
    status = x_status;
    dispatch_semaphore_signal(sem);
  });
  if (scheduled != VMNET_SUCCESS ||
      dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
    ERRORF("%s", "vmnet stop failed or timed out; ending this network session");
    exit(1);
  }
  dispatch_release(sem);
  if (status != VMNET_SUCCESS) {
    ERRORF("vmnet_stop_interface: [%d] %s", status, vmnet_strerror(status));
    exit(1);
  }
}

static int socket_bindlisten(const char *socket_path, const char *socket_group) {
  int fd = -1;
  struct sockaddr_un addr = {0};

  unlink(socket_path); /* avoid EADDRINUSE */
  if ((fd = socket(PF_LOCAL, SOCK_STREAM, 0)) < 0) {
    ERRORN("socket");
    goto err;
  }
  addr.sun_family = PF_LOCAL;
  size_t socket_len = strlen(socket_path);
  if (socket_len + 1 > sizeof(addr.sun_path)) {
    ERRORF("the socket path is too long: %zu", socket_len);
    goto err;
  }
  strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    ERRORN("bind");
    goto err;
  }
  if (listen(fd, 0) < 0) {
    ERRORN("listen");
    goto err;
  }
  if (socket_group != NULL) {
    errno = 0;
    struct group *grp = getgrnam(socket_group); /* Do not free */
    if (grp == NULL) {
      if (errno != 0)
        ERRORN("getgrnam");
      else
        ERRORF("unknown group name \"%s\"", socket_group);
      goto err;
    }
    /* fchown can't be used (EINVAL) */
    if (chown(socket_path, -1, grp->gr_gid) < 0) {
      ERRORN("chown");
      goto err;
    }
    if (chmod(socket_path, 0770) < 0) {
      ERRORN("chmod");
      goto err;
    }
  }
  return fd;
err:
  if (fd >= 0)
    close(fd);
  return -1;
}

static void remove_pidfile(const char *pidfile) {
  if (unlink(pidfile) != 0) {
    ERRORF("Failed to remove pidfile: \"%s\": %s", pidfile, strerror(errno));
    return;
  }
  INFOF("Removed pidfile \"%s\" for process %d", pidfile, getpid());
}

static int create_pidfile(const char *pidfile) {
  int flags = O_WRONLY | O_CREAT | O_EXLOCK | O_TRUNC | O_NONBLOCK;
  int fd = open(pidfile, flags, 0644);
  if (fd == -1) {
    ERRORF("Failed to open pidfile: \"%s\": %s", pidfile, strerror(errno));
    return -1;
  }

  char pid[20];
  snprintf(pid, sizeof(pid), "%u", getpid());
  ssize_t n = write(fd, pid, strlen(pid));
  if (n != (ssize_t)strlen(pid)) {
    if (n < 0) {
      ERRORF("Failed to write pidfile: \"%s\": %s", pidfile, strerror(errno));
    } else {
      // Should never happen, but if it does errno is not set.
      ERRORF("Short write to pidfile: \"%s\"", pidfile);
    }
    remove_pidfile(pidfile);
    close(fd);
    return -1;
  }

  INFOF("Created pidfile \"%s\" for process %d", pidfile, getpid());
  return fd;
}

static int setup_signals(int kq) {
  struct kevent changes[] = {
      {.ident = SIGHUP,  .filter = EVFILT_SIGNAL, .flags = EV_ADD},
      {.ident = SIGINT,  .filter = EVFILT_SIGNAL, .flags = EV_ADD},
      {.ident = SIGTERM, .filter = EVFILT_SIGNAL, .flags = EV_ADD},
  };

  // Block signals we want to receive via kqueue.
  sigset_t mask;
  sigemptyset(&mask);
  for (size_t i = 0; i < ARRAY_SIZE(changes); i++) {
    sigaddset(&mask, changes[i].ident);
  }
  if (sigprocmask(SIG_BLOCK, &mask, NULL) != 0) {
    ERRORN("sigprocmask");
    return -1;
  }

  // We will receive EPIPE on the socket.
  signal(SIGPIPE, SIG_IGN);

  if (kevent(kq, changes, ARRAY_SIZE(changes), NULL, 0, NULL) != 0) {
    ERRORN("kevent");
    return -1;
  }
  return 0;
}

static int add_listen_fd(int kq, int fd) {
  struct kevent changes[] = {
      {.ident = fd, .filter = EVFILT_READ, .flags = EV_ADD},
  };
  if (kevent(kq, changes, ARRAY_SIZE(changes), NULL, 0, NULL) != 0) {
    ERRORN("kevent");
    return -1;
  }
  return 0;
}

static void on_accept(struct state *state, int accept_fd);

static unsigned int physical_interface(const char *name) {
  struct ifaddrs *list = NULL;
  unsigned int index = 0;
  if (getifaddrs(&list)) return UINT_MAX;
  for (struct ifaddrs *item = list; item; item = item->ifa_next) {
    if (strcmp(item->ifa_name, name) || !item->ifa_addr ||
        item->ifa_addr->sa_family != AF_LINK || !(item->ifa_flags & IFF_UP)) continue;
    index = ((struct sockaddr_dl *)item->ifa_addr)->sdl_index;
    break;
  }
  freeifaddrs(list);
  if (!index) return 0;
  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) return UINT_MAX;
  struct ifmediareq media = {0};
  strlcpy(media.ifm_name, name, sizeof(media.ifm_name));
  if (!ioctl(fd, SIOCGIFMEDIA, &media)) {
    if ((media.ifm_status & IFM_AVALID) && !(media.ifm_status & IFM_ACTIVE)) index = 0;
  } else if (errno != ENOTSUP && errno != ENOTTY && errno != EINVAL) {
    index = UINT_MAX;
  }
  close(fd);
  return index;
}

static bool publish_link(struct state *state, bool up) {
  if (state->status_directory < 0) return true;
  char text[64];
  int length = snprintf(text, sizeof(text), "%llu %s\n",
      (unsigned long long)++state->status_generation, up ? "up" : "down");
  int fd = openat(state->status_directory, "link-state.tmp",
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
  if (fd < 0) return false;
  bool ok = write(fd, text, (size_t)length) == length;
  close(fd);
  if (ok) ok = !renameat(state->status_directory, "link-state.tmp", state->status_directory, "link-state");
  if (!ok) unlinkat(state->status_directory, "link-state.tmp", 0);
  return ok;
}

int main(int argc, char *argv[]) {
  debug = getenv("DEBUG") != NULL;
  int rc = 1;
  int listen_fd = -1;
  int pidfile_fd = -1;
  int kq = -1;
  interface_ref iface = NULL;

  struct state state = {.status_directory = -1};
  pthread_rwlock_init(&state.interface_lock, NULL);
  atomic_init(&state.restart_requested, false);
  struct link_recovery recovery = {0};

  struct cli_options *cliopt = cli_options_parse(argc, argv);
  assert(cliopt != NULL);
  if (geteuid() != 0) {
    WARN("Running without root. This is very unlikely to work: See README.md");
  }
  if (geteuid() != getuid()) {
    WARN("Seems running with SETUID. This is insecure and highly discouraged: See README.md");
  }

  kq = kqueue();
  state.kq = kq;
  if (kq == -1) {
    ERRORN("kqueue");
    goto done;
  }

  // Setup signals beofre creating the pidfile to ensure removal of the pidfile
  // when terminating by signal.
  if (setup_signals(kq)) {
    goto done;
  }

  if (cliopt->pidfile != NULL) {
    pidfile_fd = create_pidfile(cliopt->pidfile);
    if (pidfile_fd == -1) {
      goto done; // error already logged.
    }
  }

  DEBUGF("Opening socket \"%s\" (for UNIX group \"%s\")", cliopt->socket_path,
         cliopt->socket_group);
  listen_fd = socket_bindlisten(cliopt->socket_path, cliopt->socket_group);
  if (listen_fd < 0) {
    ERRORN("socket_bindlisten");
    goto done;
  }

  state.sem = dispatch_semaphore_create(1);

  // Queue for vm connections, allowing processing vms requests in parallel.
  state.vms_queue =
      dispatch_queue_create("io.github.lima-vm.socket_vmnet.vms", DISPATCH_QUEUE_CONCURRENT);

  // Queue for processing vmnet events.
  state.host_queue =
      dispatch_queue_create("io.github.lima-vm.socket_vmnet.host", DISPATCH_QUEUE_SERIAL);

  if (cliopt->vmnet_mode == VMNET_BRIDGED_MODE) {
    char directory[PATH_MAX];
    strlcpy(directory, cliopt->socket_path, sizeof(directory));
    char *slash = strrchr(directory, '/');
    if (!slash) goto done;
    *slash = 0;
    state.status_directory = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (state.status_directory < 0 || fstat(state.status_directory, &info) ||
        info.st_uid != 0 || (info.st_mode & 022)) goto done;
    if (!publish_link(&state, false)) goto done;
    struct kevent timer;
    EV_SET(&timer, 1, EVFILT_TIMER, EV_ADD | EV_ENABLE, 0, 1000, NULL);
    if (kevent(kq, &timer, 1, NULL, 0, NULL)) goto done;
  }
  if (cliopt->vmnet_mode != VMNET_BRIDGED_MODE) {
    iface = start(&state, cliopt);
    if (iface == NULL) goto done;
  }

  if (add_listen_fd(kq, listen_fd)) {
    goto done;
  }

  while (1) {
    struct kevent events[1];
    int n = kevent(kq, NULL, 0, events, 1, NULL);
    if (n < 0) {
      ERRORN("kevent");
      goto done;
    }

    if (events[0].filter == EVFILT_SIGNAL) {
      INFOF("Received signal %s", strsignal(events[0].ident));
      break;
    }

    if (events[0].filter == EVFILT_WRITE) {
      dispatch_semaphore_wait(state.sem, DISPATCH_TIME_FOREVER);
      for (struct conn *conn = state.conns; conn; conn = conn->next) {
        if (conn->socket_fd == (int)events[0].ident) {
          flush_connection(&state, conn);
          break;
        }
      }
      dispatch_semaphore_signal(state.sem);
      continue;
    }
    if (events[0].filter == EVFILT_TIMER) {
      unsigned int index = physical_interface(cliopt->vmnet_interface);
      if (index == UINT_MAX) continue; // An observation error is not a confirmed disconnect.
      enum link_action action = link_recovery_step(&recovery, index, iface != NULL,
          atomic_exchange(&state.restart_requested, false));
      if (action == LINK_DETACH) {
        INFOF("%s", "Bridge interface disconnected or changed; waiting to reconnect");
        if (!publish_link(&state, false)) goto done;
        stop(&state, iface);
        iface = NULL;
      } else if (action == LINK_ATTACH) {
        iface = start(&state, cliopt);
        if (iface && physical_interface(cliopt->vmnet_interface) != index) {
          stop(&state, iface);
          iface = NULL;
        }
        if (iface) {
          recovery.attached_index = index;
          if (!publish_link(&state, true)) goto done;
          INFOF("%s", "Bridge interface reconnected; existing VM connection preserved");
        } else {
          recovery.retry_ticks = 5;
          INFOF("%s", "Bridge reconnection deferred; retrying in five seconds");
        }
      }
      continue;
    }
    if (events[0].filter == EVFILT_READ) {
      int accept_fd = accept(listen_fd, NULL, NULL);
      if (accept_fd < 0) {
        ERRORN("accept");
        goto done;
      }
      struct state *state_p = &state;
      dispatch_async(state.vms_queue, ^{
        on_accept(state_p, accept_fd);
      });
    }
  }
  rc = 0;
done:
  DEBUGF("shutting down with rc=%d", rc);
  if (iface != NULL) {
    stop(&state, iface);
  }
  if (state.status_directory >= 0) close(state.status_directory);
  if (listen_fd != -1) {
    close(listen_fd);
  }
  if (pidfile_fd != -1) {
    remove_pidfile(cliopt->pidfile);
    close(pidfile_fd);
  }
  if (state.vms_queue != NULL)
    dispatch_release(state.vms_queue);
  if (state.host_queue != NULL)
    dispatch_release(state.host_queue);
  if (kq != -1) {
    close(kq);
  }
  cli_options_destroy(cliopt);
  return rc;
}

static void on_accept(struct state *state, int accept_fd) {
  INFOF("Accepted a connection (fd %d)", accept_fd);
  if (!state_add_socket_fd(state, accept_fd)) { close(accept_fd); return; }
  size_t buf_len = 64 * 1024;
  void *buf = malloc(buf_len);
  if (buf == NULL) {
    ERRORN("malloc");
    goto done;
  }
  for (uint64_t i = 0;; i++) {
    DEBUGF("[Socket-to-VMNET i=%lld] Receiving from the socket %d", i, accept_fd);
    uint32_t header_be = 0;
    ssize_t header_received = read_exact(accept_fd, &header_be, 4);
    if (header_received < 0) {
      ERRORN("read[header]");
      goto done;
    }
    if (header_received != 4) {
      // EOF according to man page of read.
      INFOF("Connection closed by peer (fd %d)", accept_fd);
      goto done;
    }
    uint32_t header = ntohl(header_be);
    if (header < 14 || header > buf_len) {
      ERRORF("Invalid Ethernet frame length: %u", header);
      goto done;
    }
    ssize_t received = read_exact(accept_fd, buf, header);
    if (received < 0) {
      ERRORN("read[body]");
      goto done;
    }
    if (received != header) {
      // EOF according to man page of read.
      INFOF("Connection closed by peer (fd %d)", accept_fd);
      goto done;
    }
    DEBUGF("[Socket-to-VMNET i=%lld] Received from the socket %d: %ld bytes", i, accept_fd,
           received);
    struct iovec iov = {
        .iov_base = buf,
        .iov_len = header,
    };
    struct vmpktdesc pd = {
        .vm_pkt_size = header,
        .vm_pkt_iov = &iov,
        .vm_pkt_iovcnt = 1,
        .vm_flags = 0,
    };
    int written_count = pd.vm_pkt_iovcnt;
    DEBUGF("[Socket-to-VMNET i=%lld] Sending to VMNET: %ld bytes", i, pd.vm_pkt_size);
    pthread_rwlock_rdlock(&state->interface_lock);
    interface_ref iface = state->active_interface;
    vmnet_return_t write_status = iface && !atomic_load(&state->restart_requested) ? vmnet_write(iface, &pd, &written_count) : VMNET_SUCCESS;
    if (write_status != VMNET_SUCCESS) atomic_store(&state->restart_requested, true);
    pthread_rwlock_unlock(&state->interface_lock);
    if (write_status != VMNET_SUCCESS) {
      ERRORF("vmnet_write: [%d] %s", write_status, vmnet_strerror(write_status));
      continue;
    }
    DEBUGF("[Socket-to-VMNET i=%lld] Sent to VMNET: %ld bytes", i, pd.vm_pkt_size);

    // Flood the packet to other VMs in the same network too.
    // (Not handled by vmnet)
    // FIXME: avoid flooding
    dispatch_semaphore_wait(state->sem, DISPATCH_TIME_FOREVER);
    struct conn *conns = state->conns;
    for (struct conn *conn = conns; conn != NULL; conn = conn->next) {
      if (conn->socket_fd == accept_fd)
        continue;
      DEBUGF("[Socket-to-Socket i=%lld] Sending from socket %d to socket %d: "
             "4 + %d bytes",
             i, accept_fd, conn->socket_fd, header);
      queue_frame(state, conn, buf, header);
    }
    dispatch_semaphore_signal(state->sem);
  }
done:
  INFOF("Closing a connection (fd %d)", accept_fd);
  state_remove_socket_fd(state, accept_fd);
  if (buf != NULL) {
    free(buf);
  }
}
