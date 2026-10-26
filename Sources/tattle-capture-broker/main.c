// The packet-access broker (ADR-0003): a root launch daemon that, on request over XPC, opens one
// BPF device read-only, binds it to the requested interface, and hands the descriptor back in
// the reply to that request. It answers only a sender that runs as the user who installed it,
// whose code satisfies the requirement given on its command line, and that no other process of
// its user can steer, judged from the request's own audit token. It parses nothing and keeps
// nothing between requests.
//
//   tattle-capture-broker --requirement <code requirement> --uid <uid> --service <name>
//       Serves the Mach service launchd holds under <name> and exits after a minute idle;
//       launchd starts it again on the next message. Tests run it the same way, as an agent in
//       the user's own launchd domain.
//
// Protocol: a dictionary whose "interface" is a string. The reply's "status" is 0 to 3; for 0
// it carries the descriptor under "descriptor", for 3 the errno under "errno".

#include "code_policy.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <net/bpf.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <syslog.h>
#include <unistd.h>
#include <xpc/xpc.h>

enum {
    STATUS_OK = 0,
    STATUS_REFUSED = 1,
    STATUS_BAD_REQUEST = 2,
    STATUS_OPEN_FAILED = 3,
};

static const int idle_seconds = 60;

// Whether `request`'s sender runs as `uid`, satisfies `requirement`, and cannot be steered by
// another process of its user (code_policy.h). The code is the request's own sender: Security
// resolves the message's audit token, whose pid version changes at exec, so a request sent before
// an exec does not resolve to the program exec'd. The uid is the connection's, from when it was
// made; only code that passes the code check can receive a descriptor, and that code sends only
// on connections it opened itself.
static bool sender_is_allowed(xpc_connection_t peer, xpc_object_t request, uid_t uid, SecRequirementRef requirement) {
    uid_t euid = xpc_connection_get_euid(peer);
    if (euid != uid) {
        syslog(LOG_NOTICE, "refused a caller running as user %u", euid);
        return false;
    }
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCreateWithXPCMessage(request, kSecCSDefaultFlags, &code);
    if (status != errSecSuccess) {
        syslog(LOG_NOTICE, "refused a caller that cannot be identified: %d", (int)status);
        return false;
    }
    status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    tattle_hardening verdict = status == errSecSuccess ? tattle_code_hardening(code) : TATTLE_HARDENING_OK;
    CFRelease(code);
    if (verdict != TATTLE_HARDENING_OK) {
        syslog(LOG_NOTICE, "refused a caller another process could steer: %s", tattle_hardening_text(verdict));
        return false;
    }
    if (status != errSecSuccess) {
        syslog(LOG_NOTICE, "refused a caller that does not satisfy the requirement: %d", (int)status);
        return false;
    }
    return true;
}

// 1 to IFNAMSIZ-1 letters and digits.
static bool is_interface_name(const char *name) {
    if (name == NULL) return false;
    size_t length = strnlen(name, IFNAMSIZ);
    if (length == 0 || length >= IFNAMSIZ) return false;
    for (size_t i = 0; i < length; i++) {
        char c = name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return false;
    }
    return true;
}

static int open_bpf(const char *ifname) {
    int fd = -1;
    char path[16];
    for (int i = 0; i < 256; i++) {
        snprintf(path, sizeof path, "/dev/bpf%d", i);
        fd = open(path, O_RDONLY);
        if (fd >= 0) break;
        if (errno != EBUSY) return -1;
    }
    if (fd < 0) return -1;
    // The buffer length must be set before binding and cannot change after.
    unsigned int want = 1 << 20;
    ioctl(fd, BIOCSBLEN, &want);
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strlcpy(ifr.ifr_name, ifname, sizeof ifr.ifr_name);
    if (ioctl(fd, BIOCSETIF, &ifr) < 0) {
        int saved = errno;
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

// The reply goes to the reply port of `request`, which belongs to the process that sent it: the
// one just checked. The connection is closed after its one request, so the uid it reports, fixed
// when it was made, is the uid of the request answered; a client asking again gets a new one.
static void serve(xpc_connection_t peer, xpc_object_t request, uid_t uid, SecRequirementRef requirement) {
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (reply == NULL) return;  // sent without asking for a reply: no one to answer
    int64_t status = STATUS_REFUSED;
    if (sender_is_allowed(peer, request, uid, requirement)) {
        const char *ifname = xpc_dictionary_get_string(request, "interface");
        if (!is_interface_name(ifname)) {
            status = STATUS_BAD_REQUEST;
        } else {
            int bpf = open_bpf(ifname);
            if (bpf < 0) {
                syslog(LOG_NOTICE, "cannot open a capture device on %s: %s", ifname, strerror(errno));
                status = STATUS_OPEN_FAILED;
                xpc_dictionary_set_int64(reply, "errno", errno);
            } else {
                status = STATUS_OK;
                xpc_dictionary_set_fd(reply, "descriptor", bpf);
                close(bpf);
                syslog(LOG_NOTICE, "handed a capture device on %s to pid %d", ifname, xpc_connection_get_pid(peer));
            }
        }
    }
    xpc_dictionary_set_int64(reply, "status", status);
    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
    xpc_connection_cancel(peer);
}

static void usage(void) {
    fprintf(stderr, "usage: tattle-capture-broker --requirement <code requirement> --uid <uid> --service <name>\n");
    exit(2);
}

// A user id in decimal, 1 to UINT32_MAX - 1: root never needs the broker, and -1 is no user.
static bool parse_uid(const char *text, uid_t *uid) {
    if (*text < '1' || *text > '9') return false;
    unsigned long long value = 0;
    for (const char *c = text; *c; c++) {
        if (*c < '0' || *c > '9') return false;
        value = value * 10 + (unsigned long long)(*c - '0');
        if (value >= UINT32_MAX) return false;
    }
    *uid = (uid_t)value;
    return true;
}

int main(int argc, char **argv) {
    const char *requirement_text = NULL;
    const char *service = NULL;
    uid_t uid = 0;
    bool has_uid = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--requirement") == 0 && i + 1 < argc) requirement_text = argv[++i];
        else if (strcmp(argv[i], "--uid") == 0 && i + 1 < argc) has_uid = parse_uid(argv[++i], &uid);
        else if (strcmp(argv[i], "--service") == 0 && i + 1 < argc) service = argv[++i];
        else usage();
    }
    // Required: a plist from before the uid existed must not start a broker for every account.
    if (requirement_text == NULL || service == NULL || !has_uid) usage();

    // LOG_PERROR: a test's agent reads the same lines from stderr; a daemon's stderr goes nowhere.
    openlog("tattle-capture-broker", LOG_PID | LOG_PERROR, LOG_DAEMON);
    CFStringRef requirement_string = CFStringCreateWithCString(NULL, requirement_text, kCFStringEncodingUTF8);
    SecRequirementRef requirement = NULL;
    if (requirement_string == NULL
        || SecRequirementCreateWithString(requirement_string, kSecCSDefaultFlags, &requirement) != errSecSuccess) {
        fprintf(stderr, "tattle-capture-broker: not a code requirement: %s\n", requirement_text);
        return 2;
    }

    // One serial queue for the listener, every peer and the idle timer, so the timer never fires
    // while a request is being served. A request that libxpc has taken off the port when the
    // timer fires is lost with the process; the client sees the connection interrupted and asks
    // once more, which launchd answers by starting the broker again.
    dispatch_queue_t queue = dispatch_get_main_queue();
    dispatch_source_t idle = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_event_handler(idle, ^{ exit(0); });
    dispatch_source_set_timer(idle, dispatch_time(DISPATCH_TIME_NOW, idle_seconds * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
    dispatch_resume(idle);

    xpc_connection_t listener = xpc_connection_create_mach_service(service, queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        xpc_connection_set_target_queue(peer, queue);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
            dispatch_source_set_timer(idle, dispatch_time(DISPATCH_TIME_NOW, idle_seconds * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
            serve(peer, message, uid, requirement);
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
    dispatch_main();
}
