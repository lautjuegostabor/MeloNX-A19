/* A19Core original policy, not an upstream emulator component. */
#pragma once
#include <stdint.h>
typedef struct {
    unsigned low_samples, high_samples;
    unsigned paused, initialized;
    uint32_t soft_limit;
    uint64_t last_ns;
} A19Policy;
typedef struct { uint32_t warm_limit; unsigned paused; } A19Decision;
/* Pure function; sample on a single control lane. Zero memory/thermal <0 = unknown. */
A19Decision a19_policy_sample(A19Policy *, uint64_t now_ns, uint64_t headroom, int thermal, uint32_t configured_limit);
/* Invoked by actual NVN pipeline prewarm path, not every guest instruction. */
int a19_prewarm_should_stop(uint64_t estimated_resident);
void a19_frame_observe(uint64_t dt_ns, int gameplay, int video, int cutscene);
void a19_session_observer_reset(const char *gid);
