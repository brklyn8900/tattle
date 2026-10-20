#include "socket_table.h"
#include <errno.h>
#include <stdlib.h>
#include <sys/sysctl.h>

int tattle_read_pcblist(const char *name, void **buffer, size_t *length) {
    // The table can grow between the size query and the read; retry with headroom.
    for (int attempt = 0; attempt < 4; attempt++) {
        size_t needed = 0;
        if (sysctlbyname(name, NULL, &needed, NULL, 0) != 0) return errno;
        needed += needed / 8 + 4096;
        void *data = malloc(needed);
        if (data == NULL) return ENOMEM;
        if (sysctlbyname(name, data, &needed, NULL, 0) == 0) {
            *buffer = data;
            *length = needed;
            return 0;
        }
        int error = errno;
        free(data);
        if (error != ENOMEM) return error;
    }
    return ENOMEM;
}
