/*
 * Small passive DNS answer collector for Keenetic/Entware.
 * Independent implementation; no HydraRoute code is used.
 * stdout: hostname<TAB>IPv4<TAB>TTL
 */
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>
#include <netinet/ip.h>
#include <netinet/ip6.h>
#include <netinet/tcp.h>
#include <netinet/udp.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_RR 64
#define MAX_NAME 256

struct rr { char name[MAX_NAME], target[MAX_NAME]; uint32_t ttl; uint32_t ip; uint16_t type; };
static volatile sig_atomic_t running = 1;
static int collector_mode;
static struct { uint64_t key; uint64_t ms; } recent[128];
static unsigned recent_next;
static void stop(int sig) { (void)sig; running = 0; }
static void observe_dns(const char *host, const char *ip, uint32_t ttl);
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
    if (collector_mode) { observe_dns(host,addr,ttl); return; }
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

/* The collector keeps DNS persistence and validation in this process. */
#define MAX_PATH_LEN 512
#define OBS_CACHE_SIZE 2048
struct obs_cache_entry { uint64_t hash, expires_ms; };
static struct obs_cache_entry obs_cache[OBS_CACHE_SIZE];
static unsigned obs_cache_cursor;
static struct { uint32_t ip; uint64_t expires_ms; } set_cache[256];
static unsigned set_cache_cursor;
static char gv_root[MAX_PATH_LEN], gv_tmpdir[MAX_PATH_LEN];
static char local_file[MAX_PATH_LEN], pending_file[MAX_PATH_LEN];
static char reported_file[MAX_PATH_LEN], log_file[MAX_PATH_LEN];
static char central_file[MAX_PATH_LEN], config_file[MAX_PATH_LEN];
static char pid_file[MAX_PATH_LEN], upload_helper[MAX_PATH_LEN];
static char fwtype[32]="", nft_table[64]="zapret2";

static uint64_t wall_seconds(void) { return (uint64_t)time(NULL); }
static uint64_t mono_millis(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC,&ts)) return 0;
    return (uint64_t)ts.tv_sec*1000+(uint64_t)ts.tv_nsec/1000000;
}
static void copy_env(char *out,size_t cap,const char *name,const char *fallback) {
    const char *v=getenv(name); snprintf(out,cap,"%s",v&&*v?v:fallback);
}
static void copy_text(char *out,size_t cap,const char *value) {
    size_t n=strlen(value); if(n>=cap)n=cap-1; memcpy(out,value,n); out[n]=0;
}
static int path_join(char *out,size_t cap,const char *base,const char *suffix) {
    size_t a=strlen(base),b=strlen(suffix); if(a+b+2>cap)return -1;
    memcpy(out,base,a); out[a]='/'; memcpy(out+a+1,suffix,b+1); return 0;
}
static int path_suffix(char *out,size_t cap,const char *base,const char *suffix) {
    size_t a=strlen(base),b=strlen(suffix); if(a+b+1>cap)return -1;
    memcpy(out,base,a); memcpy(out+a,suffix,b+1); return 0;
}
static int mkdir_parent(const char *path) {
    char tmp[MAX_PATH_LEN]; size_t n=strlen(path); if(!n||n>=sizeof(tmp))return -1;
    memcpy(tmp,path,n+1);
    char *slash=strrchr(tmp,'/'); if(!slash)return 0;
    if(slash==tmp)return 0;
    *slash=0;
    for(char *p=tmp+1;*p;p++) if(*p=='/') { *p=0; if(mkdir(tmp,0755)<0&&errno!=EEXIST)return -1; *p='/'; }
    return (mkdir(tmp,0755)<0&&errno!=EEXIST)?-1:0;
}
static void collector_paths(void) {
    char p[MAX_PATH_LEN];
    copy_env(gv_root,sizeof(gv_root),"Z2R_GV_ROOT","/opt/zator");
    copy_env(gv_tmpdir,sizeof(gv_tmpdir),"Z2R_GV_TMPDIR","/tmp/z2r-googlevideo");
    if(path_join(p,sizeof(p),gv_tmpdir,"local.tsv"))p[0]=0;
    copy_env(local_file,sizeof(local_file),"Z2R_GV_LOCAL_FILE",p);
    if(path_join(p,sizeof(p),gv_tmpdir,"pending.tsv"))p[0]=0;
    copy_env(pending_file,sizeof(pending_file),"Z2R_GOOGLEVIDEO_PENDING_FILE",p);
    if(path_join(p,sizeof(p),gv_tmpdir,"reported.tsv"))p[0]=0;
    copy_env(reported_file,sizeof(reported_file),"Z2R_GV_REPORTED_FILE",p);
    if(path_join(p,sizeof(p),gv_tmpdir,"collector.log"))p[0]=0;
    copy_env(log_file,sizeof(log_file),"Z2R_GV_LOG_FILE",p);
    if(path_join(p,sizeof(p),gv_root,"lists/googlevideo-ipv4.txt"))p[0]=0;
    copy_env(central_file,sizeof(central_file),"Z2R_GOOGLEVIDEO_IPS_FILE",p);
    copy_env(config_file,sizeof(config_file),"Z2R_GV_CONFIG","/opt/zapret2/config");
    copy_env(pid_file,sizeof(pid_file),"Z2R_GV_PIDFILE","/var/run/z2r-googlevideo-dns.pid");
    if(path_join(p,sizeof(p),gv_root,"tools/googlevideo-dns-listener.sh"))p[0]=0;
    copy_env(upload_helper,sizeof(upload_helper),"Z2R_GV_UPLOAD_HELPER",p);
}
static void log_msg(const char *fmt,...) {
    if(mkdir_parent(log_file))return;
    FILE *f=fopen(log_file,"a"); if(!f)return;
    struct tm tm; time_t now=time(NULL); localtime_r(&now,&tm); char stamp[40];
    strftime(stamp,sizeof(stamp),"%Y-%m-%dT%H:%M:%S%z",&tm); fprintf(f,"%s ",stamp);
    va_list ap; va_start(ap,fmt); vfprintf(f,fmt,ap); va_end(ap); fputc('\n',f);
    long size=ftell(f); fclose(f);
    if(size>131072) {
        char tmp[MAX_PATH_LEN],suffix[32]; snprintf(suffix,sizeof(suffix),".tmp.%ld",(long)getpid());
        if(path_suffix(tmp,sizeof(tmp),log_file,suffix))return;
        FILE *in=fopen(log_file,"r"),*out=fopen(tmp,"w");
        if(in&&out) { char line[1024]; unsigned long rows=0; while(fgets(line,sizeof(line),in))rows++; rewind(in); unsigned long skip=rows>800?rows-800:0; while(skip--&&fgets(line,sizeof(line),in)){} while(fgets(line,sizeof(line),in))fputs(line,out); }
        if(in)fclose(in);
        if(out)fclose(out);
        if(out)rename(tmp,log_file);
    }
}
static int config_value(const char *key,char *out,size_t cap) {
    FILE *f=fopen(config_file,"r"); if(!f)return 0; char line[1024]; size_t k=strlen(key); int found=0;
    while(fgets(line,sizeof(line),f)) {
        char *s=line; while(isspace((unsigned char)*s))s++;
        if(*s=='#'||strncmp(s,key,k)||s[k]!='=')continue;
        s+=k+1; while(isspace((unsigned char)*s))s++;
        size_t n=strcspn(s,"\r\n#"); while(n&&isspace((unsigned char)s[n-1]))n--;
        if(n>=2&&((s[0]=='"'&&s[n-1]=='"')||(s[0]=='\''&&s[n-1]=='\''))){s++;n-=2;}
        if(n>=cap)n=cap-1;
        memcpy(out,s,n); out[n]=0; found=1; break;
    }
    fclose(f); return found;
}
static int collector_enabled(void) {
    char a[32]="0",b[32]="0";
    return config_value("NFQWS2_ENABLE",a,sizeof(a))&&config_value("Z2R_WSSIZE_RAMP_ENABLE",b,sizeof(b))&&!strcmp(a,"1")&&!strcmp(b,"1");
}
static void load_fw_config(void) {
    char v[80];
    if(config_value("FWTYPE",v,sizeof(v)))copy_text(fwtype,sizeof(fwtype),v);
    if(config_value("ZAPRET_NFT_TABLE",v,sizeof(v))&&*v) {
        int ok=1; for(const char *p=v;*p;p++)if(!isalnum((unsigned char)*p)&&*p!='_')ok=0;
        if(ok)copy_text(nft_table,sizeof(nft_table),v);
    }
}
static int public_ipv4_text(const char *text) {
    struct in_addr a4; if(inet_pton(AF_INET,text,&a4)!=1)return 0; uint32_t h=ntohl(a4.s_addr);
    unsigned a=h>>24,b=(h>>16)&255,c=(h>>8)&255;
    if(a==0||a==10||a==127||a>=224||(a==100&&b>=64&&b<=127)||(a==169&&b==254)||
       (a==172&&b>=16&&b<=31)||(a==192&&(b==168||(b==0&&(c==0||c==2))||(b==88&&c==99)||(b==31&&c==196)||(b==52&&c==193)||(b==175&&c==48)))||
       (a==198&&(b==18||b==19||(b==51&&c==100)))||(a==203&&b==0&&c==113))return 0;
    return 1;
}
static int valid_host(char *host) {
    size_t n=strlen(host); if(n&&host[n-1]=='.')host[--n]=0;
    const char *suffix=".googlevideo.com"; size_t z=strlen(suffix);
    if(n<=z||n>253||strcasecmp(host+n-z,suffix))return 0;
    size_t label=0;
    for(size_t i=0;i<n;i++) {
        unsigned char c=(unsigned char)host[i];
        if(c=='.') { if(!label||label>63||host[i-1]=='-')return 0; label=0; continue; }
        if(!(isalnum(c)||c=='-')||(!label&&c=='-'))return 0;
        host[i]=(char)tolower(c); label++;
    }
    return label&&label<=63&&host[n-1]!='-';
}
static uint64_t fnv_pair(const char *host,const char *ip) {
    uint64_t h=1469598103934665603ULL;
    for(const char *p=host;*p;p++)h=(h^(unsigned char)tolower((unsigned char)*p))*1099511628211ULL;
    h=(h^'|')*1099511628211ULL;
    for(const char *p=ip;*p;p++)h=(h^(unsigned char)*p)*1099511628211ULL;
    return h?h:1;
}
static int duplicate_recent(const char *host,const char *ip,uint32_t ttl) {
    uint64_t now=mono_millis(),hash=fnv_pair(host,ip); size_t start=(size_t)(hash%OBS_CACHE_SIZE);
    for(size_t n=0;n<OBS_CACHE_SIZE;n++) {
        size_t i=(start+n)%OBS_CACHE_SIZE; struct obs_cache_entry *e=&obs_cache[i];
        if(e->hash==hash&&e->expires_ms>now)return 1;
        if(!e->hash||e->expires_ms<=now) { e->hash=hash; e->expires_ms=now+(uint64_t)ttl*1000; return 0; }
    }
    obs_cache[obs_cache_cursor].hash=hash; obs_cache[obs_cache_cursor].expires_ms=now+(uint64_t)ttl*1000;
    obs_cache_cursor=(obs_cache_cursor+1)%OBS_CACHE_SIZE; return 0;
}
static int central_has_ip(const char *ip) {
    FILE *f=fopen(central_file,"r"); if(!f)return 0; char line[128]; int found=0;
    while(fgets(line,sizeof(line),f)) { line[strcspn(line,"\r\n")]=0; if(!strcmp(line,ip)){found=1;break;} }
    fclose(f); return found;
}
static int reported_pair(const char *host,const char *ip,uint64_t now) {
    FILE *f=fopen(reported_file,"r"); if(!f)return 0; char line[640],h[256],a[32]; unsigned long long ts; int found=0;
    while(fgets(line,sizeof(line),f)) if(sscanf(line,"%255[^\t]\t%31[^\t]\t%llu",h,a,&ts)==3&&!strcmp(h,host)&&!strcmp(a,ip)&&ts+2592000>=now){found=1;break;}
    fclose(f); return found;
}
static int pending_pair(const char *host,const char *ip) {
    DIR *d=opendir(gv_tmpdir); if(!d)return 0; struct dirent *de; int found=0; char path[MAX_PATH_LEN];
    while((de=readdir(d))) {
        if(strcmp(de->d_name,"pending.tsv")&&strncmp(de->d_name,"pending.tsv.sending.",20)&&strncmp(de->d_name,"pending.retry.",14))continue;
        if(snprintf(path,sizeof(path),"%s/%s",gv_tmpdir,de->d_name)>=(int)sizeof(path))continue;
        FILE *f=fopen(path,"r"); if(!f)continue; char line[640],a[32],h[256]; unsigned long long ts;
        while(fgets(line,sizeof(line),f)) if(sscanf(line,"%31[^\t]\t%llu\t%255[^\t]",a,&ts,h)==3&&!strcmp(a,ip)&&!strcmp(h,host)){found=1;break;}
        fclose(f); if(found)break;
    }
    closedir(d); return found;
}
static int rewrite_bounded(const char *path,unsigned max_rows) {
    char tmp1[MAX_PATH_LEN],tmp2[MAX_PATH_LEN];
    if(snprintf(tmp1,sizeof(tmp1),"%s.tmp.%ld",path,(long)getpid())>=(int)sizeof(tmp1)||
       snprintf(tmp2,sizeof(tmp2),"%s.bounded.%ld",path,(long)getpid())>=(int)sizeof(tmp2))return -1;
    FILE *in=fopen(path,"r"); if(!in)return -1; unsigned long rows=0; char line[1024]; while(fgets(line,sizeof(line),in))rows++; rewind(in);
    if(rows<=max_rows){fclose(in);return 0;}
    FILE *out=fopen(tmp1,"w"); if(!out){fclose(in);return -1;}
    unsigned long skip=rows-max_rows; while(skip--&&fgets(line,sizeof(line),in)){} while(fgets(line,sizeof(line),in))fputs(line,out);
    int bad=ferror(in); if(fclose(in))bad=1; if(fclose(out))bad=1;
    if(!bad&&rename(tmp1,tmp2))bad=1;
    if(!bad&&rename(tmp2,path))bad=1;
    if(bad){unlink(tmp1);unlink(tmp2);return -1;} return 0;
}
static int local_write(const char *host,const char *ip,uint64_t expires,uint64_t now) {
    if(mkdir_parent(local_file))return -1;
    char tmp[MAX_PATH_LEN]; if(snprintf(tmp,sizeof(tmp),"%s.tmp.%ld",local_file,(long)getpid())>=(int)sizeof(tmp))return -1;
    FILE *in=fopen(local_file,"r"),*out=fopen(tmp,"w"); if(!out){if(in)fclose(in);return -1;}
    char line[1024],h[256],a[32]; unsigned long long exp,observed; unsigned rows=0;
    if(in) while(fgets(line,sizeof(line),in)) {
        int n=sscanf(line,"%255[^\t]\t%31[^\t]\t%llu\t%llu",h,a,&exp,&observed);
        if(n>=3&&exp<=now)continue;
        if(n>=2&&!strcmp(h,host)&&!strcmp(a,ip))continue;
        fputs(line,out); rows++;
    }
    if(in)fclose(in);
    fprintf(out,"%s\t%s\t%llu\t%llu\n",host,ip,(unsigned long long)expires,(unsigned long long)now); rows++;
    if(fclose(out)||rename(tmp,local_file)){unlink(tmp);return -1;}
    if(rows>8192&&rewrite_bounded(local_file,8192))return -1;
    return 0;
}
static int pending_append(const char *host,const char *ip,uint64_t now) {
    if(reported_pair(host,ip,now)||pending_pair(host,ip))return 0;
    if(mkdir_parent(pending_file))return -1;
    FILE *f=fopen(pending_file,"a"); if(!f)return -1;
    int rc=fprintf(f,"%s\t%llu\t%s\n",ip,(unsigned long long)now,host)<0; if(fclose(f))rc=1; if(rc)return -1;
    return rewrite_bounded(pending_file,8192);
}
static int run_argv(char *const argv[]) {
    pid_t p=fork(); if(p<0)return -1;
    if(!p) {
        int fd=open(log_file,O_WRONLY|O_CREAT|O_APPEND,0644); if(fd>=0){dup2(fd,STDERR_FILENO);close(fd);}
        execvp(argv[0],argv); _exit(127);
    }
    int status=0; while(waitpid(p,&status,0)<0){if(errno==EINTR)continue;return -1;}
    return WIFEXITED(status)?WEXITSTATUS(status):-1;
}
static int set_add(const char *ip,uint32_t ttl) {
    char timeout[32],element[128]; snprintf(timeout,sizeof(timeout),"%u",ttl);
    if(!strcmp(fwtype,"iptables")) {
        char *args[]={"ipset","add","z2r_googlevideo4",(char *)ip,"timeout",timeout,"-exist",NULL};
        return run_argv(args);
    }
    if(!strcmp(fwtype,"nftables")) {
        if(!*nft_table)snprintf(nft_table,sizeof(nft_table),"zapret2");
        snprintf(element,sizeof(element),"{ %s timeout %us }",ip,ttl);
        char *args[]={"nft","add","element","inet",nft_table,"z2r_googlevideo4",element,NULL};
        int rc=run_argv(args); if(!rc)return 0;
        /* The IP may already have been inserted by dnsmasq or a concurrent event. */
        snprintf(element,sizeof(element),"{ %s }",ip);
        char *check[]={"nft","get","element","inet",nft_table,"z2r_googlevideo4",element,NULL};
        return run_argv(check)==0?0:rc;
    }
    return -1;
}
static int set_recently_added(const char *ip,uint32_t ttl) {
    struct in_addr a4; if(inet_pton(AF_INET,ip,&a4)!=1)return 0;
    uint64_t now=mono_millis();
    for(size_t i=0;i<sizeof(set_cache)/sizeof(set_cache[0]);i++)
        if(set_cache[i].ip==a4.s_addr&&set_cache[i].expires_ms>now)return 1;
    if(set_add(ip,ttl))return 0;
    size_t i=set_cache_cursor++%(sizeof(set_cache)/sizeof(set_cache[0]));
    set_cache[i].ip=a4.s_addr; set_cache[i].expires_ms=now+(uint64_t)ttl*1000;
    return 1;
}
static void observe_dns(const char *raw_host,const char *ip,uint32_t ttl) {
    char host[MAX_NAME]; snprintf(host,sizeof(host),"%s",raw_host);
    if(!valid_host(host)||!public_ipv4_text(ip)) { log_msg("observation rejected host=%s ip=%s",raw_host,ip); return; }
    if(!ttl)return;
    if(ttl>604800)ttl=604800;
    if(duplicate_recent(host,ip,ttl))return;
    uint64_t now=wall_seconds();
    if(local_write(host,ip,now+ttl,now)) { log_msg("local_write_failed host=%s ip=%s",host,ip); return; }
    if(pending_append(host,ip,now))log_msg("queue_failed host=%s ip=%s",host,ip);
    if(!central_has_ip(ip)&&!set_recently_added(ip,ttl))log_msg("set_add_failed fwtype=%s host=%s ip=%s",fwtype,host,ip);
    log_msg("observation host=%s ip=%s ttl=%u result=stored",host,ip,ttl);
}
static int json_string(const char *json,const char *key,char *out,size_t cap) {
    char needle[80]; if(snprintf(needle,sizeof(needle),"\"%s\"",key)>=(int)sizeof(needle))return 0;
    const char *p=json;
    while((p=strstr(p,needle))) {
        p+=strlen(needle); while(isspace((unsigned char)*p))p++; if(*p++!=':')continue;
        while(isspace((unsigned char)*p))p++;
        if(*p++!='"')continue;
        size_t n=0; int valid=1;
        while(*p&&*p!='"') {
            unsigned char c=(unsigned char)*p++;
            if(c=='\\') { c=(unsigned char)*p++; if(c=='"'||c=='\\'||c=='/'){} else {valid=0;break;} }
            if(c<0x20||n+1>=cap){valid=0;break;} out[n++]=(char)c;
        }
        if(valid&&*p=='"'){out[n]=0;return 1;}
    }
    return 0;
}
static int json_uint(const char *json,const char *key,uint32_t *value) {
    char needle[80]; if(snprintf(needle,sizeof(needle),"\"%s\"",key)>=(int)sizeof(needle))return 0;
    const char *p=json;
    while((p=strstr(p,needle))) {
        p+=strlen(needle); while(isspace((unsigned char)*p))p++; if(*p++!=':')continue;
        while(isspace((unsigned char)*p))p++;
        if(!isdigit((unsigned char)*p))continue;
        uint64_t n=0; while(isdigit((unsigned char)*p)){n=n*10+(unsigned)(*p++-'0');if(n>UINT32_MAX)return 0;}
        *value=(uint32_t)n; return 1;
    }
    return 0;
}
static void observe_ubus_line(char *line) {
    if(!strstr(line,"dns_result"))return;
    char host[MAX_NAME],type[16],ip[INET_ADDRSTRLEN]; uint32_t ttl;
    if(!json_string(line,"name",host,sizeof(host))||!json_string(line,"type",type,sizeof(type))||
       !json_string(line,"address",ip,sizeof(ip))||!json_uint(line,"ttl",&ttl)||strcmp(type,"A"))return;
    observe_dns(host,ip,ttl);
}
static int attach_filter(int fd);
static int file_has_data(const char *path) { struct stat st; return !stat(path,&st)&&st.st_size>0; }
static int telemetry_allowed(void) {
    char path[MAX_PATH_LEN],line[256];
    const char *env=getenv("Z2R_GV_TELEMETRY_CFG");
    if(env&&*env)snprintf(path,sizeof(path),"%s",env); else if(path_join(path,sizeof(path),gv_root,"z2r_lib/telemetry.config"))return 0;
    FILE *f=fopen(path,"r"); if(!f)return 0; int ok=0;
    while(fgets(line,sizeof(line),f))if(!strcmp(line,"tel_enabled=1\n")||!strcmp(line,"tel_enabled=1\r\n")||!strcmp(line,"tel_enabled=1")){ok=1;break;}
    fclose(f); return ok;
}
static int has_pending(void) {
    if(file_has_data(pending_file))return 1;
    DIR *d=opendir(gv_tmpdir); if(!d)return 0; struct dirent *de; int found=0;
    while((de=readdir(d))) if(!strncmp(de->d_name,"pending.retry.",14)||!strncmp(de->d_name,"pending.tsv.sending.",20)) { char p[MAX_PATH_LEN]; if(snprintf(p,sizeof(p),"%s/%s",gv_tmpdir,de->d_name)<(int)sizeof(p)&&file_has_data(p)){found=1;break;} }
    closedir(d); return found;
}
static int upload_due(uint64_t now) {
    char path[MAX_PATH_LEN],line[64]; uint64_t stamp=0,attempt=0; unsigned interval=10800;
    if(!has_pending()||!telemetry_allowed())return 0;
    const char *e=getenv("Z2R_GOOGLEVIDEO_UPLOAD_INTERVAL"); if(e&&*e){char *end; unsigned long x=strtoul(e,&end,10);if(!*end&&x>=1&&x<=604800)interval=(unsigned)x;}
    if(path_join(path,sizeof(path),gv_tmpdir,"googlevideo-upload.ts"))return 0;
    FILE *f=fopen(path,"r"); if(f){if(fgets(line,sizeof(line),f))stamp=strtoull(line,NULL,10);fclose(f);}
    if(path_join(path,sizeof(path),gv_tmpdir,"googlevideo-upload-attempt.ts"))return 0;
    f=fopen(path,"r"); if(f){if(fgets(line,sizeof(line),f))attempt=strtoull(line,NULL,10);fclose(f);}
    if(attempt>stamp)stamp=attempt;
    return now>=stamp&&now-stamp>=interval;
}
static void write_upload_attempt(uint64_t now) {
    char path[MAX_PATH_LEN],tmp[MAX_PATH_LEN],value[32];
    if(path_join(path,sizeof(path),gv_tmpdir,"googlevideo-upload-attempt.ts"))return;
    int n=snprintf(value,sizeof(value),"%llu\n",(unsigned long long)now);
    char suffix[32]; snprintf(suffix,sizeof(suffix),".tmp.%ld",(long)getpid());
    if(path_suffix(tmp,sizeof(tmp),path,suffix))return;
    int fd=open(tmp,O_WRONLY|O_CREAT|O_TRUNC,0644); if(fd<0)return;
    int rc=write(fd,value,(size_t)n)==n?0:-1; if(close(fd))rc=-1;
    if(!rc)rename(tmp,path); else unlink(tmp);
}
static pid_t upload_child=-1;
static void maybe_upload(void) {
    if(upload_child>0) { int st; pid_t r=waitpid(upload_child,&st,WNOHANG); if(r==upload_child||r<0)upload_child=-1; }
    static uint64_t next_check;
    uint64_t now=wall_seconds(); if(now<next_check)return; next_check=now+60;
    if(upload_child>0||!upload_due(now))return;
    pid_t p=fork(); if(p<0)return;
    if(!p){execl("/bin/sh","sh",upload_helper,"upload-once",(char *)NULL);_exit(127);}
    upload_child=p; write_upload_attempt(now);
}
static int acquire_pid(void) {
    if(mkdir_parent(pid_file))return -1;
    for(unsigned attempt=0;attempt<2;attempt++) {
        int fd=open(pid_file,O_WRONLY|O_CREAT|O_EXCL,0644);
        if(fd>=0) {
            char value[32]; int n=snprintf(value,sizeof(value),"%ld\n",(long)getpid());
            int rc=write(fd,value,(size_t)n)==n?0:-1; if(close(fd))rc=-1;
            if(rc)unlink(pid_file);
            return rc? -1:0;
        }
        if(errno!=EEXIST)return -1;
        FILE *f=fopen(pid_file,"r"); long pid=0;
        if(f){if(fscanf(f,"%ld",&pid)!=1)pid=0;fclose(f);}
        if(pid==0) {
            sleep(1);
            f=fopen(pid_file,"r"); if(f){if(fscanf(f,"%ld",&pid)!=1)pid=0;fclose(f);}
        }
        if(pid>0&&pid!=(long)getpid()&&(kill((pid_t)pid,0)==0||errno==EPERM))return 1;
        if(unlink(pid_file)&&errno!=ENOENT)return -1;
    }
    return -1;
}
static void remove_pid(void) {
    FILE *f=fopen(pid_file,"r"); long pid=0;
    if(f){if(fscanf(f,"%ld",&pid)!=1)pid=0;fclose(f);}
    if(pid==(long)getpid())unlink(pid_file);
}
static int open_ubus_pipe(pid_t *child) {
    int fds[2]; if(pipe(fds))return -1;
    const char *ubus=getenv("Z2R_GV_UBUS"); if(!ubus||!*ubus)ubus="ubus";
    pid_t p=fork(); if(p<0){close(fds[0]);close(fds[1]);return -1;}
    if(!p){dup2(fds[1],STDOUT_FILENO);int devnull=open("/dev/null",O_WRONLY);if(devnull>=0){dup2(devnull,STDERR_FILENO);close(devnull);}close(fds[0]);close(fds[1]);execlp(ubus,ubus,"subscribe","dnsmasq.dns",(char *)NULL);_exit(127);}
    close(fds[1]); *child=p; return fds[0];
}
static int ubus_available(void) {
    const char *release=getenv("Z2R_GV_OPENWRT_RELEASE"); if(!release||!*release)release="/etc/openwrt_release";
    return access(release,F_OK)==0;
}
static int run_ubus_collector(void) {
    pid_t child=-1; int fd=-1; char buf[8192]; size_t used=0;
    while(running&&collector_enabled()) {
        if(fd<0) { fd=open_ubus_pipe(&child); if(fd<0){sleep(1);maybe_upload();continue;} used=0; }
        struct pollfd p={.fd=fd,.events=POLLIN|POLLHUP|POLLERR}; int rc=poll(&p,1,1000);
        if(rc>0&&(p.revents&POLLIN)) {
            char chunk[1024]; ssize_t n=read(fd,chunk,sizeof(chunk));
            if(n>0) for(ssize_t i=0;i<n;i++) {
                if(chunk[i]=='\n') { buf[used]=0; observe_ubus_line(buf); used=0; }
                else if(used+1<sizeof(buf))buf[used++]=chunk[i]; else used=0;
            }
            else if(n==0)rc=1;
        }
        if(rc>0&&(p.revents&(POLLHUP|POLLERR)))rc=1;
        if(rc>0&&!(p.revents&POLLIN))rc=1;
        int st; if(child>0&&waitpid(child,&st,WNOHANG)==child)rc=1;
        if(rc==1) {
            close(fd);fd=-1;
            if(child>0){kill(child,SIGTERM);while(waitpid(child,NULL,0)<0&&errno==EINTR){}child=-1;}
            sleep(1);
        }
        maybe_upload();
    }
    if(fd>=0)close(fd);
    if(child>0){kill(child,SIGTERM);waitpid(child,NULL,0);}
    return 0;
}
static int run_packet_collector(void) {
    int fd=socket(AF_PACKET,SOCK_RAW,htons(ETH_P_ALL)); if(fd<0){perror("AF_PACKET");return 1;}
    if(attach_filter(fd)<0){perror("SO_ATTACH_FILTER");close(fd);return 1;}
    unsigned char b[65536]; struct pollfd p={.fd=fd,.events=POLLIN};
    while(running&&collector_enabled()) {
        int rc=poll(&p,1,1000); if(rc<0){if(errno==EINTR)continue;break;}
        if(rc>0&&(p.revents&POLLIN)){ssize_t n=recv(fd,b,sizeof(b),0);if(n>0)dns_packet(b,(size_t)n);}
        maybe_upload();
    }
    close(fd); return 0;
}
static int run_collector(void) {
    collector_paths(); if(mkdir_parent(local_file)||mkdir_parent(pending_file))return 1;
    if(!collector_enabled())return 0;
    load_fw_config();
    struct sigaction sa; memset(&sa,0,sizeof(sa)); sa.sa_handler=stop; sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM,&sa,NULL);sigaction(SIGINT,&sa,NULL);sigaction(SIGHUP,&sa,NULL);
    int lock=acquire_pid();
    if(lock>0){log_msg("collector_already_running");return 0;}
    if(lock<0){log_msg("pidfile_write_failed path=%s",pid_file);return 1;}
    collector_mode=1; log_msg("collector_started source=%s",ubus_available()?"ubus":"af_packet");
    int rc=ubus_available()?run_ubus_collector():run_packet_collector();
    if(upload_child>0){int st; if(waitpid(upload_child,&st,WNOHANG)==0){sleep(1);if(waitpid(upload_child,&st,WNOHANG)==0){kill(upload_child,SIGTERM);waitpid(upload_child,&st,0);}}}
    remove_pid(); log_msg("collector_stopped"); return rc;
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
    if(argc==2&&!strcmp(argv[1],"--collector"))return run_collector();
    if(argc==2&&(!strcmp(argv[1],"--ingest-stream")||!strcmp(argv[1],"--ingest-ubus"))) {
        int ubus=!strcmp(argv[1],"--ingest-ubus"); collector_paths();load_fw_config();collector_mode=1;
        char line[8192];
        while(fgets(line,sizeof(line),stdin)) {
            if(ubus)observe_ubus_line(line);
            else { char host[MAX_NAME],ip[INET_ADDRSTRLEN],extra; unsigned ttl;
                if(sscanf(line,"%255[^\t]\t%15[^\t]\t%u%c",host,ip,&ttl,&extra)>=3)observe_dns(host,ip,ttl);
            }
        }
        return ferror(stdin)?1:0;
    }
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
