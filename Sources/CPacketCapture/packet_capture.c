#include "packet_capture.h"

#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <xpc/xpc.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/bpf.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

int tattle_capture_open(const char *ifname) {
    int fd = -1;
    char path[16];
    for (int i = 0; i < 256; i++) {
        snprintf(path, sizeof path, "/dev/bpf%d", i);
        fd = open(path, O_RDONLY);
        if (fd >= 0) break;
        if (errno != EBUSY) return -1;
    }
    if (fd < 0) return -1;

    // Must precede BIOCSETIF and cannot change after it; the kernel clamps to its maximum.
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

int tattle_capture_prepare(int fd, int timeout_ms, unsigned int *buflen, unsigned int *dlt) {
    unsigned int on = 1;
    if (ioctl(fd, BIOCIMMEDIATE, &on) < 0) return -1;
    struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
    if (ioctl(fd, BIOCSRTIMEOUT, &tv) < 0) return -1;
    if (ioctl(fd, BIOCGBLEN, buflen) < 0) return -1;
    if (ioctl(fd, BIOCGDLT, dlt) < 0) return -1;
    return 0;
}

int tattle_capture_set_filter(int fd, const tattle_filter_insn *insns, unsigned int count) {
    struct bpf_program program;
    program.bf_len = count;
    program.bf_insns = (struct bpf_insn *)insns;
    return ioctl(fd, BIOCSETF, &program);
}

int tattle_capture_next(const void *buf, size_t len, size_t offset, double *timestamp,
                        size_t *data_offset, unsigned int *caplen, size_t *next_offset) {
    if (offset + sizeof(struct bpf_hdr) > len) return 0;
    const struct bpf_hdr *h = (const struct bpf_hdr *)((const char *)buf + offset);
    if (offset + h->bh_hdrlen + h->bh_caplen > len) return 0;
    *timestamp = (double)h->bh_tstamp.tv_sec + (double)h->bh_tstamp.tv_usec / 1e6;
    *data_offset = offset + h->bh_hdrlen;
    *caplen = h->bh_caplen;
    *next_offset = offset + BPF_WORDALIGN(h->bh_hdrlen + h->bh_caplen);
    return 1;
}

int tattle_interface_mac(const char *ifname, uint8_t mac[6]) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return -1;
    int found = -1;
    for (struct ifaddrs *entry = list; entry != NULL; entry = entry->ifa_next) {
        if (entry->ifa_addr == NULL || entry->ifa_addr->sa_family != AF_LINK) continue;
        if (strcmp(entry->ifa_name, ifname) != 0) continue;
        const struct sockaddr_dl *dl = (const struct sockaddr_dl *)entry->ifa_addr;
        if (dl->sdl_alen != 6) continue;
        memcpy(mac, LLADDR(dl), 6);
        found = 0;
        break;
    }
    freeifaddrs(list);
    return found;
}

// One request on a fresh connection, answered by `deadline` or abandoned. Sets *interrupted when
// the broker went away before answering, which an idle exit racing the request also does.
static int broker_request_once(const char *service, int privileged, const char *ifname, dispatch_time_t deadline,
                               int *status, int *err, int *interrupted) {
    *status = -1;
    *err = 0;
    *interrupted = 0;
    xpc_connection_t connection = xpc_connection_create_mach_service(service, NULL, privileged ? XPC_CONNECTION_MACH_SERVICE_PRIVILEGED : 0);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { (void)event; });
    xpc_connection_activate(connection);
    xpc_object_t request = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(request, "interface", ifname);
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block xpc_object_t reply = NULL;
    xpc_connection_send_message_with_reply(connection, request, NULL, ^(xpc_object_t object) {
        reply = xpc_retain(object);
        dispatch_semaphore_signal(answered);
    });
    xpc_release(request);
    int fd = -1;
    if (dispatch_semaphore_wait(answered, deadline) != 0) {
        // Cancelling delivers the reply handler its error at once, so this wait is short.
        xpc_connection_cancel(connection);
        dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
        *err = ETIMEDOUT;
    } else if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
        if (reply == XPC_ERROR_CONNECTION_INTERRUPTED) {
            *interrupted = 1;
            *err = ECONNRESET;
        } else {
            *err = ECONNREFUSED;  // no job serves the name
        }
    } else {
        *status = (int)xpc_dictionary_get_int64(reply, "status");
        if (*status == 0) {
            fd = xpc_dictionary_dup_fd(reply, "descriptor");
            if (fd < 0) { *status = -1; *err = EPROTO; }
        } else if (*status == 3) {
            *err = (int)xpc_dictionary_get_int64(reply, "errno");
        }
    }
    if (reply != NULL) xpc_release(reply);
    dispatch_release(answered);
    xpc_connection_cancel(connection);
    xpc_release(connection);
    return fd;
}

int tattle_broker_request(const char *service, int privileged, const char *ifname, int *status, int *err) {
    // Whoever launched this process chose the task exception ports it inherited, and a trap
    // would hand them its task, and with it the descriptor. The broker cannot see them
    // (ADR-0003), so they go before any request.
    if (task_set_exception_ports(mach_task_self(), EXC_MASK_ALL, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE) != KERN_SUCCESS) {
        *status = -1;
        *err = EPERM;
        return -1;
    }
    // One deadline for both attempts, so a retry never doubles the wait a caller plans for.
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)TATTLE_BROKER_TIMEOUT_MS * NSEC_PER_MSEC);
    int interrupted = 0;
    int fd = broker_request_once(service, privileged, ifname, deadline, status, err, &interrupted);
    if (fd < 0 && interrupted) fd = broker_request_once(service, privileged, ifname, deadline, status, err, &interrupted);
    return fd;
}

int tattle_broker_is_registered(const char *service) {
    mach_port_t port = MACH_PORT_NULL;
    if (bootstrap_look_up(bootstrap_port, service, &port) != KERN_SUCCESS) return 0;
    mach_port_deallocate(mach_task_self(), port);
    return 1;
}
