#ifndef TONORA_PIANO_H
#define TONORA_PIANO_H
#include <stdbool.h>
#include <stddef.h>
typedef struct KvPianoBank KvPianoBank;
typedef struct { float reverb; float delay; double delay_seconds; } KvEffects;
KvPianoBank *kv_piano_load(const char *directory);
void kv_piano_free(KvPianoBank *piano);
/* One recording: interleaved stereo at 44100 Hz, its root note, and how many cents sharp it is (playback corrects it). */
typedef struct { const float *pcm; size_t frames; int midi; float cents; } KvSampleView;
#define KV_LAYERS 16
/* The recording of layer 0 (the bank's main sound) nearest to `midi`. */
bool kv_piano_sample(const KvPianoBank *piano,int midi,KvSampleView *sample);
/* The recording of `layer` nearest to `midi`; false when the bank has no such layer. */
bool kv_piano_layer(const KvPianoBank *piano,int midi,int layer,KvSampleView *sample);
/* Allocates interleaved stereo float PCM at 44100 Hz. Caller owns output. */
bool kv_piano_render(const KvPianoBank *piano, const int *notes, size_t count, size_t voices, double seconds, KvEffects effects, float **output, size_t *frames);
bool kv_effects_valid(KvEffects effects);
bool kv_effects_process(float *stereo, size_t frames, KvEffects effects);
#endif
