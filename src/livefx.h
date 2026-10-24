#ifndef TONORA_LIVEFX_H
#define TONORA_LIVEFX_H
#include "piano.h"
typedef struct KvLiveEffects KvLiveEffects;
KvLiveEffects *kv_live_effects_create(void);
void kv_live_effects_reset(KvLiveEffects *fx);
void kv_live_effects_free(KvLiveEffects *fx);
bool kv_live_effects_process(KvLiveEffects *fx,float *stereo,size_t frames,KvEffects settings);
#endif
