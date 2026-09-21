#ifndef SOCKET_VMNET_LOG_H
#define SOCKET_VMNET_LOG_H
#include <errno.h>

extern bool debug;

#define DEBUGF(fmt, ...)                                                                           \
  do {                                                                                             \
    if (debug)                                                                                     \
      fprintf(stderr, "DEBUG| " fmt "\n", __VA_ARGS__);                                            \
  } while (0)

#define INFOF(fmt, ...) fprintf(stderr, "INFO | " fmt "\n", __VA_ARGS__)
#define ERROR(msg) fprintf(stderr, "ERROR| " msg "\n")
#define ERRORF(fmt, ...) fprintf(stderr, "ERROR| " fmt "\n", __VA_ARGS__)
#define ERRORN(name) ERRORF(name ": %s", strerror(errno))
#define WARN(msg) fprintf(stderr, "WARN | " msg "\n")
#define WARNF(fmt, ...) fprintf(stderr, "WARN | " fmt "\n", __VA_ARGS__)

#endif /* SOCKET_VMNET_LOG_H */
