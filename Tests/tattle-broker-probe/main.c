// Test fixture, never bundled: a caller of the packet-access broker whose signature a test
// chooses. The test runner (xctest) is not hardened and carries get-task-allow, which is
// exactly the kind of caller the broker refuses, so the daemon tests copy this program, sign
// the copy the way the case needs, and run it.
//
//   tattle-broker-probe <service> <interface> [--delay <seconds>] [--hold <seconds>] [--exception-ports]
//
// <service> is a test agent's Mach service in the user's launchd domain. --delay waits before
// asking, so a test can replace the file on disk after launch. Prints
// one line: accepted | refused | bad-request | open-failed <errno> | transport <errno>.
// "accepted" means a descriptor this process could prepare and filter, so it appears only
// where the capture devices are readable; with root-only devices an accepted caller prints
// "open-failed 13".
// --hold <seconds> asks once on a connection of its own, prints the answer at once, keeps the
// connection open that long without closing it, then prints "closed" if the broker closed it
// meanwhile, "open" if not.
// --exception-ports adds three lines: "dropped-at-launch <n>", how many inherited task exception
// ports the launch drop removed; "exception-ports <n>", how many the probe still held when its own
// code started, for types that hand over its live task; and "corpse-ports <n>", how many it held
// then for corpse notifications, which must stay (ADR-0003).
//
//   tattle-broker-probe <service> <interface> --send-then-exec <program> [<argument>...]
//
// Sends the request without waiting for the answer, then execs <program> in the same process,
// which the broker must not take for the sender (ADR-0003). Prints nothing itself.
//
//   tattle-broker-probe --hold-corpse <program> [<argument>...]
//
// Holds a corpse-notification port of its own, which <program> inherits; Tattle keeps that port
// (ADR-0003). Starts <program>, waits for its first output, aborts it, and prints what the dead
// process it then receives allows: "exception <n>", "read allowed|refused", "write
// allowed|refused", "thread allowed|refused", then "descriptors-before <n>" and
// "descriptors-after <n>", the open files the kernel lists for <program> before and after.
//
//   tattle-broker-probe --wait
//
// Prints "waiting" and waits to be killed.

#include "packet_capture.h"

#include <dispatch/dispatch.h>
#include <errno.h>
#include <libproc.h>
#include <stdbool.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <signal.h>
#include <spawn.h>
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

static int ask_and_hold(const char *service, const char *ifname, unsigned seconds) {
    dispatch_queue_t queue = dispatch_queue_create("hold", NULL);
    __block bool closed = false;  // read and set on `queue` only
    xpc_connection_t connection = xpc_connection_create_mach_service(service, queue, 0);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (event == XPC_ERROR_CONNECTION_INTERRUPTED) closed = true;
    });
    xpc_connection_activate(connection);
    xpc_object_t request = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(request, "interface", ifname);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, request);
    int status = -1, err = 0, fd = -1;
    if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
        status = (int)xpc_dictionary_get_int64(reply, "status");
        if (status == 0) fd = xpc_dictionary_dup_fd(reply, "descriptor");
        else if (status == 3) err = (int)xpc_dictionary_get_int64(reply, "errno");
    } else {
        err = reply == XPC_ERROR_CONNECTION_INTERRUPTED ? ECONNRESET : ECONNREFUSED;
    }
    report(fd, status, err);
    fflush(stdout);
    sleep(seconds);
    __block bool was_closed = false;
    dispatch_sync(queue, ^{ was_closed = closed; });
    printf("%s\n", was_closed ? "closed" : "open");
    return 0;
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

extern char **environ;

// An exception message as MACH_EXCEPTION_CODES delivers it, with room for the trailer.
#pragma pack(4)
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t ndr;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    int64_t code[2];
    mach_msg_max_trailer_t trailer;
} exception_message;
#pragma pack()

static int open_files(pid_t pid) {
    struct proc_fdinfo files[256];
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, files, sizeof files);
    return bytes > 0 ? bytes / (int)sizeof files[0] : 0;
}

static int hold_corpse(char **program) {
    alarm(30);  // never outlive a test that went wrong
    mach_port_t port = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS
        || mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS
        || task_set_exception_ports(mach_task_self(), EXC_MASK_CORPSE_NOTIFY, port, EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES,
                                    THREAD_STATE_NONE) != KERN_SUCCESS) {
        fprintf(stderr, "cannot hold a corpse port\n");
        return 1;
    }
    int out[2];
    if (pipe(out) != 0) return 1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, out[0]);
    posix_spawn_file_actions_addclose(&actions, out[1]);
    pid_t pid = 0;
    int spawned = posix_spawn(&pid, program[0], &actions, NULL, program, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(out[1]);
    if (spawned != 0) {
        fprintf(stderr, "posix_spawn: %s\n", strerror(spawned));
        return 1;
    }
    char line[32];
    if (read(out[0], line, sizeof line) <= 0) {
        fprintf(stderr, "no output from %s\n", program[0]);
        return 1;
    }
    int before = open_files(pid);
    kill(pid, SIGABRT);
    exception_message message;
    memset(&message, 0, sizeof message);
    if (mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof message, port, 10000, MACH_PORT_NULL) != MACH_MSG_SUCCESS) {
        printf("nothing\n");
        return 0;
    }
    task_t corpse = message.task.name;
    printf("exception %d\n", message.exception);
    mach_vm_address_t address = 0;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    uint32_t word = 0;
    mach_vm_size_t got = 0;
    bool readable = mach_vm_region(corpse, &address, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS
        && mach_vm_read_overwrite(corpse, address, sizeof word, (mach_vm_address_t)&word, &got) == KERN_SUCCESS;
    printf("read %s\n", readable ? "allowed" : "refused");
    printf("write %s\n", mach_vm_write(corpse, address, (vm_offset_t)&word, sizeof word) == KERN_SUCCESS ? "allowed" : "refused");
    thread_act_t thread = MACH_PORT_NULL;
    printf("thread %s\n", thread_create(corpse, &thread) == KERN_SUCCESS ? "allowed" : "refused");
    printf("descriptors-before %d\n", before);
    printf("descriptors-after %d\n", open_files(pid));
    // No wait: the program cannot finish dying until this port goes, with this process.
    return 0;
}

int main(int argc, char **argv) {
    // What this program holds when its own code starts, before it asks anything.
    int held = exception_ports(EXC_MASK_ALL | EXC_MASK_CRASH);
    int corpse = exception_ports(EXC_MASK_CORPSE_NOTIFY);
    if (argc >= 3 && strcmp(argv[1], "--hold-corpse") == 0) return hold_corpse(&argv[2]);
    if (argc == 2 && strcmp(argv[1], "--wait") == 0) {
        printf("waiting\n");
        fflush(stdout);
        pause();
        return 0;
    }
    unsigned delay = 0, hold = 0;
    bool show_ports = false;
    bool usable = argc >= 3;
    for (int i = 3; usable && i < argc; i++) {
        if (strcmp(argv[i], "--send-then-exec") == 0 && i + 1 < argc) return send_then_exec(argv[1], argv[2], &argv[i + 1]);
        if (strcmp(argv[i], "--delay") == 0 && i + 1 < argc) delay = (unsigned)atoi(argv[++i]);
        else if (strcmp(argv[i], "--hold") == 0 && i + 1 < argc) hold = (unsigned)atoi(argv[++i]);
        else if (strcmp(argv[i], "--exception-ports") == 0) show_ports = true;
        else usable = false;
    }
    if (!usable) {
        fprintf(stderr, "usage: tattle-broker-probe <service> <interface> [--delay <seconds>] [--hold <seconds>] [--exception-ports]\n"
                        "       tattle-broker-probe <service> <interface> --send-then-exec <program> [<argument>...]\n"
                        "       tattle-broker-probe --hold-corpse <program> [<argument>...]\n"
                        "       tattle-broker-probe --wait\n");
        return 2;
    }
    if (delay > 0) sleep(delay);
    if (hold > 0) return ask_and_hold(argv[1], argv[2], hold);
    int status = 0, err = 0;
    int fd = tattle_broker_request(argv[1], 0, argv[2], &status, &err);
    report(fd, status, err);
    if (show_ports) {
        printf("dropped-at-launch %d\n", tattle_launch_exception_ports_dropped());
        printf("exception-ports %d\n", held);
        printf("corpse-ports %d\n", corpse);
    }
    return 0;
}
