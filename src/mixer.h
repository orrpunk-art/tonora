#ifndef TONORA_MIXER_H
#define TONORA_MIXER_H
#include "piano.h"
#include "performance.h"
#include <stdint.h>
typedef struct KvMixer KvMixer;
/* Instruments: 0 grand piano, 1 CP80, 2 Pianet, 3 bowed strings (slow attack, long release, sustain loop). */
#define KV_INSTRUMENTS 4
#define KV_INSTRUMENT_STRINGS 3
/* Polyphony as on a digital piano: 256 voices; when they run short the quietest one makes room (see steal in mixer.c). */
#define KV_VOICES 256
/* Distinct notes sounding at once (every key of the piano fits). */
#define KV_ACTIVE_NOTES 128
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
/* Sustain pedal (CC64): a key struck again while it is down lets the previous strike ring out under it (0.4 s) instead of 12 ms. */
void kv_mixer_pedal(KvMixer *mixer,bool down);
/* Voices in use, fading ones included (tests and diagnostics). */
unsigned kv_mixer_voices(const KvMixer *mixer);
/* The rhythm layer: a metronome click on a grid of the beat. While on it runs by itself — from the moment it is switched on,
   or from the first beat of a sequence that starts (again at each loop) — at seconds_per_beat; bar and pulse come from the
   meter (kv_meter_bar, kv_meter_pulse: 6/8 clicks on its two dotted quarters). A new tempo keeps the beat. The click is dry:
   it is left out of the stereo render and read with kv_mixer_dry, to be mixed after the effects. volume 0…1. */
typedef enum { KV_GRID_BEATS, KV_GRID_EIGHTHS, KV_GRID_TRIPLETS, KV_GRID_SIXTEENTHS, KV_GRID_COUNT } KvGrid;
void kv_mixer_rhythm(KvMixer *mixer,bool on,KvGrid grid,KvMeter meter,double seconds_per_beat,float volume);
/* The next sequence starts after this many beats; the metronome counts them in (one bar of the meter, as a rule). */
void kv_mixer_count_in(KvMixer *mixer,double beats);
/* Beats since the rhythm's origin (bar position: fmod(beat, kv_meter_bar)), −1 while it is off. */
double kv_mixer_rhythm_beat(const KvMixer *mixer);
/* Instead of the click: one bar of drum hits (kv_beat_bar) repeated on the rhythm's grid, on the recorded kit (kv_mixer_drums)
   or the built-in electronic one; count 0 returns to the click. A count-in is always clicked; the beat starts with the sequence. */
void kv_mixer_beat(KvMixer *mixer,const KvHit *hits,size_t count,bool electronic);
/* The recorded kit: a bank on General MIDI drum notes, layers 0-1 soft and 2-3 loud takes. Without it every beat is electronic. */
void kv_mixer_drums(KvMixer *mixer,const KvPianoBank *bank);
/* Drum voices sounding now (tests and diagnostics). */
unsigned kv_mixer_drum_voices(const KvMixer *mixer);
#define KV_DRY_FRAMES 4096
/* The dry part (the click) of the last render, stereo interleaved; frames beyond KV_DRY_FRAMES carry no click. */
const float *kv_mixer_dry(const KvMixer *mixer);
void kv_mixer_humanize(KvMixer *mixer,bool enabled);
void kv_mixer_loop(KvMixer *mixer,bool enabled);
void kv_mixer_interval(KvMixer *mixer,double seconds);
int kv_mixer_event(const KvMixer *mixer);
void kv_mixer_render(KvMixer *mixer,float *stereo,size_t frames);
bool kv_mixer_running(const KvMixer *mixer);
bool kv_mixer_busy(const KvMixer *mixer);
uint64_t kv_mixer_clock(const KvMixer *mixer);
uint64_t kv_mixer_start(const KvMixer *mixer);
unsigned kv_mixer_active(const KvMixer *mixer,int notes[KV_ACTIVE_NOTES]);
#endif
