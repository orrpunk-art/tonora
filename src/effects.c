#include "piano.h"
#include "livefx.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#define verblib_max_sample_rate_multiplier 1
#define VERBLIB_IMPLEMENTATION
#include "../third_party/verblib/verblib.h"
#define RATE 44100
#define DELAY_CAPACITY 54000
struct KvLiveEffects {
    verblib room;
    float delay[DELAY_CAPACITY][2];
    float feedback_filter[2];
    size_t cursor;
    double delay_samples,old_delay,target_delay,pending_delay;
    unsigned crossfade;
    float delay_mix,reverb_mix;
    bool initialized;
};
KvLiveEffects *kv_live_effects_create(void) {
    KvLiveEffects *fx=calloc(1,sizeof(*fx));
    if(!fx) return NULL;
    if(!verblib_initialize(&fx->room,RATE,2)) { free(fx); return NULL; }
    verblib_set_room_size(&fx->room,.72f);
    verblib_set_damping(&fx->room,.35f);
    verblib_set_width(&fx->room,1);
    verblib_set_dry(&fx->room,0);
    verblib_set_wet(&fx->room,.8f);
    return fx;
}
void kv_live_effects_reset(KvLiveEffects *fx) {
    if(!fx) return;
    verblib_mute(&fx->room); memset(fx->delay,0,sizeof(fx->delay));
    memset(fx->feedback_filter,0,sizeof(fx->feedback_filter)); fx->cursor=0;
}
void kv_live_effects_free(KvLiveEffects *fx) { free(fx); }
static float tap(const KvLiveEffects *fx,double frames,int channel) {
    double position=(double)fx->cursor-frames;
    if(position<0) position+=DELAY_CAPACITY;
    size_t at=(size_t)position,next=(at+1)%DELAY_CAPACITY;
    float fraction=(float)(position-at);
    return fx->delay[at][channel]*(1-fraction)+fx->delay[next][channel]*fraction;
}
bool kv_live_effects_process(KvLiveEffects *fx,float *pcm,size_t frames,KvEffects settings) {
    if(!fx || !pcm || !kv_effects_valid(settings)) return false;
    double requested=round(settings.delay_seconds*RATE);
    if(!fx->initialized) {
        fx->old_delay=fx->target_delay=fx->delay_samples=fx->pending_delay=requested; fx->crossfade=882;
        fx->delay_mix=settings.delay; fx->reverb_mix=settings.reverb; fx->initialized=true;
    } else fx->pending_delay=requested;
    for(size_t i=0;i<frames;i++) {
        float dry[2]={pcm[i*2],pcm[i*2+1]},room[2];
        verblib_process(&fx->room,dry,room,1);
        float fade=fminf(1,fx->crossfade/882.0f);
        float repeats[2];
        for(int c=0;c<2;c++) {
            repeats[c]=tap(fx,fx->old_delay,c)*(1-fade)+tap(fx,fx->target_delay,c)*fade;
            fx->feedback_filter[c]+=.45f*(repeats[c]-fx->feedback_filter[c]);
        }
        if(fx->crossfade<882) fx->crossfade++;
        else {
            fx->old_delay=fx->delay_samples=fx->target_delay;
            // Crossfade between fixed taps instead of pitch bending; a new time waits for the running fade, cutting it clicks.
            if(fx->pending_delay!=fx->target_delay) { fx->target_delay=fx->pending_delay; fx->crossfade=0; }
        }
        fx->delay_mix+=(settings.delay-fx->delay_mix)*.002f;
        fx->reverb_mix+=(settings.reverb-fx->reverb_mix)*.002f;
        // Equal-power reverb mix: 0 = dry, 1 = isolated reverb return.
        float dry_gain=cosf(fx->reverb_mix*(float)M_PI_2);
        float room_gain=sinf(fx->reverb_mix*(float)M_PI_2);
        for(int c=0;c<2;c++) {
            // Stereo repeats, moderate feedback, full bandwidth on the first echo.
            fx->delay[fx->cursor][c]=dry[c]+fx->feedback_filter[1-c]*.38f;
            pcm[i*2+c]=dry[c]*dry_gain+repeats[c]*fx->delay_mix*1.3f+room[c]*room_gain;
            if(!isfinite(pcm[i*2+c])) return false;
        }
        fx->cursor=(fx->cursor+1)%DELAY_CAPACITY;
    }
    return true;
}
bool kv_effects_process(float *pcm,size_t frames,KvEffects effects) {
    if(!pcm || !kv_effects_valid(effects)) return false;
    KvLiveEffects *fx=kv_live_effects_create(); if(!fx) return false;
    bool ok=kv_live_effects_process(fx,pcm,frames,effects); kv_live_effects_free(fx);
    float peak=0;
    for(size_t i=0;i<frames*2;i++) peak=fmaxf(peak,fabsf(pcm[i]));
    if(peak>.95f) for(size_t i=0;i<frames*2;i++) pcm[i]*=.95f/peak;
    return ok;
}
