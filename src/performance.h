#ifndef TONORA_PERFORMANCE_H
#define TONORA_PERFORMANCE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "music.h"
#define KV_PERFORMANCE_CAPACITY 512
typedef enum { KV_BALLAD, KV_FLOWING, KV_ALBERTI, KV_POP, KV_WALTZ, KV_DARK_JAZZ, KV_TRIP_HOP, KV_AMBIENT, KV_INTERLUDE, KV_PATTERN_COUNT } KvPianoPattern;
/* Time signature. Beats are always quarter notes; 6/8 is a three-quarter bar with a 3+3 eighth grouping. */
typedef enum { KV_METER_4_4, KV_METER_3_4, KV_METER_6_8, KV_METER_COUNT } KvMeter;
/* How long one chord of the progression lasts. A "beat" in 6/8 is a dotted quarter. */
typedef enum { KV_LENGTH_BEAT, KV_LENGTH_TWO_BEATS, KV_LENGTH_BAR, KV_LENGTH_TWO_BARS, KV_LENGTH_COUNT } KvChordLength;
/* KV_FILL_STYLE uses the style's own default (none for ambient, every bar for interlude, otherwise every 4 bars). */
typedef enum { KV_FILL_STYLE, KV_FILL_NONE, KV_FILL_EVERY_4, KV_FILL_EVERY_2, KV_FILL_EVERY_BAR, KV_FILL_COUNT } KvFillRate;
/* Arpeggio texture: the order in which chord tones are played, and the note value of each step. */
typedef enum { KV_ARP_UP, KV_ARP_DOWN, KV_ARP_UP_DOWN, KV_ARP_BROKEN, KV_ARP_WAVE, KV_ARP_COUNT } KvArpeggioPattern;
typedef enum { KV_DIV_EIGHTH, KV_DIV_SIXTEENTH, KV_DIV_TRIPLET, KV_DIV_COUNT } KvDivision;
/* Textures written for bowed strings (cellos below, violins above). NONE: the piano textures. */
typedef enum { KV_STRINGS_NONE, KV_STRINGS_CHORALE, KV_STRINGS_CANTILENA, KV_STRINGS_OSTINATO, KV_STRINGS_PIZZICATO, KV_STRINGS_COUNT } KvStringTexture;
/* MIDI pitch and normalized velocity; times are quarter-note beats, independent of BPM. */
/* stroke: bowed strings only — 0 follows the chosen articulation, otherwise KvStroke + 1 (strings textures write it).
   It sits in what was padding, so the struct (and saved tracks) keep their size. */
typedef struct { int midi; double beat,duration; float velocity; unsigned chord,hand; unsigned char fill,stroke; } KvPianoEvent;
typedef struct {
    KvPianoEvent events[KV_PERFORMANCE_CAPACITY]; size_t count,chord_count;
    double beats_per_chord,beats_per_bar,total_beats;
    bool controlled;
} KvPerformance;
typedef struct {
    KvPianoPattern style; KvMeter meter; KvChordLength length; KvFillRate fills;
    uint32_t seed;           /* Variation seed; used only when generated is true. */
    bool generated;          /* false: the style's written template; true: a seeded variation. */
    bool blocks;             /* Block chords instead of a two-hand texture. */
    bool arpeggio;           /* Arpeggiated chords: pattern and division below; style/fills are ignored. */
    KvArpeggioPattern arpeggio_pattern; KvDivision division;
    bool preview;            /* A single auditioned chord: one bar, no fills. */
    double seconds_per_beat; /* Current tempo; bounds the speed of fill notes. */
    KvStringTexture strings;  /* A strings texture replaces blocks, two hands and arpeggio (division: the ostinato's note value). */
} KvArrangement;
const char *kv_string_texture_name(KvStringTexture texture);
const char *kv_pattern_name(KvPianoPattern pattern);
const char *kv_pattern_russian(KvPianoPattern pattern);
const char *kv_meter_name(KvMeter meter);
const char *kv_arpeggio_name(KvArpeggioPattern pattern);
const char *kv_division_name(KvDivision division);
double kv_division_beats(KvDivision division);
double kv_meter_bar(KvMeter meter);
double kv_meter_pulse(KvMeter meter);
double kv_chord_beats(KvMeter meter,KvChordLength length);
KvFillRate kv_fill_rate(KvPianoPattern style,KvFillRate requested);
/* Recommended tempo range of a style, BPM. */
void kv_pattern_tempo(KvPianoPattern style,int *low,int *high);
/* Arrangement with independent meter, chord length and fill rate. Chords are already in the playing register. */
bool kv_arrange_with(const KvChord *chords,size_t count,int keyboard_base,KvKey key,KvArrangement arrangement,KvPerformance *out);
/* Legacy 0.14 entry points: one chord per 4/4 bar (Waltz 3/4), fixed fills. */
bool kv_arrange(const KvChord *chords,size_t count,int keyboard_base,KvPianoPattern pattern,KvKey key,uint32_t seed,bool generate_rhythm,KvPerformance *out);
bool kv_two_hand_key(const int chords[][3],size_t count,int keyboard_base,KvPianoPattern pattern,KvKey key,uint32_t seed,KvPerformance *out);
bool kv_two_hand(const int chords[][3],size_t count,int keyboard_base,KvPianoPattern pattern,KvPerformance *out);
/* Mechanical musical guards: monophonic lead, bounded leaps/density, no close simultaneous upper voices. */
bool kv_arrangement_controlled(const KvPerformance *performance);
bool kv_performance_valid(const KvPerformance *performance);
/* A piano key cannot sound twice at once: a note that is still held when the same pitch starts again ends there.
   Notes starting together merge into the longer one. Expects events sorted by beat. */
void kv_performance_resolve_overlaps(KvPerformance *performance);
/* What a note is to the harmony under it. A chord tone belongs to the chord sounding at its start; a non-chord tone
   that belongs to the next chord and starts in the last beat before the change (the last half of a short chord) is an
   anticipation; any other non-chord tone (passing and neighbour notes, fill runs) is passing.
   chord_masks[i] is the pitch-class set of chord i (bit 0 = C); the chord after the last is the first (the loop). */
typedef enum { KV_ROLE_CHORD, KV_ROLE_PASSING, KV_ROLE_ANTICIPATION } KvNoteRole;
void kv_note_roles(const KvPerformance *performance,const unsigned *chord_masks,size_t chord_count,unsigned char *roles);
/* Bowed strings. The articulation is what the player chose (the «Штрих» list; keyswitches MIDI 24–27 in this order),
   the stroke is what one note gets. */
typedef enum { KV_ARTICULATION_AUTO, KV_ARTICULATION_LEGATO, KV_ARTICULATION_STACCATO, KV_ARTICULATION_PIZZICATO, KV_ARTICULATION_COUNT } KvArticulation;
typedef enum { KV_STROKE_SUSTAIN, KV_STROKE_LEGATO, KV_STROKE_SPICCATO, KV_STROKE_PIZZICATO, KV_STROKE_COUNT } KvStroke;
#define KV_KEYSWITCH_LOW 24   /* C1: Авто, C♯1 Легато, D1 Стаккато, D♯1 Пиццикато */
const char *kv_articulation_name(KvArticulation articulation);
/* One stroke per event. A note's own stroke wins; Staccato and Pizzicato make every other note short; Auto makes a note
   shorter than an eighth spiccato; in Auto and Legato a note that starts while an earlier note of the same hand still
   sounds (or ends within 0.05 beat before it) is legato, any other note a sustained new bow. Expects events sorted by beat. */
void kv_string_strokes(const KvPerformance *performance,KvArticulation articulation,unsigned char *strokes);
/* Beats for the metronome's rhythm layer, played on a live kit. Drums are numbered as General MIDI drums: the recordings sit
   on these notes; without them the mixer synthesizes the same numbers. */
typedef enum { KV_DRUM_KICK=36, KV_DRUM_STICK=37, KV_DRUM_SNARE=38, KV_DRUM_CLAP=39, KV_DRUM_HAT=42, KV_DRUM_HAT_OPEN=46,
               KV_DRUM_TAMBOURINE=54, KV_DRUM_CONGA_HIGH=63, KV_DRUM_CONGA_LOW=64, KV_DRUM_SHAKER=70 } KvDrum;
typedef struct { double beat; int drum; float velocity; } KvHit;   /* beat from the bar's start; velocity 0…1 */
typedef enum { KV_BEAT_POP, KV_BEAT_BALLAD, KV_BEAT_BOSSA, KV_BEAT_SHUFFLE, KV_BEAT_HIPHOP, KV_BEAT_TRIPHOP, KV_BEAT_HOUSE, KV_BEAT_COUNT } KvBeat;
#define KV_BEAT_HITS 64
/* One bar of `beat` in `meter`, sorted by beat, every hit inside the bar; the first is the kick on the downbeat.
   4/4 has a pattern per beat; 3/4 is a waltz and 6/8 two groups of three for every beat. */
size_t kv_beat_bar(KvBeat beat,KvMeter meter,KvHit hits[KV_BEAT_HITS]);
KvBeat kv_beat_for_style(KvPianoPattern style);       /* «По стилю рисунка» */
const char *kv_beat_name(KvBeat beat);                /* Russian; the app translates */
void kv_beat_tempo(KvBeat beat,int *low,int *high);  /* the tempo the beat is usually played at */
#endif
