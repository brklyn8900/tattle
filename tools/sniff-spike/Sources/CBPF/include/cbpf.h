#ifndef CBPF_H
#define CBPF_H

#include <stddef.h>

// Opens the first free /dev/bpfN, binds it to `ifname`, enables immediate mode and a read
// timeout so the caller's loop can check for shutdown. Returns the descriptor, or -1 with
// errno set. `buflen` receives the buffer size each read(2) needs; `dlt` the link type.
int cbpf_open(const char *ifname, unsigned int *buflen, unsigned int *dlt, int timeout_ms);

// Walks one captured packet in a buffer filled by read(2). Returns 1 and fills the outputs
// when a complete packet starts at `offset`, 0 otherwise.
int cbpf_next(const void *buf, size_t len, size_t offset, double *timestamp,
              size_t *data_offset, unsigned int *caplen, size_t *next_offset);

#endif
