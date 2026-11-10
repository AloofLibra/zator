/*
 * Small passive DNS answer collector for Keenetic/Entware.
 * Independent implementation; no HydraRoute code is used.
 * stdout: hostname<TAB>IPv4<TAB>TTL
 */
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <linux/filter.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <netinet/ip.h>
#include <netinet/ip6.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAX_RR 64
#define MAX_NAME 256

struct rr { char name[MAX_NAME], target[MAX_NAME]; uint32_t ttl; uint32_t ip; uint16_t type; };
static volatile sig_atomic_t running = 1;
static struct { uint64_t key; uint64_t ms; } recent[128];
static unsigned recent_next;
static void stop(int sig) { (void)sig; running = 0; }
static uint16_t u16(const unsigned char *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t u32(const unsigned char *p) { return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }

static int name_read(const unsigned char *m, size_t n, size_t *off, char out[MAX_NAME]) {
    size_t p=*off, used=0, resume=0; unsigned jumps=0;
    while (p<n) {
        unsigned c=m[p++];
        if ((c&0xc0)==0xc0) {
            if (p>=n || ++jumps>32) return -1;
            size_t ptr=((c&0x3f)<<8)|m[p++]; if (ptr>=n) return -1;
            if (!resume) resume=p;
            p=ptr;
            continue;
        }
        if (c&0xc0) return -1;
        if (!c) { *off=resume?resume:p; if (!used) {out[0]='.';out[1]=0;} else out[used-1]=0; return 0; }
        if (c>63 || p+c>n || used+c+1>=MAX_NAME) return -1;
        for (unsigned i=0;i<c;i++) { unsigned char ch=m[p++]; if (ch=='.'||ch<'!'||ch>'~') return -1; out[used++]=(char)ch; }
        out[used++]='.';
    }
    return -1;
}

static int gv_name(const char *s) {
    size_t n=strlen(s); const char *suffix=".googlevideo.com"; size_t z=strlen(suffix);
    return n>z && !strcasecmp(s+n-z,suffix) && s[0]!='.' && s[0]!='-';
}
static int public4(uint32_t net) {
    uint32_t h=ntohl(net); unsigned a=h>>24,b=(h>>16)&255,c=(h>>8)&255;
    if (!a||a==10||a==127||a>=224) return 0;
    if (a==100&&b>=64&&b<=127) return 0;
    if (a==169&&b==254) return 0;
    if (a==172&&b>=16&&b<=31) return 0;
    if (a==192&&(b==168||(b==0&&c==0)||(b==0&&c==2)||(b==88&&c==99)||(b==0&&c==0))) return 0;
    if (a==198&&(b==18||b==19||(b==51&&c==100))) return 0;
    if (a==203&&b==0&&c==113) return 0;
    return 1;
}

static void emit_ip(const char *host, uint32_t ip, uint32_t ttl) {
    if (!ip || !public4(ip)) return;
    struct timespec ts; uint64_t ms=0, hash=1469598103934665603ULL;
    if (!clock_gettime(CLOCK_MONOTONIC,&ts)) ms=(uint64_t)ts.tv_sec*1000+(uint64_t)ts.tv_nsec/1000000;
    for (const unsigned char *p=(const unsigned char *)host;*p;p++) {
        unsigned char c=*p; if(c>='A'&&c<='Z')c=(unsigned char)(c+('a'-'A'));
        hash=(hash^c)*1099511628211ULL;
    }
    hash=(hash^(uint32_t)ip)*1099511628211ULL;
    for(unsigned i=0;i<128;i++) if(recent[i].key==hash && ms>=recent[i].ms && ms-recent[i].ms<2000) return;
    recent[recent_next].key=hash; recent[recent_next].ms=ms; recent_next=(recent_next+1)%128;
    char addr[INET_ADDRSTRLEN];
    if (!inet_ntop(AF_INET,&ip,addr,sizeof(addr))) return;
    if (ttl>604800) ttl=604800;
    if (!ttl) return;
    printf("%s\t%s\t%u\n",host,addr,ttl); fflush(stdout);
}

static int dns_emit(const unsigned char *m, size_t n) {
    if (n<12 || !(m[2]&0x80)) return 0;
    unsigned qd=u16(m+4), an=u16(m+6); if (!an || an>MAX_RR || qd>32) return 0;
    size_t p=12; char tmp[MAX_NAME];
    for (unsigned i=0;i<qd;i++) { if(name_read(m,n,&p,tmp)||p+4>n)return 0; p+=4; }
    static struct rr r[MAX_RR]; unsigned nr=0;
    for(unsigned i=0;i<an;i++) {
        struct rr x; memset(&x,0,sizeof(x));
        if(name_read(m,n,&p,x.name)||p+10>n)return 0;
        x.type=u16(m+p); uint16_t cls=u16(m+p+2), rd=u16(m+p+8); x.ttl=u32(m+p+4); p+=10;
        if(p+rd>n)return 0;
        if(cls==1 && x.type==1 && rd==4) memcpy(&x.ip,m+p,4);
        else if(cls==1 && x.type==5) { size_t rp=p; if(name_read(m,n,&rp,x.target)||rp>p+rd)return 0; }
        else x.type=0;
        p+=rd; r[nr++]=x;
    }
    for(unsigned i=0;i<nr;i++) if(gv_name(r[i].name)) {
        if(r[i].type==1) emit_ip(r[i].name,r[i].ip,r[i].ttl);
        if(r[i].type==5) {
            char target[MAX_NAME]; snprintf(target,sizeof(target),"%s",r[i].target);
            uint32_t ttl=r[i].ttl;
            for(unsigned depth=0;depth<8;depth++) {
                int changed=0;
                for(unsigned j=0;j<nr;j++) if(r[j].type==5&&!strcasecmp(r[j].name,target)) {
                    if(r[j].ttl<ttl) ttl=r[j].ttl;
                    snprintf(target,sizeof(target),"%s",r[j].target); changed=1; break;
                }
                if(!changed) break;
            }
            for(unsigned j=0;j<nr;j++) if(r[j].type==1&&!strcasecmp(r[j].name,target)) {
                uint32_t answer_ttl=ttl<r[j].ttl?ttl:r[j].ttl;
                emit_ip(r[i].name,r[j].ip,answer_ttl);
            }
        }
    }
    return 0;
}

static int dns_packet(const unsigned char *b,size_t n) {
    if(n<14) return 0;
    size_t l=14; uint16_t proto=u16(b+12);
    if(proto==0x8100||proto==0x88a8){if(n<18)return 0;proto=u16(b+16);l=18;}
    const unsigned char *d=NULL; size_t z=0;
    if(proto==ETH_P_IP) {
        if(n<l+20||(b[l]>>4)!=4) return 0;
        size_t ihl=(b[l]&15)*4;
        if(ihl<20||n<l+ihl+8||(u16(b+l+6)&0x3fff))return 0;
        unsigned pr=b[l+9]; const unsigned char *t=b+l+ihl;
        if(pr==IPPROTO_UDP){if(u16(t)!=53)return 0; z=u16(t+4);if(z<8||l+ihl+z>n)return 0;d=t+8;z-=8;}
        else if(pr==IPPROTO_TCP){if(u16(t)!=53||n<l+ihl+20)return 0;size_t th=(t[12]>>4)*4;if(th<20||l+ihl+th>n)return 0;d=t+th;z=n-(size_t)(d-b);if(z<14)return 0;z=u16(d);d+=2;if(z>n-(size_t)(d-b))return 0;}
        else return 0;
    } else if(proto==ETH_P_IPV6) {
        if(n<l+40||(b[l]>>4)!=6) return 0;
        unsigned pr=b[l+6]; const unsigned char *t=b+l+40;
        if(pr==IPPROTO_UDP){if(n<l+48||u16(t)!=53)return 0;z=u16(t+4);if(z<8||l+40+z>n)return 0;d=t+8;z-=8;}
        else if(pr==IPPROTO_TCP){if(n<l+60||u16(t)!=53)return 0;size_t th=(t[12]>>4)*4;if(th<20||l+40+th>n)return 0;d=t+th;z=n-(size_t)(d-b);if(z<14)return 0;z=u16(d);d+=2;if(z>n-(size_t)(d-b))return 0;}
        else return 0;
    } else return 0;
    return dns_emit(d,z);
}

/* Keep non-DNS traffic out of userspace; parse IPv4 options using BPF MSH. */
/* shortcut: skips IPv6 extension headers and fragmented TCP DNS messages; add reassembly if captures show either form in use. */
static int attach_filter(int fd) {
    struct sock_filter f[]={
        BPF_STMT(BPF_LD|BPF_H|BPF_ABS,12),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,ETH_P_IP,0,8),
        BPF_STMT(BPF_LD|BPF_B|BPF_ABS,23),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,IPPROTO_UDP,1,0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,IPPROTO_TCP,0,4),
        BPF_STMT(BPF_LDX|BPF_B|BPF_MSH,14),
        BPF_STMT(BPF_LD|BPF_H|BPF_IND,14),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,53,8,1),
        BPF_STMT(BPF_RET|BPF_K,0),
        BPF_STMT(BPF_RET|BPF_K,0),
        BPF_STMT(BPF_LD|BPF_B|BPF_ABS,20),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,IPPROTO_UDP,1,0),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,IPPROTO_TCP,0,2),
        BPF_STMT(BPF_LD|BPF_H|BPF_ABS,54),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,53,1,0),
        BPF_STMT(BPF_RET|BPF_K,0),
        BPF_STMT(BPF_RET|BPF_K,0xffff)
    };
    struct sock_fprog p={.len=(unsigned short)(sizeof(f)/sizeof(f[0])),.filter=f};
    return setsockopt(fd,SOL_SOCKET,SO_ATTACH_FILTER,&p,sizeof(p));
}

int main(int argc,char **argv) {
    if(argc==2&&!strcmp(argv[1],"--replay")) {
        unsigned char b[65536]; size_t n=fread(b,1,sizeof(b),stdin); return dns_emit(b,n);
    }
    if(argc==2&&!strcmp(argv[1],"--replay-packet")) {
        unsigned char b[65536]; size_t n=fread(b,1,sizeof(b),stdin); return dns_packet(b,n);
    }
    if(argc==2&&!strcmp(argv[1],"--replay-stream")) {
        unsigned char b[65536], lenbuf[2]; size_t n;
        while(fread(lenbuf,1,2,stdin)==2) {
            n=u16(lenbuf); if(!n||n>sizeof(b)||fread(b,1,n,stdin)!=n) return 1;
            dns_emit(b,n);
        }
        return ferror(stdin)?1:0;
    }
    if(argc==2&&!strcmp(argv[1],"--check-filter")) {
        int testfd=socket(AF_PACKET,SOCK_RAW,htons(ETH_P_ALL));
        if(testfd<0){perror("AF_PACKET");return 1;}
        int rc=attach_filter(testfd); if(rc<0)perror("SO_ATTACH_FILTER");
        close(testfd); return rc<0?1:0;
    }
    struct sigaction sa; memset(&sa,0,sizeof(sa)); sa.sa_handler=stop; sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM,&sa,NULL); sigaction(SIGINT,&sa,NULL); sigaction(SIGHUP,&sa,NULL);
    int fd=socket(AF_PACKET,SOCK_RAW,htons(ETH_P_ALL)); if(fd<0){perror("AF_PACKET");return 1;}
    if(attach_filter(fd)<0){perror("SO_ATTACH_FILTER");close(fd);return 1;}
    unsigned char b[65536];
    while(running){ssize_t n=recv(fd,b,sizeof(b),0);if(n<0){if(errno==EINTR)continue;perror("recv");break;}dns_packet(b,(size_t)n);}
    close(fd); return 0;
}
