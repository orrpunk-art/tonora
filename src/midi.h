#ifndef TONORA_MIDI_H
#define TONORA_MIDI_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "performance.h"
/* Standard MIDI File, format 1, 480 ticks per quarter: a conductor track (name, tempo, time and key
   signature) plus one track per hand. Returns the number of bytes written, 0 if the buffer is too small
   or the performance is invalid. `denominator_power` is the SMF exponent (2 = quarter, 3 = eighth). */
#define KV_MIDI_PPQ 480
size_t kv_midi_encode(const KvPerformance *performance,double bpm,int numerator,int denominator_power,int sharps,bool minor,int program,const char *title,uint8_t *out,size_t capacity);
/* Same file from a loose list of notes (a clip): no chord bookkeeping, only pitch, timing and velocity are used.
   `length_beats` is where the tracks end (rounded up to whole bars by the caller). */
size_t kv_midi_encode_events(const KvPianoEvent *events,size_t count,double length_beats,double bpm,int numerator,int denominator_power,int sharps,bool minor,int program,const char *title,uint8_t *out,size_t capacity);
/* A whole song: any number of notes; drums (beat from the song's start, General MIDI notes) on channel 10 in a fourth track;
   markers (meta event 6, in time order) in the conductor track. */
typedef struct { double beat; const char *name; } KvMidiMarker;
/* A tempo change for the conductor track: from `beat` on, `bpm` (in order; the song starts at `bpm` of the call). */
typedef struct { double beat,bpm; } KvMidiTempo;
size_t kv_midi_encode_song(const KvPianoEvent *events,size_t count,const KvHit *drums,size_t drum_count,const KvMidiMarker *markers,size_t marker_count,double length_beats,double bpm,const KvMidiTempo *tempos,size_t tempo_count,int numerator,int denominator_power,int sharps,bool minor,int program,const char *title,uint8_t *out,size_t capacity);
bool kv_midi_write(const KvPerformance *performance,double bpm,int numerator,int denominator_power,int sharps,bool minor,int program,const char *title,const char *path);
/* A Standard MIDI File read back (format 0 or 1, ticks per quarter note). Every length is checked against the data:
   a damaged or unsupported file returns false and never reads past `size`. Notes are in time order with beat and
   duration in quarter notes and velocity 0…1; hand: channels 1 and 2 when the file uses exactly those (Tonora's own
   export), otherwise below middle C is the left hand. Channel 10 (General MIDI drums) is left out. The first tempo, time and key signature of the file count.
   Notes beyond the performance capacity are counted in `dropped`. */
typedef struct {
    KvPianoEvent notes[KV_PERFORMANCE_CAPACITY]; size_t count,dropped;
    double bpm,length;              /* length: beats to the end of the last note */
    int numerator,denominator; bool has_meter;
    int sharps; bool minor,has_key;
} KvMidiSong;
bool kv_midi_decode(const uint8_t *data,size_t size,KvMidiSong *out);
/* Name of a set of pitch classes as a chord (e.g. "Am7", "Csus4"); returns false when nothing fits. */
bool kv_midi_chord_name(const int *midi,size_t count,char name[32],int *root_pitch_class);
#endif
