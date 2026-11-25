#include "a19_policy.h"
#include <assert.h>
#include <stdio.h>
#define MIB (1024ull*1024)
#define S 1000000000ull
int main(void){
 A19Policy p={0};A19Decision d=a19_policy_sample(&p,0,2048*MIB,0,6000);assert(!d.paused&&d.warm_limit==4200);
 for(unsigned i=1;i<=3;i++)d=a19_policy_sample(&p,i*S,256*MIB,1,6000);
 assert(d.paused);
 for(unsigned i=4;i<13;i++){d=a19_policy_sample(&p,i*S,1200*MIB,1,6000);assert(d.paused);}
 d=a19_policy_sample(&p,13*S,1200*MIB,1,6000);assert(!d.paused);
 d=a19_policy_sample(&p,14*S,0,3,0);assert(d.paused);
 d=a19_policy_sample(&p,15*S,0,-1,0);assert(d.paused);
 puts("A19 policy: low-memory hysteresis, recovery, unknown samples, critical thermal");
 return 0;
}
