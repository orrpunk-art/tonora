#import <Cocoa/Cocoa.h>
#include "performance.h"
#import "mididrag.h"
@class KvPianoRoll;
/* The owner keeps the track (a KvPerformance) and the undo history; the roll edits the track in place and reports. */
@protocol KvPianoRollOwner <NSObject>
- (void)pianoRollWillEdit:(KvPianoRoll *)roll;
- (void)pianoRollDidEdit:(KvPianoRoll *)roll;
- (void)pianoRoll:(KvPianoRoll *)roll audition:(int)midi;
- (NSString *)pianoRoll:(KvPianoRoll *)roll nameForMidi:(int)midi;
- (NSArray<NSString *> *)pianoRollChordNames:(KvPianoRoll *)roll;
- (double)pianoRollBeatsPerBar:(KvPianoRoll *)roll;
- (void)pianoRollResetRequested:(KvPianoRoll *)roll;
- (void)pianoRoll:(KvPianoRoll *)roll speedChanged:(double)speed;
- (void)pianoRollUndo:(KvPianoRoll *)roll;
- (void)pianoRollRedo:(KvPianoRoll *)roll;
- (void)pianoRollForwardKey:(NSEvent *)event;
- (BOOL)pianoRollPlayKey:(NSEvent *)event;
- (void)pianoRollToggleShortcuts:(KvPianoRoll *)roll;
- (BOOL)pianoRollShortcutsVisible:(KvPianoRoll *)roll;   /* the computer keyboard plays notes: YES when it took the key */
- (NSURL *)pianoRollMidiClip:(KvPianoRoll *)roll;   /* writes the clip (selection, or the whole track) and returns its file */
- (void)pianoRollCopyMidi:(KvPianoRoll *)roll;
/* The selected key's scale as a 12-bit mask of pitch classes (bit 0 = C), its tonic pitch class and its name. */
- (unsigned)pianoRollScale:(KvPianoRoll *)roll tonic:(int *)tonic;
- (NSString *)pianoRollScaleName:(KvPianoRoll *)roll;
/* Pitch-class set of each chord of the progression (bit 0 = C), to tell chord tones from passing notes and anticipations. */
- (NSArray<NSNumber *> *)pianoRollChordMasks:(KvPianoRoll *)roll;
@optional
/* A section of the song is open: the song's sections by name (nil for the draft), the open one, switching (−1: back to the
   arranger), and the song's number of the first bar shown. */
- (NSArray<NSString *> *)pianoRollSections:(KvPianoRoll *)roll;
- (NSInteger)pianoRollSection:(KvPianoRoll *)roll;
- (void)pianoRoll:(KvPianoRoll *)roll openSection:(NSInteger)index;
- (int)pianoRollFirstBar:(KvPianoRoll *)roll;
@end
@interface KvPianoRoll : NSView
@property(nonatomic,weak) id<KvPianoRollOwner> owner;
@property(nonatomic) KvPerformance *track;
@property(nonatomic) double playheadBeat;   /* < 0 when stopped */
@property(nonatomic) double gridBeats;      /* snap step in beats, 0 = free */
@property(nonatomic) double speed;          /* playback speed shown in the toolbar */
@property(nonatomic) int splitNote;         /* new notes below this pitch belong to the left hand */
@property(nonatomic) BOOL edited;           /* shown in the toolbar: the track differs from the arrangement */
@property(nonatomic) BOOL showHelp;         /* the window's shortcuts card (⌘/), opened from the roll */
@property(nonatomic) BOOL showScale;        /* highlight the rows of the selected scale (Ableton's Scale); remembered */
@property(nonatomic) BOOL fold;             /* only the scale's rows (or, without the scale, rows with notes) plus rows holding notes; F; remembered */
- (NSUInteger)rowCount;
- (unsigned char)roleOfNote:(NSUInteger)index;   /* KvNoteRole as last drawn */                     /* pitches that have a row now (88 unfolded) */
@property(nonatomic) BOOL follow;           /* page after the playhead; a manual time zoom or scroll while playing turns it off (⌘F, button) */
- (void)reload;                             /* new notes from the owner; keeps zoom, scroll and row height */
- (void)resetView;                          /* ⌘0: four bars from the start, rows fitted to the notes */
@property(nonatomic) double zoom;
- (void)updateToolbar;
- (NSUInteger)selectedCount;
- (BOOL)isSelectedAt:(NSUInteger)index;
@property(nonatomic,readonly) KvMidiDragHandle *dragHandle;
@property(nonatomic,readonly) NSPopUpButton *sectionChoice;   /* shown instead of the note count while a section of the song is open */
- (void)selectAll;
- (void)deselectAll;
- (void)deleteSelected;
- (void)duplicateSelected;
- (void)quantizeSelected;
- (void)setSelected:(BOOL)selected at:(NSUInteger)index;
- (BOOL)addNoteAtBeat:(double)beat midi:(int)midi duration:(double)duration;
- (BOOL)resizeNoteAt:(NSUInteger)index toDuration:(double)duration;
- (BOOL)moveNoteAt:(NSUInteger)index toBeat:(double)beat midi:(int)midi;
- (BOOL)setHand:(unsigned)hand forSelected:(BOOL)onlySelected;
- (void)changeVelocityOfSelectedBy:(float)delta;
- (NSUInteger)noteIndexAtPoint:(NSPoint)point edge:(BOOL *)edge;
- (NSRect)noteAreaRect;
- (double)beatAtX:(CGFloat)x;
- (double)visibleBeats;
@property(nonatomic) double scrollBeat;
- (void)zoomBy:(double)factor aroundX:(CGFloat)anchorX;
- (void)zoomRowsBy:(double)factor aroundY:(CGFloat)anchorY;
@property(nonatomic) CGFloat rowHeight;
- (int)midiAtY:(CGFloat)y;
@end
