// Test fixture, never bundled: a caller of the packet-access broker whose signature a test
// chooses. The test runner (xctest) is not hardened and carries get-task-allow, which is
// exactly the kind of caller the broker refuses, so the daemon tests copy this program, sign
// the copy the way the case needs, and run it.
//
//   tattle-broker-probe <service> <interface> [--delay <seconds>] [--exception-ports]
//
// <service> is a test agent's Mach service in the user's launchd domain. --delay waits before
// asking, so a test can replace the file on disk after launch. Prints
// one line: accepted | refused | bad-request | open-failed <errno> | transport <errno>.
// --exception-ports adds three lines: "inherited-ports <n>", how many crash exception ports the
// probe held before asking; "exception-ports <n>", how many ports it still holds after asking for
// types that hand over its live task; and "corpse-ports <n>", how many it holds for corpse
// notifications, which must stay (ADR-0003).
//
//   tattle-broker-probe <service> <interface> --send-then-exec <program> [<argument>...]
//
// Sends the request without waiting for the answer, then execs <program> in the same process,
// which the broker must not take for the sender (ADR-0003). Prints nothing itself.
// "accepted" means a descriptor this process could prepare and filter, so it appears only
// where the capture devices are readable; with root-only devices an accepted caller prints
// "open-failed 13".

#include "packet_capture.h"

#include <dispatch/dispatch.h>
#include <errno.h>
#include <stdbool.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <xpc/xpc.h>

static int exception_ports(exception_mask_t mask) {
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    if (task_get_exception_ports(mach_task_self(), mask, masks, &count, ports, behaviors, flavors) != KERN_SUCCESS) return -1;
    int held = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (MACH_PORT_VALID(ports[i])) held++;
    }
    return held;
}

static void report(int fd, int status, int err) {
    if (fd >= 0) {
        unsigned int length = 0, link = 0;
        tattle_filter_insn accept_all = { 0x06, 0, 0, 0xffff };  // BPF_RET|BPF_K
        if (tattle_capture_prepare(fd, 100, &length, &link) == 0 && length > 0
            && tattle_capture_set_filter(fd, &accept_all, 1) == 0) {
            printf("accepted\n");
        } else {
            printf("transport %d\n", errno);
        }
        close(fd);
        return;
    }
    switch (status) {
    case 1: printf("refused\n"); break;
    case 2: printf("bad-request\n"); break;
    case 3: printf("open-failed %d\n", err); break;
    default: printf("transport %d\n", err); break;
    }
}

// The barrier runs once the request has left this process, so the exec cannot overtake it.
static int send_then_exec(const char *service, const char *ifname, char **program) {
    xpc_connection_t connection = xpc_connection_create_mach_service(service, NULL, 0);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { (void)event; });
    xpc_connection_activate(connection);
    xpc_object_t request = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(request, "interface", ifname);
    xpc_connection_send_message_with_reply(connection, request, NULL, ^(xpc_object_t reply) { (void)reply; });
    dispatch_semaphore_t sent = dispatch_semaphore_create(0);
    xpc_connection_send_barrier(connection, ^{ dispatch_semaphore_signal(sent); });
    dispatch_semaphore_wait(sent, DISPATCH_TIME_FOREVER);
    execv(program[0], program);
    perror("execv");
    return 1;
}

int main(int argc, char **argv) {
    unsigned delay = 0;
    bool show_ports = false;
    bool usable = argc >= 3;
    for (int i = 3; usable && i < argc; i++) {
        if (strcmp(argv[i], "--send-then-exec") == 0 && i + 1 < argc) return send_then_exec(argv[1], argv[2], &argv[i + 1]);
        if (strcmp(argv[i], "--delay") == 0 && i + 1 < argc) delay = (unsigned)atoi(argv[++i]);
        else if (strcmp(argv[i], "--exception-ports") == 0) show_ports = true;
        else usable = false;
    }
    if (!usable) {
        fprintf(stderr, "usage: tattle-broker-probe <service> <interface> [--delay <seconds>] [--exception-ports]\n"
                        "       tattle-broker-probe <service> <interface> --send-then-exec <program> [<argument>...]\n");
        return 2;
    }
    if (delay > 0) sleep(delay);
    int inherited = exception_ports(EXC_MASK_CRASH);
    int status = 0, err = 0;
    int fd = tattle_broker_request(argv[1], 0, argv[2], &status, &err);
    report(fd, status, err);
    if (show_ports) {
        printf("inherited-ports %d\n", inherited);
        printf("exception-ports %d\n", exception_ports(EXC_MASK_ALL | EXC_MASK_CRASH));
        printf("corpse-ports %d\n", exception_ports(EXC_MASK_CORPSE_NOTIFY));
    }
    return 0;
}
