#include <dispatch/dispatch.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

#ifndef NETWORK_SERVICE_NAME
#define NETWORK_SERVICE_NAME "dev.tryomarchy.network"
#endif
#include "payload-check.h"

int main(int argc, char **argv) {
    if (argc != 2 && argc != 3 && argc != 7) return 64;
    bool check = argc == 3 && !strcmp(argv[1], "check");
    if (!check && strcmp(argv[1], "ping") && strcmp(argv[1], "start")) return 64;
    if (!strcmp(argv[1], "start") && argc != 7) return 64;
    xpc_connection_t connection = xpc_connection_create_mach_service(NETWORK_SERVICE_NAME, NULL, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "operation", check ? "ping" : argv[1]);
    if (argc == 7) {
        xpc_dictionary_set_string(request, "interface", argv[2]);
        xpc_dictionary_set_int64(request, "owner", getppid());
        xpc_dictionary_set_string(request, "app", argv[3]);
        xpc_dictionary_set_string(request, "stop", argv[4]);
        xpc_dictionary_set_string(request, "compatibility", argv[5]);
        xpc_dictionary_set_string(request, "version", argv[6]);
    }
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block int result = 1;
    xpc_connection_send_message_with_reply(connection, request, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY && xpc_connection_get_euid(connection) == 0) {
            const char *error = xpc_dictionary_get_string(reply, "error");
            const char *stage = xpc_dictionary_get_string(reply, "stage");
            if (error) fprintf(stderr, "%s\n", error);
            else if (check) {
                const char *location = xpc_dictionary_get_string(reply, "resources");
                char actual[PATH_MAX], expected[PATH_MAX];
                if (location && realpath(location, actual) && realpath(argv[2], expected) && !strcmp(actual, expected) &&
                    matches_payload(expected, "socket_vmnet", xpc_dictionary_get_string(reply, "server_sha256")) &&
                    matches_payload(expected, "omarchy-network-supervisor", xpc_dictionary_get_string(reply, "supervisor_sha256"))) result = 0;
                else fprintf(stderr, "The approved networking helper belongs to another app copy or an older build. Shut down bridged VMs and use Set Up / Repair Networking from this app.\n");
            } else { if (stage) puts(stage); result = 0; }
        } else fprintf(stderr, "Networking service unavailable or this app build is not authorized. Use Set Up / Repair Networking in the launch menu.\n");
        dispatch_semaphore_signal(completed);
    });
    if (dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC))) {
        fprintf(stderr, "Networking service did not respond.\n");
        return 1;
    }
    return result;
}
