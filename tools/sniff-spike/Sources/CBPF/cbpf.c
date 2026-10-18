#include "cbpf.h"

#include <errno.h>
#include <fcntl.h>
#include <net/bpf.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <unistd.h>

int cbpf_open(const char *ifname, unsigned int *buflen, unsigned int *dlt, int timeout_ms) {
    int fd = -1;
    char path[16];
    for (int i = 0; i < 256; i++) {
        snprintf(path, sizeof path, "/dev/bpf%d", i);
        fd = open(path, O_RDONLY);
        if (fd >= 0) break;
        if (errno != EBUSY) return -1;
    }
    if (fd < 0) return -1;

    // Must precede BIOCSETIF; the kernel clamps to its maximum.
    unsigned int want = 1 << 20;
    ioctl(fd, BIOCSBLEN, &want);

    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strlcpy(ifr.ifr_name, ifname, sizeof ifr.ifr_name);
    if (ioctl(fd, BIOCSETIF, &ifr) < 0) goto fail;

    unsigned int on = 1;
    if (ioctl(fd, BIOCIMMEDIATE, &on) < 0) goto fail;

    struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
    if (ioctl(fd, BIOCSRTIMEOUT, &tv) < 0) goto fail;

    if (ioctl(fd, BIOCGBLEN, buflen) < 0) goto fail;
    if (ioctl(fd, BIOCGDLT, dlt) < 0) goto fail;
    return fd;

fail:
    close(fd);
    return -1;
}

int cbpf_next(const void *buf, size_t len, size_t offset, double *timestamp,
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
