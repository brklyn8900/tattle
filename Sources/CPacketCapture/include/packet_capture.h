// Thin C layer over the BPF device (net/bpf.h), which Swift cannot use directly: the
// ioctls are macros and struct bpf_hdr is variable-length.

#ifndef TATTLE_PACKET_CAPTURE_H
#define TATTLE_PACKET_CAPTURE_H

#include <stddef.h>
#include <stdint.h>

// One kernel filter instruction, laid out like struct bpf_insn.
typedef struct {
    uint16_t code;
    uint8_t jt;
    uint8_t jf;
    uint32_t k;
} tattle_filter_insn;

// Opens the first free /dev/bpfN read-only, sets the buffer length (which must precede
// binding) and binds the device to `ifname`. Returns the descriptor, or -1 with errno set.
// This is the only step that needs root or readable devices; the broker (ADR-0003) does
// the same and hands the descriptor over.
int tattle_capture_open(const char *ifname);

// Prepares a bound descriptor for reading: immediate mode and a read timeout so the loop
// can check for shutdown. Reports the buffer length each read(2) needs and the link type.
// Returns 0, or -1 with errno set.
int tattle_capture_prepare(int fd, int timeout_ms, unsigned int *buflen, unsigned int *dlt);

// Installs a kernel filter. Returns 0, or -1 with errno set (EINVAL: the kernel rejected
// the program).
int tattle_capture_set_filter(int fd, const tattle_filter_insn *insns, unsigned int count);

// Walks one captured packet in a buffer filled by read(2). Returns 1 and fills the outputs
// when a complete packet starts at `offset`, 0 otherwise.
int tattle_capture_next(const void *buf, size_t len, size_t offset, double *timestamp,
                        size_t *data_offset, unsigned int *caplen, size_t *next_offset);

// The hardware address of an interface. Returns 0 and fills `mac`, or -1 when the
// interface has none (a tunnel, for instance).
int tattle_interface_mac(const char *ifname, uint8_t mac[6]);

#endif
