#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <vmnet/vmnet.h>

static volatile sig_atomic_t stopping;
static const char *compatibility_key = "net.link.bridge.use_dhcp_xid";
static void stop(int value) { (void)value; stopping = 1; }
static bool process_info(pid_t pid, struct proc_bsdinfo *info) {
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info)) == sizeof(*info);
}
static bool same_process(pid_t pid, const struct proc_bsdinfo *original) {
    struct proc_bsdinfo current;
    return process_info(pid, &current) && current.pbi_status != 5 &&
        current.pbi_uid == original->pbi_uid &&
        current.pbi_start_tvsec == original->pbi_start_tvsec &&
        current.pbi_start_tvusec == original->pbi_start_tvusec;
}
static pid_t parse_pid(const char *text) {
    char *end;
    long result = strtol(text, &end, 10);
    return *text && !*end && result > 1 && result <= INT_MAX ? (pid_t)result : -1;
}
static void marker(int directory, const char *name, const char *value) {
    int fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0644);
    if (fd >= 0) { (void)write(fd, value, strlen(value)); close(fd); }
}
static bool change_setting(int value) {
    return sysctlbyname(compatibility_key, NULL, NULL, &value, sizeof(value)) == 0;
}
static void terminate(pid_t child) {
    if (child < 1) return;
    kill(child, SIGTERM);
    for (int i = 0; i < 50; ++i) {
        if (waitpid(child, NULL, WNOHANG) == child) return;
        usleep(100000);
    }
    kill(child, SIGKILL);
    (void)waitpid(child, NULL, 0);
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--interfaces")) {
        xpc_object_t list = vmnet_copy_shared_interface_list();
        if (!list) return 1;
        for (size_t i = 0; i < xpc_array_get_count(list); ++i)
            puts(xpc_array_get_string(list, i));
        xpc_release(list);
        return 0;
    }
    if (argc != 8 || strcmp(argv[1], "run") || geteuid() != 0) return 64;
    const char *stage = argv[2], *interface = argv[3], *stop_path = argv[6];
    bool compatibility = !strcmp(argv[7], "1");
    if (!compatibility && strcmp(argv[7], "0")) return 64;
    if (strncmp(stage, "/private/tmp/omarchy-network.", 29) || strchr(stage + 29, '/')) return 64;
    int directory = open(stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    struct stat statbuf;
    if (directory < 0 || fstat(directory, &statbuf) || statbuf.st_uid != 0 || (statbuf.st_mode & 022)) return 1;
    int result = 1, lock = -1, previous = -1;
    bool changed = false;
    pid_t child = -1;
    pid_t owner = parse_pid(argv[4]), app = parse_pid(argv[5]);
    struct proc_bsdinfo owner_info, app_info;
    if (owner < 0 || app < 0 || !process_info(owner, &owner_info) ||
        !process_info(app, &app_info) || !owner_info.pbi_uid || owner_info.pbi_uid != app_info.pbi_uid) {
        fprintf(stderr, "The launching application is no longer available.\n"); goto finish;
    }
    signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGHUP, stop);
    signal(SIGPIPE, SIG_IGN);
    char helper[PATH_MAX], socket_path[PATH_MAX], interface_argument[128];
    if (snprintf(helper, sizeof(helper), "%s/socket_vmnet", stage) >= (int)sizeof(helper) ||
        snprintf(socket_path, sizeof(socket_path), "%s/network.sock", stage) >= (int)sizeof(socket_path) ||
        snprintf(interface_argument, sizeof(interface_argument), "--vmnet-interface=%s", interface) >= (int)sizeof(interface_argument)) goto finish;
    lock = open("/private/var/run/try-omarchy-network.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    if (lock < 0 || fstat(lock, &statbuf) || !S_ISREG(statbuf.st_mode) || statbuf.st_uid != 0 ||
        statbuf.st_nlink != 1 || (statbuf.st_mode & 077) || flock(lock, LOCK_EX | LOCK_NB)) {
        fprintf(stderr, "Another bridged Try Omarchy session is active, or its lock is unavailable.\n"); goto finish;
    }
    /* Recover a pending restoration after an interrupted supervisor. */
    char pending[4] = {0};
    ssize_t count = pread(lock, pending, sizeof(pending), 0);
    if (count < 0) goto finish;
    if (count) {
        if (count != 2 || pending[1] != '\n' || (pending[0] != '0' && pending[0] != '1') ||
            !change_setting(pending[0] - '0') || ftruncate(lock, 0) || fsync(lock)) {
            fprintf(stderr, "Cannot restore the previous Wi-Fi compatibility setting.\n"); goto finish;
        }
    }
    if (compatibility) {
        size_t length = sizeof(previous);
        if (sysctlbyname(compatibility_key, &previous, &length, NULL, 0)) {
            if (errno != ENOENT) { perror("Read Wi-Fi compatibility"); goto finish; }
        } else {
            if (length != sizeof(previous) || (previous != 0 && previous != 1)) goto finish;
            if (previous == 1) {
                if (pwrite(lock, "1\n", 2, 0) != 2 || fsync(lock)) goto finish;
                changed = true;
                if (!change_setting(0)) { perror("Enable Wi-Fi compatibility"); goto finish; }
            }
        }
    }
    child = fork();
    if (child < 0) goto finish;
    if (child == 0) {
        close(lock); close(directory);
        execl(helper, helper, "--vmnet-mode=bridged", interface_argument, socket_path, (char *)NULL);
        _exit(127);
    }
    bool ready = false;
    struct timespec started, now;
    clock_gettime(CLOCK_MONOTONIC, &started);
    while (!stopping && same_process(owner, &owner_info) && same_process(app, &app_info) && access(stop_path, F_OK)) {
        int status;
        if (waitpid(child, &status, WNOHANG) == child) {
            child = -1;
            fprintf(stderr, "The network helper exited unexpectedly.\n"); goto finish;
        }
        if (!ready && fstatat(directory, "network.sock", &statbuf, AT_SYMLINK_NOFOLLOW) == 0 && S_ISSOCK(statbuf.st_mode)) {
            if (fchownat(directory, "network.sock", owner_info.pbi_uid, -1, AT_SYMLINK_NOFOLLOW) ||
                fchmodat(directory, "network.sock", 0600, 0)) goto finish;
            if (fchmod(directory, 0711)) goto finish;
            marker(directory, "ready", "ready\n"); ready = true;
        }
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (!ready && now.tv_sec - started.tv_sec > 15) {
            fprintf(stderr, "The bridge did not become ready.\n"); goto finish;
        }
        usleep(100000);
    }
    result = 0;
finish:
    terminate(child);
    if (changed) {
        if (!change_setting(previous)) {
            fprintf(stderr, "Wi-Fi restoration failed. Restore %s to %d.\n", compatibility_key, previous);
            result = 1;
        } else if (ftruncate(lock, 0) || fsync(lock)) {
            fprintf(stderr, "Could not clear the Wi-Fi recovery record.\n"); result = 1;
        } else fprintf(stderr, "Wi-Fi compatibility restored.\n");
    }
    if (lock >= 0) close(lock);
    fchmod(directory, 0711);
    marker(directory, result ? "failed" : "done", result ? "failed\n" : "done\n");
    /* Leave a short window for the launcher to read the result and error log. */
    sleep(10);
    const char *files[] = {"network.sock", "link-state", "link-state.tmp", "ready", "done", "failed", "log", "socket_vmnet", "supervisor"};
    for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); ++i) unlinkat(directory, files[i], 0);
    close(directory);
    rmdir(stage);
    return result;
}
