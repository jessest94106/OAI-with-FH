// Measure UDP packet-loss DISTRIBUTION over a link (no capture -> no capture loss).
// Uses sendmmsg/recvmmsg so the generator/receiver are NOT syscall-bound (single
// sendto/recv tops out ~4-5 Gbps; batched can saturate the NIC). Every packet carries
// a 64-bit seq; receiver reconstructs the loss pattern -> burst-length histogram.
//   send: ./nicloss send <dstip> <port> <rate_mbps 0=max> <seconds>
//   recv: ./nicloss recv <port> <seconds_idle_timeout>
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <time.h>

#ifndef PLEN
#define PLEN 1400
#endif
#define BATCH 64
#define MAXBURST 8192
#define MAXTRACE (8*1024*1024)
static const uint64_t ENDMARK = ~0ULL;
static double now_s(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec*1e-9; }

int main(int argc, char**argv){
  if (argc<2){ fprintf(stderr,"usage: send <ip> <port> <rate_mbps 0=max> <sec> | recv <port> <idle_sec>\n"); return 1; }

  if (!strcmp(argv[1],"send") && argc>=6){
    const char*ip=argv[2]; int port=atoi(argv[3]); double rate=atof(argv[4]); double secs=atof(argv[5]);
    int s=socket(AF_INET,SOCK_DGRAM,0);
    struct sockaddr_in d={0}; d.sin_family=AF_INET; d.sin_port=htons(port); inet_pton(AF_INET,ip,&d.sin_addr);
    if (connect(s,(void*)&d,sizeof d)){ perror("connect"); return 1; }
    int sz=16<<20; setsockopt(s,SOL_SOCKET,SO_SNDBUF,&sz,sizeof sz);
    static char bufs[BATCH][PLEN]; struct mmsghdr msgs[BATCH]; struct iovec iov[BATCH];
    memset(bufs,0xab,sizeof bufs);
    for(int i=0;i<BATCH;i++){ iov[i].iov_base=bufs[i]; iov[i].iov_len=PLEN; memset(&msgs[i],0,sizeof msgs[i]);
      msgs[i].msg_hdr.msg_iov=&iov[i]; msgs[i].msg_hdr.msg_iovlen=1; }
    uint64_t seq=0; double t0=now_s(), tend=t0+secs; double bps=rate*1e6/8.0;
    while (now_s()<tend){
      for (int i=0;i<BATCH;i++){ memcpy(bufs[i],&seq,8); seq++; }
      int sent=sendmmsg(s,msgs,BATCH,0); if(sent<0){ if(seq==BATCH)perror("sendmmsg"); }
      if (rate>0){ double should=t0+(double)seq*PLEN/bps, dt=should-now_s();
        if (dt>0){ struct timespec ts={(long)dt,(long)((dt-(long)dt)*1e9)}; nanosleep(&ts,0); } }
    }
    for (int i=0;i<BATCH;i++) memcpy(bufs[i],&ENDMARK,8);
    for (int r=0;r<3;r++) sendmmsg(s,msgs,BATCH,0);
    fprintf(stderr,"SENT %lu pkts %.0f Mbps over %.1fs\n",(unsigned long)seq,(double)seq*PLEN*8/1e6/secs,secs);
    return 0;
  }

  if (!strcmp(argv[1],"recv") && argc>=4){
    int port=atoi(argv[2]); double idle=atof(argv[3]); const char*tracef=(argc>=5)?argv[4]:NULL;
    int s=socket(AF_INET,SOCK_DGRAM,0);
    struct sockaddr_in a={0}; a.sin_family=AF_INET; a.sin_addr.s_addr=INADDR_ANY; a.sin_port=htons(port);
    if (bind(s,(void*)&a,sizeof a)){ perror("bind"); return 1; }
    int sz=128<<20; setsockopt(s,SOL_SOCKET,SO_RCVBUF,&sz,sizeof sz);
    struct timeval tv={(long)idle,0}; setsockopt(s,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof tv);
    static char bufs[BATCH][PLEN+16]; struct mmsghdr msgs[BATCH]; struct iovec iov[BATCH];
    for(int i=0;i<BATCH;i++){ iov[i].iov_base=bufs[i]; iov[i].iov_len=sizeof bufs[i]; memset(&msgs[i],0,sizeof msgs[i]);
      msgs[i].msg_hdr.msg_iov=&iov[i]; msgs[i].msg_hdr.msg_iovlen=1; }
    uint64_t recvd=0,last=0,mins=~0ULL,maxs=0,losses=0,ooo=0; int have=0,done=0;
    uint64_t *hist=calloc(MAXBURST+1,sizeof(uint64_t));
    unsigned char *dmap = tracef ? calloc(MAXTRACE,1) : NULL;   // 1=dropped, 0=kept, indexed by abs seq
    while (!done){
      int n=recvmmsg(s,msgs,BATCH,0,NULL);
      if (n<=0) break;                 // idle timeout -> done
      for (int j=0;j<n;j++){
        if (msgs[j].msg_len<8) continue;
        uint64_t seq; memcpy(&seq,bufs[j],8);
        if (seq==ENDMARK){ done=1; break; }
        recvd++;
        if (seq<mins) mins=seq; if (seq>maxs) maxs=seq;
        if (!have){ have=1; last=seq; continue; }
        if (seq==last+1) last=seq;
        else if (seq>last+1){ uint64_t b=seq-last-1; losses+=b;
          if(dmap) for(uint64_t g=last+1; g<seq && g<MAXTRACE; g++) dmap[g]=1;
          if(b>MAXBURST)b=MAXBURST; hist[b]++; last=seq; }
        else ooo++;
      }
    }
    uint64_t sent=(maxs>=mins)?(maxs-mins+1):0;
    printf("RECV recvd=%lu est_sent=%lu lost=%lu loss_pct=%.3f ooo=%lu\n",
      (unsigned long)recvd,(unsigned long)sent,(unsigned long)losses, sent?100.0*losses/sent:0.0,(unsigned long)ooo);
    uint64_t nb=0; double slb=0;
    printf("burstlen,count\n");
    for (int k=1;k<=MAXBURST;k++) if (hist[k]){ printf("%d,%lu\n",k,(unsigned long)hist[k]); nb+=hist[k]; slb+=(double)k*hist[k]; }
    double p = sent?(double)losses/sent:0.0;
    printf("SUMMARY loss_pct=%.3f n_loss_events=%lu lost_pkts=%lu mean_burst=%.3f singleton_frac=%.4f bernoulli_mean_burst=%.3f\n",
      100.0*p,(unsigned long)nb,(unsigned long)losses, nb?slb/nb:0.0, nb?(double)hist[1]/nb:0.0, (p<1)?1.0/(1.0-p):0.0);
    if (dmap){ uint64_t len=(maxs+1<MAXTRACE)?maxs+1:MAXTRACE; FILE*tf=fopen(tracef,"wb");
      if(tf){ fwrite(dmap,1,len,tf); fclose(tf); fprintf(stderr,"TRACE %lu pkts (drop-bitmap) -> %s\n",(unsigned long)len,tracef);} }
    return 0;
  }
  fprintf(stderr,"bad args\n"); return 1;
}
