// The packet-access broker (ADR-0003): a root launch daemon that, on request over a local
// socket, opens one BPF device read-only, binds it to the requested interface, and hands
// the descriptor to the caller. It answers only a caller whose code satisfies the
// requirement given on its command line, identified by the socket peer's audit token.
// It parses nothing and keeps nothing between requests.
//
//   tattle-capture-broker --requirement <code requirement>
//       Serves the launchd socket named "Listener" and exits after a minute idle;
//       launchd starts it again on the next connection.
//   tattle-capture-broker --requirement <code requirement> --socket <path> [--once]
//       Serves a socket it binds itself, for tests. --once answers one request and exits.
//
// Protocol: the client sends the interface name and a newline. The broker replies with
// one status byte, then, for status 0, the descriptor as ancillary data; for status 3,
// four bytes of errno in host order.

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <launch.h>
#include <net/bpf.h>
#include <net/if.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <syslog.h>
#include <unistd.h>

enum {
    STATUS_OK = 0,
    STATUS_REFUSED = 1,
    STATUS_BAD_REQUEST = 2,
    STATUS_OPEN_FAILED = 3,
};

static const int idle_seconds = 60;
static const int request_timeout_ms = 2000;

// Whether the process at the other end of `fd` satisfies `requirement`.
static bool peer_is_allowed(int fd, SecRequirementRef requirement) {
    audit_token_t token;
    socklen_t length = sizeof token;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) != 0 || length != sizeof token) {
        syslog(LOG_WARNING, "no audit token for peer: %s", strerror(errno));
        return false;
    }
    CFDataRef token_data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof token);
    const void *keys[] = { kSecGuestAttributeAudit };
    const void *values[] = { token_data };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1,
                                                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    CFRelease(attributes);
    CFRelease(token_data);
    if (status != errSecSuccess) {
        syslog(LOG_WARNING, "cannot identify peer: %d", (int)status);
        return false;
    }
    status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    CFRelease(code);
    return status == errSecSuccess;
}

// Reads the interface name: up to IFNAMSIZ-1 letters and digits, then a newline.
static bool read_interface(int fd, char *name, size_t size) {
    size_t length = 0;
    while (true) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        if (poll(&pfd, 1, request_timeout_ms) <= 0) return false;
        char c;
        ssize_t n = read(fd, &c, 1);
        if (n != 1) return false;
        if (c == '\n') break;
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        if (!ok || length + 1 >= size) return false;
        name[length++] = c;
    }
    name[length] = 0;
    return length > 0;
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

static void reply(int fd, unsigned char status, int bpf, int err) {
    struct iovec iov = { .iov_base = &status, .iov_len = 1 };
    struct msghdr msg;
    memset(&msg, 0, sizeof msg);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    char control[CMSG_SPACE(sizeof(int))];
    if (status == STATUS_OK) {
        memset(control, 0, sizeof control);
        msg.msg_control = control;
        msg.msg_controllen = sizeof control;
        struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
        cmsg->cmsg_level = SOL_SOCKET;
        cmsg->cmsg_type = SCM_RIGHTS;
        cmsg->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(cmsg), &bpf, sizeof(int));
    }
    if (sendmsg(fd, &msg, 0) < 0) {
        syslog(LOG_WARNING, "reply failed: %s", strerror(errno));
        return;
    }
    if (status == STATUS_OPEN_FAILED) {
        (void)write(fd, &err, sizeof err);
    }
}

static void serve(int fd, SecRequirementRef requirement) {
    if (!peer_is_allowed(fd, requirement)) {
        syslog(LOG_NOTICE, "refused a caller that does not satisfy the requirement");
        reply(fd, STATUS_REFUSED, -1, 0);
        return;
    }
    char ifname[IFNAMSIZ];
    if (!read_interface(fd, ifname, sizeof ifname)) {
        reply(fd, STATUS_BAD_REQUEST, -1, 0);
        return;
    }
    int bpf = open_bpf(ifname);
    if (bpf < 0) {
        syslog(LOG_NOTICE, "cannot open a capture device on %s: %s", ifname, strerror(errno));
        reply(fd, STATUS_OPEN_FAILED, -1, errno);
        return;
    }
    reply(fd, STATUS_OK, bpf, 0);
    close(bpf);
}

// Binds under a temporary name and renames once listening, so the socket at `path`
// never exists before it accepts connections.
static int listen_on(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) + 4 >= sizeof addr.sun_path) { close(fd); errno = ENAMETOOLONG; return -1; }
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s.tmp", path);
    unlink(addr.sun_path);
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(fd, 8) < 0 || rename(addr.sun_path, path) < 0) {
        int saved = errno;
        unlink(addr.sun_path);
        close(fd);
        errno = saved;
        return -1;
    }
    return fd;
}

static void usage(void) {
    fprintf(stderr, "usage: tattle-capture-broker --requirement <code requirement> [--socket <path>] [--once]\n");
    exit(2);
}

int main(int argc, char **argv) {
    const char *requirement_text = NULL;
    const char *socket_path = NULL;
    bool once = false;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--requirement") == 0 && i + 1 < argc) requirement_text = argv[++i];
        else if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) socket_path = argv[++i];
        else if (strcmp(argv[i], "--once") == 0) once = true;
        else usage();
    }
    if (requirement_text == NULL) usage();

    // A peer that hangs up before the reply must cost one failed send, not the daemon: the
    // socket is world-writable, and launchd's respawn would meet the next dead peer the same way.
    signal(SIGPIPE, SIG_IGN);
    openlog("tattle-capture-broker", LOG_PID, LOG_DAEMON);
    CFStringRef requirement_string = CFStringCreateWithCString(NULL, requirement_text, kCFStringEncodingUTF8);
    SecRequirementRef requirement = NULL;
    if (requirement_string == NULL
        || SecRequirementCreateWithString(requirement_string, kSecCSDefaultFlags, &requirement) != errSecSuccess) {
        fprintf(stderr, "tattle-capture-broker: not a code requirement: %s\n", requirement_text);
        return 2;
    }

    int listener = -1;
    if (socket_path != NULL) {
        listener = listen_on(socket_path);
        if (listener < 0) {
            fprintf(stderr, "tattle-capture-broker: cannot listen on %s: %s\n", socket_path, strerror(errno));
            return 1;
        }
    } else {
        int *fds = NULL;
        size_t count = 0;
        if (launch_activate_socket("Listener", &fds, &count) != 0 || count < 1) {
            syslog(LOG_ERR, "no launchd socket named Listener");
            return 1;
        }
        listener = fds[0];
        free(fds);
    }

    while (true) {
        struct pollfd pfd = { .fd = listener, .events = POLLIN };
        int ready = poll(&pfd, 1, once ? -1 : idle_seconds * 1000);
        if (ready == 0) break;  // idle: launchd starts us again on the next connection
        if (ready < 0) {
            if (errno == EINTR) continue;
            break;
        }
        int client = accept(listener, NULL, NULL);
        if (client < 0) continue;
        int on = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        serve(client, requirement);
        close(client);
        if (once) break;
    }
    if (socket_path != NULL) unlink(socket_path);
    CFRelease(requirement);
    CFRelease(requirement_string);
    return 0;
}
