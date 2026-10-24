#ifndef TONORA_SONG_H
#define TONORA_SONG_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "music.h"
#include "performance.h"
/* A song: sections in a row sharing key, meter, tempo, instrument and register. A section is one pass of its progression
   (up to eight chord codes, one KvPerformance) played `repeats` times; its notes are generated from its fields, or —
   when `edited` — they are the user's track for one pass, which the app keeps beside the song (by section id). */
#define KV_SONG_SECTIONS 32
#define KV_SECTION_REPEATS 8
typedef enum { KV_SECTION_INTRO, KV_SECTION_VERSE, KV_SECTION_CHORUS, KV_SECTION_PIT, KV_SECTION_TRANSITION, KV_SECTION_OUTRO, KV_SECTION_KINDS } KvSectionKind;
/* How a transition leads from its left neighbour into its right one (spec 1.4 §4.3). */
typedef enum { KV_TRANSITION_RISE, KV_TRANSITION_DOMINANT, KV_TRANSITION_FILL, KV_TRANSITION_BREAK, KV_TRANSITION_KINDS } KvTransitionKind;
/* The rhythm layer under a section: the song's choice, none, a quiet hi-hat and shaker, the beat that suits the texture, or `beat_fixed`. */
typedef enum { KV_SECTION_BEAT_SONG, KV_SECTION_BEAT_OFF, KV_SECTION_BEAT_QUIET, KV_SECTION_BEAT_STYLE, KV_SECTION_BEAT_FIXED, KV_SECTION_BEAT_KINDS } KvSectionBeat;
typedef struct {
    uint32_t id;               /* unique in the song, never 0 */
    KvSectionKind kind;
    char name[32];             /* UTF-8; empty: the kind's name and number (the app builds it, translated) */
    int codes[8]; size_t count;/* one pass: chord codes (kv_code_chord) */
    int repeats;               /* 1…KV_SECTION_REPEATS */
    KvArrangement arrangement; /* texture, style, chord length, fills, seed; meter, tempo and preview come from the song */
    float level;               /* velocity factor 0.5…1.2 */
    KvSectionBeat beat; KvBeat beat_fixed;
    int lift;                  /* +12 right hand an octave up, −12 both hands down, 0 as the circle */
    KvTransitionKind transition;
    bool edited;
} KvSection;
typedef struct {
    KvKey key; KvMeter meter; double bpm;
    int keyboard_base, extension;   /* register (36…84, a C) and chord complexity 0…4, as on the circle */
    uint32_t next_id;
    KvSection sections[KV_SONG_SECTIONS]; size_t count;
} KvSong;

const char *kv_section_kind_name(KvSectionKind kind);       /* Russian; the app translates */
const char *kv_transition_name(KvTransitionKind kind);      /* Russian */
bool kv_section_valid(const KvSection *section);
bool kv_song_valid(const KvSong *song);
/* Time, in quarter-note beats from the song's start. */
double kv_section_chord_beats(const KvSong *song,const KvSection *section);
double kv_section_pass_beats(const KvSong *song,const KvSection *section);
double kv_section_beats(const KvSong *song,size_t index);
double kv_section_start(const KvSong *song,size_t index);
double kv_song_beats(const KvSong *song);
/* The section sounding at `beat` and the beat inside it; count when past the end. */
size_t kv_song_section_at(const KvSong *song,double beat,double *offset);

/* One pass as the piano roll shows it: the generated notes with the lift (an edited section's notes are the app's track). */
bool kv_section_notes(const KvSong *song,size_t index,KvPerformance *out);
/* One pass as it plays: `edited` (the app's track; NULL unless section.edited) or the generated notes, at the section's level. */
bool kv_section_plan(const KvSong *song,size_t index,const KvPerformance *edited,KvPerformance *out);

/* Editing the row. Insert assigns the section a fresh id (returned, 0 on failure). */
uint32_t kv_song_insert(KvSong *song,size_t index,const KvSection *section);
bool kv_song_remove(KvSong *song,size_t index);
bool kv_song_move(KvSong *song,size_t from,size_t to);
/* A copy right after the original with a fresh id (the app copies the edited track). */
uint32_t kv_song_duplicate(KvSong *song,size_t index);
bool kv_song_set_repeats(KvSong *song,size_t index,int repeats);
/* Cuts land on whole bars that are also chord boundaries; between passes when the section repeats and cannot be unrolled
   into one pass of at most eight chords. kv_song_snap_cut: the allowed cut nearest to `beat` (inside the section), or −1. */
double kv_song_snap_cut(const KvSong *song,size_t index,double beat);
/* Cuts section `index` at `beat` (an allowed cut) into two; `edited` is its track (NULL when not edited), the parts' tracks
   go to left/right (either may be NULL when not edited). The right part gets a fresh id. */
bool kv_song_cut(KvSong *song,size_t index,double beat,const KvPerformance *edited,KvPerformance *left,KvPerformance *right);

/* Tracks (one pass of an edited section). Split at a chord boundary; repeat a pass `times` (≤ 8 chords in all);
   transpose by semitones, moving a note that would leave the keyboard an octave back. */
bool kv_track_split(const KvPerformance *track,size_t chord,KvPerformance *left,KvPerformance *right);
bool kv_track_repeat(const KvPerformance *track,int times,KvPerformance *out);
void kv_track_transpose(KvPerformance *track,int semitones);
/* A section made from what the circle holds: its progression and texture. */
KvSection kv_section_from_draft(KvSectionKind kind,const int *codes,size_t count,KvArrangement arrangement);
#endif
