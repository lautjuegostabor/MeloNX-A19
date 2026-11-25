#include "a19_policy.h"
#define MIB (1024ull*1024ull)
#define SECOND 1000000000ull
/* Conservative candidate: only restrict speculative prewarming; never reject
 * mandatory first-use pipelines, change game timing or remove disk cache.
 * Thresholds are provisional until measured on the target device. */
A19Decision a19_policy_sample(A19Policy *p, uint64_t now, uint64_t room, int thermal, uint32_t configured) {
    uint32_t limit=configured ? (uint32_t)((uint64_t)configured*70/100) : 0;
    if(!p->initialized || now < p->last_ns) {
        p->initialized=1;p->last_ns=now;p->low_samples=0;p->high_samples=0;p->paused=0;
    } else if(now-p->last_ns<SECOND) {
        return (A19Decision){p->soft_limit,p->paused};
    }
    p->last_ns=now;
    unsigned low=(room && room<512*MIB)||thermal>=3;
    unsigned high=room>=1024*MIB && thermal>=0 && thermal<=1;
    if(low) { if(p->low_samples<3)++p->low_samples;p->high_samples=0; }
    else if(high) { if(p->high_samples<10)++p->high_samples;p->low_samples=0; }
    else {p->low_samples=0;p->high_samples=0;}
    if(p->low_samples>=3 || thermal>=3) p->paused=1;
    if(p->high_samples>=10) p->paused=0;
    p->soft_limit=limit;
    return (A19Decision){limit,p->paused};
}
