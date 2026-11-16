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

// How long an answered connection may stay open when its caller does not close it: the client's
// own deadline for an answer (TATTLE_BROKER_TIMEOUT_MS in packet_capture.h), which starts
// before it sends, so a caller still waiting by then has already given up.
static const int close_seconds = 5;

// At most this many answered connections stay open waiting for their callers to close them; past
// it the oldest is closed at once. Without a cap a caller that never closes could hold as many
// as it can send in close_seconds, each costing the broker its ports and memory.
static const int lingering_cap = 256;

// An answered connection whose caller has not closed it yet. Created when the answer is sent,
// freed at the connection's last event. Used only on the main queue, so it needs no lock.
struct lingering {
    xpc_connection_t peer;
    dispatch_source_t backstop;
    struct lingering *older, *newer;
    bool listed;
};

static struct lingering *oldest_lingering, *newest_lingering;
static int lingering_count;

static void unlist(struct lingering *l) {
    if (!l->listed) return;
    if (l->older) l->older->newer = l->newer; else oldest_lingering = l->newer;
    if (l->newer) l->newer->older = l->older; else newest_lingering = l->older;
    l->older = l->newer = NULL;
    l->listed = false;
    lingering_count--;
}

// Closes a connection the caller has left open: its backstop fired, or it is the oldest past the
// cap. The connection's last event, which follows, frees it.
static void close_lingering(struct lingering *l) {
    if (!l->listed) return;
    unlist(l);
    dispatch_source_cancel(l->backstop);
    xpc_connection_cancel(l->peer);
}

// Lists `peer`, just answered, and starts its backstop. The backstop holds its own reference to
// the connection, given back when it is stopped. It does not touch the idle timer, so it neither
// keeps the broker running nor starts it.
static struct lingering *linger(xpc_connection_t peer, dispatch_queue_t queue) {
    struct lingering *l = calloc(1, sizeof *l);
    if (l == NULL) {
        xpc_connection_cancel(peer);
        return NULL;
    }
    l->peer = peer;
    xpc_retain(peer);
    l->backstop = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_event_handler(l->backstop, ^{ close_lingering(l); });
    dispatch_source_set_cancel_handler(l->backstop, ^{ xpc_release(peer); });
    dispatch_source_set_timer(l->backstop, dispatch_time(DISPATCH_TIME_NOW, close_seconds * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 10);
    dispatch_resume(l->backstop);
    l->older = newest_lingering;
    if (newest_lingering) newest_lingering->newer = l; else oldest_lingering = l;
    newest_lingering = l;
    l->listed = true;
    lingering_count++;
    while (lingering_count > lingering_cap) close_lingering(oldest_lingering);
    return l;
}

// The connection's last event, whoever closed it: stops the backstop if it has not fired, so it
// never fires on a connection gone, and frees what linger made.
static void forget(struct lingering *l) {
    if (l->listed) {
        unlist(l);
        dispatch_source_cancel(l->backstop);
    }
    dispatch_release(l->backstop);
    free(l);
}

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
// one just checked.
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
                int error = errno;  // before syslog, which may change it
                syslog(LOG_NOTICE, "cannot open a capture device on %s: %s", ifname, strerror(error));
                status = STATUS_OPEN_FAILED;
                xpc_dictionary_set_int64(reply, "errno", error);
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
        // One message per connection, answered or not, so the uid the connection reports,
        // fixed when it was made, is that of the request answered; a client asking again gets
        // a new one. The connection is not closed with the answer: a close while the caller
        // waits can make it drop a reply already delivered and see the connection interrupted
        // instead. The caller closes it, which ends it here at once; a second message closes it
        // unanswered; otherwise its backstop closes it close_seconds after the answer, or sooner
        // past lingering_cap. All of it runs on `queue`, so `taken` and `answered` need no lock.
        __block bool taken = false;
        __block struct lingering *answered = NULL;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            if (xpc_get_type(message) == XPC_TYPE_ERROR) {
                if (answered != NULL) forget(answered);
                answered = NULL;
                return;
            }
            if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
            if (taken) {
                xpc_connection_cancel(peer);
                return;
            }
            taken = true;
            // Another account's messages must not keep a root process running.
            if (xpc_connection_get_euid(peer) == uid) {
                dispatch_source_set_timer(idle, dispatch_time(DISPATCH_TIME_NOW, idle_seconds * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
            }
            serve(peer, message, uid, requirement);
            answered = linger(peer, queue);
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
    dispatch_main();
}
