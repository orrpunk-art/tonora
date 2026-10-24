#include "audio.h"
#include "mixer.h"
#include "livefx.h"
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define FRAMES 256
#define COMMANDS 64
struct Command { unsigned epoch; int type,instrument,rhythm; size_t count,voices; double seconds; float values[2]; KvEffects effects; int notes[256]; KvPerformance performance; KvHit hits[KV_BEAT_HITS]; };
struct KvAudio {
    AudioQueueRef queue; AudioQueueBufferRef buffers[3];
    KvMixer *mixer; KvLiveEffects *fx; KvPianoBank *banks[KV_INSTRUMENTS],*drums;
    struct Command commands[COMMANDS]; atomic_uint read,write,stop_epoch; unsigned applied_stop;
    atomic_bool closing,playing,stop_requested; atomic_uint pending_plays; bool muted; float output_gain; atomic_int error,event;
    atomic_uint_fast64_t clock,start,active_low,active_high,part_start,silent; atomic_uint part; _Atomic double rhythm_beat;
    KvEffects effects; int instrument; bool started; uint64_t tail;
};
static bool send(KvAudio *audio,struct Command command) {
    unsigned write=atomic_load_explicit(&audio->write,memory_order_relaxed),next=(write+1)%COMMANDS;
    if(next==atomic_load_explicit(&audio->read,memory_order_acquire)) return false;
    command.epoch=atomic_load(&audio->stop_epoch);
    audio->commands[write]=command; atomic_store_explicit(&audio->write,next,memory_order_release); return true;
}
static void apply_stop(KvAudio *a) {
    unsigned epoch=atomic_load(&a->stop_epoch);
    if(epoch==a->applied_stop) return;
    kv_mixer_stop(a->mixer); kv_live_effects_reset(a->fx); a->tail=0;
    a->muted=true; a->applied_stop=epoch; atomic_store(&a->playing,false);
}
static void fill(void *context,AudioQueueRef queue,AudioQueueBufferRef buffer) {
    KvAudio *a=context; if(atomic_load(&a->closing)) return;
    apply_stop(a);
    unsigned read=atomic_load_explicit(&a->read,memory_order_relaxed),write=atomic_load_explicit(&a->write,memory_order_acquire);
    while(read!=write) {
        struct Command *c=&a->commands[read];
        apply_stop(a);
        bool stale=c->epoch!=a->applied_stop && (c->type==1 || c->type==2 || c->type==5 || c->type==6 || c->type==7 || c->type==8 || c->type==9 || c->type==15 || c->type==17 || c->type==18);   // a count-in belongs to its performance
        if(stale) { /* A stop invalidates queued playback and loop commands. */ }
        else if(c->type==0) { kv_mixer_stop(a->mixer); a->muted=true; atomic_store(&a->playing,false); }
        else if(c->type==3) a->effects=c->effects;
        else if(c->type==4) kv_mixer_humanize(a->mixer,c->count!=0);
        else if(c->type==7) {
            if(kv_mixer_performance(a->mixer,&c->performance,c->seconds,c->instrument)) {
                a->muted=false; atomic_store(&a->start,kv_mixer_start(a->mixer)); atomic_store(&a->playing,true);
            } else atomic_store(&a->error,1);
        }
        else if(c->type==6) kv_mixer_loop(a->mixer,c->count!=0);
        else if(c->type==8) {
            if(kv_mixer_preview(a->mixer,c->notes[0],c->seconds,c->instrument)) { a->muted=false; atomic_store(&a->playing,true); }
            else atomic_store(&a->error,1);
        }
        else if(c->type==5) kv_mixer_interval(a->mixer,c->seconds);
        else if(c->type==9) {
            if(kv_mixer_hold(a->mixer,c->notes[0],(float)c->seconds,c->instrument)) { a->muted=false; atomic_store(&a->playing,true); }
            else atomic_store(&a->error,1);
        }
        else if(c->type==10) kv_mixer_release(a->mixer,c->notes[0]);
        else if(c->type==11) kv_mixer_articulation(a->mixer,(KvArticulation)c->count);
        else if(c->type==12) kv_mixer_dynamics(a->mixer,c->values[0],c->values[1]);
        else if(c->type==13) kv_mixer_pedal(a->mixer,c->count!=0);
        else if(c->type==14) kv_mixer_rhythm(a->mixer,c->count!=0,(KvGrid)c->voices,(KvMeter)c->instrument,c->seconds,c->values[0]);
        else if(c->type==15) kv_mixer_count_in(a->mixer,c->seconds);
        else if(c->type==16) kv_mixer_beat(a->mixer,c->hits,c->count,c->voices!=0);
        else if(c->type==17) { if(!kv_mixer_queue(a->mixer,&c->performance,c->rhythm,c->hits,c->count,c->seconds)) atomic_store(&a->error,1); }
        else if(c->type==18) kv_mixer_phase(a->mixer,c->seconds);
        else if(kv_mixer_play(a->mixer,c->notes,c->count,c->voices,c->seconds,c->instrument,c->type==2)) {
            a->muted=false; atomic_store(&a->start,kv_mixer_start(a->mixer)); atomic_store(&a->playing,true);
        } else atomic_store(&a->error,1);
        if(c->type==1 || c->type==2 || c->type==7 || c->type==8 || c->type==9) atomic_fetch_sub(&a->pending_plays,1);
        read=(read+1)%COMMANDS;
    }
    atomic_store_explicit(&a->read,read,memory_order_release);
    apply_stop(a);
    float *pcm=buffer->mAudioData;
    if(!a->tail && kv_mixer_silent(a->mixer)) {   // nothing sounds and the effects have died away: zeros, only the clock moves
        kv_mixer_skip(a->mixer,FRAMES); memset(pcm,0,FRAMES*8); atomic_store(&a->playing,false); atomic_fetch_add(&a->silent,FRAMES);
        atomic_store(&a->part,kv_mixer_part(a->mixer)); atomic_store(&a->part_start,kv_mixer_start(a->mixer));
        atomic_store(&a->clock,kv_mixer_clock(a->mixer)); atomic_store(&a->event,kv_mixer_event(a->mixer)); atomic_store(&a->rhythm_beat,kv_mixer_rhythm_beat(a->mixer));
        atomic_store(&a->active_low,0); atomic_store(&a->active_high,0);
        buffer->mAudioDataByteSize=FRAMES*8;
        OSStatus result=AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
        if(result!=noErr && !atomic_load(&a->closing)) { atomic_store(&a->error,(int)result); atomic_store(&a->playing,false); }
        return;
    }
    atomic_store(&a->silent,0);
    kv_mixer_render(a->mixer,pcm,FRAMES); const float *dry=kv_mixer_dry(a->mixer);
    atomic_store(&a->playing,!a->muted && kv_mixer_running(a->mixer));
    if(kv_mixer_busy(a->mixer)) a->tail=(a->effects.reverb>0 || a->effects.delay>0)?44100*6:0;
    else if(a->tail>FRAMES) a->tail-=FRAMES;
    else { a->tail=0; atomic_store(&a->playing,false); }
    if(!kv_live_effects_process(a->fx,pcm,FRAMES,a->effects)) { memset(pcm,0,FRAMES*8); atomic_store(&a->error,2); }
    for(size_t i=0;i<FRAMES;i++) {
        a->output_gain+=( (a->muted?0:1)-a->output_gain)*.005f;
        for(int c=0;c<2;c++) {
            float x=pcm[i*2+c],magnitude=fabsf(x);
            float limited=magnitude<=.85f?x:copysignf(.85f+.10f*tanhf((magnitude-.85f)/.10f),x);
            float out=(isfinite(x)?limited*a->output_gain:0)+dry[i*2+c];   // the click goes in after the effects and the fade-out
            pcm[i*2+c]=fmaxf(-1,fminf(1,out));
        }
    }
    atomic_store(&a->part,kv_mixer_part(a->mixer)); atomic_store(&a->part_start,kv_mixer_start(a->mixer));
    atomic_store(&a->clock,kv_mixer_clock(a->mixer)); atomic_store(&a->event,kv_mixer_event(a->mixer)); atomic_store(&a->rhythm_beat,kv_mixer_rhythm_beat(a->mixer));
    int notes[KV_ACTIVE_NOTES]; unsigned count=kv_mixer_active(a->mixer,notes); uint64_t low=0,high=0;
    for(unsigned i=0;i<count;i++) { if(notes[i]<64) low|=UINT64_C(1)<<notes[i]; else high|=UINT64_C(1)<<(notes[i]-64); }
    atomic_store(&a->active_low,low); atomic_store(&a->active_high,high);
    buffer->mAudioDataByteSize=FRAMES*8;
    OSStatus result=AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
    if(result!=noErr && !atomic_load(&a->closing)) { atomic_store(&a->error,(int)result); atomic_store(&a->playing,false); }
}
KvAudio *kv_audio_create(void) {
    KvAudio *a=calloc(1,sizeof(*a)); if(!a) return NULL;
    atomic_init(&a->stop_epoch,0); atomic_init(&a->pending_plays,0); atomic_init(&a->stop_requested,false); atomic_init(&a->read,0); atomic_init(&a->write,0); atomic_init(&a->closing,false); atomic_init(&a->playing,false); atomic_init(&a->error,0); atomic_init(&a->event,-1);
    atomic_init(&a->clock,0); atomic_init(&a->start,0); atomic_init(&a->rhythm_beat,-1.0); atomic_init(&a->active_low,0); atomic_init(&a->active_high,0);
    a->effects=(KvEffects){0,0,.3}; a->output_gain=1; a->mixer=kv_mixer_create(); a->fx=kv_live_effects_create();
    if(!a->mixer || !a->fx) { kv_audio_destroy(a); return NULL; }
    AudioStreamBasicDescription format={.mSampleRate=44100,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,.mBytesPerPacket=8,.mFramesPerPacket=1,.mBytesPerFrame=8,.mChannelsPerFrame=2,.mBitsPerChannel=32};
    OSStatus result=AudioQueueNewOutput(&format,fill,a,NULL,NULL,0,&a->queue);
    if(result!=noErr) { fprintf(stderr,"AudioQueueNewOutput: %d\n",(int)result); kv_audio_destroy(a); return NULL; }
    for(int i=0;i<3;i++) if((result=AudioQueueAllocateBuffer(a->queue,FRAMES*8,&a->buffers[i]))!=noErr) { fprintf(stderr,"AudioQueueAllocateBuffer: %d\n",(int)result); kv_audio_destroy(a); return NULL; }
    return a;
}
bool kv_audio_load_instrument(KvAudio *a,int instrument,const char *directory) {
    if(!a || instrument<0 || instrument>=KV_INSTRUMENTS || a->started || a->banks[instrument]) return false;
    KvPianoBank *bank=kv_piano_load(directory); if(!bank) return false;
    a->banks[instrument]=bank; kv_mixer_bank(a->mixer,instrument,bank); return true;
}
bool kv_audio_load_piano(KvAudio *a,const char *directory) { return kv_audio_load_instrument(a,0,directory); }
bool kv_audio_load_drums(KvAudio *a,const char *directory) {
    if(!a || a->started || a->drums) return false;
    KvPianoBank *bank=kv_piano_load(directory); if(!bank) return false;
    a->drums=bank; kv_mixer_drums(a->mixer,bank); return true;
}
static bool start(KvAudio *a) {
    if(a->started) return true;
    if(!a->banks[0]) return false;
    for(int i=0;i<3;i++) fill(a,a->queue,a->buffers[i]);
    OSStatus result=AudioQueueStart(a->queue,NULL);
    if(result!=noErr) { fprintf(stderr,"AudioQueueStart: %d\n",(int)result); return false; }
    a->started=true; return true;
}
bool kv_audio_suspend(KvAudio *a) {
    if(!a || !a->started || atomic_load(&a->silent)<44100*3) return false;
    // Nothing waiting in the command ring (only this thread writes it): a stopped queue would leave it unplayed.
    if(atomic_load(&a->read)!=atomic_load(&a->write) || atomic_load(&a->pending_plays)) return false;
    AudioQueueStop(a->queue,true); a->started=false; atomic_store(&a->silent,0); return true;
}
void kv_audio_stop(KvAudio *a) {
    if(!a) return;
    atomic_store(&a->stop_requested,true);
    atomic_fetch_add(&a->stop_epoch,1);
    atomic_store(&a->playing,false); atomic_store(&a->active_low,0); atomic_store(&a->active_high,0);
}
bool kv_audio_set_instrument(KvAudio *a,int instrument) { if(!a || instrument<0 || instrument>=KV_INSTRUMENTS || !a->banks[instrument]) return false; a->instrument=instrument; return true; }
bool kv_audio_set_effects(KvAudio *a,KvEffects effects) { return a && kv_effects_valid(effects) && send(a,(struct Command){.type=3,.effects=effects}); }
bool kv_audio_play(KvAudio *a,const int *notes,size_t count,size_t voices,double seconds) {
    if(!a || !notes || !count || count>256 || !voices || voices>8 || count%voices || !isfinite(seconds) || seconds<.08 || seconds>3) return false;
    for(size_t i=0;i<count;i++) if(notes[i]<21 || notes[i]>108) return false;
    if(!start(a)) return false;
    struct Command command={.type=count==1?2:1,.instrument=a->instrument,.count=count,.voices=voices,.seconds=seconds}; memcpy(command.notes,notes,count*sizeof(int));
    atomic_store(&a->start,atomic_load(&a->clock)); atomic_store(&a->stop_requested,false);
    atomic_fetch_add(&a->pending_plays,1);
    if(!send(a,command)) { atomic_fetch_sub(&a->pending_plays,1); return false; }
    return true;
}
bool kv_audio_audition(KvAudio *a,int midi,double seconds) {
    if(!a || midi<21 || midi>108 || !isfinite(seconds) || seconds<.08 || seconds>3 || !start(a)) return false;
    struct Command command={.type=2,.instrument=a->instrument,.count=1,.voices=1,.seconds=seconds}; command.notes[0]=midi;
    if(!kv_audio_is_playing(a)) { atomic_store(&a->start,atomic_load(&a->clock)); atomic_store(&a->stop_requested,false); }
    atomic_fetch_add(&a->pending_plays,1);
    if(!send(a,command)) { atomic_fetch_sub(&a->pending_plays,1); return false; }
    return true;
}
bool kv_audio_hold(KvAudio *a,int midi,double velocity) {
    if(!a || midi<21 || midi>108 || !isfinite(velocity) || !start(a)) return false;
    struct Command command={.type=9,.instrument=a->instrument,.count=1,.voices=1,.seconds=velocity}; command.notes[0]=midi;
    if(!kv_audio_is_playing(a)) { atomic_store(&a->start,atomic_load(&a->clock)); atomic_store(&a->stop_requested,false); }
    atomic_fetch_add(&a->pending_plays,1);
    if(!send(a,command)) { atomic_fetch_sub(&a->pending_plays,1); return false; }
    return true;
}
bool kv_audio_release(KvAudio *a,int midi) {
    if(!a) return false;
    struct Command command={.type=10,.count=1,.voices=1}; command.notes[0]=midi; return send(a,command);
}
bool kv_audio_preview(KvAudio *a,int midi,double seconds) {
    if(!a || midi<21 || midi>108 || !isfinite(seconds) || seconds<.08 || seconds>3 || !start(a)) return false;
    struct Command command={.type=8,.instrument=a->instrument,.count=1,.voices=1,.seconds=seconds}; command.notes[0]=midi;
    if(!kv_audio_is_playing(a)) { atomic_store(&a->start,atomic_load(&a->clock)); atomic_store(&a->stop_requested,false); }
    atomic_fetch_add(&a->pending_plays,1);
    if(!send(a,command)) { atomic_fetch_sub(&a->pending_plays,1); return false; }
    return true;
}
/* Beats may be slowed to a quarter of the tempo for practice: 50 BPM × ¼ is 4.8 s per beat. */
bool kv_audio_performance(KvAudio *a,const KvPerformance *p,double seconds) {
    if(!a || !kv_performance_playable(p) || !isfinite(seconds) || seconds<.25 || seconds>5 || !start(a)) return false;
    struct Command command={.type=7,.instrument=a->instrument,.seconds=seconds,.performance=*p};
    atomic_store(&a->start,atomic_load(&a->clock)); atomic_store(&a->stop_requested,false); atomic_fetch_add(&a->pending_plays,1);
    if(!send(a,command)) { atomic_fetch_sub(&a->pending_plays,1); return false; } return true;
}
bool kv_audio_queue(KvAudio *a,const KvPerformance *p,int rhythm,const KvHit *hits,size_t count,double phase) {
    if(!a || !kv_performance_playable(p) || rhythm<-1 || rhythm>1 || count>KV_BEAT_HITS || (count && !hits) || !isfinite(phase) || phase<0 || phase>16) return false;
    struct Command command={.type=17,.rhythm=rhythm,.count=count,.seconds=phase,.performance=*p}; if(count) memcpy(command.hits,hits,count*sizeof *hits);
    return send(a,command);
}
unsigned kv_audio_part(KvAudio *a,double *seconds) {
    if(!a) return 0;
    unsigned part=atomic_load(&a->part); uint64_t now=atomic_load(&a->clock),from=atomic_load(&a->part_start);
    // Until a new performance is under way the atomics still describe the last one: report its start, not a stale part.
    if(atomic_load(&a->pending_plays) || from<atomic_load(&a->start)) { if(seconds) *seconds=0; return 0; }
    if(seconds) *seconds=now>=from?(double)(now-from)/44100:0;
    return part;
}
bool kv_audio_set_articulation(KvAudio *a,KvArticulation articulation) { return a && articulation>=0 && articulation<KV_ARTICULATION_COUNT && send(a,(struct Command){.type=11,.count=(size_t)articulation}); }
bool kv_audio_set_rhythm(KvAudio *a,bool on,KvGrid grid,KvMeter meter,double seconds_per_beat,double volume) {
    if(!a || grid<0 || grid>=KV_GRID_COUNT || meter<0 || meter>=KV_METER_COUNT || !isfinite(seconds_per_beat) || seconds_per_beat<.08 || seconds_per_beat>5 || !isfinite(volume)) return false;
    if(on && !start(a)) return false;
    return send(a,(struct Command){.type=14,.count=on,.voices=(size_t)grid,.instrument=(int)meter,.seconds=seconds_per_beat,.values={(float)volume,0}});
}
bool kv_audio_set_beat(KvAudio *a,const KvHit *hits,size_t count,bool electronic) {
    if(!a || count>KV_BEAT_HITS || (count && !hits)) return false;
    struct Command command={.type=16,.count=count,.voices=electronic}; if(count) memcpy(command.hits,hits,count*sizeof *hits);
    return send(a,command);
}
bool kv_audio_phase(KvAudio *a,double beats) { return a && isfinite(beats) && beats>=0 && beats<=16 && send(a,(struct Command){.type=18,.seconds=beats}); }
bool kv_audio_count_in(KvAudio *a,double beats) { return a && isfinite(beats) && beats>=0 && beats<=16 && send(a,(struct Command){.type=15,.seconds=beats}); }
double kv_audio_rhythm_beat(KvAudio *a) { return a?atomic_load(&a->rhythm_beat):-1; }
bool kv_audio_set_pedal(KvAudio *a,bool down) { return a && send(a,(struct Command){.type=13,.count=down}); }
bool kv_audio_set_dynamics(KvAudio *a,double dynamics,double expression) {
    return a && isfinite(dynamics) && isfinite(expression) && send(a,(struct Command){.type=12,.values={(float)fmax(0,fmin(1,dynamics)),(float)fmax(0,fmin(1,expression))}});
}
bool kv_audio_set_loop(KvAudio *a,bool enabled) { return a && send(a,(struct Command){.type=6,.count=enabled?1:0}); }
bool kv_audio_set_interval(KvAudio *a,double seconds) { return a && isfinite(seconds) && seconds>=.08 && seconds<=5 && send(a,(struct Command){.type=5,.seconds=seconds}); }
int kv_audio_event(const KvAudio *a) { return a?atomic_load(&a->event):-1; }
bool kv_audio_set_humanize(KvAudio *a,bool enabled) { return a && send(a,(struct Command){.type=4,.count=enabled?1:0}); }
bool kv_audio_is_playing(const KvAudio *a) { return a && !atomic_load(&a->stop_requested) && (atomic_load(&a->pending_plays)>0 || atomic_load(&a->playing)); }
bool kv_audio_playhead(KvAudio *a,double *seconds) {
    if(!a || !seconds || !kv_audio_is_playing(a)) return false;
    uint64_t now=atomic_load(&a->clock),start_frame=atomic_load(&a->start);
    *seconds=now>=start_frame?(double)(now-start_frame)/44100:0; return true;
}
unsigned kv_audio_active_notes(KvAudio *a,int notes[KV_ACTIVE_NOTES]) {
    if(!a || !notes || !kv_audio_is_playing(a)) return 0;
    uint64_t low=atomic_load(&a->active_low),high=atomic_load(&a->active_high); unsigned count=0;
    for(int i=21;i<=108 && count<KV_ACTIVE_NOTES;i++) if(i<64?(low&(UINT64_C(1)<<i)):(high&(UINT64_C(1)<<(i-64)))) notes[count++]=i;
    return count;
}
int kv_audio_error(const KvAudio *a) { return a?atomic_load(&a->error):1; }
void kv_audio_destroy(KvAudio *a) {
    if(!a) return; atomic_store(&a->closing,true);
    if(a->queue) {
        OSStatus result=AudioQueueDispose(a->queue,true);
        if(result!=noErr) fprintf(stderr,"AudioQueueDispose: %d\n",(int)result);
    }
    kv_live_effects_free(a->fx); kv_mixer_free(a->mixer);
    for(int i=0;i<KV_INSTRUMENTS;i++) kv_piano_free(a->banks[i]); kv_piano_free(a->drums); free(a);
}
