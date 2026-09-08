// Work around SME routines compiled with a non-streaming SVE prologue.
// Vivaldi 8.2.4133.33 calls CNTD before SMSTART on SME-only Apple CPUs,
// causing SIGILL while converting YouTube frames. Keep NEON and all other
// capabilities; only hide SME from this opt-in browser process when SVE is
// absent. This library is never preloaded into the system or other apps.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <sys/auxv.h>
#include <unistd.h>

static unsigned long (*original_getauxval)(unsigned long);
static pthread_once_t resolve_once = PTHREAD_ONCE_INIT;
static void resolve_getauxval(void) {
    original_getauxval = (unsigned long (*)(unsigned long))dlsym(RTLD_NEXT, "getauxval");
    if (!original_getauxval) _exit(127);
}
unsigned long getauxval(unsigned long type) {
    pthread_once(&resolve_once, resolve_getauxval);
    unsigned long value = original_getauxval(type);
#if defined(__aarch64__)
    if (type == AT_HWCAP2) {
        int saved_errno = errno;
        if (!(original_getauxval(AT_HWCAP) & (1UL << 22)))
            value &= ~((1UL << 23) | (1UL << 37));
        errno = saved_errno;
    }
#endif
    return value;
}
