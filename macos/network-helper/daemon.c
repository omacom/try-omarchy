#include <CommonCrypto/CommonDigest.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>
#include "network-build.h"

static pid_t session_pid = -1;
static char resources[PATH_MAX];
static dispatch_source_t termination;
static bool valid_app(pid_t pid, uid_t uid) {
    struct proc_bsdinfo info;
    if (pid <= 1 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) || info.pbi_uid != uid) return false;
    char actual[PROC_PIDPATHINFO_MAXSIZE], expected[PATH_MAX], canonical[PATH_MAX];
    if (snprintf(expected,sizeof(expected),"%s/../MacOS/omarchy-vm-helper",resources)>=(int)sizeof(expected) ||
        !realpath(expected,canonical) || proc_pidpath(pid,actual,sizeof(actual))<=0) return false;
    char actual_canonical[PATH_MAX];
    return realpath(actual,actual_canonical) && !strcmp(canonical,actual_canonical);
}
static bool copy_verified(const char *name, const char *expected, int directory, const char *destination) {
    char source[PATH_MAX];
    if (snprintf(source, sizeof(source), "%s/network/%s", resources, name) >= (int)sizeof(source)) return false;
    int input = open(source, O_RDONLY | O_NOFOLLOW);
    struct stat info;
    if (input < 0) return false;
    if (fstat(input, &info) || !S_ISREG(info.st_mode) || info.st_size > 8*1024*1024) { close(input); return false; }
    int output = openat(directory, destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0500);
    if (output < 0) { close(input); return false; }
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    unsigned char buffer[16384], digest[CC_SHA256_DIGEST_LENGTH];
    ssize_t count;
    bool valid = true;
    while ((count = read(input, buffer, sizeof(buffer))) > 0) {
        CC_SHA256_Update(&hash, buffer, (CC_LONG)count);
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(output, buffer + offset, (size_t)(count-offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) { valid = false; break; }
            offset += written;
        }
        if (!valid) break;
    }
    if (count < 0 || fsync(output)) valid = false;
    CC_SHA256_Final(digest, &hash);
    close(input); close(output);
    char hex[65];
    for (size_t i=0; i<sizeof(digest); ++i) sprintf(hex+2*i, "%02x", digest[i]);
    return valid && !strcmp(hex, expected);
}
static const char *start(xpc_connection_t peer, xpc_object_t request, char stage[PATH_MAX]) {
    uid_t uid = xpc_connection_get_euid(peer), console_uid = 0;
    CFStringRef console = SCDynamicStoreCopyConsoleUser(NULL, &console_uid, NULL);
    if (console) CFRelease(console);
    if (!uid || uid != console_uid) return "Only the active signed-in user can start networking.";
    const char *interface = xpc_dictionary_get_string(request, "interface");
    const char *app = xpc_dictionary_get_string(request, "app");
    const char *stop = xpc_dictionary_get_string(request, "stop");
    const char *compat = xpc_dictionary_get_string(request, "compatibility");
    const char *version = xpc_dictionary_get_string(request, "version");
    int64_t owner = xpc_dictionary_get_int64(request, "owner");
    struct proc_bsdinfo client_info, owner_info;
    if (!version || strcmp(version, "1") || !interface || !app || !stop || !compat ||
        strlen(interface)>32 || !*interface || strspn(interface,"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")!=strlen(interface) ||
        (strcmp(compat,"0") && strcmp(compat,"1")) || owner<=1 || owner>INT_MAX) return "Invalid networking request.";
    char *end; long app_pid=strtol(app,&end,10);
    if (!*app || *end || app_pid<=1 || app_pid>INT_MAX || !valid_app((pid_t)app_pid,uid)) return "The requesting application is not authorized.";
    if (proc_pidinfo(xpc_connection_get_pid(peer), PROC_PIDTBSDINFO, 0, &client_info, sizeof(client_info)) != sizeof(client_info) ||
        client_info.pbi_ppid != owner || proc_pidinfo((pid_t)owner, PROC_PIDTBSDINFO, 0, &owner_info, sizeof(owner_info)) != sizeof(owner_info) ||
        owner_info.pbi_uid != uid || owner_info.pbi_ppid != app_pid) return "The networking request does not belong to this app launch.";
    const char *prefix="/private/tmp/omarchy-qemu-gpu.";
    size_t prefix_length=strlen(prefix);
    if (strlen(stop)!=prefix_length+6+strlen("/network.stop") || strncmp(stop,prefix,prefix_length) ||
        strspn(stop+prefix_length,"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") != 6 ||
        strcmp(stop+prefix_length+6,"/network.stop")) return "Invalid session stop path.";
    if (session_pid>0) {
        pid_t finished=waitpid(session_pid,NULL,WNOHANG);
        if (finished==0) return "Another bridged session is still active or finishing cleanup.";
        if (finished<0 && errno!=ECHILD) return "Cannot determine the previous networking session’s state.";
        kill(-session_pid, SIGTERM);
        session_pid=-1;
    }
    strcpy(stage,"/private/tmp/omarchy-network.XXXXXX");
    if (!mkdtemp(stage)) return "Cannot create the private network session.";
    int directory=open(stage,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    bool prepared = directory>=0 && copy_verified("socket_vmnet",SERVER_SHA256,directory,"socket_vmnet") &&
        copy_verified("omarchy-network-supervisor",SUPERVISOR_SHA256,directory,"supervisor");
    char executable[PATH_MAX], owner_text[32];
    snprintf(executable,sizeof(executable),"%s/supervisor",stage);
    snprintf(owner_text,sizeof(owner_text),"%lld",owner);
    char *args[]={executable,"run",stage,(char *)interface,owner_text,(char *)app,(char *)stop,(char *)compat,NULL};
    char *environment[]={"PATH=/usr/bin:/bin",NULL};
    int log=prepared?openat(directory,"log",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0644):-1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0);
    if (log>=0) {
        posix_spawn_file_actions_adddup2(&actions,log,STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions,log,STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions,log);
    }
    posix_spawnattr_t attributes;
    int error=posix_spawnattr_init(&attributes);
    if (!error) {
        error=posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
        if (!error) error=posix_spawnattr_setpgroup(&attributes, 0);
        if (!error) error=prepared && log>=0 ? posix_spawn(&session_pid,executable,&actions,&attributes,args,environment):EIO;
        posix_spawnattr_destroy(&attributes);
    }
    posix_spawn_file_actions_destroy(&actions);
    if(log>=0)close(log);
    if(error) {
        session_pid=-1;
        if(directory>=0) { unlinkat(directory,"log",0); unlinkat(directory,"supervisor",0); unlinkat(directory,"socket_vmnet",0); }
        rmdir(stage);
    }
    if(directory>=0)close(directory);
    return error?"The bundled network runtime failed verification or could not start.":NULL;
}
int main(void) {
    if(geteuid()!=0)return 1;
    char executable[PATH_MAX];uint32_t size=sizeof(executable);
    if(_NSGetExecutablePath(executable,&size))return 1;
    char *slash=strrchr(executable,'/');if(!slash)return 1;*slash=0;
    // Daemon is in Contents/MacOS; payloads remain in this app's Resources.
    slash=strrchr(executable,'/');if(!slash)return 1;*slash=0;
    if(snprintf(resources,sizeof(resources),"%s/Resources",executable)>=(int)sizeof(resources))return 1;
    signal(SIGTERM,SIG_IGN);
    termination=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
    dispatch_source_set_event_handler(termination, ^{
        if(session_pid>0) {
            kill(session_pid,SIGTERM);
            while(waitpid(session_pid,NULL,0)<0 && errno==EINTR){}
            kill(-session_pid,SIGTERM);
        }
        exit(0);
    });dispatch_resume(termination);
    xpc_connection_t listener=xpc_connection_create_mach_service(NETWORK_SERVICE_NAME,dispatch_get_main_queue(),XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if(xpc_connection_set_peer_code_signing_requirement(listener,CLIENT_REQUIREMENT))return 1;
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if(xpc_get_type(peer)!=XPC_TYPE_CONNECTION)return;
        xpc_connection_set_target_queue(peer,dispatch_get_main_queue());
        xpc_connection_set_event_handler(peer, ^(xpc_object_t request) {
            if(xpc_get_type(request)!=XPC_TYPE_DICTIONARY)return;
            xpc_object_t reply=xpc_dictionary_create_reply(request);if(!reply)return;
            const char *operation=xpc_dictionary_get_string(request,"operation");
            const char *error=NULL;char stage[PATH_MAX]={0};
            if(operation && !strcmp(operation,"start"))error=start(peer,request,stage);
            else if(!operation || strcmp(operation,"ping"))error="Unsupported networking operation.";
            if(error)xpc_dictionary_set_string(reply,"error",error);
            else {
                xpc_dictionary_set_string(reply,"resources",resources);
                xpc_dictionary_set_string(reply,"server_sha256",SERVER_SHA256);
                xpc_dictionary_set_string(reply,"supervisor_sha256",SUPERVISOR_SHA256);
                if(*stage)xpc_dictionary_set_string(reply,"stage",stage);
            }
            xpc_connection_send_message(peer,reply);xpc_release(reply);
        });xpc_connection_resume(peer);
    });xpc_connection_resume(listener);dispatch_main();
}
