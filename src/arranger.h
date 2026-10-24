#import <Cocoa/Cocoa.h>
#include "song.h"
@class KvArranger;
/* The section properties set from the «Секция» panel. */
typedef enum { KvSectionFieldKind, KvSectionFieldRepeats, KvSectionFieldLevel, KvSectionFieldBeat, KvSectionFieldLift, KvSectionFieldTransition } KvSectionField;
/* Tools of the tracks (spec 1.5 §4): ⌘ held gives the scissors for a moment. */
typedef enum { KvToolPointer, KvToolScissors, KvToolPencil } KvArrangerTool;
/* Snap: «smart» follows the zoom (a bar far out, a beat, an eighth close up). */
typedef enum { KvSnapSmart, KvSnapBar, KvSnapBeat, KvSnapEighth, KvSnapOff } KvArrangerSnap;
/* The owner keeps the song, its tracks and undo; the arranger draws the tracks and reports gestures. */
@protocol KvArrangerOwner <NSObject>
- (const KvSong *)arrangerSong;
- (NSString *)arrangerName:(NSInteger)index;       /* «Куплет 1», or the user's name */
- (NSString *)arrangerChords:(NSInteger)index;     /* «C Am F G» */
- (NSString *)arrangerDetails:(NSInteger)index;    /* «8 тактов · ×2 · баллада» */
- (BOOL)arrangerEdited:(NSInteger)index;           /* the section plays the user's notes */
- (NSData *)arrangerNotes:(NSInteger)index;        /* KvPianoEvent of the whole section as it sounds, beats from its start */
- (NSData *)arrangerHits:(NSInteger)index;         /* KvHit of its beat, beats from its start; empty when no beat plays */
- (NSString *)arrangerDrumsHint;                   /* why the drums track is silent (the metronome is off or a click), nil when it plays */
- (double)arrangerPlayheadBeat;                    /* in the song, −1 when it does not play */
- (void)arrangerSelect:(NSInteger)index;
- (void)arrangerOpenInRoll:(NSInteger)index;
- (void)arrangerOpenInRoll:(NSInteger)index track:(int)track;   /* the roll on one track's hand; −1 both */
- (void)arrangerMove:(NSInteger)from to:(NSInteger)to copy:(BOOL)copy;
- (void)arrangerCut:(NSInteger)index atBeat:(double)beat;   /* beat inside the section, already an allowed cut */
- (void)arrangerMoveRange:(NSRange)range to:(NSInteger)to copy:(BOOL)copy;   /* to: a seam among the sections, 0…count */
- (void)arrangerRemoveRange:(NSRange)range;
- (void)arrangerSwap:(NSInteger)a with:(NSInteger)b;           /* a region dropped on another */
- (void)arrangerSetLength:(NSInteger)index beats:(double)beats; /* the resize corner */
- (void)arrangerTrimStart:(NSInteger)index beats:(double)beats; /* the start corner: + later in the pass, − earlier */
- (void)arrangerShiftRegion:(NSInteger)index track:(int)track shift:(double)shift;   /* a region dragged on its track: beats, ±32 */
- (void)arrangerExport:(NSInteger)what;           /* MIDI: 0 the song, 1 the melody, 2 the bass, 3 the drums */
- (void)arrangerSetCurve:(int)curve to:(const KvCurve *)points;   /* automation: −1 the tempo, 0…2 a track's volume */
- (void)arrangerRemove:(NSInteger)index;
- (void)arrangerSet:(KvSectionField)field value:(NSInteger)value;   /* of the selected section */
- (void)arrangerSetTrack:(int)track mute:(int)mute solo:(int)solo level:(double)level;   /* −1 (level < 0): unchanged */
- (void)arrangerSetRegion:(int)track mute:(int)mute level:(double)level;                 /* of the selected section; −1: unchanged */
- (void)arrangerRevert:(id)sender;                 /* the selected section's notes back to its texture */
- (void)arrangerTakeDraft:(id)sender;              /* the circle's progression becomes a section */
- (void)arrangerGenerateSong:(id)sender;           /* the empty song: a whole one from the circle's chords (made first when there are none) */
- (void)arrangerForwardKey:(NSEvent *)event;
/* What may come after section `index`, best first, for the ghosts under it: @"title", @"tip", @"beats", @"leadBeats" (a transition
   first, 0 for none), @"kind" (KvSectionKind), @"chorus" (a new chorus: ⌥-click offers others), @"leadKind" (KvTransitionKind of the lead-in). */
- (NSArray<NSDictionary *> *)arrangerSuggestions:(NSInteger)index;
- (void)arrangerAccept:(NSInteger)suggestion after:(NSInteger)index;
- (NSArray<NSString *> *)arrangerChorusVariants:(NSInteger)index;       /* other choruses for ⌥-click, by their chords */
- (void)arrangerAcceptVariant:(NSInteger)variant after:(NSInteger)index;
- (void)arrangerTransitionAfter:(NSInteger)index kind:(NSInteger)kind;    /* between index and index+1; kind −1: the one that suits */
- (void)arrangerAudition:(NSInteger)suggestion after:(NSInteger)index;    /* plays a ghost; suggestion −1 stops */
- (void)arrangerPlayFrom:(double)beat;              /* a click on the ruler while the song plays: on from there */
- (void)arrangerSetCycleFrom:(double)from to:(double)to;   /* a drag on the ruler; from == to: no cycle */
- (BOOL)arrangerCycles;                             /* ↻ is on: the cycle (or the song) repeats */
- (void)arrangerToggleLoop;                         /* a click on the cycle: ↻ on or off */
- (void)arrangerDrawAt:(NSInteger)index;            /* pencil: the circle's progression becomes a section at index */
/* Song forms (spec 1.5 §6): the built-in ones, then the user's: @"name", @"letters" («И–К–Пр…»), @"slots" (NSNumber), @"user". */
- (NSArray<NSDictionary *> *)arrangerForms;
- (void)arrangerApplyForm:(NSDictionary *)form;
- (void)arrangerAnotherForm:(id)sender;             /* ⌘R after a form: another variant of it */
- (void)arrangerSaveForm:(id)sender;                /* asks for a name */
- (void)arrangerDeleteForm:(NSString *)name;
@end
/* Tracks of the song (spec 1.5 §2): a ruler, the arrangement track of section markers, the melody, bass and drum tracks with
   their headers and regions, and an overview of the whole song. */
@interface KvArranger : NSView
@property(nonatomic,weak) id<KvArrangerOwner> owner;
@property(nonatomic) NSInteger selected;           /* the owner sets it; −1 none */
@property(nonatomic) double scrollBeat;            /* first beat shown */
@property(nonatomic) KvArrangerTool tool;
@property(nonatomic) KvArrangerSnap snap;
@property(nonatomic) double zoom;                  /* 1: the whole song (at least 18 pt a bar); more: closer */
@property(nonatomic) double cursorBeat;            /* the playhead at rest: a click on the ruler puts it there, the song plays from it */
- (double)snapGrid:(NSEventModifierFlags)flags;    /* in beats, 0 none (⌃ held: none) */
- (CGFloat)scale;                                  /* points per beat */
- (void)zoomBy:(double)factor aroundX:(CGFloat)x;
- (void)showWholeSong:(id)sender;                  /* Z */
- (void)reload;                                    /* the song or the selection changed */
- (void)updatePlayhead;                            /* each frame while something plays: moves the playhead line only */
- (NSRect)rectOfSection:(NSInteger)index;          /* its marker on the arrangement track, in view coordinates */
- (NSRect)rectOfRegion:(NSInteger)index track:(int)track;
- (double)beatAtX:(CGFloat)x;
- (CGFloat)xOfBeat:(double)beat;
- (NSArray<NSValue *> *)ghostRectsAfter:(NSInteger)index;   /* where the ghosts of a section are drawn (self-test) */
- (void)hoverAtPoint:(NSPoint)point;                        /* as a mouse move there (self-test) */
@property(nonatomic,readonly) NSInteger hoverSection,hoverGhost,hoverSeam;
/* Selection (spec 1.5 §4): a click one section, ⇧-click a range, ⌘A all; the owner's `selected` is the one in the inspector. */
@property(nonatomic) NSRange selection;
@property(nonatomic) int selectedTrack;            /* the track whose region was clicked, −1 the whole section (the marker) */
@property(nonatomic,readonly) NSInteger hoverRegion,hoverButton;   /* the region under the pointer (its buttons show), the button */
@property(nonatomic,readonly) int hoverTrack;
- (NSArray<NSValue *> *)buttonRectsOf:(NSInteger)index track:(int)track;   /* ✎ ✂ ⧉ ✕ of a hovered region; empty when too small */
- (NSMenu *)menuForSection:(NSInteger)index track:(int)track beat:(double)beat;   /* the right-click menu; track −1: the marker */
- (NSRect)endSlotRect;
- (void)clearCycle:(id)sender;                      /* the ruler's menu: «Снять цикл» */                              /* «+» after the song: hovering it shows what may come next */
/* The «Секция» tab of the inspector: the owner places it; the arranger fills and updates it. */
@property(nonatomic,readonly) NSView *sectionPanel;
@property(nonatomic,readonly) NSSegmentedControl *toolChoice;
@property(nonatomic,readonly) NSPopUpButton *snapChoice;
@property(nonatomic,readonly) NSButton *zoomOutButton,*zoomInButton,*wholeSongButton;
@property(nonatomic,readonly) NSPopUpButton *structureChoice;   /* «Структура ▾»: forms, «Сохранить форму…», another variant */
/* Automation lanes (spec 1.5 §6а): the tempo under the ruler (⌁), a volume lane under each track («A»). */
@property(nonatomic) BOOL showTempo;
- (BOOL)showsVolume:(int)track;
- (void)setShowsVolume:(BOOL)shown track:(int)track;
- (NSRect)curveRect:(int)curve;                     /* −1 the tempo lane, 0…2 a track's volume lane; NSZeroRect when hidden */
- (NSPoint)pointOfCurve:(int)curve value:(double)value beat:(double)beat;   /* where a value sits in its lane */
@property(nonatomic,readonly) NSButton *tempoButton;
@property(nonatomic,readonly) NSArray<NSButton *> *volumeButtons;
@property(nonatomic,readonly) NSInteger selectedPoint;   /* of the curve last touched, −1 none */
@property(nonatomic,readonly) NSPopUpButton *kindChoice,*repeatsChoice,*levelChoice,*beatChoice,*liftChoice,*transitionChoice;
@property(nonatomic,readonly) NSButton *openButton,*revertButton,*removeButton,*takeButton,*exportButton;
@property(nonatomic,readonly) NSButton *generateButton;   /* «✦ Сгенерировать песню» on the empty melody track */
@property(nonatomic,readonly) NSArray<NSButton *> *trackMutes,*trackSolos,*regionMutes;   /* per track */
@property(nonatomic,readonly) NSArray<NSSlider *> *trackLevels,*regionLevels;             /* melody, bass (drums: none) */
@end
