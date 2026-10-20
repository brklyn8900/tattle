#include "packet_capture.h"

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
