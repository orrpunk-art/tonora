#ifndef KVARTA_AUDIO_H
#define KVARTA_AUDIO_H
#include <stdbool.h>
#include <stddef.h>
#include "piano.h"
#include "performance.h"
#include "mixer.h"
typedef struct KvAudio KvAudio;
KvAudio *kv_audio_create(void);
bool kv_audio_load_instrument(KvAudio *audio,int instrument,const char *directory);
bool kv_audio_set_instrument(KvAudio *audio,int instrument);
unsigned kv_audio_active_notes(KvAudio *audio,int notes[KV_ACTIVE_NOTES]);
int kv_audio_error(const KvAudio *audio);
bool kv_audio_set_humanize(KvAudio *audio,bool enabled);
bool kv_audio_set_loop(KvAudio *audio,bool enabled);
bool kv_audio_set_interval(KvAudio *audio,double seconds);
int kv_audio_event(const KvAudio *audio);
bool kv_audio_load_piano(KvAudio *audio, const char *directory);
bool kv_audio_set_effects(KvAudio *audio, KvEffects effects);
/* Main-thread calls only. Single notes overlap; sequences replace future scheduled events with release tails. */
bool kv_audio_performance(KvAudio *audio,const KvPerformance *performance,double seconds_per_beat);
/* The part to play after the current performance ends (a song's next section), gapless; see kv_mixer_queue. Send it while the
   current part plays, after its kv_audio_performance. kv_audio_part: parts started since that call, and seconds into the
   current one (0 during a count-in). */
bool kv_audio_queue(KvAudio *audio,const KvPerformance *performance,int rhythm,const KvHit *hits,size_t count);
unsigned kv_audio_part(KvAudio *audio,double *seconds);
bool kv_audio_play(KvAudio *audio, const int *notes, size_t note_count, size_t voices, double seconds_per_event);
/* One note on top of whatever is playing: never cancels a scheduled performance or moves the playhead. */
bool kv_audio_audition(KvAudio *audio,int midi,double seconds);
/* A key held on a keyboard (MIDI or the computer's): sounds until kv_audio_release; velocity 0…1. midi −1 releases all. */
bool kv_audio_hold(KvAudio *audio,int midi,double velocity);
bool kv_audio_release(KvAudio *audio,int midi);
/* Editor preview: monophonic among previews — each new one releases the previous within ~12 ms. */
bool kv_audio_preview(KvAudio *audio,int midi,double seconds);
/* Bowed strings: articulation (Auto, Legato, Staccato, Pizzicato) and dynamics 0…1 (mod wheel) with expression 0…1 (CC11). */
bool kv_audio_set_articulation(KvAudio *audio,KvArticulation articulation);
bool kv_audio_set_dynamics(KvAudio *audio,double dynamics,double expression);
/* Sustain pedal down or up (CC64): a key struck again under it rings on its previous strike. */
bool kv_audio_set_pedal(KvAudio *audio,bool down);
/* The metronome (see kv_mixer_rhythm): on/off, grid, meter, tempo and volume 0…1; idempotent, a new tempo keeps the beat. */
bool kv_audio_set_rhythm(KvAudio *audio,bool on,KvGrid grid,KvMeter meter,double seconds_per_beat,double volume);
/* The next kv_audio_performance starts after `beats` beats, counted in by the metronome. */
bool kv_audio_count_in(KvAudio *audio,double beats);
/* The recorded kit (before the first sound, like an instrument) and the beat played instead of the click (count 0: the click). */
bool kv_audio_load_drums(KvAudio *audio,const char *directory);
bool kv_audio_set_beat(KvAudio *audio,const KvHit *hits,size_t count,bool electronic);
/* Beats since the rhythm's origin (for the beat dots), −1 while it is off. */
double kv_audio_rhythm_beat(KvAudio *audio);
void kv_audio_stop(KvAudio *audio);
void kv_audio_destroy(KvAudio *audio);
bool kv_audio_is_playing(const KvAudio *audio);
bool kv_audio_playhead(KvAudio *audio, double *seconds);
#endif
