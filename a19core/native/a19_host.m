/* A19Core platform policy and real frame telemetry. No per-frame file I/O. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <os/proc.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "a19_policy.h"
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static A19Policy policy;
static char game[32];
static uint64_t nframes, slow, duration_ns, max_ns, hist[16], minimum_room=UINT64_MAX, last_write, last_sample;
static uint64_t latest_room, latest_footprint;
static int latest_thermal=-1;
static _Atomic int running;
static dispatch_queue_t writer;
static uint64_t nsnow(void){return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);}
static uint64_t footprint(void){
    task_vm_info_data_t t;mach_msg_type_number_t n=TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&t,&n)==KERN_SUCCESS?t.phys_footprint:0;
}
static int target_device(void){
    char m[64]={0};size_t n=sizeof m;
    return sysctlbyname("hw.machine",m,&n,NULL,0)==0 && strcmp(m,"iPhone18,3")==0;
}
void a19_session_observer_reset(const char *gid){
    pthread_mutex_lock(&lock);
    memset(&policy,0,sizeof policy);nframes=slow=duration_ns=max_ns=last_write=last_sample=latest_room=latest_footprint=0;
    minimum_room=UINT64_MAX;memset(hist,0,sizeof hist);
    snprintf(game,sizeof game,"%s",gid?gid:""); atomic_store(&running,target_device() && strlen(game)==16);
    if(!writer)writer=dispatch_queue_create("a19core.telemetry",DISPATCH_QUEUE_SERIAL);
    pthread_mutex_unlock(&lock);
}
int a19_prewarm_should_stop(uint64_t estimate){
    (void)estimate;
    if(!atomic_load(&running))return 0;
    const char *enabled=getenv("A19CORE_ADAPTIVE");
    if(!enabled||strcmp(enabled,"1"))return 0;
    pthread_mutex_lock(&lock);
    uint64_t now=nsnow();
    A19Decision d={policy.soft_limit,policy.paused};
    if(!policy.initialized||now-policy.last_ns>=1000000000ull)
        d=a19_policy_sample(&policy,now,os_proc_available_memory(),(int)NSProcessInfo.processInfo.thermalState,0);
    pthread_mutex_unlock(&lock);
    return d.paused;
}
static void flush_stats(void){
    /* Called at most once per 10 seconds by the presenting thread, but writes
       dispatched away from the render lane. A single immutable snapshot. */
    uint64_t count=nframes,elapsed=duration_ns,maximum=max_ns,headroom=minimum_room;
    NSDictionary *d=@{@"titleId":@(game),@"frames":@(count),@"seconds":@((double)elapsed/1e9),
        @"guestFps":@(elapsed?(double)count*1e9/elapsed:0),@"over100ms":@(slow),
        @"maxFrameMs":@((double)maximum/1e6),@"minimumHeadroomBytes":@(headroom==UINT64_MAX?0:headroom),
        @"currentHeadroomBytes":@(latest_room),@"physFootprintBytes":@(latest_footprint),
        @"thermal":@(latest_thermal),@"adaptivePrewarmStopped":@(policy.paused),
        @"frameHistogramUpperMs":@[@4,@8,@12,@16,@20,@25,@33,@40,@50,@67,@83,@100,@150,@250,@500,@"over500"],
        @"frameHistogram":@[@(hist[0]),@(hist[1]),@(hist[2]),@(hist[3]),@(hist[4]),@(hist[5]),@(hist[6]),@(hist[7]),@(hist[8]),@(hist[9]),@(hist[10]),@(hist[11]),@(hist[12]),@(hist[13]),@(hist[14]),@(hist[15])]};
    dispatch_async(writer, ^{
        @autoreleasepool {
            NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            if(!docs)return;
            NSURL *dir=[docs URLByAppendingPathComponent:@"A19Diagnostics" isDirectory:YES];
            NSError *e=nil;
            if(![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&e])return;
            NSData *json=[NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&e];
            if(json)[json writeToURL:[dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.json",d[@"titleId"]]] options:NSDataWritingAtomic error:&e];
        }
    });
}
void a19_frame_observe(uint64_t dt,int gameplay,int video,int cutscene){
    if(!atomic_load(&running)||!gameplay||video||cutscene||!dt||dt>=1000000000ull)return;
    if(pthread_mutex_trylock(&lock))return; // never wait on prewarm lane
    @autoreleasepool {
        uint64_t now=nsnow();++nframes;duration_ns+=dt;if(dt>max_ns)max_ns=dt;if(dt>100000000ull)++slow;
        static const uint32_t upper[15]={4,8,12,16,20,25,33,40,50,67,83,100,150,250,500};
        unsigned i=0;while(i<15&&dt>(uint64_t)upper[i]*1000000ull)++i;++hist[i];
        if(!last_sample||now-last_sample>=1000000000ull){last_sample=now;latest_room=os_proc_available_memory();latest_footprint=footprint();latest_thermal=(int)NSProcessInfo.processInfo.thermalState;if(latest_room&&latest_room<minimum_room)minimum_room=latest_room;}
        if(!last_write||now-last_write>=10000000000ull){last_write=now;flush_stats();}
    }
    pthread_mutex_unlock(&lock);
}
