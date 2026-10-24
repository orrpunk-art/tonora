#ifndef TONORA_MIXER_H
#define TONORA_MIXER_H
#include "piano.h"
#include "performance.h"
#include <stdint.h>
typedef struct KvMixer KvMixer;
/* Instruments: 0 grand piano, 1 CP80, 2 Pianet, 3 bowed strings (slow attack, long release, sustain loop). */
#define KV_INSTRUMENTS 4
#define KV_INSTRUMENT_STRINGS 3
KvMixer *kv_mixer_create(void);
void kv_mixer_free(KvMixer *mixer);
void kv_mixer_bank(KvMixer *mixer,int instrument,const KvPianoBank *bank);
bool kv_mixer_performance(KvMixer *mixer,const KvPerformance *performance,double seconds_per_beat,int instrument);
bool kv_mixer_play(KvMixer *mixer,const int *notes,size_t count,size_t voices,double duration,int instrument,bool overlay);
/* Editor preview: like an overlaid note, but a new preview quickly releases the previous one (Ableton-style audition). */
bool kv_mixer_preview(KvMixer *mixer,int midi,double duration,int instrument);
/* Keyboard keys: a held note sounds until released (velocity 0…1); release(-1) lets go of every held key. */
bool kv_mixer_hold(KvMixer *mixer,int midi,float velocity,int instrument);
void kv_mixer_release(KvMixer *mixer,int midi);
void kv_mixer_stop(KvMixer *mixer);
/* Bowed strings: the articulation choice (re-decides the strokes of a playing sequence), the dynamics 0…1 (mod wheel:
   soft↔loud recordings and level) and the expression 0…1 (CC11: level only). */
void kv_mixer_articulation(KvMixer *mixer,KvArticulation articulation);
void kv_mixer_dynamics(KvMixer *mixer,float dynamics,float expression);
void kv_mixer_humanize(KvMixer *mixer,bool enabled);
void kv_mixer_loop(KvMixer *mixer,bool enabled);
void kv_mixer_interval(KvMixer *mixer,double seconds);
int kv_mixer_event(const KvMixer *mixer);
void kv_mixer_render(KvMixer *mixer,float *stereo,size_t frames);
bool kv_mixer_running(const KvMixer *mixer);
bool kv_mixer_busy(const KvMixer *mixer);
uint64_t kv_mixer_clock(const KvMixer *mixer);
uint64_t kv_mixer_start(const KvMixer *mixer);
unsigned kv_mixer_active(const KvMixer *mixer,int notes[64]);
#endif
