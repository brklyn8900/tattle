// The helper QuickExitSimulationTests starts: `quick-exit-helper <port> <ms>` connects to
// 127.0.0.1:<port>, lives <ms> milliseconds more, and exits. Build it with
// `cc -O2 -o <path> Tests/quick-exit-helper.c` and pass <path> as TATTLE_SIM_HELPER.
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)atoi(argv[1]));
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof address) != 0) return 1;
    usleep((useconds_t)atoi(argv[2]) * 1000);
    return 0;
}
