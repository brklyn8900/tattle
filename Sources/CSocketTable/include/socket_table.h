// Record layouts returned by the net.inet.{tcp,udp}.pcblist_n sysctls. The kernel's own
// definitions live in XNU's bsd/sys/socketvar.h, bsd/netinet/in_pcb.h and
// bsd/netinet/tcp_var.h; they are not in the public SDK, so they are declared here under
// a tattle_ prefix (the SDK declares some of the names) with the kernel's field names so
// the two can be compared. netstat reads the same records.
//
// The sysctl returns one xinpgen header, then a sequence of records each starting with a
// length and a kind (XSO_*), 8-byte aligned. A socket is described by consecutive records:
// XSO_INPCB, XSO_SOCKET, XSO_RCVBUF, XSO_SNDBUF, XSO_STATS and, for TCP, XSO_TCPCB.

#ifndef TATTLE_SOCKET_TABLE_H
#define TATTLE_SOCKET_TABLE_H

#include <stdint.h>
#include <sys/types.h>
#include <netinet/in.h>

#define XSO_SOCKET 0x001
#define XSO_RCVBUF 0x002
#define XSO_SNDBUF 0x004
#define XSO_STATS  0x008
#define XSO_INPCB  0x010
#define XSO_TCPCB  0x020

#define INP_IPV4 0x1
#define INP_IPV6 0x2

// XNU declares these records under #pragma pack(4).
#pragma pack(push, 4)

struct tattle_xinpgen {
    uint32_t xig_len;
    uint32_t xig_count;
    uint64_t xig_gen;
    uint64_t xig_sogen;
};

struct tattle_xgen_n {
    uint32_t xgn_len;
    uint32_t xgn_kind;
};

struct tattle_xsocket_n {
    uint32_t xso_len;
    uint32_t xso_kind;
    uint64_t xso_so;
    short    so_type;
    uint32_t so_options;
    short    so_linger;
    short    so_state;
    uint64_t so_pcb;
    int      xso_protocol;
    int      xso_family;
    short    so_qlen;
    short    so_incqlen;
    short    so_qlimit;
    short    so_timeo;
    u_short  so_error;
    pid_t    so_pgid;
    uint32_t so_oobmark;
    uid_t    so_uid;
    pid_t    so_last_pid;
    pid_t    so_e_pid;
    uint64_t so_gencnt;
    uint32_t so_flags;
    uint32_t so_flags1;
    int32_t  so_usecount;
    int32_t  so_retaincnt;
    uint32_t xso_filter_flags;
};

struct tattle_in_addr_4in6 {
    uint32_t       ia46_pad32[3];
    struct in_addr ia46_addr4;
};

struct tattle_xinpcb_n {
    uint32_t xi_len;
    uint32_t xi_kind;
    uint64_t xi_inpp;
    u_short  inp_fport;
    u_short  inp_lport;
    uint64_t inp_ppcb;
    uint64_t inp_gencnt;
    int      inp_flags;
    uint32_t inp_flow;
    u_char   inp_vflag;
    u_char   inp_ip_ttl;
    u_char   inp_ip_p;
    union {
        struct tattle_in_addr_4in6 inp46_foreign;
        struct in6_addr     inp6_foreign;
    } inp_dependfaddr;
    union {
        struct tattle_in_addr_4in6 inp46_local;
        struct in6_addr     inp6_local;
    } inp_dependladdr;
    struct {
        u_char inp4_ip_tos;
    } inp_depend4;
    struct {
        uint8_t inp6_hlim;
        int     inp6_cksum;
        u_short inp6_ifindex;
        short   inp6_hops;
    } inp_depend6;
    uint32_t inp_flowhash;
    uint32_t inp_flags2;
};

// Only the leading fields of xtcpcb_n: the record is longer, and t_state is all that is
// read. TCPT_NTIMERS_EXT is 4 (netinet/tcp_timer.h).
struct tattle_xtcpcb_n_head {
    uint32_t xt_len;
    uint32_t xt_kind;
    uint64_t t_segq;
    int      t_dupacks;
    int      t_timer[4];
    int      t_state;
};

#pragma pack(pop)

/// Reads a pcblist_n sysctl into a malloc'd buffer. Returns 0 and sets *buffer and
/// *length on success, or errno. The caller frees the buffer.
int tattle_read_pcblist(const char *name, void **buffer, size_t *length);

#endif
