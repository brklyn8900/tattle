// Test fixture, never bundled: a caller of the packet-access broker whose signature a test
// chooses. The test runner (xctest) is not hardened and carries get-task-allow, which is
// exactly the kind of caller the broker refuses, so the daemon tests copy this program, sign
// the copy the way the case needs, and run it.
//
//   tattle-broker-probe <service> <interface> [--delay <seconds>]
//
// <service> is a test agent's Mach service in the user's launchd domain. --delay waits before
// asking, so a test can replace the file on disk after launch. Prints
// one line: accepted | refused | bad-request | open-failed <errno> | transport <errno>.
// "accepted" means a descriptor this process could prepare and filter, so it appears only
// where the capture devices are readable; with root-only devices an accepted caller prints
// "open-failed 13".

#include "packet_capture.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3 && !(argc == 5 && strcmp(argv[3], "--delay") == 0)) {
        fprintf(stderr, "usage: tattle-broker-probe <service> <interface> [--delay <seconds>]\n");
        return 2;
    }
    if (argc == 5) sleep((unsigned)atoi(argv[4]));
    int status = 0, err = 0;
    int fd = tattle_broker_request(argv[1], 0, argv[2], &status, &err);
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
        return 0;
    }
    switch (status) {
    case 1: printf("refused\n"); break;
    case 2: printf("bad-request\n"); break;
    case 3: printf("open-failed %d\n", err); break;
    default: printf("transport %d\n", err); break;
    }
    return 0;
}
