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
// --exception-ports adds a second line, "exception-ports <n>": how many task exception ports
// the probe still holds after asking.
// "accepted" means a descriptor this process could prepare and filter, so it appears only
// where the capture devices are readable; with root-only devices an accepted caller prints
// "open-failed 13".

#include "packet_capture.h"

#include <errno.h>
#include <stdbool.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int exception_ports(void) {
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    if (task_get_exception_ports(mach_task_self(), EXC_MASK_ALL, masks, &count, ports, behaviors, flavors) != KERN_SUCCESS) return -1;
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

int main(int argc, char **argv) {
    unsigned delay = 0;
    bool show_ports = false;
    bool usable = argc >= 3;
    for (int i = 3; usable && i < argc; i++) {
        if (strcmp(argv[i], "--delay") == 0 && i + 1 < argc) delay = (unsigned)atoi(argv[++i]);
        else if (strcmp(argv[i], "--exception-ports") == 0) show_ports = true;
        else usable = false;
    }
    if (!usable) {
        fprintf(stderr, "usage: tattle-broker-probe <service> <interface> [--delay <seconds>] [--exception-ports]\n");
        return 2;
    }
    if (delay > 0) sleep(delay);
    int status = 0, err = 0;
    int fd = tattle_broker_request(argv[1], 0, argv[2], &status, &err);
    report(fd, status, err);
    if (show_ports) printf("exception-ports %d\n", exception_ports());
    return 0;
}
