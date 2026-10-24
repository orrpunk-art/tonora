#ifndef KV_FINGERING_H
#define KV_FINGERING_H
#include <stdbool.h>
#include <stddef.h>
#include "performance.h"
/* Piano fingering: 1 = thumb … 5 = little finger, 0 = not fingered (more than five notes in one hand at once).

   Offline (a whole performance or a scale): notes of one hand are grouped by onset and fingered with dynamic
   programming over the groups. The cost model prefers a still hand, thumb-under after 3 or 4 when going up
   (cross-over onto 3 or 4 when going down), no thumb on black keys, comfortable spans in chords and no reuse of a
   finger that still holds a key. A C major scale comes out 1-2-3-1-2-3-4-5 in the right hand, 5-4-3-2-1-3-2-1 in the left.
   Only music the app plays is fingered; keys pressed by hand move no fingers. */

/* Fingers every event of `events` that belongs to `hand` (0 left, 1 right); other entries of `fingers` are untouched. */
void kv_finger_events(const KvPianoEvent *events, size_t count, unsigned hand, unsigned char *fingers);
/* Both hands of a performance; `fingers` has p->count entries. */
void kv_finger_performance(const KvPerformance *p, unsigned char *fingers);

#endif
