#ifndef KVARTA_MUSIC_H
#define KVARTA_MUSIC_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int circle_index;
    bool minor;
    /* 0 retains major/natural minor; 1..7 select parallel modal scales. */
    int mode;
    /* 0: the circle's default spelling of the tonic; 1..7: tonic letter C..B (e.g. A-flat instead of G-sharp). */
    int spelling;
    /* Pentatonic: the mode's five notes without its two leading tones (major kind: no 4th and 7th; minor kind: no 2nd and 6th).
       Chords, degrees and names stay those of the seven-note mode; scale notes, highlights and melodies use the five. */
    bool pentatonic;
} KvKey;
typedef struct {
    char name[64];
    char degree[24];   /* Roman numeral: "vi", "V7/ii", "♭VI", "subV7/V", "♭II" */
    int midi[7];       /* root position, ascending */
    size_t count;
    int bass;          /* index in midi of the bass tone: 0 root position, 1 third, 2 fifth, 3 seventh */
    int lean;          /* chords outside the key: +1 raised notes (dominants), −1 lowered (borrowed from minor, ♭II, subV); 0 diatonic */
} KvChord;
const char *kv_mode_name(KvKey key);
int kv_mod(int n, int divisor);
int kv_tonic(KvKey key);
bool kv_chord_contains(KvKey key, int degree, int pitch_class);
const char *kv_key_label(KvKey key);
/* Tonic name only (no "m"), honouring the key's spelling. */
const char *kv_key_root(KvKey key);
/* Written keys have at most seven sharps or flats. Keeps the given spelling when it fits,
   otherwise picks the enharmonic tonic letter with the fewest accidentals (D♯ melodic minor → E♭). */
KvKey kv_key_normalize(KvKey key);
/* Accidentals written at the clef: harmonic and melodic minor use the natural minor's signature. */
int kv_written_signature(KvKey key);
const char *kv_key_russian(KvKey key);
/* The interface language of names and explanations: false Russian (the default), true English. */
extern bool kv_english;
const char *kv_key_title(KvKey key);   /* «До мажор» or «C major», «Ре · Дорийский» or «D Dorian» */
int kv_signature(KvKey key);
void kv_scale(KvKey key, int midi[8]);
void kv_scale_names(KvKey key, char names[7][8]);
bool kv_contains(KvKey key, int pitch_class);              /* the seven-note mode, pentatonic or not */
bool kv_in_scale(KvKey key, int pitch_class);              /* the scale in use: five notes when pentatonic */
int kv_scale_used(KvKey key, int midi[8]);                 /* its notes from the tonic, octave appended; returns 5 or 7 */
bool kv_chord_extended(KvKey key,int degree,int extension,KvChord *out);
bool kv_chord(KvKey key, int degree, KvChord *out);
/* Chord codes: what a progression stores. Independent of the key (V7/ii is the dominant of degree ii in every key).
   0–6 scale degree · 16+t secondary dominant V7/t · 24+t tritone substitute subV7/t · 32+d degree d of the parallel
   major/natural minor · 40 Neapolitan ♭II · bits 8–9 the inversion (0 root position … 3 seventh in the bass). */
enum { KV_CODE_SECONDARY=16, KV_CODE_TRITONE=24, KV_CODE_BORROWED=32, KV_CODE_NEAPOLITAN=40 };
static inline int kv_code_base(int code) { return code&255; }
static inline int kv_code_inversion(int code) { return (code>>8)&3; }
static inline int kv_code_with_inversion(int code,int inversion) { return (code&255)|((inversion&3)<<8); }
bool kv_code_valid(int code);
/* The chord of a code in this key; `extension` (0 triads … 4 thirteenths) applies to diatonic and borrowed chords,
   dominants are always seventh chords, ♭II a triad. Inversions add "/bass" to the name. */
bool kv_code_chord(KvKey key,int code,int extension,KvChord *out);
/* Chords outside the key worth offering here, in display order, without duplicates of each other or of the key's own
   chords. group: 0 secondary dominants, 1 borrowed (and ♭II), 2 tritone substitutes. Returns the count. */
size_t kv_chromatic_codes(KvKey key,int extension,int *codes,int *groups,size_t capacity);
/* A short Russian explanation: what the chord is, where it goes, which notes are foreign to the key. */
void kv_code_story(KvKey key,int code,int extension,char *out,size_t capacity);
/* Notes to sound the chord in its inversion: the bass tone lowest, the others above it. Returns the count. */
size_t kv_chord_voiced(const KvChord *chord,int *midi);
/* Triads two keys share (same notes): how many, with each one's degree in `from` and in `to`. */
size_t kv_common_chords(KvKey from,KvKey to,int *from_degrees,int *to_degrees,size_t capacity);
/* Key finding (Krumhansl–Kessler profiles) from the time each pitch class sounds. With a key signature (sharps > 0,
   flats < 0) its major and relative minor win when they fit within 0.05 of the best. Natural major/minor only. */
KvKey kv_detect_key(const double weights[12],bool has_signature,int sharps,double *fit);
/* The chord code that best explains pitch-class weights in this key: the key's own triads first, then the chords
   outside it; a bass that is the chord's third or fifth gives the inversion. −1 when nothing sounds. */
int kv_detect_chord(KvKey key,const double weights[12],int bass_pitch_class);
/* Styles: 0 pop, 1 classical cadence, 2 calm. Output is scale degrees 0..6. */
/* Continues a progression: after `existing` (n chords; their scale degrees, −1 for chords outside the key) come `add`
   new degrees, up to eight in all. Whole blocks of four are the style's patterns; a remainder takes a pattern's ending,
   its cadence. No block starts on the chord just before it. n = 0 makes a fresh progression of any length 1–8. */
bool kv_generate_more(KvKey key,int style,const int *existing,size_t n,size_t add,uint32_t seed,int *out);
bool kv_generate(KvKey key, int style, size_t count, uint32_t seed, int *degrees);
#endif
