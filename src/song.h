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
typedef enum { KV_SECTION_INTRO, KV_SECTION_VERSE, KV_SECTION_CHORUS, KV_SECTION_PIT, KV_SECTION_TRANSITION, KV_SECTION_OUTRO, KV_SECTION_BRIDGE, KV_SECTION_KINDS } KvSectionKind;
/* Three tracks run through the song (spec 1.5): the right hand, the left hand, the beat. */
enum { KV_TRACK_MELODY, KV_TRACK_BASS, KV_TRACK_DRUMS, KV_TRACKS };
/* A section on one track: muted, its level 0.5…1.2 (unused on drums, whose beat is the section's), and moved by `shift` beats
   (± 32; drums move by whole beats). */
typedef struct { bool mute; float level; double shift; } KvRegion;
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
    double length;             /* beats; 0: one pass × repeats. Set by a cut or by dragging the length */
    double start;              /* beats into the pass where the section begins (a cut or a trim), 0 … pass */
    KvRegion regions[KV_TRACKS];
} KvSection;
typedef struct {
    KvKey key; KvMeter meter; double bpm;
    int keyboard_base, extension;   /* register (36…84, a C) and chord complexity 0…4, as on the circle */
    uint32_t next_id;
    KvSection sections[KV_SONG_SECTIONS]; size_t count;
    float track_level[KV_TRACKS];             /* 0…1.2 over the regions' levels */
    bool track_mute[KV_TRACKS],track_solo[KV_TRACKS];
    double cycle_from,cycle_to;               /* beats; the cycle the loop plays, none when to ≤ from */
} KvSong;
/* An empty song: no sections, every track at full level, no cycle. */
void kv_song_reset(KvSong *song);

const char *kv_section_kind_name(KvSectionKind kind);       /* Russian; the app translates */
const char *kv_transition_name(KvTransitionKind kind);      /* Russian */
bool kv_section_valid(const KvSection *section);
bool kv_song_valid(const KvSong *song);
/* Time, in quarter-note beats from the song's start. A section lasts `length`, or one pass × repeats. */
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
/* Whether a track sounds in a section: its region and the track are not muted, and no other track is soloed. */
bool kv_region_audible(const KvSong *song,size_t index,int track);
/* A stretch of the section as it sounds, [from, from+length) beats into it, ready to play: the pass (`edited` or the generated
   notes) laid end to end from `start`, cut at the section's length, each hand through its region (mute, level, shift) and track.
   Notes keep their pass chord; total_beats is the stretch's length; it may hold no notes. False when it would not fit a plan
   (more than KV_PERFORMANCE_CAPACITY notes: ask for a shorter stretch). */
bool kv_section_part(const KvSong *song,size_t index,const KvPerformance *edited,double from,double length,KvPerformance *out);

/* Editing the row. Insert assigns the section a fresh id (returned, 0 on failure). */
uint32_t kv_song_insert(KvSong *song,size_t index,const KvSection *section);
bool kv_song_remove(KvSong *song,size_t index);
bool kv_song_move(KvSong *song,size_t from,size_t to);
/* A copy right after the original with a fresh id (the app copies the edited track). */
uint32_t kv_song_duplicate(KvSong *song,size_t index);
/* Repeats (the loop corner) set the length back to whole passes; a length (the resize corner, 1/8 beat … 512 beats) is kept as it
   is; a trim moves the start by `beats` (±) and keeps the end where it was. */
bool kv_song_set_repeats(KvSong *song,size_t index,int repeats);
bool kv_song_set_length(KvSong *song,size_t index,double beats);
bool kv_song_trim_start(KvSong *song,size_t index,double beats);
/* The cut nearest to `beat` (inside section `index`) on the song's grid of `grid` beats (0: anywhere), or −1. */
double kv_song_snap_cut(const KvSong *song,size_t index,double beat,double grid);
/* Cuts section `index` at `beat` beats into it, anywhere: the left part ends there, the right one starts there in the pass and
   keeps the rest. Both keep the whole progression (and an edited pass: the app copies the track to the new id, returned). */
uint32_t kv_song_cut(KvSong *song,size_t index,double beat);
/* Transpose an edited track by semitones, moving a note that would leave the keyboard an octave back. */
void kv_track_transpose(KvPerformance *track,int semitones);
/* A section made from what the circle holds: its progression and texture. */
KvSection kv_section_from_draft(KvSectionKind kind,const int *codes,size_t count,KvArrangement arrangement);

/* Generators (spec 1.4 §4). Each returns a section (id 0: insert it) that follows `verse` — its texture, its chords. The chorus:
   a chorus turn of the key's kind other than the verse's, starting on I, IV or vi (i or VI in minor) and not on the verse's
   last chord, twice, the second time closing on the tonic; denser fills, the right hand up, louder, with a beat. `seed` picks
   among the turns that fit. The breakdown: two chords away from the tonic, two bars each, sparse and quiet. */
KvSection kv_section_chorus(const KvSong *song,const KvSection *verse,uint32_t seed);
KvSection kv_section_pit(const KvSong *song,const KvSection *verse);
KvSection kv_section_intro(const KvSong *song,const KvSection *verse);
KvSection kv_section_outro(const KvSong *song,const KvSection *before);
/* The bridge: four chords of the same energy away from the tonic (IV or vi; minor VI or iv), back to the dominant; four bars,
   the verse's texture, the right hand up as in a chorus. */
KvSection kv_section_bridge(const KvSong *song,const KvSection *verse,uint32_t seed);
/* A one-bar transition from `left` into `right` (either may be NULL): rise (the dominant of right's first chord in a rising
   arpeggio over a snare roll), dominant (that dominant in left's texture with a fill), fill (an interlude on left's last chord),
   break (left's last chord struck once, silence, a two-note pickup into right). kv_transition_for: the one that suits the seam. */
KvSection kv_section_transition(const KvSong *song,const KvSection *left,const KvSection *right,KvTransitionKind kind);
KvTransitionKind kv_transition_for(const KvSection *left,const KvSection *right);
/* Transitions take their chords and texture from their neighbours; the row edits above call this themselves. */
void kv_song_refresh_transitions(KvSong *song);
/* The drum bar under a transition: a rising snare roll over a kick (rise), one kick (break); 0 for the others (the beat goes on). */
size_t kv_transition_hits(KvTransitionKind kind,KvMeter meter,KvHit hits[KV_BEAT_HITS]);
/* What usually comes after section `after`, best first: a section to insert after it (before it when `before`), maybe led in
   by a transition; `copy_of` names the section it repeats (its edited notes go with it), 0 for a new one. */
typedef struct { KvSection section; bool lead_in,before; KvSection transition; uint32_t copy_of; } KvSuggestion;
size_t kv_song_suggest(const KvSong *song,size_t after,uint32_t seed,KvSuggestion out[4]);

/* Song forms (spec 1.5 §6): slots in order, each a KvSectionKind, KV_FORM_TRANSITION+t a transition of kind t, KV_FORM_BUILD a
   two-bar rise, KV_FORM_DROP a chorus on the house beat. */
enum { KV_FORM_TRANSITION=16, KV_FORM_BUILD=32, KV_FORM_DROP=33, KV_FORM_SLOTS=24 };
typedef struct { int slots[KV_FORM_SLOTS]; size_t count; } KvForm;
size_t kv_song_forms(const KvForm **forms);   /* the built-in forms */
const char *kv_form_name(size_t index);       /* «Поп», «С ямой»…; Russian, the app translates */
const char *kv_form_label(int slot);          /* «Билд», «Дроп»; "" for the rest */
bool kv_form_slot_valid(int slot);
/* Rebuilds the song in a form around section `verse`: verses are it, the chorus the song's first one or a new one, the rest
   generated, with a rise, break or dominant between neighbours that call for one. Sections edited by hand are kept: they fill
   their kind's first slots, and those left over go to the end. copy_of[i] (KV_SONG_SECTIONS entries): the id of the section the
   new i-th one repeats, whose edited notes go with it; 0 for a new or kept one. */
bool kv_song_apply_form(KvSong *song,const int *slots,size_t count,size_t verse,uint32_t seed,uint32_t *copy_of);
#endif
