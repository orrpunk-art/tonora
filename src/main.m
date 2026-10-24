#import <Cocoa/Cocoa.h>
#include <math.h>
#include "music.h"
#include "audio.h"
#include "mixer.h"
#import "brand.h"
#import "controls.h"
#include "midi.h"
#include "fingering.h"
#import "midiio.h"
#import "pianoroll.h"
#import "arranger.h"
@interface KvPianoRoll (SelfTest)   /* geometry the self-test needs to aim mouse events */
- (NSRect)rectForNote:(NSUInteger)index;
@end
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "mididrag.h"
#define KV_CHECK(condition,message) do { if(!(condition)) { fprintf(stderr,"Integration check failed: %s\n",[(message) UTF8String]); return 1; } } while(0)

static NSColor *Accent(void) { return TNAccent(); }
static NSColor *Ink(void) { return NSColor.labelColor; }
static NSUserDefaults *Defaults(void) { return TNDefaults(); }
static NSString *S(const char *text) { return T([NSString stringWithUTF8String:text]); }   // names from the C core are translated too
static void Text(NSString *text, NSRect rect, CGFloat size, NSFontWeight weight, NSColor *color, NSTextAlignment align) {
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.alignment=align; style.lineBreakMode=NSLineBreakByTruncatingTail;
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:weight], NSForegroundColorAttributeName:color, NSParagraphStyleAttributeName:style}];
}
static void Line(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    [NSColor.separatorColor setStroke]; NSBezierPath *p=[NSBezierPath bezierPath]; [p moveToPoint:NSMakePoint(x1,y1)]; [p lineToPoint:NSMakePoint(x2,y2)]; [p stroke];
}
@class KvRoot, KvChip;
/* The app delegate builds the window's view and menus; a new interface language asks it to build them again. */
@protocol KvInterfaceHost <NSObject>
- (void)rebuildInterface;
@end
static const CGFloat KvStrokeRowHeight=78;
static const NSInteger KvBeatByStyle=99;   /* rhythmBeat: the beat that suits the two hands' style */   /* FX: the «Штрих» row with its explanation, shown for the strings */
/* Window grid. All values are points in the flipped root view; nothing is scaled non-uniformly. */
typedef struct { CGFloat w,h,inspectorX,dockTop,cx,cw,headY,kbY,legendY,sepY,seqY,transportY,statusY,slotW,tempoX,registerX; } KvMetrics;
static const CGFloat KvMargin=24, KvInspectorWidth=320, KvHeaderHeight=52, KvSlotGap=6, KvChipHeight=36, KvTransportHeight=32, KvKeyboardHeight=88;
static const CGFloat KvMinWidth=1120, KvMinHeight=680, KvMaxContentWidth=1160, KvMaxCircleRadius=280;
static CGFloat KvDockHeight(void) { return 10+28+6+KvKeyboardHeight+6+24+8+1+8+KvChipHeight+8+KvTransportHeight+6+18+6; }
@interface KvCircle : NSView {
    int _fingerNote[2][5]; float _fingerLevel[2][5]; NSTimeInterval _lastFrame;
    int _hoverIndex, _hoverRing; unsigned _common[2];   /* the hovered other key and the sectors of the chords it shares */
}
@property(nonatomic) NSTrackingArea *hoverArea;
- (void)hoverAtPoint:(NSPoint)p;
- (void)geometry:(NSPoint *)center radius:(CGFloat *)radius;
@property(nonatomic, weak) KvRoot *owner;
/* notes[5]: MIDI note held by thumb…little finger of that hand, or -1. */
- (void)setHand:(int)hand fingers:(const int *)notes;
- (void)advanceFingers;
- (void)retriggerNote:(int)midi;   /* the finger on this key strikes it again */
- (int)noteOfFinger:(int)finger hand:(int)hand;   /* 0 = thumb; −1 when the finger is up */
- (int)pressedFingersForHand:(int)hand;
- (BOOL)handsVisible;
- (NSRect)handBox:(int)hand;
- (void)drawHand:(int)hand inRect:(NSRect)box;
@end
/* One hand beside the circle, a view of its own: a moving finger repaints the hand, never the circle. */
@interface KvHandView : NSView
@property(nonatomic,weak) KvCircle *circle; @property(nonatomic) int hand;
@end
@implementation KvHandView
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }   // clicks go to the circle under it
- (void)drawRect:(NSRect)dirtyRect { (void)dirtyRect; NSRect box=[self.circle handBox:self.hand]; [self.circle drawHand:self.hand inRect:NSOffsetRect(box,-NSMinX(self.frame),-NSMinY(self.frame))]; }
@end
@interface KvPiano : NSView {
    float _levels[128];
    unsigned char _role[128];   /* KvNoteRole of each sounding key (performance playback only) */
    BOOL _sustain[128];         /* sounding now: the key stays down for the whole note, as the finger does */
    BOOL _active[128];
    NSTimeInterval _litAt[128];
    NSTimeInterval _lastFrame;
}
@property(nonatomic, weak) KvRoot *owner;
@property(nonatomic) int pressed;
@property(nonatomic) int hovered;
@property(nonatomic) NSTrackingArea *keyTracking;
- (void)flashNotes:(NSArray<NSNumber *> *)notes;
- (void)setActiveNotes:(NSArray<NSNumber *> *)notes;
- (NSRect)rectFor:(int)midi;
- (void)setRoles:(const unsigned char *)roles;   /* 128 entries; NULL clears */
- (void)retrigger:(int)midi;                     /* the same key struck again: lift it and press it anew */
- (float)levelOf:(int)midi;
- (unsigned char)roleOf:(int)midi;
- (void)advanceAnimation;
@end
@interface KvRoot : NSView <KvPianoRollOwner,KvArrangerOwner> {
    BOOL _midiSounding[2][128]; BOOL _held[128];
    int _soundCount[128], _keyNotes[128][8], _keyNoteCount[128];   /* manual playing: notes each key started, and how many keys hold each note */
    BOOL _pedalHeld[128];   /* let go while the sustain pedal (CC64) is down: sounds on until the pedal comes up */
    int _computerKey[128];          /* computer keyboard: key code → the pitch it is holding, −1 when up */
    unsigned char _planFingers[KV_PERFORMANCE_CAPACITY];          /* fingering of currentPlan, computed when it starts */
    unsigned char _planRoles[KV_PERFORMANCE_CAPACITY];            /* chord tone / passing / anticipation, same moment */
    long _soundingEvent[128];                                     /* plan event each key is sounding, to see a key struck again */
    unsigned char _visualHand[256], _visualFinger[256]; int _visualMidi[256]; size_t _visualVoices, _visualCount; /* scale and chord previews */
}
@property(nonatomic) KvKey key;
@property(nonatomic) KvMidi *midi;
@property(nonatomic) KvPerformance *currentPlan;
/* The editable track: what the piano roll shows and, once edited, what plays and exports. */
@property(nonatomic) KvPerformance *track;
@property(nonatomic) BOOL trackEdited;
@property(nonatomic) NSMutableArray<NSData *> *trackUndo,*trackRedo;
@property(nonatomic) KvPianoRoll *roll;
@property(nonatomic) NSSegmentedControl *viewSwitch;
@property(nonatomic) NSInteger viewMode;     /* 0 circle, 1 piano roll, 2 arranger */
/* The song (spec 1.4): its sections, the edited sections' tracks by id, and its undo. The working state — progression, texture,
   track — belongs to the draft on the circle or, while editingSection ≥ 0, to that section; draftState keeps the draft meanwhile. */
@property(nonatomic) KvSong *song;
@property(nonatomic) NSMutableDictionary<NSNumber *,NSData *> *sectionTracks;
@property(nonatomic) NSInteger editingSection;
@property(nonatomic) NSDictionary *draftState;
@property(nonatomic) NSMutableArray<NSDictionary *> *songUndo,*songRedo;
@property(nonatomic) KvArranger *arranger;
/* Song playback: the section of each part in play order, the song beat where each part starts, plans by section, parts started. */
@property(nonatomic) BOOL songPlaying;
@property(nonatomic) BOOL rollDocked;                      /* the piano roll under the arranger's tracks, on the selected section */
@property(nonatomic) NSMutableArray<NSNumber *> *songOrder,*songOrderBeats,*songOrderFrom,*songOrderLength;   /* per part: section, song beat, beat in the section, length */
@property(nonatomic) NSString *playingTimeline;             /* the sections' ids, lengths, passes and trims the play order was built on; a change rebuilds the order from the part playing */
@property(nonatomic) NSMutableDictionary<NSString *,NSData *> *songPlans;   /* parts already built, by section, start and length */
@property(nonatomic) NSInteger songPart,songQueued;
@property(nonatomic) uint32_t suggestSeed;                  /* picks among the choruses that fit; new after each accepted suggestion */
@property(nonatomic) NSArray<NSData *> *chorusVariants;     /* ⌥-click on a chorus ghost: the other choruses offered */
@property(nonatomic) BOOL auditioningGhost;
@property(nonatomic) BOOL transportPlaying;
@property(nonatomic) NSUInteger idleTicks;                  /* frames since anything last played or moved */                 /* what the play button showed at the last frame */
@property(nonatomic) double speed;           /* practice speed factor, 1 = tempo as set */
@property(nonatomic) BOOL restoring;         /* saveState is a no-op while the saved state is being replayed */
/* Musical time is piecewise linear: after each tempo or speed change it continues from (rateBeat, rateSeconds). */
@property(nonatomic) double rateBeat,rateSeconds;
@property(nonatomic) NSSegmentedControl *inspectorTabs;
@property(nonatomic) NSMutableArray<KvChip *> *chromaticChips;          /* «Вне лада»: one tile per chord, rebuilt with the key */
@property(nonatomic) NSArray<NSTextField *> *chromaticHeaders;
@property(nonatomic) NSTextField *chromaticStory;
@property(nonatomic) NSTextField *chromaticTitle;   /* the selected tile's chord, next to «Добавить» */
@property(nonatomic) NSButton *chromaticAddButton;
@property(nonatomic) NSArray<NSNumber *> *chromaticGroups;
@property(nonatomic) NSInteger inspectorTab;
@property(nonatomic) NSArray<NSView *> *midiViews;
@property(nonatomic) NSTextField *midiExportInfo;
@property(nonatomic) NSButton *midiExportButton;
@property(nonatomic) NSButton *midiCopyButton;
@property(nonatomic) KvMidiDragHandle *midiDragHandle;
@property(nonatomic) NSPopUpButton *midiDestination;
@property(nonatomic) NSButton *midiOutToggle;
@property(nonatomic) NSButton *midiInToggle;
@property(nonatomic) NSButton *chordKeysToggle;
@property(nonatomic) BOOL chordKeys;   /* one key plays the key's chord built on it (InstaChord-style) */
@property(nonatomic) NSTextField *midiChordLabel;
@property(nonatomic) NSTextField *midiHeldLabel;
@property(nonatomic) NSButton *midiAddChordButton;
@property(nonatomic) NSTextField *midiStatus;
@property(nonatomic) NSInteger detectedDegree;
@property(nonatomic) BOOL midiOutEnabled;
@property(nonatomic) int keyboardBase;
@property(nonatomic) NSSegmentedControl *registerControl;
@property(nonatomic) KvMetrics metrics;
@property(nonatomic) BOOL respelledNote;
@property(nonatomic,copy) NSString *respelledFrom;
/* The tonic letter the user picked (0 = circle default). Each mode change starts from it, so a forced respelling never sticks. */
@property(nonatomic) int requestedSpelling;
@property(nonatomic) NSPopUpButton *instrumentChoice;
@property(nonatomic) BOOL stringsAvailable;   /* the bowed-strings recordings were found and loaded */
@property(nonatomic) BOOL drumsAvailable;     /* the percussion recordings (acoustic beats) were found and loaded */
@property(nonatomic) NSSlider *dynamicsSlider;            /* strings only, left of the keyboard; the mod wheel moves it */
@property(nonatomic) NSSegmentedControl *articulationControl; @property(nonatomic) NSTextField *articulationLabel;   /* FX, strings only */
@property(nonatomic) KvArticulation articulation;
@property(nonatomic) double stringDynamics,stringExpression;
@property(nonatomic) BOOL pedalDown;
@property(nonatomic) CGFloat soundPanelShift;            /* how far the FX rows below the instrument sit lower for the «Штрих» row */
@property(nonatomic) KvChordLength chordLengthStrings;
@property(nonatomic) NSInteger instrument;
@property(nonatomic) NSSegmentedControl *humanizeControl;
@property(nonatomic) BOOL humanize;
@property(nonatomic) NSArray<NSArray<NSNumber *> *> *visualEvents;
@property(nonatomic) double visualEventSeconds;
@property(nonatomic) NSInteger visualEvent;
@property(nonatomic) BOOL visualPlayback;
@property(nonatomic) NSInteger selectedDegree;
@property(nonatomic) NSMutableArray<NSNumber *> *progression;
@property(nonatomic) KvCircle *circle;
@property(nonatomic) KvPiano *piano;
@property(nonatomic) NSPopUpButton *mode;
@property(nonatomic) NSSegmentedControl *keyboardMode;
@property(nonatomic) NSTextField *keyboardHeading;
@property(nonatomic) NSTextField *keyboardNotes;
@property(nonatomic) NSUInteger playbackGeneration;
@property(nonatomic) NSButton *soundSettingsButton;
@property(nonatomic) NSButton *generateSequenceButton;
@property(nonatomic) NSButton *presetsButton;
@property(nonatomic) TNPopup *generateCountChoice;   /* how many chords the wand makes: 4, 6 or 8 */
@property(nonatomic) int generateCount;
@property(nonatomic) NSPanel *soundPanel;
@property(nonatomic) NSSlider *reverbSlider;
@property(nonatomic) NSSlider *delaySlider;
@property(nonatomic) NSSlider *delayTimeSlider;
@property(nonatomic) NSTextField *reverbValue;
@property(nonatomic) NSTextField *delayValue;
@property(nonatomic) NSTextField *delayTimeValue;
@property(nonatomic) NSSlider *tempoSlider;
@property(nonatomic) NSTextField *tempoValue;
@property(nonatomic) double tempo;
@property(nonatomic) NSPopUpButton *delayDivision;
@property(nonatomic) NSSegmentedControl *delayMode;
@property(nonatomic) double freeDelaySeconds;
@property(nonatomic) NSTextField *delayUnitLabel;
@property(nonatomic) NSTextField *fxTempoValue;
@property(nonatomic) NSInteger delayDivisionIndex;
@property(nonatomic) NSArray<NSNumber *> *playingDegrees;
@property(nonatomic) KvEffects effects;
@property(nonatomic) NSButton *soundButton;
@property(nonatomic) NSButton *computerKeyboardButton;
@property(nonatomic) NSButton *shortcutsButton;
@property(nonatomic) NSView *shortcutsCard;
@property(nonatomic) NSMapTable<NSView *,NSString *> *silencedToolTips;   /* AppKit tooltips taken off the views under the open card */
@property(nonatomic) BOOL computerKeyboard;      /* play notes from the computer keyboard, as Ableton's Computer MIDI Keyboard (M) */
@property(nonatomic) int computerBase,computerVelocity;
@property(nonatomic) NSButton *scaleButton;
@property(nonatomic) NSButton *playButton;
@property(nonatomic) NSPopUpButton *performanceChoice;
@property(nonatomic) NSTextField *articulationHint;
@property(nonatomic) NSSegmentedControl *languageControl;   /* FX: English | Русский */        /* FX: what «Авто» does, under the stroke control */
@property(nonatomic) NSPopUpButton *patternChoice;
@property(nonatomic) NSInteger performanceMode;
@property(nonatomic) NSInteger chordExtension;
@property(nonatomic) NSPopUpButton *harmonyChoice;
@property(nonatomic) NSButton *arrangeButton;
@property(nonatomic) uint32_t arrangementSeed;
@property(nonatomic) BOOL generatedRhythm;
@property(nonatomic) KvPianoPattern pianoPattern;
@property(nonatomic) BOOL playingTwoHand;
@property(nonatomic) BOOL playingPerformance;
@property(nonatomic) double playingBeatsPerChord;
@property(nonatomic) NSUInteger playOffset;
@property(nonatomic) NSInteger currentChip;
@property(nonatomic) NSInteger selectedChip;
@property(nonatomic) NSPopUpButton *meterChoice;
@property(nonatomic) NSPopUpButton *lengthChoice;
@property(nonatomic) NSPopUpButton *fillChoice;
@property(nonatomic) KvMeter meter;
@property(nonatomic) KvChordLength chordLengthBlocks;
@property(nonatomic) KvChordLength chordLengthHands;
@property(nonatomic) KvChordLength chordLengthArp;
@property(nonatomic) NSPopUpButton *arpeggioChoice;
@property(nonatomic) NSPopUpButton *divisionChoice;
@property(nonatomic) KvArpeggioPattern arpeggioPattern;
@property(nonatomic) KvDivision division;
@property(nonatomic) KvFillRate fillRate;
@property(nonatomic) NSButton *loopButton;
@property(nonatomic) BOOL loopEnabled;
@property(nonatomic) NSButton *metronomeButton;        /* the click on/off · ⌘K; it sounds only while something plays */
@property(nonatomic) NSPopUpButton *rhythmChoice;      /* beside it: the click grid and the count-in */
@property(nonatomic) NSButton *drumsButton;            /* the drums on/off · ⇧⌘K */
@property(nonatomic) NSPopUpButton *drumsChoice;       /* beside it: by the style, or one beat */
@property(nonatomic) BOOL drumsOn;                     /* the drums play under the song (each section's) and the circle's progression (by its style) */
@property(nonatomic) BOOL rhythmAlone;                 /* Play with nothing to play: the click and the drums run by themselves until Stop */
@property(nonatomic) BOOL songRestart;                 /* the song starting again after an edit: no count-in, no status line */
@property(nonatomic) BOOL metronomeOn,countIn;           /* the metronome starts off at every launch; the count-in is kept */
@property(nonatomic) KvGrid rhythmGrid;
@property(nonatomic) NSInteger rhythmBeat;               /* the drums' beat: a KvBeat, or KvBeatByStyle */
@property(nonatomic) NSMenu *drumsMenu;                   /* unused since the metronome holds the drums */
@property(nonatomic) NSDictionary *lastForm;              /* the form just applied: ⌘R makes another variant until the song is edited otherwise */
@property(nonatomic) uint32_t formSeed;
@property(nonatomic) NSInteger tempoPart;                 /* the song's tempo curve while it plays: the part counted, */
@property(nonatomic) double tempoSeconds,tempoBeats,appliedBpm;   /* its seconds and beats so far, the tempo the engine has */                   /* «Ударные черновика» in the metronome's menu */
@property(nonatomic) NSData *sentHits;                    /* a section's hits the engine plays now */
@property(nonatomic) NSInteger sentBeat,sentBeatMeter;   /* what the engine plays now, to send a new bar only when it changes */
@property(nonatomic) double rhythmVolume;                /* 0…1, FX «Ритм · громкость» */
@property(nonatomic) NSSlider *rhythmVolumeSlider; @property(nonatomic) NSTextField *rhythmVolumeValue;
@property(nonatomic) NSInteger beatDot;                  /* the lit beat dot, −1 for none */
@property(nonatomic) id playbackActivity;
@property(nonatomic) NSButton *clearButton;
@property(nonatomic) NSButton *undoSequenceButton;
@property(nonatomic) NSArray<NSNumber *> *sequenceUndo;
@property(nonatomic) NSTextField *arrangementInfo;
@property(nonatomic) NSTextField *heading;
@property(nonatomic) NSTextField *signature;
@property(nonatomic) NSTextField *scaleNames;
@property(nonatomic) NSTextField *chordHeading;
@property(nonatomic) NSTextField *hint;
@property(nonatomic) NSTextField *status;
@property(nonatomic) NSArray<NSButton *> *chordButtons;
@property(nonatomic) NSArray<NSButton *> *addButtons;
@property(nonatomic) NSMutableArray<NSButton *> *progressionButtons;
@property(nonatomic) KvAudio *audio;
- (void)selectIndex:(int)index minor:(BOOL)minor;
- (BOOL)keyboardHighlights:(int)midi;
- (NSString *)keyboardName:(int)midi;
- (int)keyboardRoot;
- (void)playNotes:(const int *)notes count:(size_t)count voices:(size_t)voices duration:(double)duration;
- (void)playTonic:(id)sender;
- (void)circleSelected:(int)index minor:(BOOL)minor;
- (void)circleSelected:(int)index minor:(BOOL)minor spelling:(int)spelling;
- (NSString *)circleLabelAt:(int)index minor:(BOOL)minor;
- (void)chordClicked:(NSButton *)sender;
- (void)refresh;
- (void)saveState;
- (void)updateTransport;
- (void)toggleMetronome:(id)sender;
- (void)rhythmChanged:(NSPopUpButton *)sender;
- (void)applyRhythm;
- (void)rhythmVolumeChanged:(NSSlider *)sender;
- (void)defaultSound:(id)sender;
- (void)updateBeatDots;
- (void)previewChord:(const KvChord *)chord;
- (void)playProgressionFrom:(NSUInteger)start;
- (void)moveChordFrom:(NSInteger)from to:(NSInteger)to;
- (void)chip:(NSButton *)chip droppedAt:(CGFloat)x;
- (void)stopPlayback:(id)sender;
- (int)keyboardStart;
- (int)keyboardCount;
- (int)keyboardViewStart;      /* first key drawn: the register, shifted by the computer keyboard's octave (Z / X) */
- (int)computerLetterBase;     /* pitch of the A key while the computer keyboard is on, else −1 */
- (void)shiftOctave:(NSInteger)delta;
- (NSString *)layoutProblem;
- (NSString *)keyboardName:(int)midi;
- (void)midiNote:(int)midi velocity:(int)velocity on:(BOOL)on;
- (BOOL)exportMidiToPath:(NSString *)path;
- (void)updateHands;
- (NSString *)modulationTo:(int)index minor:(BOOL)minor masks:(unsigned *)masks;
- (void)chromaticClicked:(KvChip *)sender;
- (void)addChromatic:(id)sender;
- (void)placeCode:(int)code;
- (void)continueProgression:(id)sender;
- (NSUInteger)continueCount;
- (void)generateCountChanged:(NSPopUpButton *)sender;
- (void)setInversion:(NSMenuItem *)sender;
- (void)applyPreset:(NSMenuItem *)item;
- (BOOL)validateMenuItem:(NSMenuItem *)item;
- (BOOL)importMidiData:(NSData *)data name:(NSString *)name;
- (void)toggleShortcuts:(id)sender;
@property(nonatomic,readonly) BOOL shortcutsVisible;
- (void)toggleComputerKeyboard:(id)sender;
- (BOOL)computerKeyDown:(NSEvent *)event;
- (BOOL)computerKeyUp:(NSEvent *)event;
- (void)releaseComputerKeys;
- (BOOL)isHeld:(int)midi;
- (BOOL)isSounding:(int)midi;
- (NSString *)visualFingering;
- (void)silenceMidi;
- (NSURL *)midiClipURLSelectionOnly:(BOOL)selectionOnly;
- (BOOL)copyMidiToPasteboard:(NSPasteboard *)pasteboard;
- (void)reconcilePlayback;
- (BOOL)isPlayingProgression;
- (double)playheadBeat;
- (BOOL)buildTrack;
- (void)viewChanged:(NSSegmentedControl *)sender;
@end

/* Over the current key or the centre the circle explains itself; over another key it suggests the modulation. */
static NSString *const KvCircleHint=@"Клик выбирает тонику — нажатый сектор остаётся выделенным в любом ладу. Светлые сектора с номерами — аккорды выбранного лада, пунктир — тот же тон на другом кольце. Лад меняется в списке «Лад» и не сдвигает тонику.";
@implementation KvCircle
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        for(int h=0;h<2;h++) for(int f=0;f<5;f++) _fingerNote[h][f]=-1; _hoverIndex=-1;
        for(int h=0;h<2;h++) { KvHandView *view=[[KvHandView alloc] initWithFrame:NSZeroRect]; view.circle=self; view.hand=h; [self addSubview:view]; }
    }
    return self;
}
- (NSArray<KvHandView *> *)handViews { NSMutableArray *views=[NSMutableArray array]; for(NSView *view in self.subviews) if([view isKindOfClass:KvHandView.class]) [views addObject:view]; return views; }
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; self.needsLayout=YES; }
- (void)layout {
    [super layout]; BOOL visible=[self handsVisible];
    for(KvHandView *view in [self handViews]) { NSRect box=[self handBox:view.hand]; view.hidden=!visible;
        if(visible) view.frame=NSIntegralRect(NSMakeRect(NSMinX(box)-26,NSMinY(box)-NSHeight(box)*.35,NSWidth(box)+52,NSHeight(box)*1.35+40)); }
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(self.hoverArea) [self removeTrackingArea:self.hoverArea];
    self.hoverArea=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]; [self addTrackingArea:self.hoverArea];
}
/* Hovering another key shows how to get there: the shared chords are outlined, a bubble names the pivot. */
- (void)hoverAtPoint:(NSPoint)p {
    NSPoint c; CGFloat r; [self geometry:&c radius:&r]; CGFloat distance=hypot(p.x-c.x,p.y-c.y);
    int index=-1,ring=0;
    if(distance<=r && distance>=r*.35) { double a=atan2(p.y-c.y,p.x-c.x)+M_PI_2; index=kv_mod((int)floor(a/(M_PI/6)+.5),12); ring=distance<r*.69; }
    if(index>=0 && index==self.owner.key.circle_index && ring==self.owner.key.minor) index=-1;   // the current key itself
    if(index<0 && distance<=r) { index=-2; ring=0; }
    if(TNViewCovered(self,[self convertPoint:p toView:nil])) index=-1;
    if(index==_hoverIndex && ring==_hoverRing) return;
    _hoverIndex=index; _hoverRing=ring; _common[0]=_common[1]=0; self.needsDisplay=YES;
    if(index==-1) { TNHintHide(self); return; }
    NSString *text=index==-2?T(KvCircleHint):[self.owner modulationTo:index minor:ring==1 masks:_common];
    TNHintShow(self,NSMakeRect(p.x-2,p.y-2,4,4),text,NO);
}
- (void)mouseMoved:(NSEvent *)event { [self hoverAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]; }
- (void)mouseExited:(NSEvent *)event { (void)event; _hoverIndex=-1; _common[0]=_common[1]=0; TNHintHide(self); self.needsDisplay=YES; }
- (BOOL)isFlipped { return YES; }
/* A finger that moves from one key to another lifts and presses again, so every note is a visible stroke. */
- (void)setHand:(int)hand fingers:(const int *)notes {
    if(hand<0 || hand>1) return;
    BOOL changed=NO;
    for(int f=0;f<5;f++) { int note=notes?notes[f]:-1; if(note>=0 && _fingerNote[hand][f]>=0 && note!=_fingerNote[hand][f]) _fingerLevel[hand][f]=fminf(_fingerLevel[hand][f],.25f); changed|=_fingerNote[hand][f]!=note; _fingerNote[hand][f]=note; }
    if(changed) [self invalidateHand:hand];   // the caption names the held notes
}
- (int)pressedFingersForHand:(int)hand { int n=0; for(int f=0;f<5;f++) if(_fingerNote[hand][f]>=0) n++; return n; }
- (int)noteOfFinger:(int)finger hand:(int)hand { return hand>=0 && hand<2 && finger>=0 && finger<5?_fingerNote[hand][finger]:-1; }
- (void)retriggerNote:(int)midi { for(int h=0;h<2;h++) for(int f=0;f<5;f++) if(_fingerNote[h][f]==midi) { _fingerLevel[h][f]=fminf(_fingerLevel[h][f],.25f); [self invalidateHand:h]; } }
/* What a moving finger repaints: the two hands with their captions, never the circle between them. */
- (NSRect)handBox:(int)hand {
    CGFloat w=[self handWidth]; NSPoint c; CGFloat r; [self geometry:&c radius:&r]; CGFloat h=w*1.25,y=c.y-h/2;
    return NSMakeRect(hand?c.x+r+12:c.x-r-12-w,y,w,h);
}
- (void)invalidateHands { for(KvHandView *view in [self handViews]) view.needsDisplay=YES; }
- (void)invalidateHand:(int)hand { for(KvHandView *view in [self handViews]) if(view.hand==hand) view.needsDisplay=YES; }
- (void)advanceFingers {
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime; double dt=_lastFrame?fmin(.05,now-_lastFrame):1.0/60; _lastFrame=now;
    BOOL changed[2]={NO,NO},reduce=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    for(int h=0;h<2;h++) for(int f=0;f<5;f++) {
        float target=_fingerNote[h][f]>=0?1:0,old=_fingerLevel[h][f];
        _fingerLevel[h][f]=reduce?target:old+(target-old)*(1-exp(-dt/(target?.012:.06)));
        if(fabsf(_fingerLevel[h][f]-target)<.002) _fingerLevel[h][f]=target;
        if(fabsf(old-_fingerLevel[h][f])>.001) changed[h]=YES;
    }
    for(int h=0;h<2;h++) if(changed[h]) [self invalidateHand:h];
}
- (CGFloat)handWidth {
    NSPoint c; CGFloat r; [self geometry:&c radius:&r];
    CGFloat side=MIN(c.x-r,NSWidth(self.bounds)-(c.x+r))-24;
    return side>=56?MIN(104,side):0;
}
- (BOOL)handsVisible { return [self handWidth]>0; }
/* A hand seen from above: palm, four fingers and a thumb that points towards the circle. Pressed fingers bend (shorten) and take the accent colour. */
- (void)drawHand:(int)hand inRect:(NSRect)box {
    CGFloat w=NSWidth(box),h=NSHeight(box),fw=w*.155,gap=w*.045;
    NSColor *skin=TNSurface(),*edge=[NSColor.labelColor colorWithAlphaComponent:.22];
    // Fingers 2–5 stand on the palm; the thumb leans out of the palm's inner side.
    static const CGFloat lengths[4]={.56,.64,.60,.48};
    CGFloat palmTop=box.origin.y+h*.42,palmH=h*.40;
    NSRect palm=NSMakeRect(box.origin.x+fw*.5,palmTop,w-fw,palmH);
    NSBezierPath *palmPath=[NSBezierPath bezierPathWithRoundedRect:palm xRadius:w*.16 yRadius:w*.16];
    [skin setFill]; [palmPath fill]; [edge setStroke]; palmPath.lineWidth=1; [palmPath stroke];
    for(int i=0;i<4;i++) {
        int finger=hand?i+1:4-i; // left hand: little finger at the left, index next to the thumb
        float level=_fingerLevel[hand][finger];
        CGFloat len=h*lengths[hand?i:3-i]*(1-.14*level),x=palm.origin.x+gap+i*((palm.size.width-2*gap)/4)+((palm.size.width-2*gap)/4-fw)/2;
        NSRect rect=NSMakeRect(x,palmTop-len+fw*.5,fw,len+fw*.5);
        NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:rect xRadius:fw/2 yRadius:fw/2];
        [[skin blendedColorWithFraction:level ofColor:Accent()] setFill]; [path fill]; [edge setStroke]; [path stroke];
        Text([NSString stringWithFormat:@"%d",finger+1],NSMakeRect(x-4,rect.origin.y+2,fw+8,12),9,NSFontWeightSemibold,level>.5?NSColor.whiteColor:NSColor.secondaryLabelColor,NSTextAlignmentCenter);
    }
    float thumb=_fingerLevel[hand][0]; CGFloat tl=h*.36*(1-.12*thumb);
    NSGraphicsContext *context=NSGraphicsContext.currentContext; [context saveGraphicsState];
    NSAffineTransform *t=[NSAffineTransform transform];
    CGFloat pivotX=hand?palm.origin.x+fw*.3:NSMaxX(palm)-fw*.3,pivotY=palmTop+palmH*.35;
    [t translateXBy:pivotX yBy:pivotY]; [t rotateByDegrees:hand?38:-38]; [t concat];
    NSRect thumbRect=NSMakeRect(-fw/2,-tl,fw,tl+fw*.4);
    NSBezierPath *thumbPath=[NSBezierPath bezierPathWithRoundedRect:thumbRect xRadius:fw/2 yRadius:fw/2];
    [[skin blendedColorWithFraction:thumb ofColor:Accent()] setFill]; [thumbPath fill]; [edge setStroke]; [thumbPath stroke];
    Text(@"1",NSMakeRect(-fw/2-4,-tl+2,fw+8,12),9,NSFontWeightSemibold,thumb>.5?NSColor.whiteColor:NSColor.secondaryLabelColor,NSTextAlignmentCenter);
    [context restoreGraphicsState];
    // Caption: which hand, and what it holds right now.
    NSMutableArray *names=[NSMutableArray array];
    for(int f=0;f<5;f++) if(_fingerNote[hand][f]>=0) [names addObject:[NSString stringWithFormat:@"%@%d",[self.owner keyboardName:_fingerNote[hand][f]],_fingerNote[hand][f]/12-1]];
    Text(hand?T(@"Правая"):T(@"Левая"),NSMakeRect(box.origin.x-10,NSMaxY(palm)+4,w+20,14),10,NSFontWeightMedium,NSColor.secondaryLabelColor,NSTextAlignmentCenter);
    Text(names.count?[names componentsJoinedByString:@" "]:@"",NSMakeRect(box.origin.x-24,NSMaxY(palm)+18,w+48,14),10,NSFontWeightSemibold,Accent(),NSTextAlignmentCenter);
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event { [self.owner keyDown:event]; }
- (void)geometry:(NSPoint *)center radius:(CGFloat *)radius {
    *center=NSMakePoint(round(NSMidX(self.bounds)),round(NSMidY(self.bounds)));
    *radius=MIN(KvMaxCircleRadius,MIN(NSWidth(self.bounds),NSHeight(self.bounds))/2-4);
}
- (NSBezierPath *)sector:(int)i inner:(CGFloat)inner outer:(CGFloat)outer center:(NSPoint)c {
    NSBezierPath *path=[NSBezierPath bezierPath];
    double start=-M_PI_2+(i-0.5)*M_PI/6;
    for(int j=0;j<=24;j++) { double a=start+j*(M_PI/6)/24; NSPoint p=NSMakePoint(c.x+outer*cos(a),c.y+outer*sin(a)); if(j==0) [path moveToPoint:p]; else [path lineToPoint:p]; }
    for(int j=24;j>=0;j--) { double a=start+j*(M_PI/6)/24; [path lineToPoint:NSMakePoint(c.x+inner*cos(a),c.y+inner*sin(a))]; }
    [path closePath]; return path;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSPoint c; CGFloat r; [self geometry:&c radius:&r];
    CGFloat middle=r*0.69, core=r*0.35;
    KvKey key=self.owner.key;
    KvChord chords[7]; BOOL has[7]; for(int degree=0;degree<7;degree++) has[degree]=kv_chord_extended(key,degree,(int)self.owner.chordExtension,&chords[degree]);   // once, not per sector
    for(int i=0;i<12;i++) for(int ring=0;ring<2;ring++) {
        NSBezierPath *path=[self sector:i inner:ring?core:middle outer:ring?middle:r center:c];
        NSColor *fill=TNSurface();
        // The sector the user picked stays the tonic in every mode; the mode only changes which chords light up.
        BOOL selected=i==key.circle_index && ring==key.minor;
        KvKey sectorKey={i,ring==1,0,0};
        BOOL related=NO, activeChord=NO; const char *degreeLabel=NULL; char degreeText[24];
        for(int degree=0;degree<7;degree++) {
            KvChord chord=chords[degree];
            if(!has[degree]) continue;
            int third=chord.midi[1]-chord.midi[0], fifth=chord.midi[2]-chord.midi[0];
            if(fifth==7 && kv_tonic(sectorKey)==chord.midi[0]%12 && sectorKey.minor==(third==3)) {
                related=YES; snprintf(degreeText,sizeof(degreeText),"%s",chord.degree); degreeLabel=degreeText;
                activeChord=self.owner.keyboardMode.selectedSegment==1 && kv_code_base((int)self.owner.selectedDegree)==degree;
            }
        }
        if(related) fill=[Accent() colorWithAlphaComponent:0.18];
        if(activeChord) fill=[NSColor.systemTealColor colorWithAlphaComponent:0.35];
        if(selected) fill=Accent();
        [fill setFill]; [path fill]; [NSColor.separatorColor setStroke]; path.lineWidth=0.75; [path stroke];
        if(activeChord) { [NSColor.systemTealColor setStroke]; path.lineWidth=2.5; [path stroke]; }
        if(_common[ring]>>i&1u) { // a chord shared with the hovered key
            NSBezierPath *shared=[self sector:i inner:(ring?core:middle)+3 outer:(ring?middle:r)-3 center:c];
            CGFloat dots[]={3,3}; [shared setLineDash:dots count:2 phase:0]; shared.lineWidth=2.5; [NSColor.systemOrangeColor setStroke]; [shared stroke];
        }
        if(i==_hoverIndex && ring==_hoverRing) { NSBezierPath *target=[self sector:i inner:(ring?core:middle)+1.5 outer:(ring?middle:r)-1.5 center:c]; target.lineWidth=3; [NSColor.systemOrangeColor setStroke]; [target stroke]; }
        if(!selected && kv_tonic(sectorKey)==kv_tonic(key)) {
            // The same tonic on the other ring (parallel major/minor): outlined, not filled — it is not this key's chord.
            NSBezierPath *outline=[self sector:i inner:(ring?core:middle)+2 outer:(ring?middle:r)-2 center:c];
            CGFloat dash[]={5,3}; [outline setLineDash:dash count:2 phase:0]; outline.lineWidth=2; [Accent() setStroke]; [outline stroke];
        }
        double a=-M_PI_2+i*M_PI/6;
        CGFloat at=ring?(middle+core)/2:(r+middle)/2;
        CGFloat size=ring?MAX(14,r*0.064):MAX(21,r*0.095);
        NSColor *color=selected ? NSColor.whiteColor : ring?NSColor.secondaryLabelColor:Ink();
        Text([self.owner circleLabelAt:i minor:ring==1],NSMakeRect(c.x+at*cos(a)-50,c.y+at*sin(a)-size*0.65,100,size*1.5),size,ring?NSFontWeightMedium:NSFontWeightSemibold,color,NSTextAlignmentCenter);
        if(selected && !degreeLabel) degreeLabel="тоника"; // e.g. outer A♭ in A♭ harmonic minor: the tonic, not a chord of the key
        if(degreeLabel && (!ring || r>=170 || selected)) Text(S(degreeLabel),NSMakeRect(c.x+at*cos(a)-25,c.y+at*sin(a)+size*.65,50,15),10,NSFontWeightSemibold,selected?NSColor.whiteColor:Accent(),NSTextAlignmentCenter);
    }
    // Key, mode and note glyph form one block that is sized by and centred in the core.
    CGFloat big=MAX(26,core*.62),small=MAX(10,core*.17),glyph=MAX(14,core*.28);
    CGFloat hb=big*1.25,hs=small*1.45,hg=glyph*1.25,top=c.y-(hb+hs+hg)/2;
    Text(S(kv_key_label(key)),NSMakeRect(c.x-core,top,core*2,hb),big,NSFontWeightSemibold,Ink(),NSTextAlignmentCenter);
    Text(S(kv_mode_name(key)),NSMakeRect(c.x-core+6,top+hb,core*2-12,hs),small,NSFontWeightRegular,NSColor.secondaryLabelColor,NSTextAlignmentCenter);
    Text(@"♪",NSMakeRect(c.x-glyph,top+hb+hs,glyph*2,hg),glyph,NSFontWeightMedium,Accent(),NSTextAlignmentCenter);
}
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self.owner]; TNHintHide(self); _hoverIndex=-1; _common[0]=_common[1]=0;
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil], c; CGFloat r;
    [self geometry:&c radius:&r]; CGFloat distance=hypot(p.x-c.x,p.y-c.y);
    if(distance>r) return;
    if(distance<r*0.35) { [self.owner playTonic:self]; return; }
    double a=atan2(p.y-c.y,p.x-c.x)+M_PI_2;
    int i=kv_mod((int)floor(a/(M_PI/6)+0.5),12);
    BOOL minor=distance<r*0.69; NSString *label=[self.owner circleLabelAt:i minor:minor];
    NSRange letter=[@"CDEFGAB" rangeOfString:[label substringToIndex:1]];
    [self.owner circleSelected:i minor:minor spelling:letter.location==NSNotFound?0:(int)letter.location+1];
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityLabel { return T(@"Квартоквинтовый круг. Стрелки влево и вправо выбирают тональность, вверх и вниз — мажор или минор, с Option — лад. Пробел — играть или остановить последовательность; T — тоника; 1–7 — ступени."); }
- (NSString *)accessibilityValue { return S(kv_key_title(self.owner.key)); }
@end

@implementation KvPiano
- (instancetype)initWithFrame:(NSRect)frame { if((self=[super initWithFrame:frame])) { _pressed=-1; _hovered=-1; } return self; }
- (BOOL)isFlipped { return YES; }
- (BOOL)isBlack:(int)midi { int p=midi%12; return p==1||p==3||p==6||p==8||p==10; }
- (NSRect)rectFor:(int)midi {
    CGFloat width=self.bounds.size.width/([self.owner keyboardCount]/12*7);
    int whites=0;
    for(int i=[self.owner keyboardViewStart];i<midi;i++) if(![self isBlack:i]) whites++;
    if([self isBlack:midi]) return NSMakeRect(whites*width-width*0.30,0,width*0.60,self.bounds.size.height*0.62);
    return NSMakeRect(whites*width,0,width,self.bounds.size.height);
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSColor *tonic=[NSColor colorWithCalibratedRed:0.0 green:0.48 blue:0.36 alpha:1];
    int letterBase=[self.owner computerLetterBase];
    static NSString *const letters[18]={@"A",@"W",@"S",@"E",@"D",@"F",@"T",@"G",@"Y",@"H",@"U",@"J",@"K",@"O",@"L",@"P",@";",@"'"};
    for(int pass=0;pass<2;pass++) for(int midi=[self.owner keyboardViewStart];midi<[self.owner keyboardViewStart]+[self.owner keyboardCount];midi++) {
        BOOL black=[self isBlack:midi]; if(black!=(pass==1)) continue;
        if(![self needsToDrawRect:[self rectFor:midi]]) continue;   // untouched by what changed
        NSRect rect=NSInsetRect([self rectFor:midi],0.75,0.75);
        NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:rect xRadius:4 yRadius:4];
        BOOL selected=[self.owner keyboardHighlights:midi];
        BOOL root=selected && midi%12==[self.owner keyboardRoot];
        NSColor *color=black?[NSColor colorWithWhite:0.14 alpha:1]:[NSColor colorWithWhite:0.96 alpha:1];
        if(selected) color=root?tonic:Accent();
        if(self.hovered==midi) color=[color blendedColorWithFraction:.16 ofColor:NSColor.blackColor];
        float motion=_levels[midi];
        // A sounding key glows orange; a melody note outside the chord glows in its own colour and says what it is.
        unsigned char role=_role[midi]; NSColor *glow=role==KV_ROLE_PASSING?TNPassing():role==KV_ROLE_ANTICIPATION?TNAnticipation():[NSColor colorWithCalibratedRed:1 green:.70 blue:.30 alpha:1];
        if(motion>0.01) color=[color blendedColorWithFraction:motion*(role?1:.9) ofColor:glow];
        CGFloat travel=(black?2:3)*motion;
        rect.origin.y+=travel; rect.size.height-=travel;
        path=[NSBezierPath bezierPathWithRoundedRect:rect xRadius:4 yRadius:4];
        [color setFill]; [path fill];
        [[NSColor colorWithWhite:black?0.08:0.69 alpha:1] setStroke]; path.lineWidth=0.6; [path stroke];
        NSColor *labelColor=selected||black||_levels[midi]>.4?NSColor.whiteColor:[NSColor colorWithWhite:0.4 alpha:1];
        Text([self.owner keyboardName:midi],NSMakeRect(rect.origin.x,NSMaxY(rect)-23,rect.size.width,19),black?11:13,selected?NSFontWeightBold:NSFontWeightRegular,labelColor,NSTextAlignmentCenter);
        if(letterBase>=0 && midi>=letterBase && midi<letterBase+18) // the computer key that plays it, as Ableton shows
            Text(letters[midi-letterBase],NSMakeRect(rect.origin.x,rect.origin.y+(black?3:4),rect.size.width,12),black?8.5:9.5,NSFontWeightBold,black||selected?[NSColor colorWithWhite:1 alpha:.75]:[NSColor colorWithWhite:.45 alpha:1],NSTextAlignmentCenter);
        if(role && motion>.3) { // on a white key, in the free strip below the black keys and above the note name
            CGFloat y=black?NSMaxY(rect)-38:MAX(self.bounds.size.height*.62+1,NSMaxY(rect)-37);
            Text(role==KV_ROLE_PASSING?T(@"прох."):T(@"предв."),NSMakeRect(rect.origin.x-2,y,rect.size.width+4,12),black?8:9,NSFontWeightBold,NSColor.whiteColor,NSTextAlignmentCenter);
        }
        else if(selected) {
            [NSColor.whiteColor setFill];
            if(root) Text(@"1",NSMakeRect(NSMidX(rect)-9,NSMaxY(rect)-43,18,18),11,NSFontWeightBold,NSColor.whiteColor,NSTextAlignmentCenter);
            else [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(rect)-2.5,NSMaxY(rect)-35,5,5)] fill];
        }
    }
}
- (int)noteAtPoint:(NSPoint)point {
    for(int pass=1;pass>=0;pass--) for(int midi=[self.owner keyboardViewStart];midi<[self.owner keyboardViewStart]+[self.owner keyboardCount];midi++) if([self isBlack:midi]==(pass==1) && NSPointInRect(point,[self rectFor:midi])) return midi;
    return -1;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(self.keyTracking) [self removeTrackingArea:self.keyTracking];
    self.keyTracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]; [self addTrackingArea:self.keyTracking];
}
- (void)mouseMoved:(NSEvent *)event {
    int note=TNViewCovered(self,event.locationInWindow)?-1:[self noteAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if(note!=self.hovered) { self.hovered=note; self.needsDisplay=YES; }
}
- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseExited:(NSEvent *)event { (void)event; self.hovered=-1; self.needsDisplay=YES; }
- (void)flashNotes:(NSArray<NSNumber *> *)notes {
    for(NSNumber *note in notes) { NSInteger midi=note.integerValue; if(midi>=0 && midi<128) { _levels[midi]=1; _active[midi]=YES; _litAt[midi]=NSProcessInfo.processInfo.systemUptime; } }
    self.needsDisplay=YES; [self displayIfNeeded];
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    int found=[self noteAtPoint:p];
    // A screen key is a key: it sounds and stays lit while the mouse is down, like a MIDI or computer key.
    if(found>=0) { self.pressed=found; [self.owner midiNote:found velocity:100 on:YES]; [self.window makeFirstResponder:self.owner]; }
}
- (void)mouseDragged:(NSEvent *)event {
    int found=[self noteAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    if(found==self.pressed || found<0) return;
    if(self.pressed>=0) [self.owner midiNote:self.pressed velocity:0 on:NO];
    self.pressed=found; [self.owner midiNote:found velocity:100 on:YES];
}
- (void)mouseUp:(NSEvent *)event { (void)event; if(self.pressed>=0) [self.owner midiNote:self.pressed velocity:0 on:NO]; self.pressed=-1; }
- (void)retrigger:(int)midi { if(midi<0 || midi>127) return; _levels[midi]=fminf(_levels[midi],.25f); _litAt[midi]=NSProcessInfo.processInfo.systemUptime; [self invalidateKey:midi]; }
/* A key that changes repaints itself (and whatever its rectangle overlaps), not the whole keyboard. */
- (void)invalidateKey:(int)midi {
    int start=[self.owner keyboardViewStart]; if(midi<start || midi>=start+[self.owner keyboardCount]) return;
    [self setNeedsDisplayInRect:NSInsetRect([self rectFor:midi],-1,-1)];
}
- (float)levelOf:(int)midi { return midi>=0 && midi<128?_levels[midi]:0; }
- (void)setRoles:(const unsigned char *)roles {
    unsigned char next[128]; if(roles) memcpy(next,roles,sizeof(next)); else memset(next,0,sizeof(next));
    for(int midi=0;midi<128;midi++) if(next[midi]!=_role[midi]) { _role[midi]=next[midi]; [self invalidateKey:midi]; }
}
- (unsigned char)roleOf:(int)midi { return midi>=0 && midi<128?_role[midi]:0; }
- (void)setActiveNotes:(NSArray<NSNumber *> *)notes {
    BOOL previous[128]; memcpy(previous,_active,sizeof(previous)); memset(_active,0,sizeof(_active)); memset(_sustain,0,sizeof(_sustain));
    for(NSNumber *note in notes) { NSInteger midi=note.integerValue; if(midi>=0 && midi<128) {
        _active[midi]=YES; _sustain[midi]=YES; if(!previous[midi]) _litAt[midi]=NSProcessInfo.processInfo.systemUptime;
    } }
}
- (void)advanceAnimation {
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    double dt=_lastFrame?fmin(.05,now-_lastFrame):1.0/60; _lastFrame=now;
    BOOL changed=NO,reduce=NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    for(int midi=0;midi<128;midi++) {
        // A sounding note keeps its key down for its whole length; a flash (audition, chord change) is a short press.
        float target=(_sustain[midi] || (_active[midi] && now-_litAt[midi]<.065))?1:0,old=_levels[midi];
        _levels[midi]=reduce?target:old+(target-old)*(1-exp(-dt/(target?.008:.025)));
        if(fabsf(_levels[midi]-target)<.002) _levels[midi]=target;
        if(fabsf(old-_levels[midi])>.001) { changed=YES; [self invalidateKey:midi]; }
    }
    (void)changed;
}
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor]; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityLabel { return [NSString stringWithFormat:T(@"Клавиатура C%d–B%d. %@. %@"),[self.owner keyboardViewStart]/12-1,([self.owner keyboardViewStart]+[self.owner keyboardCount])/12-2,self.owner.keyboardHeading.stringValue,self.owner.keyboardNotes.stringValue]; }
- (NSString *)accessibilityValue {
    NSMutableArray *notes=[NSMutableArray array];
    for(int midi=0;midi<128;midi++) if(_active[midi]) [notes addObject:[NSString stringWithFormat:@"%@%d",[self.owner keyboardName:midi],midi/12-1]];
    return notes.count?[T(@"Звучит: ") stringByAppendingString:[notes componentsJoinedByString:@", "]]:T(@"Нет активных клавиш");
}
@end

static NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *label=[NSTextField labelWithString:text]; label.font=[NSFont systemFontOfSize:size weight:weight]; label.textColor=Ink(); return label;
}
static NSButton *Button(NSString *title, id target, SEL action) {
    NSButton *button=[TNButton buttonWithTitle:title target:target action:action]; button.bezelStyle=NSBezelStyleRounded; button.bordered=NO; button.font=[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]; return button;
}
/* Hover label for a Tonora button (a bubble on hover); plain tooltip for anything else. */
static void Hint(NSButton *button,NSString *text) { if([button isKindOfClass:TNButton.class]) ((TNButton *)button).hint=text; else { button.toolTip=text; [button setAccessibilityLabel:text]; } }
/* Icon-only button: the label appears on hover. Falls back to a text glyph where the system lacks the symbol. */
static NSButton *IconButton(NSString *symbol,NSString *fallback,NSString *tip,id target,SEL action) {
    NSButton *button=Button(@"",target,action);
    NSImage *image=TNIcon(symbol,14);
    if(image) { image.accessibilityDescription=tip; button.image=image; } else button.title=fallback;
    Hint(button,tip); return button;
}
/* Segmented control of icons with a hover label per segment. */
static TNSegmented *IconSegments(NSArray<NSArray<NSString *> *> *items,id target,SEL action) {
    NSMutableArray *labels=[NSMutableArray array]; for(NSUInteger i=0;i<items.count;i++) [labels addObject:@""];
    TNSegmented *control=[TNSegmented segmentedControlWithLabels:labels trackingMode:NSSegmentSwitchTrackingSelectOne target:target action:action];
    NSMutableArray *hints=[NSMutableArray array];
    for(NSUInteger i=0;i<items.count;i++) { NSImage *image=TNIcon(items[i][0],14); if(image) [control setImage:image forSegment:(NSInteger)i]; else [control setLabel:items[i][1] forSegment:(NSInteger)i]; [hints addObject:items[i][2]]; }
    control.hints=hints; return control;
}
/* Popup whose menu shows full titles and whose button shows a short one: @[@[menu title, short title], …]. */
static TNPopup *Choice(NSArray<NSArray<NSString *> *> *items,id target,SEL action,NSString *tip) {
    TNPopup *popup=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for(NSArray<NSString *> *item in items) { [popup addItemWithTitle:item[0]]; popup.lastItem.representedObject=item[1]; }
    popup.target=target; popup.action=action; popup.toolTip=tip; [popup setAccessibilityLabel:tip]; return popup;
}
/* One slot of the progression: position and degree on top, chord name below, shrunk to fit instead of truncated. */
@interface KvChip : TNButton
@property(nonatomic,copy) NSString *degreeText;
@property(nonatomic) BOOL palette;   /* a tile of the «Вне лада» palette: a plain button, no number, no dragging */
@property(nonatomic) BOOL current;
+ (NSFont *)fittedFont:(NSString *)name width:(CGFloat)width;
- (CGFloat)nameWidth;
@end
@implementation KvChip
+ (NSFont *)fittedFont:(NSString *)name width:(CGFloat)width {
    for(CGFloat size=13;size>=9.5;size-=.5) {
        NSFont *font=[NSFont systemFontOfSize:size weight:NSFontWeightSemibold];
        if(ceil([name sizeWithAttributes:@{NSFontAttributeName:font}].width)<=width) return font;
    }
    return nil;
}
- (CGFloat)nameWidth { return NSWidth(self.bounds)-(self.palette?6:10); }
/* Click plays the chord; dragging sideways reorders the progression. */
- (void)mouseDown:(NSEvent *)event {
    if(!self.enabled) return;
    if(self.palette) { [super mouseDown:event]; return; }
    NSPoint start=[self.superview convertPoint:event.locationInWindow fromView:nil]; NSRect origin=self.frame; BOOL dragging=NO;
    self.highlighted=YES;
    while(YES) {
        NSEvent *next=[self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged|NSEventMaskLeftMouseUp];
        if(!next || next.type==NSEventTypeLeftMouseUp) break;
        CGFloat dx=[self.superview convertPoint:next.locationInWindow fromView:nil].x-start.x;
        if(!dragging && fabs(dx)>5) { dragging=YES; self.highlighted=NO; [self.superview addSubview:self positioned:NSWindowAbove relativeTo:nil]; [NSCursor.closedHandCursor push]; }
        if(dragging) { NSRect frame=origin; frame.origin.x+=dx; self.frame=frame; }
    }
    self.highlighted=NO;
    if(dragging) { [NSCursor pop]; [(KvRoot *)self.target chip:self droppedAt:NSMidX(self.frame)]; }
    else [self sendAction:self.action to:self.target];
}
- (void)drawRect:(NSRect)dirtyRect {
    if(!self.current) { [super drawRect:dirtyRect]; return; }
    NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,2) xRadius:8 yRadius:8];
    [Accent() setFill]; [path fill];
    [self drawLabelInRect:self.bounds color:NSColor.whiteColor];
}
- (void)drawLabelInRect:(NSRect)rect color:(NSColor *)color {
    (void)rect; NSRect b=self.bounds;
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.alignment=NSTextAlignmentCenter; style.lineBreakMode=NSLineBreakByTruncatingTail;
    NSString *top=self.palette?(self.degreeText?:@""):self.degreeText.length?[NSString stringWithFormat:@"%ld · %@",(long)self.tag+1,self.degreeText]:[NSString stringWithFormat:@"%ld",(long)self.tag+1];
    CGFloat inset=self.palette?3:5;
    [top drawInRect:NSMakeRect(inset,4,NSWidth(b)-2*inset,13) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:self.palette?9:9.5 weight:NSFontWeightMedium],NSForegroundColorAttributeName:[color colorWithAlphaComponent:color.alphaComponent*.65],NSParagraphStyleAttributeName:style}];
    NSFont *font=[KvChip fittedFont:self.title width:[self nameWidth]]?:[NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold];
    [self.title drawInRect:NSMakeRect(inset,16,NSWidth(b)-2*inset,18) withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:style}];
}
@end
@interface KvPanelContent : NSView
@end
@implementation KvPanelContent
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)rect { [TNSurface() setFill]; NSRectFill(rect); }
@end
static NSTextField *PanelLabel(NSView *view,NSString *text,NSRect frame,CGFloat size) {
    NSTextField *label=Label(text,size,NSFontWeightRegular); label.frame=frame; [view addSubview:label]; return label;
}
static NSPanel *Panel(NSString *title,CGFloat width,CGFloat height) {
    NSPanel *panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,width,height) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    panel.title=title; panel.contentView=[[KvPanelContent alloc] initWithFrame:NSMakeRect(0,0,width,height)];
    return panel;
}

/* All keyboard shortcuts of the app on one card over the window: ⌘/ anywhere, the "?" buttons, Справка menu. */
@interface KvShortcutsCard : NSView
@property(nonatomic,weak) KvRoot *owner;
@property(nonatomic) NSInteger tab;   // 0 shortcuts, 1 the circle of fifths, 2 the arranger
- (CGFloat)columnsHeight:(CGFloat)column;   /* how tall the tab's columns are at this width */
@end
typedef struct { const char *key,*text; } KvShortcut;
static const KvShortcut KvGeneral[]={
    {"Пробел","играть · стоп"},{"Esc","стоп · закрыть эту карточку"},{"← →","соседняя тональность"},{"↑ ↓","мажор · минор"},{"⌥↑ ⌥↓","лад"},
    {"1–7","послушать ступень"},{"⇧1–⇧7","добавить ступень"},{"T","тоника"},{"L","повтор"},{"⌫","удалить выбранный аккорд"},
    {"⌘← ⌘→","переставить аккорд"},{"⌘↑ ⌘↓","регистр клавиатуры"},{"⌘N · ⇧⌘N","новые аккорды · дополнить"},{"⌘Z · ⌘⇧Z","вернуть · повторить"},
    {"⌘R","новая вариация рисунка"},{"⌘K","метроном · клик, пока идёт игра"},{"⇧⌘K","ударные · по стилю или бит"},{"⌘C · ⇧⌘O","скопировать MIDI-клип · импорт MIDI"},{"⌘O · ⌘S","открыть · сохранить песню .tonora"},{"⌘1 ⌘2 ⌘3 · ⇧⌘A","круг · ролл · песня · в аранжировщик"},{"M","клавиатура компьютера"},{"⌘/","эта карточка"},{NULL,NULL}};
static const KvShortcut KvRollKeys[]={
    {"Двойной щелчок в сетке","добавить ноту"},{"Двойной щелчок по ноте","удалить ноту"},{"Перетащить ноту","время и высота"},
    {"Перетащить с ⌥","копия"},{"Правый край ноты","длина по сетке"},{"Рамка · ⇧-клик","выделение"},{"⌘A · ⌘D","выделить всё · дублировать"},
    {"⌫","удалить выделенное"},{"← →","сдвиг на шаг сетки"},{"↑ ↓ · ⇧↑ ⇧↓","полутон или ступень · октава"},{"⌥↑ ⌥↓","громкость"},
    {"⌘+колесо · ⌘+ ⌘−","масштаб времени"},{"⌘⌥+колесо · ⌘⌥±","высота строк"},{"Колесо · ⇧+колесо","прокрутка"},{"⌘0","4 такта, высота по нотам"},
    {"⌘F","следовать за курсором"},{"F","свернуть до гаммы"},{NULL,NULL}};
static const KvShortcut KvSongKeys[]={
    {"T · I · P","инструменты ▸ ✂ ✎"},{"⌘ при щелчке","ножницы на миг"},{"Z · ⌘← ⌘→","вся песня · зум шагом"},{"⌘+колесо · щипок","зум к курсору"},
    {"Щелчок по линейке","играть отсюда · протяжка — перемотка"},{"⇧-протяжка по линейке","цикл · ↻ или L — по кругу"},{"⇧-щелчок · ⌘A · Esc","диапазон · все · одна"},
    {"⌘D · ⌫ · ⌘T","копия · удалить · разрез"},{"⌥⌘← ⌥⌘→","переставить секцию"},{"Углы региона","повторы · длина · начало"},
    {"Регион на дорожке","сдвиг по времени"},{"⌃ при жесте","без привязки"},{"⌘R после формы","другой вариант формы"},{"Щелчок ×2 в полосе","точка автоматизации"},{NULL,NULL}};
static const KvShortcut KvComputerKeys[]={
    {"A S D F G H J K L ; '","белые клавиши от до"},{"W E · T Y U · O P","чёрные клавиши"},{"Z X","октава ниже · выше"},{"C V","сила удара −20 · +20"},{NULL,NULL}};
@implementation KvShortcutsCard
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)mouseDown:(NSEvent *)event {
    NSPoint point=[self convertPoint:event.locationInWindow fromView:nil];
    for(NSInteger i=0;i<3;i++) if(NSPointInRect(point,[self tabRect:i])) { self.tab=i; self.needsDisplay=YES; return; }   // the card takes the new tab's size on the next draw
    [self.owner toggleShortcuts:nil];
}
static NSString *const KvCardTabs[]={@"Сочетания клавиш",@"Квинтовый круг",@"Аранжировщик"};
- (NSRect)tabRect:(NSInteger)i {
    NSRect card=[self cardRect]; CGFloat x=card.origin.x+24;
    for(NSInteger j=0;j<=i;j++) {
        CGFloat w=ceil([T(KvCardTabs[j]) sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:17 weight:NSFontWeightSemibold]}].width);
        if(j==i) return NSMakeRect(x,card.origin.y+12,w,32);
        x+=w+28;
    }
    return NSZeroRect;
}
/* The card is as large as its text needs: as wide as the window allows (up to 1320 points), as tall as the longest column once
   every line has wrapped to its width — nothing is cut off. */
- (NSRect)cardRect {
    CGFloat w=MIN(NSWidth(self.bounds)-40,1320),column=(w-48-2*24)/3,h=MIN(NSHeight(self.bounds)-24,56+[self columnsHeight:column]+28);
    return NSMakeRect(round(NSMidX(self.bounds)-w/2),round(NSMidY(self.bounds)-h/2),w,h);
}
static const char *const KvCircleHelp[][2]={
    {"Что это за круг","Все двенадцать тональностей стоят по кругу так, что каждый шаг по часовой стрелке — квинта вверх: C → G → D → A… Против часовой — квинта вниз (кварта вверх): C → F → B♭… Соседние тональности отличаются одним знаком при ключе: вправо прибавляется диез, влево — бемоль. Внизу круг смыкается — там одни и те же клавиши пишутся двумя способами (F♯ = G♭).\nВнешнее кольцо — мажорные тональности, внутреннее — параллельные миноры с теми же знаками: C и Am, G и Em."},
    {"Почему всё строится от него","Аккорды тональности на круге — соседи. Тоника в середине, слева от неё субдоминанта IV, справа доминанта V, а под ними на внутреннем кольце — ii, vi и iii. Шесть соседних секторов дают все мажорные и минорные трезвучия тональности; седьмое, уменьшённое vii°, своего сектора не имеет.\nПоэтому в Tonora всё идёт от нажатого сектора: гамма и ноты на клавиатуре, номера ступеней, генератор и готовые прогрессии, аккорды вне лада, рисунок рук и арпеджио. Другой лад — тот же круг, только подсвечено другое окно соседей."},
    {"Как этим пользоваться","Щелчок по сектору выбирает тонику, центр играет её трезвучие; ← → шагают по кругу, ↑ ↓ меняют мажор и минор.\nСамое сильное тяготение — шаг против часовой стрелки: V → I, ii → V → I. На нём держатся каденции и цепочки доминант, поэтому хорошие прогрессии часто идут по кругу вниз.\nЧем ближе две тональности, тем больше у них общих аккордов и тем мягче переход. Наведите на чужой сектор — круг обведёт общие аккорды и подскажет путь модуляции."}};
static const char *const KvArrangerHelp[][2]={
    {"С чего начать","⌘3 открывает аранжировщик. ⇧⌘A делает последовательность с круга секцией песни; «✦ Сгенерировать песню» на пустой дорожке «Мелодия» собирает целую песню из аккордов круга — интро, куплеты, припевы, бридж, переходы. «Структура ▾» пересобирает песню по форме вокруг выбранного куплета, ⌘R даёт другой вариант. «+» после последней секции показывает, что может быть дальше: щелчок вставляет, Пробел над подсказкой — послушать.\nТри дорожки: «Мелодия» — правая рука, «Бас» — левая, «Ударные» — бит секций. У каждой M (выкл), S (соло) и фейдер — они действуют сразу, даже во время игры. «A» открывает кривую громкости дорожки, ⌁ — кривую темпа; двойной щелчок по полосе ставит точку, ⌫ удаляет.\nДвойной щелчок, Enter, ✎ или «Открыть в ролле» открывают пиано-ролл под дорожками на руке той дорожки, по которой щёлкнули; «Свернуть» или Esc убирают его, ⌘2 — ролл на всё окно. Правки нот остаются у секции (✎ на маркере), ↺ возвращает рисунок."},
    {"Секции и регионы","Щелчок по маркеру выбирает секцию, по региону — её дорожку; ⇧-щелчок — диапазон, ⌘A — все. Перетаскивание маркера или региона двигает секцию, ⌥ — копирует, бросок на середину другой меняет их местами. Правый край — длина, левый — начало в прогрессии, маленький верхний правый угол региона — повторы. Ножницы (I, ⌘-щелчок или ✂ на регионе) режут там, где щёлкнуть; карандаш (P) ставит последовательность с круга новой секцией. Правый щелчок — меню секции и региона: разрезать, дублировать, удалить, добавить после, вставить переход, цикл по секции, M региона, бит ударных.\nВкладка «Секция» справа: тип, повторы, громкость, регистр, вид перехода, M и громкость регионов, ударные секции («Как у песни», свой бит, тихо, без). Рисунок и фактура внизу окна меняются у всей песни, когда выбрана одна секция, и только у выделенных, когда их несколько."},
    {"Игра, цикл и экспорт","Пробел играет от курсора; щелчок по линейке ставит курсор, двойной — играет отсюда, во время игры щелчок переносит игру. С ↻ и циклом Пробел играет от начала цикла и крутит его. Цикл рисуется протяжкой по полосе над номерами тактов; за середину он переносится, за края растягивается, щелчок по нему включает и выключает ↻, правый щелчок — «Снять цикл». Home — в начало, ⌥Пробел — только выбранная секция.\nМетроном (⌘K) — клик, он щёлкает только пока идёт игра; сетка и отсчёт такта — в его меню. Ударные (⇧⌘K) — своя кнопка и меню: по стилю или один бит; под песней у каждой секции свой. Громкость ритма — в FX (⌘,).\nМасштаб: ⌘+ и ⌘−, ⌘+колесо или щипок, Z — вся песня; привязка — в меню «Умная · такт · доля · 1/8», ⌃ во время жеста — без привязки. ⇧⌘E экспортирует песню в MIDI с ударными и маркерами, кнопка ↓ — одну дорожку. ⌘Z отменяет правки песни."},
};
static BOOL KvMeasuring;   /* the card's helpers only measure (cardRect sizes the card to its text) */
/* Wrapped text: its height at this width; drawn unless measuring. */
static CGFloat Wrapped(NSString *text,CGFloat x,CGFloat y,CGFloat width,CGFloat size,NSFontWeight weight,NSColor *color) {
    NSDictionary *a=@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:weight],NSForegroundColorAttributeName:color};
    CGFloat h=ceil([text boundingRectWithSize:NSMakeSize(width,10000) options:NSStringDrawingUsesLineFragmentOrigin attributes:a].size.height);
    if(!KvMeasuring) [text drawWithRect:NSMakeRect(x,y,width,h) options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
    return h;
}
static CGFloat DrawParagraphs(NSString *title,NSString *body,CGFloat x,CGFloat y,CGFloat width) {
    if(!KvMeasuring) Text(title,NSMakeRect(x,y,width,18),12,NSFontWeightBold,Accent(),NSTextAlignmentLeft); y+=24;
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.lineSpacing=2; style.paragraphSpacing=12;
    NSDictionary *attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:12],NSForegroundColorAttributeName:NSColor.labelColor,NSParagraphStyleAttributeName:style};
    NSRect rect=[body boundingRectWithSize:NSMakeSize(width,10000) options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes];
    if(!KvMeasuring) [body drawWithRect:NSMakeRect(x,y,width,ceil(rect.size.height)) options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes];
    return y+ceil(rect.size.height);
}
static CGFloat DrawShortcuts(NSString *title,const KvShortcut *rows,CGFloat x,CGFloat y,CGFloat width) {
    if(!KvMeasuring) Text(title,NSMakeRect(x,y,width,18),12,NSFontWeightBold,Accent(),NSTextAlignmentLeft); y+=24;
    for(int i=0;rows[i].key;i++) {   // a line too long for its column wraps under itself instead of being cut
        CGFloat k=Wrapped(T(@(rows[i].key)),x,y,width*.42-6,11.5,NSFontWeightSemibold,NSColor.labelColor);
        CGFloat t=Wrapped(T(@(rows[i].text)),x+width*.42,y,width*.58,11.5,NSFontWeightRegular,NSColor.secondaryLabelColor);
        y+=MAX(18,MAX(k,t)+3);
    }
    return y;
}
- (CGFloat)columnsHeight:(CGFloat)column { KvMeasuring=YES; CGFloat h=[self drawColumnsAtX:0 top:0 column:column]; KvMeasuring=NO; return h; }
/* The three columns of the tab shown, from `top`; returns how far down the longest one reaches (below `top`). */
- (CGFloat)drawColumnsAtX:(CGFloat)x top:(CGFloat)top column:(CGFloat)column {
    CGFloat bottom=top;
    if(self.tab==1 || self.tab==2) { for(int i=0;i<3;i++) bottom=MAX(bottom,DrawParagraphs(T(@(self.tab==1?KvCircleHelp[i][0]:KvArrangerHelp[i][0])),T(@(self.tab==1?KvCircleHelp[i][1]:KvArrangerHelp[i][1])),x+i*(column+24),top,column)); return bottom-top; }
    bottom=MAX(bottom,DrawShortcuts(T(@"Везде"),KvGeneral,x,top,column));
    bottom=MAX(bottom,DrawShortcuts(T(@"Пиано-ролл"),KvRollKeys,x+column+24,top,column));
    CGFloat below=DrawShortcuts(T(@"Клавиатура компьютера · M"),KvComputerKeys,x+2*(column+24),top,column);
    bottom=MAX(bottom,DrawShortcuts(T(@"Песня · аранжировщик"),KvSongKeys,x+2*(column+24),below+14,column));
    return bottom-top;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; [[NSColor.blackColor colorWithAlphaComponent:.28] setFill]; NSRectFillUsingOperation(self.bounds,NSCompositingOperationSourceOver);
    NSRect card=[self cardRect]; NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:card xRadius:14 yRadius:14];
    [TNSurface() setFill]; [path fill]; [[NSColor.labelColor colorWithAlphaComponent:.18] setStroke]; [path stroke];
    for(NSInteger i=0;i<3;i++) {
        NSRect tab=[self tabRect:i];
        Text(T(KvCardTabs[i]),NSMakeRect(tab.origin.x,tab.origin.y+4,tab.size.width+2,24),17,NSFontWeightSemibold,i==self.tab?NSColor.labelColor:NSColor.tertiaryLabelColor,NSTextAlignmentLeft);
        if(i==self.tab) { [Accent() setFill]; NSRectFill(NSMakeRect(tab.origin.x,NSMaxY(tab)-3,tab.size.width,2)); }
    }
    Text(T(@"Tab — вкладка · Esc, ⌘/ или щелчок — закрыть"),NSMakeRect(NSMaxX(card)-344,card.origin.y+20,320,18),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NSTextAlignmentRight);
    CGFloat column=(card.size.width-48-2*24)/3;
    [self drawColumnsAtX:card.origin.x+24 top:card.origin.y+56 column:column];
}
@end

@implementation KvRoot
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        kv_english=TNEnglish();   // the C core names keys and explains chords in the interface language
        _key=(KvKey){0,false,0,0}; _humanize=YES; _keyboardBase=60; _visualEvent=-1; _selectedDegree=0; _progression=[NSMutableArray array]; _progressionButtons=[NSMutableArray array];
        _audio=kv_audio_create();
        NSString *pianoDirectory=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Piano"];
        if(_audio && !kv_audio_load_piano(_audio,pianoDirectory.fileSystemRepresentation)) {
            kv_audio_destroy(_audio); _audio=NULL;
        }
        if(_audio) {
            NSString *resources=NSBundle.mainBundle.resourcePath;
            if(!kv_audio_load_instrument(_audio,1,[[resources stringByAppendingPathComponent:@"CP80"] fileSystemRepresentation]) || !kv_audio_load_instrument(_audio,2,[[resources stringByAppendingPathComponent:@"Pianet"] fileSystemRepresentation])) {
                kv_audio_destroy(_audio); _audio=NULL;
            }
            // Strings are optional: a build without their recordings still plays the keyboards.
            if(_audio) _stringsAvailable=kv_audio_load_instrument(_audio,KV_INSTRUMENT_STRINGS,[[resources stringByAppendingPathComponent:@"Strings"] fileSystemRepresentation]);
            // Without the percussion recordings the acoustic beats play on the synthesized kit.
            if(_audio) _drumsAvailable=kv_audio_load_drums(_audio,[[resources stringByAppendingPathComponent:@"Percussion"] fileSystemRepresentation]);
            if(_audio) kv_audio_load_drums_electronic(_audio,[[resources stringByAppendingPathComponent:@"Percussion808"] fileSystemRepresentation]);   // the 808 for house, hip-hop and trip-hop; without it the synthesized kit
        }
        _effects=(KvEffects){.10,.10,.3}; _tempo=100;
        _song=calloc(1,sizeof(KvSong)); kv_song_reset(_song); _sectionTracks=[NSMutableDictionary dictionary]; _editingSection=-1; _songUndo=[NSMutableArray array]; _songRedo=[NSMutableArray array]; _suggestSeed=arc4random();
        for(int i=0;i<128;i++) { _computerKey[i]=-1; _soundingEvent[i]=-1; } _computerBase=60; _computerVelocity=100;
        _registerControl=[TNSegmented segmentedControlWithLabels:@[@"C2",@"C3",@"C4",@"C5",@"C6"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(registerChanged:)];
        _registerControl.toolTip=T(@"Регистр клавиатуры и воспроизведения · ⌘↓ / ⌘↑"); [_registerControl setAccessibilityLabel:T(@"Регистр")]; [self addSubview:_registerControl];
        _soundSettingsButton=IconButton(@"slider.horizontal.3",@"FX",T(@"Звук: инструмент, исполнение, реверберация, дилей"),self,@selector(showSoundSettings:)); [self addSubview:_soundSettingsButton];
        _circle=[[KvCircle alloc] initWithFrame:NSZeroRect]; _circle.owner=self; [_circle setAccessibilityHelp:T(KvCircleHint)]; [self addSubview:_circle];
        _piano=[[KvPiano alloc] initWithFrame:NSZeroRect]; _piano.owner=self; [self addSubview:_piano];
        _keyboardMode=[TNSegmented segmentedControlWithLabels:@[T(@"Ноты тональности"),T(@"Ноты аккорда")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(keyboardModeChanged:)];
        _keyboardMode.selectedSegment=0; [self addSubview:_keyboardMode];
        _keyboardHeading=Label(@"",15,NSFontWeightSemibold); [self addSubview:_keyboardHeading];
        _keyboardNotes=Label(@"",13,NSFontWeightMedium); _keyboardNotes.textColor=NSColor.secondaryLabelColor; [self addSubview:_keyboardNotes];
        _mode=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [_mode addItemsWithTitles:@[T(@"Мажор · ионийский"),T(@"Минор · эолийский"),T(@"Дорийский"),T(@"Фригийский"),T(@"Лидийский"),T(@"Миксолидийский"),T(@"Локрийский"),T(@"Гармонический минор"),T(@"Мелодический минор"),T(@"Мажорная пентатоника"),T(@"Минорная пентатоника")]];
        _mode.target=self; _mode.action=@selector(modeChanged:); _mode.toolTip=T(@"Лад меняет ноты и аккорды. Мелодический минор: восходящая форма в обоих направлениях."); [_mode setAccessibilityLabel:T(@"Лад")]; [self addSubview:_mode];
        _soundButton=IconButton(@"speaker.wave.2.fill",@"♪",T(@"Прослушать тонику · T"),self,@selector(playTonic:));
        _shortcutsButton=IconButton(@"questionmark.circle",@"?",T(@"Все сочетания клавиш · ⌘/"),self,@selector(toggleShortcuts:)); [self addSubview:_shortcutsButton];
        _computerKeyboardButton=IconButton(@"keyboard",@"⌨",T(@"Играть с клавиатуры компьютера · M"),self,@selector(toggleComputerKeyboard:)); [_computerKeyboardButton setButtonType:NSButtonTypePushOnPushOff]; [self addSubview:_computerKeyboardButton]; [self addSubview:_soundButton];
        _heading=Label(@"",24,NSFontWeightBold); [self addSubview:_heading];
        _signature=Label(@"",12,NSFontWeightRegular); _signature.textColor=NSColor.secondaryLabelColor; [self addSubview:_signature];
        _scaleNames=Label(@"",16,NSFontWeightMedium); _scaleNames.alignment=NSTextAlignmentCenter; [self addSubview:_scaleNames];
        _chordHeading=Label(T(@"Аккорды тональности"),15,NSFontWeightSemibold); [self addSubview:_chordHeading];
        _hint=Label(T(@"Нажмите аккорд: ноты на клавиатуре + звук"),10,NSFontWeightRegular); _hint.textColor=NSColor.secondaryLabelColor; [self addSubview:_hint];
        NSMutableArray *chords=[NSMutableArray array], *adds=[NSMutableArray array];
        for(int i=0;i<7;i++) {
            NSButton *chord=Button(@"",self,@selector(chordClicked:)); chord.tag=i; chord.alignment=NSTextAlignmentLeft; chord.font=[NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightMedium]; [chords addObject:chord]; [self addSubview:chord];
            NSButton *add=IconButton(@"plus",@"+",T(@"Добавить в последовательность"),self,@selector(addChord:)); add.tag=i; [adds addObject:add]; [self addSubview:add];
        }
        _chordButtons=chords; _addButtons=adds;
        _scaleButton=IconButton(@"tonora.scale",@"♪",T(@"Прослушать гамму"),self,@selector(playScale:)); [self addSubview:_scaleButton];
        _viewSwitch=IconSegments(@[@[@"tonora.circle",T(@"Круг"),T(@"Круг квинт · тональность и аккорды")],@[@"tonora.roll",T(@"Ролл"),T(@"Пиано-ролл · редактор дорожки")],@[@"rectangle.split.3x1",T(@"Песня"),T(@"Аранжировщик · песня из секций · ⌘3")]],self,@selector(viewChanged:));
        _viewSwitch.selectedSegment=0; [_viewSwitch setAccessibilityLabel:T(@"Вид")]; [self addSubview:_viewSwitch];
        _roll=[[KvPianoRoll alloc] initWithFrame:NSZeroRect]; _roll.owner=self; _roll.hidden=YES; [self addSubview:_roll];
        _arranger=[[KvArranger alloc] initWithFrame:NSZeroRect]; _arranger.owner=self; _arranger.hidden=YES; [self addSubview:_arranger];
        _arranger.sectionPanel.hidden=YES; [self addSubview:_arranger.sectionPanel];
        _track=calloc(1,sizeof(KvPerformance)); _roll.track=_track; _trackUndo=[NSMutableArray array]; _trackRedo=[NSMutableArray array]; _speed=1;
        _inspectorTabs=[TNSegmented segmentedControlWithLabels:@[T(@"Аккорды"),T(@"Вне лада"),@"MIDI",T(@"Секция")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(inspectorTabChanged:)];
        _chromaticChips=[NSMutableArray array];
        NSMutableArray *headers=[NSMutableArray array];
        for(NSString *title in @[T(@"Побочные доминанты"),T(@"Заимствованные"),T(@"Тритоновые замены")]) { NSTextField *h=Label(title,12,NSFontWeightSemibold); h.textColor=NSColor.secondaryLabelColor; [self addSubview:h]; [headers addObject:h]; }
        _chromaticHeaders=headers;
        _chromaticStory=Label(@"",11,NSFontWeightRegular); _chromaticStory.textColor=NSColor.secondaryLabelColor; _chromaticStory.lineBreakMode=NSLineBreakByWordWrapping; _chromaticStory.maximumNumberOfLines=5; [self addSubview:_chromaticStory];
        _chromaticTitle=Label(@"",13,NSFontWeightSemibold); _chromaticTitle.lineBreakMode=NSLineBreakByTruncatingTail; [self addSubview:_chromaticTitle];
        _chromaticAddButton=Button(T(@"Добавить"),self,@selector(addChromatic:)); ((TNButton *)_chromaticAddButton).hint=T(@"Добавить выбранный аккорд в конец последовательности · двойной щелчок по плитке делает то же"); [self addSubview:_chromaticAddButton];
        _inspectorTabs.selectedSegment=0; [_inspectorTabs setAccessibilityLabel:T(@"Вкладки инспектора")]; [self addSubview:_inspectorTabs];
        _midi=[KvMidi new]; _detectedDegree=-1;
        __weak KvRoot *weakRoot=self;
        _midi.onNote=^(int midi,int velocity,BOOL on) { [weakRoot midiNote:midi velocity:velocity on:on]; };
        _midi.onControl=^(int controller,int value) { [weakRoot midiControl:controller value:value]; };
        _midi.onDevicesChanged=^{ [weakRoot refreshMidiDevices]; };
        NSMutableArray *midiViews=[NSMutableArray array];
        NSTextField *(^section)(NSString *)=^NSTextField *(NSString *title) { NSTextField *label=Label(title,13,NSFontWeightSemibold); [self addSubview:label]; [midiViews addObject:label]; return label; };
        section(T(@"Файл"));
        _midiExportButton=IconButton(@"square.and.arrow.down",@"↓",T(@"Сохранить .mid… · обе руки, темп, размер, знаки при ключе"),self,@selector(exportMidi:)); [self addSubview:_midiExportButton]; [midiViews addObject:_midiExportButton];
        _midiCopyButton=IconButton(@"doc.on.doc",@"⧉",T(@"Скопировать MIDI-клип · ⌘C · вставьте в DAW"),self,@selector(copyMidi:)); [self addSubview:_midiCopyButton]; [midiViews addObject:_midiCopyButton];
        _midiDragHandle=[[KvMidiDragHandle alloc] initWithFrame:NSZeroRect]; _midiDragHandle.title=T(@"⠿  MIDI-клип"); _midiDragHandle.hint=T(@"Перетащите на дорожку DAW или в Finder");
        _midiDragHandle.provider=^NSURL *{ KvRoot *root=weakRoot; return root?[root midiClipURLSelectionOnly:NO]:nil; }; [self addSubview:_midiDragHandle]; [midiViews addObject:_midiDragHandle];
        _midiExportInfo=Label(@"",11,NSFontWeightRegular); _midiExportInfo.textColor=NSColor.secondaryLabelColor; _midiExportInfo.lineBreakMode=NSLineBreakByWordWrapping; _midiExportInfo.maximumNumberOfLines=2; [self addSubview:_midiExportInfo]; [midiViews addObject:_midiExportInfo];
        section(T(@"Выход"));
        _midiDestination=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO]; _midiDestination.target=self; _midiDestination.action=@selector(midiDestinationChanged:); _midiDestination.toolTip=T(@"Куда отправлять ноты. Виртуальный порт «Tonora» виден в любой DAW как MIDI-вход"); [self addSubview:_midiDestination]; [midiViews addObject:_midiDestination];
        _midiOutToggle=[NSButton checkboxWithTitle:T(@"Отправлять ноты при игре") target:self action:@selector(midiOutToggled:)]; _midiOutToggle.toolTip=T(@"Всё, что звучит, уходит нотами в порт «Tonora» и в выбранное устройство: левая рука — канал 1, правая — канал 2"); _midiOutToggle.font=[NSFont systemFontOfSize:12]; [self addSubview:_midiOutToggle]; [midiViews addObject:_midiOutToggle];
        section(T(@"Вход"));
        _midiInToggle=[NSButton checkboxWithTitle:T(@"Принимать ноты") target:self action:@selector(midiInToggled:)]; _midiInToggle.font=[NSFont systemFontOfSize:12]; [self addSubview:_midiInToggle]; [midiViews addObject:_midiInToggle];
        _chordKeysToggle=[NSButton checkboxWithTitle:T(@"Аккорд одной клавишей") target:self action:@selector(chordKeysToggled:)]; _chordKeysToggle.font=[NSFont systemFontOfSize:12];
        _chordKeysToggle.toolTip=T(@"Клавиша-ступень лада играет свой аккорд с выбранной сложностью гармонии: MIDI-клавиатура, клавиатура компьютера и экранная клавиатура. Клавиша вне лада — одна нота");
        [self addSubview:_chordKeysToggle]; [midiViews addObject:_chordKeysToggle];
        _midiChordLabel=Label(@"—",22,NSFontWeightBold); [self addSubview:_midiChordLabel]; [midiViews addObject:_midiChordLabel];
        _midiHeldLabel=Label(T(@"Сыгранные ноты звучат роялем Tonora и подсвечиваются на клавиатуре; аккорд из двух и более нот называется здесь."),11,NSFontWeightRegular); _midiHeldLabel.textColor=NSColor.secondaryLabelColor; _midiHeldLabel.lineBreakMode=NSLineBreakByWordWrapping; _midiHeldLabel.maximumNumberOfLines=3; [self addSubview:_midiHeldLabel]; [midiViews addObject:_midiHeldLabel];
        _midiAddChordButton=Button(T(@"Добавить"),self,@selector(addDetectedChord:)); ((TNButton *)_midiAddChordButton).hint=T(@"Добавить сыгранный аккорд в конец последовательности"); [self addSubview:_midiAddChordButton]; [midiViews addObject:_midiAddChordButton];
        _midiStatus=Label(@"",11,NSFontWeightRegular); _midiStatus.textColor=NSColor.secondaryLabelColor; _midiStatus.lineBreakMode=NSLineBreakByWordWrapping; _midiStatus.maximumNumberOfLines=2; [self addSubview:_midiStatus]; [midiViews addObject:_midiStatus];
        _midiViews=midiViews; for(NSView *view in midiViews) view.hidden=YES;
        _midi.destinationIndex=0;
        _playButton=IconButton(@"play.fill",@"▶",T(@"Играть · Пробел"),self,@selector(togglePlayback:)); _playButton.bezelColor=Accent(); [self addSubview:_playButton];
        _performanceChoice=[self makeTextureMenu]; [self addSubview:_performanceChoice];
        _arpeggioChoice=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for(int i=0;i<KV_ARP_COUNT;i++) { [_arpeggioChoice addItemWithTitle:[NSString stringWithFormat:T(@"Арпеджио %@"),[S(kv_arpeggio_name((KvArpeggioPattern)i)) lowercaseString]]]; _arpeggioChoice.lastItem.representedObject=S(kv_arpeggio_name((KvArpeggioPattern)i)); }
        [_arpeggioChoice.menu addItem:NSMenuItem.separatorItem]; [_arpeggioChoice addItemWithTitle:T(@"Шаблон рисунка")]; [_arpeggioChoice addItemWithTitle:T(@"Вариация")];
        _arpeggioChoice.target=self; _arpeggioChoice.action=@selector(arpeggioChanged:); _arpeggioChoice.toolTip=T(@"Порядок нот арпеджио"); [_arpeggioChoice setAccessibilityLabel:T(@"Рисунок арпеджио")]; [self addSubview:_arpeggioChoice];
        _divisionChoice=Choice(@[@[T(@"Восьмые"),T(@"8-е")],@[T(@"Шестнадцатые"),T(@"16-е")],@[T(@"Триоли"),T(@"Триоли")]],self,@selector(arpeggioDivisionChanged:),T(@"Длительность каждой ноты арпеджио")); [self addSubview:_divisionChoice];
        _meterChoice=Choice(@[@[T(@"4/4 · четыре четверти"),@"4/4"],@[T(@"3/4 · три четверти"),@"3/4"],@[T(@"6/8 · шесть восьмых"),@"6/8"]],self,@selector(meterChanged:),T(@"Размер такта")); [self addSubview:_meterChoice];
        _lengthChoice=Choice(@[@[T(@"Аккорд длится 1 долю"),T(@"1 доля")],@[T(@"Аккорд длится 2 доли"),T(@"2 доли")],@[T(@"Аккорд длится 1 такт"),T(@"1 такт")],@[T(@"Аккорд длится 2 такта"),T(@"2 такта")]],self,@selector(lengthChanged:),T(@"Сколько звучит один аккорд последовательности")); [self addSubview:_lengthChoice];
        _fillChoice=Choice(@[@[T(@"Проигрыши по стилю"),T(@"Проигр. · стиль")],@[T(@"Без проигрышей"),T(@"Без проигр.")],@[T(@"Проигрыш каждые 4 такта"),T(@"Проигр. · 4 т")],@[T(@"Проигрыш каждые 2 такта"),T(@"Проигр. · 2 т")],@[T(@"Проигрыш каждый такт"),T(@"Проигр. · 1 т")]],self,@selector(fillChanged:),T(@"Проигрыш — короткий ход к следующему аккорду в конце фразы")); [self addSubview:_fillChoice];
        _harmonyChoice=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];
        // Full names in the menu, short ones on the button.
        for(NSArray *item in @[@[T(@"Трезвучия · 3 ноты"),T(@"Трезвучия · 3")],@[T(@"Септаккорды · 7"),T(@"Септаккорды · 7")],@[T(@"Нонаккорды · 9"),T(@"Нонаккорды · 9")],@[T(@"Ундецимаккорды · 11"),T(@"Ундецим. · 11")],@[T(@"Терцдецимаккорды · 13"),T(@"Терцдецим. · 13")]]) { [_harmonyChoice addItemWithTitle:item[0]]; _harmonyChoice.lastItem.representedObject=item[1]; }
        _harmonyChoice.toolTip=T(@"Трезвучия / септаккорды / нонаккорды / 11 / 13. Все ступени в выбранной тональности");
        _harmonyChoice.target=self; _harmonyChoice.action=@selector(harmonyChanged:); [self addSubview:_harmonyChoice];
        _arrangeButton=IconButton(@"dice",@"↻",T(@"Новая вариация рисунка · ⌘R. Аккорды сохраняются"),self,@selector(regenerateArrangement:)); [self addSubview:_arrangeButton];
        _patternChoice=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for(int i=0;i<KV_PATTERN_COUNT;i++) { [_patternChoice addItemWithTitle:[NSString stringWithFormat:@"%@ · %@",S(kv_pattern_russian((KvPianoPattern)i)),S(kv_pattern_name((KvPianoPattern)i))]]; _patternChoice.lastItem.representedObject=S(kv_pattern_russian((KvPianoPattern)i)); }
        [_patternChoice.menu addItem:NSMenuItem.separatorItem];
        [_patternChoice addItemWithTitle:T(@"Шаблон стиля")]; [_patternChoice addItemWithTitle:T(@"Вариация")];
        _patternChoice.target=self; _patternChoice.action=@selector(patternChanged:); _patternChoice.toolTip=T(@"Стиль рисунка двух рук"); [_patternChoice setAccessibilityLabel:T(@"Стиль")]; [self addSubview:_patternChoice];
        _loopButton=IconButton(@"repeat",@"↻",T(@"Повтор · L"),self,@selector(loopChanged:)); [_loopButton setButtonType:NSButtonTypePushOnPushOff]; [self addSubview:_loopButton];
        _metronomeButton=IconButton(@"metronome",@"♩",T(@"Метроном · ⌘K · щёлкает, пока идёт игра"),self,@selector(toggleMetronome:)); [_metronomeButton setButtonType:NSButtonTypePushOnPushOff]; [self addSubview:_metronomeButton];
        _drumsButton=IconButton(@"music.quarternote.3",@"♩♩",T(@"Ударные · ⇧⌘K · бит под песней и под кругом"),self,@selector(toggleDrums:)); [_drumsButton setButtonType:NSButtonTypePushOnPushOff]; [self addSubview:_drumsButton];
        _drumsChoice=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:YES]; _drumsChoice.autoenablesItems=NO; [_drumsChoice addItemWithTitle:@""];
        _rhythmChoice=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:YES]; _rhythmChoice.autoenablesItems=NO; [_rhythmChoice addItemWithTitle:@""];
        { // The metronome is the click, the drums are their own layer (feedback on 1.5, build 31): the click's grid and count-in here,
          // the drums by the style or one beat in their own menu; both may sound together.
          NSMenuItem *(^header)(NSString *)=^NSMenuItem *(NSString *title) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""]; item.enabled=NO; item.tag=-1; [self->_rhythmChoice.menu addItem:item]; return item; };
          header(T(@"Метроном: клик"));
          NSArray *grids=@[T(@"Клик · доли"),T(@"Клик · восьмые"),T(@"Клик · триоли"),T(@"Клик · шестнадцатые")];
          for(NSInteger i=0;i<KV_GRID_COUNT;i++) { [_rhythmChoice addItemWithTitle:grids[i]]; _rhythmChoice.lastItem.tag=i; }
          [_rhythmChoice.menu addItem:NSMenuItem.separatorItem]; _rhythmChoice.lastItem.tag=-1;
          [_rhythmChoice addItemWithTitle:T(@"Отсчёт такта перед игрой")]; _rhythmChoice.lastItem.tag=100;
          _rhythmChoice.target=self; _rhythmChoice.action=@selector(rhythmChanged:); _rhythmChoice.toolTip=T(@"Метроном: сетка клика · отсчёт такта");
          [_rhythmChoice setAccessibilityLabel:T(@"Метроном")]; [self addSubview:_rhythmChoice];
          NSMenuItem *title=[[NSMenuItem alloc] initWithTitle:T(@"Ударные") action:NULL keyEquivalent:@""]; title.enabled=NO; title.tag=-1; [_drumsChoice.menu addItem:title];
          [_drumsChoice addItemWithTitle:T(@"По стилю · в песне у каждой секции свои")]; _drumsChoice.lastItem.tag=300;
          NSDictionary *grey=@{NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
          NSString *titles[KV_BEAT_COUNT]={T(@"Поп · бочка, малый, хай-хэт"),T(@"Баллада · стик и хай-хэт"),T(@"Босса-нова · стик, шейкер, конги"),T(@"Шаффл · триольный хай-хэт"),T(@"Хип-хоп"),T(@"Трип-хоп · бэкбит на третью"),T(@"Хаус · прямая бочка")};
          for(NSNumber *beat in @[@(KV_BEAT_POP),@(KV_BEAT_BALLAD),@(KV_BEAT_BOSSA),@(KV_BEAT_SHUFFLE),@(KV_BEAT_HIPHOP),@(KV_BEAT_TRIPHOP),@(KV_BEAT_HOUSE)]) {
              int low=0,high=0; kv_beat_tempo((KvBeat)beat.intValue,&low,&high); NSString *title=titles[beat.intValue]; [_drumsChoice addItemWithTitle:title]; NSMenuItem *item=_drumsChoice.lastItem; item.tag=200+beat.integerValue;
              NSMutableAttributedString *text=[[NSMutableAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName:[NSFont menuFontOfSize:0]}];
              [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   %d–%d BPM",low,high] attributes:@{NSFontAttributeName:[NSFont menuFontOfSize:0],NSForegroundColorAttributeName:grey[NSForegroundColorAttributeName]}]];
              item.attributedTitle=text; }
          [_drumsChoice.menu addItem:NSMenuItem.separatorItem]; _drumsChoice.lastItem.tag=-1;
          [_drumsChoice addItemWithTitle:T(@"Выключить ударные")]; _drumsChoice.lastItem.tag=400; }
        _drumsChoice.target=self; _drumsChoice.action=@selector(drumsChanged:); _drumsChoice.toolTip=T(@"Ударные: по стилю рисунка или один бит; у секции песни — свой выбор в инспекторе");
        [_drumsChoice setAccessibilityLabel:T(@"Ударные")]; [self addSubview:_drumsChoice]; _beatDot=-1;
        _tempoSlider=[TNSlider sliderWithValue:_tempo minValue:50 maxValue:240 target:self action:@selector(tempoChanged:)];
        _tempoSlider.continuous=YES; [_tempoSlider setAccessibilityLabel:T(@"Темп воспроизведения")]; [self addSubview:_tempoSlider];
        _tempoSlider.toolTip=T(@"Темп, четверти в минуту"); _tempoValue=Label(@"",12,NSFontWeightSemibold); [self addSubview:_tempoValue];

        _presetsButton=IconButton(@"list.bullet",@"≡",T(@"Готовые прогрессии: поп, джаз, классика, минор, хроматика"),self,@selector(showPresets:)); [self addSubview:_presetsButton];
        _generateCountChoice=Choice(@[@[T(@"4 аккорда"),@"4"],@[T(@"6 аккордов"),@"6"],@[T(@"8 аккордов"),@"8"]],self,@selector(generateCountChanged:),T(@"Сколько аккордов создаёт генератор"));
        [self addSubview:_generateCountChoice];
        _generateSequenceButton=IconButton(@"wand.and.stars",@"✦",T(@"Новые аккорды в текущей тональности и ладу · ⌘N · сколько — в списке справа"),self,@selector(generateProgression:)); [self addSubview:_generateSequenceButton];
        _undoSequenceButton=IconButton(@"arrow.uturn.backward",@"↶",T(@"Вернуть предыдущую последовательность · ⌘Z"),self,@selector(undoSequence:)); [self addSubview:_undoSequenceButton];
        _arrangementInfo=Label(@"",11,NSFontWeightRegular); _arrangementInfo.textColor=NSColor.secondaryLabelColor; _arrangementInfo.alignment=NSTextAlignmentRight; [self addSubview:_arrangementInfo];
        _clearButton=IconButton(@"trash",@"✕",T(@"Очистить последовательность"),self,@selector(clearProgression:)); [self addSubview:_clearButton];
        _status=Label(_audio?T(@"Готово · Пробел — играть · ⌘/ — все сочетания клавиш"):T(@"Аудиоустройство недоступно"),11,NSFontWeightRegular); _status.textColor=NSColor.secondaryLabelColor; [self addSubview:_status];
        NSUserDefaults *defaults=Defaults();
        if([defaults objectForKey:@"reverb"]) {
            KvEffects savedEffects={(float)[defaults doubleForKey:@"reverb"],(float)[defaults doubleForKey:@"delay"],[defaults doubleForKey:@"delaySeconds"]};
            if(kv_effects_valid(savedEffects)) _effects=savedEffects;
        }
        _delayDivisionIndex=[defaults objectForKey:@"delayDivision"]?MIN(5,MAX(0,[defaults integerForKey:@"delayDivision"])):1;
        _freeDelaySeconds=[defaults doubleForKey:@"freeDelaySeconds"];
        if(_freeDelaySeconds<.08 || _freeDelaySeconds>1.2) _freeDelaySeconds=.3;
        if([defaults integerForKey:@"fxEngineVersion"]!=2) { _effects=(KvEffects){.10,.10,.3}; _delayDivisionIndex=1; }   // first launch: piano, reverb 10 %, delay 10 % on 1/8
        _chordExtension=MIN(4,MAX(0,[defaults integerForKey:@"chordExtension"])); [_harmonyChoice selectItemAtIndex:_chordExtension];
        _arrangementSeed=(uint32_t)[defaults integerForKey:@"arrangementSeed"]; if(!_arrangementSeed) _arrangementSeed=arc4random();
        _generatedRhythm=[defaults boolForKey:@"generatedRhythm"];
        _performanceMode=[defaults objectForKey:@"texture"]?MIN(6,MAX(0,[defaults integerForKey:@"texture"])):[defaults objectForKey:@"twoHandPiano"] && ![defaults boolForKey:@"twoHandPiano"]?0:1;   // first launch: two hands
        _arpeggioPattern=(KvArpeggioPattern)MIN(KV_ARP_COUNT-1,MAX(0,[defaults integerForKey:@"arpeggioPattern"]));
        _division=[defaults objectForKey:@"division"]?(KvDivision)MIN(KV_DIV_COUNT-1,MAX(0,[defaults integerForKey:@"division"])):KV_DIV_SIXTEENTH;
        _chordLengthArp=[defaults objectForKey:@"chordLengthArp"]?(KvChordLength)MIN(KV_LENGTH_COUNT-1,MAX(0,[defaults integerForKey:@"chordLengthArp"])):KV_LENGTH_BAR;
        NSInteger savedPattern=[defaults integerForKey:@"pianoPattern"]; _pianoPattern=(KvPianoPattern)(savedPattern>=0 && savedPattern<KV_PATTERN_COUNT?savedPattern:0);
        // 0.14 tied 3/4 to the waltz; keep what such users heard, then let meter stand on its own.
        if([defaults objectForKey:@"meter"]) _meter=(KvMeter)MIN(KV_METER_COUNT-1,MAX(0,[defaults integerForKey:@"meter"]));
        else _meter=_pianoPattern==KV_WALTZ?KV_METER_3_4:KV_METER_6_8;   // first launch: 6/8
        _chordLengthBlocks=[defaults objectForKey:@"chordLengthBlocks"]?(KvChordLength)MIN(KV_LENGTH_COUNT-1,MAX(0,[defaults integerForKey:@"chordLengthBlocks"])):KV_LENGTH_BEAT;
        _chordLengthHands=[defaults objectForKey:@"chordLengthHands"]?(KvChordLength)MIN(KV_LENGTH_COUNT-1,MAX(0,[defaults integerForKey:@"chordLengthHands"])):KV_LENGTH_BAR;
        _chordLengthStrings=[defaults objectForKey:@"chordLengthStrings"]?(KvChordLength)MIN(KV_LENGTH_COUNT-1,MAX(0,[defaults integerForKey:@"chordLengthStrings"])):KV_LENGTH_BAR;
        _fillRate=(KvFillRate)MIN(KV_FILL_COUNT-1,MAX(0,[defaults integerForKey:@"fillRate"]));
        _selectedChip=-1; _currentChip=-1;
        _midiOutEnabled=[defaults boolForKey:@"midiOut"]; _midiOutToggle.state=_midiOutEnabled?NSControlStateValueOn:NSControlStateValueOff;
        if([defaults boolForKey:@"midiIn"]) { _midi.inputEnabled=YES; _midiInToggle.state=NSControlStateValueOn; }
        _chordKeys=[defaults boolForKey:@"chordKeys"]; _chordKeysToggle.state=_chordKeys?NSControlStateValueOn:NSControlStateValueOff;
        [self refreshMidiDevices];
        double savedTempo=[defaults doubleForKey:@"tempo"];
        if(savedTempo>=50 && savedTempo<=240) _tempo=savedTempo;
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];   // drop a .mid file anywhere on the window
        { NSInteger count=[defaults integerForKey:@"generateCount"]; _generateCount=count==6 || count==8?(int)count:4; [_generateCountChoice selectItemAtIndex:_generateCount/2-2]; }
        _computerKeyboard=[defaults boolForKey:@"computerKeyboard"]; _computerKeyboardButton.state=_computerKeyboard?NSControlStateValueOn:NSControlStateValueOff;
        _loopEnabled=[defaults boolForKey:@"loopEnabled"]; _loopButton.state=_loopEnabled?NSControlStateValueOn:NSControlStateValueOff;
        _rhythmGrid=(KvGrid)MIN(KV_GRID_COUNT-1,MAX(0,[defaults integerForKey:@"rhythmGrid"])); _countIn=[defaults boolForKey:@"countIn"];
        { NSInteger beat=[defaults objectForKey:@"rhythmBeat"]?[defaults integerForKey:@"rhythmBeat"]:KvBeatByStyle; _rhythmBeat=beat>=0 && beat<KV_BEAT_COUNT?beat:KvBeatByStyle;
          // Before build 31 the metronome was a click (−1) or these drums: such a state keeps its drums and leaves the click off; a new one has the drums on.
          _drumsOn=[defaults objectForKey:@"drumsOn"]?[defaults boolForKey:@"drumsOn"]:[defaults objectForKey:@"rhythmBeat"]?beat>=0:YES; _drumsButton.state=_drumsOn?NSControlStateValueOn:NSControlStateValueOff; }
        _rhythmVolume=[defaults objectForKey:@"rhythmVolume"]?MIN(1,MAX(0,[defaults doubleForKey:@"rhythmVolume"])):.6; _sentBeat=-2; _sentBeatMeter=-1; [self applyRhythm];   // the menu marks; the metronome itself starts off
        _tempoSlider.doubleValue=_tempo; _tempoValue.stringValue=[NSString stringWithFormat:@"%.0f BPM",_tempo];
        if(_delayDivisionIndex<5) { const double beats[]={1,.5,.25,.75,1.0/3}; _effects.delay_seconds=60.0/_tempo*beats[_delayDivisionIndex]; }
        if(_audio && !kv_audio_set_effects(_audio,_effects)) _status.stringValue=T(@"Не удалось применить настройки звука");
        if([defaults objectForKey:@"humanize"]) _humanize=[defaults boolForKey:@"humanize"];
        if(_audio && !kv_audio_set_humanize(_audio,_humanize)) _status.stringValue=T(@"Не удалось применить настройки исполнения");
        NSInteger savedInstrument=[defaults objectForKey:@"instrument"]?[defaults integerForKey:@"instrument"]:KV_INSTRUMENT_STRINGS;   // first launch: the strings, pizzicato
        if(savedInstrument>=0 && savedInstrument<KV_INSTRUMENTS && (savedInstrument!=KV_INSTRUMENT_STRINGS || _stringsAvailable)) _instrument=savedInstrument;
        if(![defaults objectForKey:@"texture"] && ![defaults objectForKey:@"twoHandPiano"] && _instrument==KV_INSTRUMENT_STRINGS) _performanceMode=3+KV_STRINGS_PIZZICATO-KV_STRINGS_CHORALE;
        if(_performanceMode>=3 && _instrument!=KV_INSTRUMENT_STRINGS) _performanceMode=1;   // strings textures need the strings
        _articulation=(KvArticulation)MIN(KV_ARTICULATION_COUNT-1,MAX(0,[defaults integerForKey:@"articulation"]));
        _stringDynamics=[defaults objectForKey:@"stringDynamics"]?MIN(1,MAX(0,[defaults doubleForKey:@"stringDynamics"])):.6; _stringExpression=1;
        if(_audio && !(kv_audio_set_articulation(_audio,_articulation) && kv_audio_set_dynamics(_audio,_stringDynamics,_stringExpression))) _status.stringValue=T(@"Не удалось применить настройки струнных");
        _dynamicsSlider=[TNSlider sliderWithValue:_stringDynamics minValue:0 maxValue:1 target:self action:@selector(dynamicsChanged:)];
        _dynamicsSlider.vertical=YES; _dynamicsSlider.continuous=YES; [_dynamicsSlider setAccessibilityLabel:T(@"Динамика струнных")];
        _dynamicsSlider.toolTip=T(@"Динамика струнных: вниз — тише и мягче, вверх — громче и ярче · колесо модуляции (CC1) · в фактурах — глубина «дыхания» аккорда");
        [self addSubview:_dynamicsSlider];
        if(_audio && !kv_audio_set_instrument(_audio,(int)_instrument)) _status.stringValue=T(@"Инструмент недоступен");
        NSInteger savedBase=[defaults integerForKey:@"keyboardBase"];
        if(savedBase>=36 && savedBase<=84 && savedBase%12==0) _keyboardBase=(int)savedBase;
        NSInteger savedIndex=[defaults integerForKey:@"circleIndex"];
        _requestedSpelling=(int)MIN(7,MAX(0,[defaults integerForKey:@"spelling"]));
        _key=kv_key_normalize((KvKey){(int)(savedIndex>=0 && savedIndex<12?savedIndex:0),[defaults boolForKey:@"minor"],(int)MIN(7,MAX(0,[defaults integerForKey:@"scaleMode"])),_requestedSpelling,[defaults boolForKey:@"pentatonic"]});
        _keyboardMode.selectedSegment=[defaults boolForKey:@"showChord"]?1:0;
        NSInteger savedDegree=[defaults integerForKey:@"selectedDegree"];
        _selectedDegree=kv_code_valid((int)savedDegree)?savedDegree:0;
        _restoring=YES;
        NSArray *saved=[defaults arrayForKey:@"progression"];
        for(id code in saved) if([code isKindOfClass:NSNumber.class] && kv_code_valid([code intValue]) && self.progression.count<8) [self appendDegree:[code intValue]];
        self.sequenceUndo=nil;
        [self restoreTrack]; [self restoreSong]; _restoring=NO;
        [self refresh];
        if(_viewMode==2) { [_arranger reload]; if(_song->count) [self editSection:_arranger.selected]; }
        [self matchInspectorToView];
        __weak KvRoot *weakSelf=self;
        // Common modes: the frame clock keeps running while a slider or a menu tracks the mouse.
        [NSRunLoop.mainRunLoop addTimer:[NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *timer) {
            KvRoot *root=weakSelf;
            if(!root) { [timer invalidate]; return; }
            // Two quiet seconds in: ten frames a second are enough, and the output queue may rest.
            BOOL busy=kv_audio_is_playing(root.audio) || root.visualPlayback || root.songPlaying;
            root.idleTicks=busy?0:root.idleTicks+1;
            if(root.idleTicks>120) { if(root.idleTicks%60==0 && root.audio) kv_audio_suspend(root.audio); if(root.idleTicks%6) return; }
            [root updatePlaybackVisualization]; [root.piano advanceAnimation]; [root updateHands]; [root.circle advanceFingers]; [root updateMidiOut]; [root updateTransportIfChanged]; [root updateBeatDots]; [root updateSongPlayback]; [root updateSongTempo]; if(root.viewMode==2) [root.arranger updatePlayhead];
            [root reconcilePlayback];
            if(!root.roll.hidden) {
                double beat=[root rollPlayheadBeat];
                if(beat!=root.roll.playheadBeat) { root.roll.playheadBeat=beat; root.roll.needsDisplay=YES; }
            }
            if(root.playbackActivity && !kv_audio_is_playing(root.audio)) {
                [NSProcessInfo.processInfo endActivity:root.playbackActivity]; root.playbackActivity=nil;
            }
            if([root.status.stringValue hasPrefix:T(@"Воспроизведение ·")] && !kv_audio_is_playing(root.audio)) root.status.stringValue=T(@"Готово · Пробел — играть · ⌘/ — все сочетания клавиш");
        }] forMode:NSRunLoopCommonModes];
    } return self;
}
- (void)dealloc { if(_playbackActivity) [NSProcessInfo.processInfo endActivity:_playbackActivity]; kv_audio_destroy(_audio); free(_currentPlan); free(_track); }
- (KvMetrics)computeMetrics {
    KvMetrics m={0}; m.w=self.bounds.size.width; m.h=self.bounds.size.height;
    m.inspectorX=m.w-KvInspectorWidth; m.dockTop=floor(m.h-KvDockHeight());
    m.cw=MIN(m.w-2*KvMargin,KvMaxContentWidth); m.cx=floor((m.w-m.cw)/2);
    m.headY=m.dockTop+10; m.kbY=m.headY+28+6; m.legendY=m.kbY+KvKeyboardHeight+6; m.sepY=m.legendY+24+8;
    m.seqY=m.sepY+1+8; m.transportY=m.seqY+KvChipHeight+8; m.statusY=m.transportY+KvTransportHeight+6;
    if(self.viewMode==2) m.dockTop=m.sepY;   // the arranger has no keyboard: its tracks take the room (spec 1.5 §2)
    m.slotW=floor((m.cw-200-16-7*KvSlotGap)/8); m.tempoX=m.cx+202; m.registerX=m.cx+m.cw-200;
    return m;
}
- (void)layout {
    [super layout]; KvMetrics m=[self computeMetrics]; self.metrics=m;
    CGFloat left=m.inspectorX;
    // Header: brand, key controls next to it, session actions at the right edge of the circle area.
    self.viewSwitch.frame=NSMakeRect(168,12,132,28);
    self.mode.frame=NSMakeRect(312,12,206,28); self.soundButton.frame=NSMakeRect(524,12,36,28); self.computerKeyboardButton.frame=NSMakeRect(566,12,36,28);
    self.soundSettingsButton.frame=NSMakeRect(left-KvMargin-36,12,36,28); self.shortcutsButton.frame=NSMakeRect(left-KvMargin-78,12,36,28);
    self.shortcutsCard.frame=self.bounds;
    NSRect area=NSMakeRect(16,KvHeaderHeight,left-32,m.dockTop-KvHeaderHeight-8); self.circle.frame=area; self.roll.frame=area; self.arranger.frame=area;
    BOOL docked=self.viewMode==2 && self.rollDocked && self.song->count;   // the roll under the tracks, on the selected section
    if(docked) { CGFloat rollHeight=MAX(200,floor(NSHeight(area)*.42)); self.arranger.frame=NSMakeRect(NSMinX(area),NSMinY(area),NSWidth(area),NSHeight(area)-rollHeight-8); self.roll.frame=NSMakeRect(NSMinX(area),NSMaxY(area)-rollHeight,NSWidth(area),rollHeight); }
    self.circle.hidden=self.viewMode!=0; self.roll.hidden=self.viewMode!=1 && !docked; self.arranger.hidden=self.viewMode!=2;
    // Inspector: tabs on top; the chord tab's rows grow with the window between 28 and 36 points.
    CGFloat x=m.inspectorX+KvMargin,iw=KvInspectorWidth-2*KvMargin,y=10;
    self.inspectorTabs.frame=NSMakeRect(x,y,iw,24); y+=30;
    BOOL midiTab=self.inspectorTab==2,chromaticTab=self.inspectorTab==1,sectionTab=self.inspectorTab==3,chordTab=!midiTab && !chromaticTab && !sectionTab;
    if(self.inspectorTabs.segmentCount>3) [self.inspectorTabs setEnabled:YES forSegment:3];
    self.arranger.sectionPanel.hidden=!sectionTab; if(sectionTab) self.arranger.sectionPanel.frame=NSMakeRect(x,y+6,iw,m.dockTop-y-16);
    for(NSView *view in @[self.heading,self.signature,self.scaleNames,self.harmonyChoice,self.scaleButton]) view.hidden=!chordTab;
    for(NSButton *button in self.chordButtons) button.hidden=!chordTab; for(NSButton *button in self.addButtons) button.hidden=!chordTab;
    for(NSView *view in self.midiViews) view.hidden=!midiTab;
    for(NSView *view in self.chromaticChips) view.hidden=!chromaticTab;
    for(NSView *view in self.chromaticHeaders) view.hidden=!chromaticTab;
    self.chromaticStory.hidden=!chromaticTab; self.chromaticAddButton.hidden=!chromaticTab; self.chromaticTitle.hidden=!chromaticTab;
    if(chromaticTab) { // «Вне лада»: groups of tiles, five to a row; then the selected chord with «Добавить», and what it is
        CGFloat cy=y,tile=floor((iw-4*5)/5); NSInteger shown[3]={0};
        for(NSUInteger i=0;i<self.chromaticChips.count;i++) shown[self.chromaticGroups[i].intValue]++;
        for(int g=0;g<3;g++) {
            self.chromaticHeaders[g].hidden=!shown[g]; if(!shown[g]) continue;
            self.chromaticHeaders[g].frame=NSMakeRect(x,cy,iw,16); cy+=20; NSInteger k=0;
            for(NSUInteger i=0;i<self.chromaticChips.count;i++) if(self.chromaticGroups[i].intValue==g) { self.chromaticChips[i].frame=NSMakeRect(x+(k%5)*(tile+5),cy+(k/5)*38,tile,34); k++; }
            cy+=((k+4)/5)*38+4;
        }
        cy+=2; self.chromaticTitle.frame=NSMakeRect(x,cy+5,iw-110,20); self.chromaticAddButton.frame=NSMakeRect(x+iw-104,cy,104,28); cy+=34;
        self.chromaticStory.frame=NSMakeRect(x,cy,iw,MAX(16,MIN(90,m.dockTop-cy-8)));
    }
    self.heading.frame=NSMakeRect(x,y,iw,28); self.signature.frame=NSMakeRect(x,y+28,iw,16);
    self.scaleNames.frame=NSMakeRect(x,y+46,iw,20); self.harmonyChoice.frame=NSMakeRect(x,y+70,iw-40,28); self.scaleButton.frame=NSMakeRect(x+iw-34,y+70,34,28); y+=100;
    // The hint line and the "chords of the key" heading give way first when the window is short.
    CGFloat available=m.dockTop-y-10;
    BOOL hint=available-24>=7*30; if(hint) available-=24;
    BOOL heading=chordTab && available-26>=7*32; self.chordHeading.hidden=!heading;
    if(heading) { self.chordHeading.frame=NSMakeRect(x,y,iw,20); y+=26; available-=26; }
    CGFloat row=floor(MIN(36,available/7));
    for(int i=0;i<7;i++) { self.chordButtons[i].frame=NSMakeRect(x,y+i*row,iw-40,row-2); self.addButtons[i].frame=NSMakeRect(x+iw-34,y+i*row,34,row-2); }
    y+=7*row+4; self.hint.hidden=!chordTab || !hint; if(hint) { self.hint.frame=NSMakeRect(x,y,iw,16); y+=24; }
    // MIDI tab: file, output, input, status.
    CGFloat my=40; NSView *fileLabel=nil,*outLabel=nil,*inLabel=nil;
    for(NSView *view in self.midiViews) if([view isKindOfClass:NSTextField.class]) { NSString *title=[(NSTextField *)view stringValue]; if([title isEqualToString:T(@"Файл")]) fileLabel=view; else if([title isEqualToString:T(@"Выход")]) outLabel=view; else if([title isEqualToString:T(@"Вход")]) inLabel=view; }
    fileLabel.frame=NSMakeRect(x,my,iw,18); my+=22; self.midiExportButton.frame=NSMakeRect(x,my,36,28); self.midiCopyButton.frame=NSMakeRect(x+42,my,36,28); self.midiDragHandle.frame=NSMakeRect(x+88,my,iw-88,28); my+=32; self.midiExportInfo.frame=NSMakeRect(x,my,iw,30); my+=36;
    outLabel.frame=NSMakeRect(x,my,iw,18); my+=22; self.midiDestination.frame=NSMakeRect(x,my,iw,28); my+=32; self.midiOutToggle.frame=NSMakeRect(x-2,my,iw+2,20); my+=28;
    inLabel.frame=NSMakeRect(x,my,iw,18); my+=22; self.midiInToggle.frame=NSMakeRect(x-2,my,iw+2,20); my+=22; self.chordKeysToggle.frame=NSMakeRect(x-2,my,iw+2,20); my+=24;
    self.midiChordLabel.frame=NSMakeRect(x,my,iw-110,28); self.midiAddChordButton.frame=NSMakeRect(x+iw-104,my,104,28); my+=30; self.midiHeldLabel.frame=NSMakeRect(x,my,iw,44); my+=48;
    self.midiStatus.frame=NSMakeRect(x,my,iw,MAX(14,MIN(32,m.dockTop-my-6)));
    // Keyboard dock: one heading line, keyboard, legend with register.
    CGFloat headingWidth=ceil([self.keyboardHeading.stringValue sizeWithAttributes:@{NSFontAttributeName:self.keyboardHeading.font}].width)+6;
    CGFloat segmentX=m.cx+m.cw-300; headingWidth=MIN(headingWidth,segmentX-m.cx-140);
    self.keyboardHeading.frame=NSMakeRect(m.cx,m.headY+4,headingWidth,20);
    self.keyboardNotes.frame=NSMakeRect(m.cx+headingWidth+14,m.headY+5,segmentX-16-(m.cx+headingWidth+14),19);
    self.keyboardMode.frame=NSMakeRect(segmentX,m.headY,300,28);
    // Strings: the dynamics slider stands left of the keyboard.
    BOOL bowed=[self stringsChosen]; self.dynamicsSlider.hidden=!bowed;
    self.dynamicsSlider.frame=NSMakeRect(m.cx,m.kbY+4,24,KvKeyboardHeight-8);
    self.piano.frame=bowed?NSMakeRect(m.cx+32,m.kbY,m.cw-32,KvKeyboardHeight):NSMakeRect(m.cx,m.kbY,m.cw,KvKeyboardHeight);
    self.registerControl.frame=NSMakeRect(m.registerX,m.legendY,200,24);
    BOOL keys=self.viewMode!=2; for(NSView *view in @[self.piano,self.keyboardHeading,self.keyboardNotes,self.keyboardMode,self.registerControl]) view.hidden=!keys;
    if(!keys) self.dynamicsSlider.hidden=YES;
    // Sequence: eight fixed slots, edit actions at the right.
    for(NSUInteger i=0;i<self.progressionButtons.count;i++) self.progressionButtons[i].frame=NSMakeRect(m.cx+i*(m.slotW+KvSlotGap),m.seqY,m.slotW,KvChipHeight);
    // Right of the slots: wand, its chord count, presets, undo, clear.
    self.generateSequenceButton.frame=NSMakeRect(m.cx+m.cw-196,m.seqY+2,32,32); self.generateCountChoice.frame=NSMakeRect(m.cx+m.cw-160,m.seqY+4,52,28);
    self.presetsButton.frame=NSMakeRect(m.cx+m.cw-104,m.seqY+2,32,32);
    self.undoSequenceButton.frame=NSMakeRect(m.cx+m.cw-68,m.seqY+2,32,32); self.clearButton.frame=NSMakeRect(m.cx+m.cw-32,m.seqY+2,32,32);
    // Transport: play, loop and tempo at the left; texture and pattern at the right.
    CGFloat ty=m.transportY;
    self.playButton.frame=NSMakeRect(m.cx,ty,56,KvTransportHeight); self.loopButton.frame=NSMakeRect(m.cx+60,ty,32,KvTransportHeight);
    // The metronome and the drums each read as a button and its menu; the beat dots (or «Темп») have their own 40 points before the slider.
    self.metronomeButton.frame=NSMakeRect(m.cx+96,ty,32,KvTransportHeight); self.rhythmChoice.frame=NSMakeRect(m.cx+129,ty,16,KvTransportHeight);
    self.drumsButton.frame=NSMakeRect(m.cx+148,ty,32,KvTransportHeight); self.drumsChoice.frame=NSMakeRect(m.cx+181,ty,16,KvTransportHeight);
    self.tempoSlider.frame=NSMakeRect(m.tempoX+44,ty+3,78,26); self.tempoValue.frame=NSMakeRect(m.tempoX+126,ty+7,54,18);
    // Right group, read left to right: texture, meter, style, chord length, fills, variation.
    CGFloat right=m.cx+m.cw; BOOL hands=self.performanceMode==1,arp=self.performanceMode==2,strings=self.performanceMode>=3,ostinato=self.performanceMode==3+KV_STRINGS_OSTINATO-KV_STRINGS_CHORALE;
    NSArray<NSView *> *group=hands?@[self.performanceChoice,self.meterChoice,self.patternChoice,self.lengthChoice,self.fillChoice,self.arrangeButton]:arp?@[self.performanceChoice,self.meterChoice,self.arpeggioChoice,self.lengthChoice,self.divisionChoice,self.arrangeButton]
        :ostinato?@[self.performanceChoice,self.meterChoice,self.lengthChoice,self.divisionChoice,self.arrangeButton]:strings?@[self.performanceChoice,self.meterChoice,self.lengthChoice,self.arrangeButton]:@[self.performanceChoice,self.meterChoice,self.lengthChoice];
    NSDictionary<NSValue *,NSNumber *> *widths=@{[NSValue valueWithNonretainedObject:self.performanceChoice]:@148,[NSValue valueWithNonretainedObject:self.meterChoice]:@68,[NSValue valueWithNonretainedObject:self.patternChoice]:@164,[NSValue valueWithNonretainedObject:self.lengthChoice]:@100,[NSValue valueWithNonretainedObject:self.fillChoice]:@148,[NSValue valueWithNonretainedObject:self.arrangeButton]:@32,[NSValue valueWithNonretainedObject:self.arpeggioChoice]:@164,[NSValue valueWithNonretainedObject:self.divisionChoice]:@96};
    for(NSView *view in group.reverseObjectEnumerator) { CGFloat width=widths[[NSValue valueWithNonretainedObject:view]].doubleValue; right-=width; view.frame=NSMakeRect(right,ty,width,KvTransportHeight); right-=6; }
    CGFloat statusWidth=floor(m.cw*.55);
    self.status.frame=NSMakeRect(m.cx,m.statusY,statusWidth,18); self.status.toolTip=self.status.stringValue;
    self.arrangementInfo.frame=NSMakeRect(m.cx+statusWidth+12,m.statusY,m.cw-statusWidth-12,18);
    self.needsDisplay=YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; [TNCanvas() setFill]; NSRectFill(self.bounds);
    KvMetrics m=self.metrics; if(m.w!=self.bounds.size.width || m.h!=self.bounds.size.height) m=[self computeMetrics];
    [TNSurface() setFill]; NSRectFill(NSMakeRect(m.inspectorX,0,KvInspectorWidth,m.dockTop));
    Line(m.inspectorX,0,m.inspectorX,m.dockTop); Line(0,m.dockTop,m.w,m.dockTop); Line(m.cx,m.sepY,m.cx+m.cw,m.sepY);
    KvDrawBrand(NSMakeRect(24,9,34,34));
    Text(@"Tonora",NSMakeRect(68,13,90,28),20,NSFontWeightSemibold,Ink(),NSTextAlignmentLeft);
    if(self.viewMode!=2) [self drawLegend:m];
    if(self.metronomeOn || self.drumsOn) [self drawBeatDots:[self beatDotsRect]];   // the rhythm shows its beats where «Темп» stands
    else Text(T(@"Темп"),NSMakeRect(m.tempoX,m.transportY+8,40,18),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NSTextAlignmentLeft);
    CGFloat dash[]={4,3};
    for(NSUInteger i=self.progression.count;i<8 && self.progression.count;i++) {
        NSBezierPath *slot=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(NSMakeRect(m.cx+i*(m.slotW+KvSlotGap),m.seqY,m.slotW,KvChipHeight),1.5,2.5) xRadius:8 yRadius:8];
        [slot setLineDash:dash count:2 phase:0]; slot.lineWidth=1; [[NSColor.labelColor colorWithAlphaComponent:.18] setStroke]; [slot stroke];
    }
    if([self continueCount]) Text([self continueLinkText],[self continueLinkRect],12,NSFontWeightSemibold,Accent(),NSTextAlignmentCenter);
    if(!self.progression.count) {
        NSRect strip=NSMakeRect(m.cx,m.seqY,8*m.slotW+7*KvSlotGap,KvChipHeight);
        NSBezierPath *frame=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(strip,1.5,2.5) xRadius:8 yRadius:8];
        [frame setLineDash:dash count:2 phase:0]; frame.lineWidth=1; [[NSColor.labelColor colorWithAlphaComponent:.18] setStroke]; [frame stroke];
        NSRect link=[self generatorLinkRect];
        Text(T(EmptyHint),NSMakeRect(NSMinX(strip),m.seqY+10,NSMinX(link)-NSMinX(strip)-4,18),12,NSFontWeightRegular,NSColor.secondaryLabelColor,NSTextAlignmentRight);
        Text(T(EmptyLink),link,12,NSFontWeightSemibold,Accent(),NSTextAlignmentLeft);
    }
}
/* Under the keyboard: what its colours mean, and its range. */
- (void)drawLegend:(KvMetrics)m {
    BOOL chordMode=self.keyboardMode.selectedSegment==1;
    NSColor *tonic=[NSColor colorWithCalibratedRed:0 green:0.48 blue:0.36 alpha:1];
    [tonic setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(m.cx+1,m.legendY+8,8,8)] fill];
    Text(chordMode?T(@"1 — основной тон аккорда"):T(@"1 — тоника тональности"),NSMakeRect(m.cx+14,m.legendY+3,220,18),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NSTextAlignmentLeft);
    [Accent() setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(m.cx+237,m.legendY+8,8,8)] fill];
    Text(chordMode?T(@"ноты выбранного аккорда"):T(@"остальные ноты тональности"),NSMakeRect(m.cx+250,m.legendY+3,170,18),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NSTextAlignmentLeft);
    if(self.performanceMode==1) { // two hands: the melody also plays notes outside the chord
        [TNPassing() setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(m.cx+426,m.legendY+8,8,8)] fill];
        Text(T(@"проходящая"),NSMakeRect(m.cx+439,m.legendY+3,80,18),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NSTextAlignmentLeft);
        [TNAnticipation() setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(m.cx+522,m.legendY+8,8,8)] fill];
        Text(T(@"предвосхищение"),NSMakeRect(m.cx+535,m.legendY+3,100,18),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NSTextAlignmentLeft);
    }
    Text([NSString stringWithFormat:T(@"Клавиатура %@ · регистр"),[self rangeText]],NSMakeRect(m.registerX-12-260,m.legendY+3,260,18),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NSTextAlignmentRight);
}
static NSString *const EmptyHint=@"Последовательность пуста — добавьте аккорды «+» в списке справа или ";
static NSString *const EmptyLink=@"✦ создайте новые аккорды";
- (NSRect)generatorLinkRect {
    KvMetrics m=self.metrics; if(m.w!=self.bounds.size.width) m=[self computeMetrics];
    CGFloat hint=ceil([T(EmptyHint) sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12]}].width);
    CGFloat link=ceil([T(EmptyLink) sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]}].width)+4;
    CGFloat strip=8*m.slotW+7*KvSlotGap,x=m.cx+floor((strip-hint-link)/2)+hint;
    return NSMakeRect(x,m.seqY+10,link,18);
}
/* A partly filled progression: the free slots offer to continue it with the generator. */
- (NSString *)continueLinkText { return [NSString stringWithFormat:T(@"✦ Дополнить: ещё %lu"),(unsigned long)[self continueCount]]; }
- (NSRect)continueLinkRect {
    KvMetrics m=self.metrics; if(m.w!=self.bounds.size.width) m=[self computeMetrics];
    NSUInteger n=self.progression.count,free=[self continueCount]; if(!free) return NSZeroRect;
    CGFloat x=m.cx+n*(m.slotW+KvSlotGap),width=free*(m.slotW+KvSlotGap)-KvSlotGap;
    CGFloat text=ceil([[self continueLinkText] sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]}].width)+8;
    return NSMakeRect(x+floor((width-text)/2),m.seqY+10,text,18);
}
/* The empty progression's hint is a link to the generator; free slots link to continuing it. */
- (void)mouseDown:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    if(!self.progression.count && NSPointInRect(p,NSInsetRect([self generatorLinkRect],-4,-6))) { [self generateProgression:nil]; return; }
    if([self continueCount] && NSPointInRect(p,NSInsetRect([self continueLinkRect],-6,-8))) { [self continueProgression:nil]; return; }
    [super mouseDown:event];
}
- (void)resetCursorRects {
    [super resetCursorRects];
    if(!self.progression.count) [self addCursorRect:[self generatorLinkRect] cursor:NSCursor.pointingHandCursor];
    else if([self continueCount]) [self addCursorRect:[self continueLinkRect] cursor:NSCursor.pointingHandCursor];
}
- (NSString *)rangeText { return [NSString stringWithFormat:@"C%d–B%d",[self keyboardViewStart]/12-1,([self keyboardViewStart]+[self keyboardCount])/12-2]; }
/* Self-test: the first Cyrillic text under a view — titles, labels, tooltips, hover labels, popup items, menus, accessibility. */
static NSString *KvCyrillicIn(NSView *view) {
    NSCharacterSet *cyrillic=[NSCharacterSet characterSetWithRange:NSMakeRange(0x400,0x100)];
    NSMutableArray<NSString *> *texts=[NSMutableArray array];
    void (^add)(id)=^(id text) { if([text isKindOfClass:NSString.class]) [texts addObject:text]; else if([text isKindOfClass:NSAttributedString.class]) [texts addObject:[text string]]; };
    NSMutableArray<NSView *> *views=[NSMutableArray arrayWithObject:view];
    while(views.count) { NSView *v=views.lastObject; [views removeLastObject]; [views addObjectsFromArray:v.subviews];
        add(v.toolTip); add(v.accessibilityLabel); add(v.accessibilityHelp);
        if([v isKindOfClass:NSTextField.class]) add([(NSTextField *)v stringValue]);
        if([v isKindOfClass:NSButton.class]) add([(NSButton *)v title]);
        if([v isKindOfClass:TNButton.class]) add([(TNButton *)v hint]);
        if([v isKindOfClass:NSSegmentedControl.class]) { NSSegmentedControl *control=(NSSegmentedControl *)v; for(NSInteger i=0;i<control.segmentCount;i++) add([control labelForSegment:i]);
            if([v isKindOfClass:TNSegmented.class]) for(NSString *hint in [(TNSegmented *)v hints]) add(hint); }
        if([v isKindOfClass:NSPopUpButton.class]) for(NSMenuItem *item in [(NSPopUpButton *)v itemArray]) { add(item.title); add(item.toolTip); add(item.representedObject); add(item.attributedTitle); }
    }
    NSSet *bilingual=[NSSet setWithObjects:@"Язык · Language",@"Русский",nil];   // the language switch reads the same in both languages
    for(NSString *text in texts) if(![bilingual containsObject:text] && [text rangeOfCharacterFromSet:cyrillic].location!=NSNotFound) return text;
    return nil;
}
static NSString *Describe(NSView *view) {
    NSString *name=view.accessibilityLabel.length?view.accessibilityLabel:[view respondsToSelector:@selector(title)]?[(id)view title]:[view isKindOfClass:NSTextField.class]?[(NSTextField *)view stringValue]:@"";
    return [NSString stringWithFormat:@"%@ «%@» %@",NSStringFromClass(view.class),name,NSStringFromRect(view.frame)];
}
- (NSString *)layoutProblem {
    [self layout];
    NSMutableArray<NSView *> *views=[NSMutableArray array];
    for(NSView *view in self.subviews) if(!view.hidden && NSWidth(view.frame)>0 && NSHeight(view.frame)>0 && view!=self.shortcutsCard) [views addObject:view];
    for(NSView *view in views) if(!NSContainsRect(NSInsetRect(self.bounds,-.5,-.5),view.frame)) return [@"Outside window: " stringByAppendingString:Describe(view)];
    for(NSUInteger i=0;i<views.count;i++) for(NSUInteger j=i+1;j<views.count;j++)
        if(NSIntersectsRect(NSInsetRect(views[i].frame,.5,.5),NSInsetRect(views[j].frame,.5,.5))) return [NSString stringWithFormat:@"Overlap: %@ / %@",Describe(views[i]),Describe(views[j])];
    NSPoint center; CGFloat radius; [self.circle geometry:&center radius:&radius];
    if(radius<160) return [NSString stringWithFormat:@"Circle radius %.1f < 160",radius];
    if(NSMinY(self.chordButtons[1].frame)-NSMinY(self.chordButtons[0].frame)<28) return @"Chord rows below 28 pt";
    if(NSHeight(self.chordButtons[0].frame)<26) return @"Chord buttons below 26 pt";
    for(KvChip *chip in self.progressionButtons) if(![KvChip fittedFont:chip.title width:chip.nameWidth]) return [@"Chip name does not fit: " stringByAppendingString:chip.title];
    // Icon-only buttons must say what they do on hover (and to VoiceOver).
    for(NSView *view in [self.subviews arrayByAddingObjectsFromArray:self.roll.subviews]) if([view isKindOfClass:TNButton.class]) {
        TNButton *button=(TNButton *)view; if(button.image && !button.title.length && !button.hint.length) return [@"Icon button without a hover label: " stringByAppendingString:Describe(view)];
    }
    if(NSWidth(self.keyboardNotes.frame)<180) return @"Keyboard note list too narrow";
    // Every visible popup shows its whole short title for every item (text area = width - 44, see TNPopupCell).
    for(NSView *view in views) if([view isKindOfClass:NSPopUpButton.class]) for(NSMenuItem *item in [(NSPopUpButton *)view itemArray]) {
        if(item.isSeparatorItem) continue;
        NSString *title=[item.representedObject isKindOfClass:NSString.class]?item.representedObject:item.title;
        if([(NSPopUpButton *)view pullsDown] || NSWidth(view.frame)<60) continue;
        if(view.superview==self && view!=self.patternChoice && view!=self.arpeggioChoice && [title sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]}].width>NSWidth(view.frame)-44-(item.image?22:0)) return [NSString stringWithFormat:@"Popup title truncated: «%@» in %@",title,Describe(view)];
        if((view==self.patternChoice || view==self.arpeggioChoice) && [item.representedObject isKindOfClass:NSString.class] && [[title stringByAppendingString:T(@" · вар.")] sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]}].width>NSWidth(view.frame)-44) return [NSString stringWithFormat:T(@"Style title truncated: «%@ · вар.»"),title];
    }
    return nil;
}
/* The arranger's window (self-test): no keyboard, the Section tab, tracks at least 72 points, nothing outside or overlapping
   in the tracks' headers or the panel, every popup title whole. */
- (NSString *)arrangerLayoutProblem {
    [self layout]; [self.arranger layout];
    if(!self.piano.hidden || !self.keyboardHeading.hidden || !self.registerControl.hidden) return @"Keyboard shown in the arranger";
    if(self.inspectorTab!=3 || self.arranger.sectionPanel.hidden) return @"The Section tab is not shown";
    for(NSView *box in @[self.arranger,self.arranger.sectionPanel]) {
        NSMutableArray<NSView *> *views=[NSMutableArray array];
        for(NSView *view in box.subviews) if(!view.hidden && NSWidth(view.frame)>0 && NSHeight(view.frame)>0) [views addObject:view];
        for(NSView *view in views) if(!NSContainsRect(NSInsetRect(box.bounds,-.5,-.5),view.frame)) return [@"Outside the arranger: " stringByAppendingString:Describe(view)];
        for(NSUInteger i=0;i<views.count;i++) for(NSUInteger j=i+1;j<views.count;j++)
            if(NSIntersectsRect(NSInsetRect(views[i].frame,.5,.5),NSInsetRect(views[j].frame,.5,.5))) return [NSString stringWithFormat:@"Arranger overlap: %@ / %@",Describe(views[i]),Describe(views[j])];
        for(NSView *view in views) if([view isKindOfClass:NSPopUpButton.class]) for(NSMenuItem *item in [(NSPopUpButton *)view itemArray]) {
            if(item.isSeparatorItem || [(NSPopUpButton *)view pullsDown]) continue;   // a pull-down shows its own title only
            NSString *title=[item.representedObject isKindOfClass:NSString.class]?item.representedObject:item.title;
            if([title sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]}].width>NSWidth(view.frame)-44-(item.image?22:0)) return [NSString stringWithFormat:@"Popup title truncated: «%@» in %@",title,Describe(view)];
        }
    }
    const KvSong *song=[self songWithWorking]; NSRect marker=[self.arranger rectOfSection:0];
    for(int t=0;t<KV_TRACKS && song->count;t++) {
        NSRect r=[self.arranger rectOfRegion:0 track:t]; if(NSHeight(r)+4<72) return [NSString stringWithFormat:@"Track %d below 72 pt",t];
        if(NSMinY(r)<NSMaxY(marker) || NSMaxY(r)>NSHeight(self.arranger.bounds)-18) return [NSString stringWithFormat:@"Track %d outside its place",t];
        if(t && NSMinY(r)<NSMaxY([self.arranger rectOfRegion:0 track:t-1])) return [NSString stringWithFormat:@"Tracks %d and %d overlap",t-1,t];
    }
    return nil;
}
/* Key signature as written: harmonic and melodic minor keep the natural minor signature; the raised degrees are accidentals. */
- (int)writtenSignature { return kv_written_signature(self.key); }
/* Circle labels follow the selected key: its own chords are spelled as in the key (D♭m, F♭ in A♭ minor),
   other black-key roots follow the direction of the key signature. */
- (NSString *)circleLabelAt:(int)index minor:(BOOL)minor {
    KvKey sector={index,minor,0,0}; int tonic=kv_tonic(sector);
    for(int degree=0;degree<7;degree++) {
        KvChord chord; if(!kv_chord(self.key,degree,&chord)) continue;
        int third=chord.midi[1]-chord.midi[0],fifth=chord.midi[2]-chord.midi[0];
        if(fifth==7 && chord.midi[0]%12==tonic && (third==3)==minor) return S(chord.name);
    }
    static const char *flats[12]={"C","D♭","D","E♭","E","F","G♭","G","A♭","A","B♭","B"},*sharps[12]={"C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"};
    BOOL black=tonic==1 || tonic==3 || tonic==6 || tonic==8 || tonic==10; int signature=[self writtenSignature];
    if(black && signature) return [NSString stringWithFormat:@"%@%@",S((signature<0?flats:sharps)[tonic]),minor?@"m":@""];
    return S(kv_key_label(sector)); // no key signature: the circle's usual names
}
- (BOOL)keyboardHighlights:(int)midi {
    if(self.keyboardMode.selectedSegment!=1) return kv_in_scale(self.key,midi);
    KvChord chord; if(!kv_code_chord(self.key,(int)self.selectedDegree,(int)self.chordExtension,&chord)) return NO;
    for(size_t i=0;i<chord.count;i++) if(chord.midi[i]%12==midi%12) return YES; return NO;
}
- (int)keyboardRoot {
    KvChord chord;
    if(self.keyboardMode.selectedSegment==1 && kv_code_chord(self.key,(int)self.selectedDegree,(int)self.chordExtension,&chord)) return chord.midi[0]%12;
    return kv_tonic(self.key);
}
- (NSString *)keyboardName:(int)midi {
    char names[7][8]; int scale[8]; kv_scale_names(self.key,names); kv_scale(self.key,scale);
    for(int i=0;i<7;i++) if(scale[i]%12==kv_mod(midi,12)) return S(names[i]);
    // Notes outside the scale follow the key signature: G♭ in flat keys, F♯ in sharp ones.
    static const char *sharps[12]={"C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"},*flats[12]={"C","D♭","D","E♭","E","F","G♭","G","A♭","A","B♭","B"};
    return S(([self writtenSignature]<0?flats:sharps)[kv_mod(midi,12)]);
}
/* One title for the key everywhere: "Ля-бемоль · гарм. минор", "До мажор". */
- (NSString *)keyTitle {
    NSString *title=S(kv_key_title(self.key));
    if(self.key.mode) { NSArray *parts=[title componentsSeparatedByString:@" · "]; title=[NSString stringWithFormat:@"%@ · %@",parts.firstObject,[parts.lastObject lowercaseString]]; }
    if(self.key.pentatonic) title=[title stringByAppendingString:T(@" · пентатоника")];
    return title;
}
- (NSString *)noteDescription:(int)midi {
    NSString *name=[self keyboardName:midi]; if(TNEnglish()) return name;   // the solfège syllable is for Russian readers
    NSDictionary *russian=@{@"C":T(@"до"),@"D":T(@"ре"),@"E":T(@"ми"),@"F":T(@"фа"),@"G":T(@"соль"),@"A":T(@"ля"),@"B":T(@"си")};
    NSString *letter=[name substringToIndex:1];
    NSString *acc=[name containsString:@"𝄪"]?@"𝄪":[name containsString:@"𝄫"]?@"𝄫":[name containsString:@"♯"]?@"♯":[name containsString:@"♭"]?@"♭":@"";
    return [NSString stringWithFormat:@"%@ · %@%@",name,russian[letter],acc];
}
- (void)keyboardModeChanged:(id)sender {
    (void)sender; kv_audio_stop(self.audio); self.playbackGeneration++; [self refresh]; [self saveState];
}
- (void)saveState {
    if(self.restoring) return;
    NSUserDefaults *defaults=Defaults();
    // While a section is being edited the working state is the section's: the draft's keys come from the kept draft.
    [self storeWorking]; [self saveSong];
    NSDictionary *draft=self.editingSection>=0 && self.draftState?self.draftState:[self captureWorking];
    for(NSString *name in @[@"progression",@"arrangementSeed",@"generatedRhythm",@"texture",@"arpeggioPattern",@"division",@"chordLengthArp",@"pianoPattern",@"chordLengthBlocks",@"chordLengthHands",@"chordLengthStrings",@"fillRate",@"trackEdited"]) [defaults setObject:draft[name] forKey:name];
    [defaults setBool:[draft[@"texture"] integerValue]==1 forKey:@"twoHandPiano"];
    if([draft[@"trackEdited"] boolValue] && draft[@"trackData"]) [defaults setObject:draft[@"trackData"] forKey:@"trackData"]; else [defaults removeObjectForKey:@"trackData"];
    [defaults setInteger:self.key.circle_index forKey:@"circleIndex"];
    [defaults setBool:self.key.minor forKey:@"minor"];
    [defaults setInteger:self.key.mode forKey:@"scaleMode"]; [defaults setBool:self.key.pentatonic forKey:@"pentatonic"];
    [defaults setInteger:self.requestedSpelling forKey:@"spelling"];
    [defaults setBool:self.keyboardMode.selectedSegment==1 forKey:@"showChord"];
    [defaults setInteger:self.selectedDegree forKey:@"selectedDegree"];
    [defaults setInteger:self.keyboardBase forKey:@"keyboardBase"];
    [defaults setInteger:self.instrument forKey:@"instrument"];
    [defaults setBool:self.humanize forKey:@"humanize"];
    [defaults setDouble:self.effects.reverb forKey:@"reverb"];
    [defaults setDouble:self.effects.delay forKey:@"delay"];
    [defaults setInteger:2 forKey:@"fxEngineVersion"];
    [defaults setDouble:self.freeDelaySeconds forKey:@"freeDelaySeconds"];
    [defaults setInteger:self.delayDivisionIndex forKey:@"delayDivision"];
    [defaults setDouble:self.effects.delay_seconds forKey:@"delaySeconds"];
    [defaults setInteger:self.chordExtension forKey:@"chordExtension"];
    [defaults setInteger:self.meter forKey:@"meter"];
    [defaults setInteger:self.articulation forKey:@"articulation"]; [defaults setDouble:self.stringDynamics forKey:@"stringDynamics"];
    [defaults setBool:self.midiOutEnabled forKey:@"midiOut"]; [defaults setBool:self.midi.inputEnabled forKey:@"midiIn"]; [defaults setBool:self.chordKeys forKey:@"chordKeys"]; [defaults setInteger:self.generateCount forKey:@"generateCount"];
    [defaults setInteger:self.viewMode forKey:@"viewMode"];
    [defaults setBool:self.loopEnabled forKey:@"loopEnabled"]; [defaults setInteger:self.rhythmGrid forKey:@"rhythmGrid"]; [defaults setBool:self.countIn forKey:@"countIn"];
    [defaults setInteger:self.rhythmBeat forKey:@"rhythmBeat"]; [defaults setBool:self.drumsOn forKey:@"drumsOn"]; [defaults setDouble:self.rhythmVolume forKey:@"rhythmVolume"];
    [defaults setDouble:self.tempo forKey:@"tempo"];
    id host=NSApp.delegate; if([host respondsToSelector:@selector(stateSaved)]) [host performSelector:@selector(stateSaved)];   // the open file's «edited» dot
}
/* «Вне лада»: the tiles follow the key and the harmony; the selected one is lit and explained. */
- (void)refreshChromatic {
    int codes[24],groups[24]; size_t n=kv_chromatic_codes(self.key,(int)self.chordExtension,codes,groups,24);
    BOOL same=n==self.chromaticChips.count; for(size_t i=0;same && i<n;i++) if(self.chromaticChips[i].tag!=codes[i]) same=NO;
    if(!same) {
        for(KvChip *chip in self.chromaticChips) [chip removeFromSuperview]; [self.chromaticChips removeAllObjects];
        NSMutableArray *g=[NSMutableArray array];
        for(size_t i=0;i<n;i++) {
            KvChip *chip=[KvChip buttonWithTitle:@"" target:self action:@selector(chromaticClicked:)]; chip.bezelStyle=NSBezelStyleRounded; chip.bordered=NO; chip.palette=YES; chip.tag=codes[i];
            chip.hidden=self.inspectorTab!=1; [self.chromaticChips addObject:chip]; [self addSubview:chip]; [g addObject:@(groups[i])];
        }
        self.chromaticGroups=g; self.needsLayout=YES;
    }
    int selected=(int)self.selectedDegree; BOOL outside=kv_code_base(selected)>6 && self.keyboardMode.selectedSegment==1;
    for(KvChip *chip in self.chromaticChips) {
        KvChord chord; if(!kv_code_chord(self.key,(int)chip.tag,(int)self.chordExtension,&chord)) continue;
        chip.title=S(chord.name); chip.degreeText=S(chord.degree);
        chip.hint=[NSString stringWithFormat:T(@"%@ · %@ — щелчок: послушать и прочитать, двойной щелчок: добавить"),S(chord.name),S(chord.degree)];
        BOOL current=outside && kv_code_base(selected)==chip.tag; if(chip.current!=current) chip.current=current; chip.needsDisplay=YES;
    }
    char story[400]="";
    if(outside) kv_code_story(self.key,selected,(int)self.chordExtension,story,sizeof(story));
    self.chromaticStory.stringValue=story[0]?S(story):T(@"Аккорды не из лада, но звучащие в нём: доминанты к другим ступеням, аккорды из одноимённого лада, тритоновые замены. Щелчок по плитке — послушать и прочитать, двойной щелчок или «Добавить» — в последовательность.");
    KvChord picked; BOOL has=outside && kv_code_chord(self.key,selected,(int)self.chordExtension,&picked);
    self.chromaticTitle.stringValue=has?[NSString stringWithFormat:@"%@ · %@",S(picked.name),S(picked.degree)]:T(@"Выберите плитку");
    self.chromaticTitle.textColor=has?Ink():NSColor.secondaryLabelColor;
    [self configurePlaceButton:self.chromaticAddButton available:has];
}
- (void)chromaticClicked:(KvChip *)sender {
    int code=(int)sender.tag; self.selectedDegree=code; self.keyboardMode.selectedSegment=1; [self refresh]; [self saveState];
    if(NSApp.currentEvent.clickCount>=2) { [self placeCode:code]; return; }
    KvChord chord; if(kv_code_chord(self.key,code,(int)self.chordExtension,&chord)) { int voiced[8]; size_t n=kv_chord_voiced(&chord,voiced); [self playNotes:voiced count:n voices:n duration:1]; }
}
- (void)addChromatic:(id)sender { (void)sender; if(kv_code_base((int)self.selectedDegree)>6) [self placeCode:(int)self.selectedDegree]; }
/* Where a chosen chord goes: the end of the sequence, or — when all eight slots are taken — the slot selected in it. */
- (NSInteger)replaceSlot { return self.progression.count>=8 && self.selectedChip>=0 && self.selectedChip<(NSInteger)self.progression.count?self.selectedChip:-1; }
- (void)configurePlaceButton:(NSButton *)button available:(BOOL)available {
    BOOL full=self.progression.count>=8; NSInteger slot=[self replaceSlot];
    NSString *title=!full?T(@"Добавить"):slot>=0?[NSString stringWithFormat:T(@"Заменить %ld-й"),(long)slot+1]:T(@"8 из 8");
    if(![button.title isEqualToString:title]) button.title=title;
    Hint(button,!full?T(@"Добавить аккорд в конец последовательности"):slot>=0?[NSString stringWithFormat:T(@"Последовательность заполнена: аккорд встанет на место %ld-го · ⌘Z — вернуть"),(long)slot+1]:T(@"Все 8 мест заняты: выберите аккорд в последовательности, чтобы заменить его, или удалите один"));
    button.enabled=available && (!full || slot>=0);
}
- (void)placeCode:(int)code {
    if(!kv_code_valid(code)) return;
    if(self.progression.count<8) { [self addChordCode:code]; return; }
    NSInteger slot=[self replaceSlot]; if(slot<0) { self.status.stringValue=T(@"Все 8 мест заняты: выберите аккорд в последовательности, чтобы заменить его"); return; }
    [self changeArrangement:^{ self.sequenceUndo=[self.progression copy]; self.progression[slot]=@(code); }];
    KvChord chord; if(kv_code_chord(self.key,code,(int)self.chordExtension,&chord)) self.status.stringValue=[NSString stringWithFormat:T(@"%ld-й аккорд заменён на %@ · ⌘Z — вернуть"),(long)slot+1,S(chord.name)];
}
- (void)refresh {
    [self applyRhythm];   // meter or tempo may have changed; the engine keeps the beat
    NSString *heading=[self keyTitle];
    self.heading.stringValue=heading; if(!self.roll.hidden) { [self.roll updateToolbar]; self.roll.needsDisplay=YES; }
    for(CGFloat size=24;size>=15;size-=1) { self.heading.font=[NSFont systemFontOfSize:size weight:NSFontWeightBold]; if([heading sizeWithAttributes:@{NSFontAttributeName:self.heading.font}].width<=KvInspectorWidth-2*KvMargin-4) break; }
    int signs=kv_signature(self.key);
    signs=[self writtenSignature]; char spelled[7][8]; kv_scale_names(self.key,spelled);
    NSString *raised=self.key.mode==6?[NSString stringWithFormat:T(@" · VII повышена: %@"),S(spelled[6])]:self.key.mode==7?[NSString stringWithFormat:T(@" · VI, VII повышены: %@, %@"),S(spelled[5]),S(spelled[6])]:@"";
    self.signature.stringValue=[(signs==0?T(@"Без знаков при ключе"):[NSString stringWithFormat:T(@"При ключе: %d %@"),abs(signs),signs>0?@"♯":@"♭"]) stringByAppendingString:raised];
    if(self.respelledFrom) { self.signature.stringValue=[NSString stringWithFormat:@"%@ · %@",self.signature.stringValue,self.respelledFrom]; self.signature.toolTip=T(@"Тональности с восемью и более знаками при ключе не записывают; взята одноимённая с теми же клавишами."); } else self.signature.toolTip=nil;
    char names[7][8]; int scale[8]; kv_scale_names(self.key,names); kv_scale(self.key,scale); NSMutableArray *notes=[NSMutableArray array];
    for(int i=0;i<7;i++) if(kv_in_scale(self.key,scale[i])) [notes addObject:S(names[i])]; self.scaleNames.stringValue=[notes componentsJoinedByString:@"   "];
    [self.mode selectItemAtIndex:self.key.pentatonic?(self.key.minor?10:9):self.key.mode?self.key.mode+1:self.key.minor?1:0];
    for(int i=0;i<7;i++) {
        KvChord chord; if(!kv_chord_extended(self.key,i,(int)self.chordExtension,&chord)) continue;
        self.chordButtons[i].title=[NSString stringWithFormat:@"▶  %@  %@",[S(chord.degree) stringByPaddingToLength:5 withString:@" " startingAtIndex:0],S(chord.name)];
        self.chordButtons[i].toolTip=[NSString stringWithFormat:T(@"Прослушать %@"),S(chord.name)];
        BOOL active=self.keyboardMode.selectedSegment==1 && i==kv_code_base((int)self.selectedDegree);
        self.chordButtons[i].contentTintColor=active?Accent():Ink();
        self.chordButtons[i].state=active?NSControlStateValueOn:NSControlStateValueOff;
        if(active) self.chordButtons[i].title=[self.chordButtons[i].title stringByReplacingOccurrencesOfString:@"▶" withString:@"●"];
        NSString *addHint=[NSString stringWithFormat:T(@"Добавить %@ в последовательность · ⇧%d"),S(chord.name),i+1];
        if(![((TNButton *)self.addButtons[i]).hint isEqualToString:addHint]) Hint(self.addButtons[i],addHint);
        self.addButtons[i].enabled=self.progression.count<8;
    }
    for(NSUInteger i=0;i<self.progressionButtons.count;i++) {
        KvChip *chip=(KvChip *)self.progressionButtons[i]; KvChord chord;
        if(kv_code_chord(self.key,self.progression[i].intValue,(int)self.chordExtension,&chord)) {
            chip.title=S(chord.name); chip.degreeText=S(chord.degree); chip.needsDisplay=YES;
            chip.toolTip=[NSString stringWithFormat:T(@"%@ · клик — прослушать · правый клик — обращение, удалить, переместить"),S(chord.name)];
            [chip setAccessibilityLabel:[NSString stringWithFormat:T(@"Аккорд %lu из %lu, %@"),(unsigned long)i+1,(unsigned long)self.progression.count,S(chord.name)]];
        }
    }
    [self refreshChromatic];
    self.registerControl.selectedSegment=self.keyboardBase/12-3;
    BOOL hands=self.performanceMode==1,arp=self.performanceMode==2,strings=self.performanceMode>=3,ostinato=self.performanceMode==3+KV_STRINGS_OSTINATO-KV_STRINGS_CHORALE;
    self.patternChoice.hidden=!hands; self.fillChoice.hidden=!hands; self.arrangeButton.hidden=!(hands || arp || strings);
    self.arpeggioChoice.hidden=!arp; self.divisionChoice.hidden=!(arp || ostinato);
    [self refreshTextureMenu]; self.dynamicsSlider.doubleValue=self.stringDynamics;
    [self.meterChoice selectItemAtIndex:self.meter];
    [self.lengthChoice selectItemAtIndex:[self chordLength]]; [self.fillChoice selectItemAtIndex:self.fillRate]; [self.divisionChoice selectItemAtIndex:self.division];
    [self updatePatternMenu];
    int low=0,high=0; if(hands) kv_pattern_tempo(self.pianoPattern,&low,&high); else if(arp) { low=self.division==KV_DIV_SIXTEENTH?60:80; high=self.division==KV_DIV_SIXTEENTH?110:140; }
    else if(strings) { static const int lows[4]={50,56,90,80},highs[4]={80,84,140,120}; low=lows[self.performanceMode-3]; high=highs[self.performanceMode-3]; }
    ((TNSlider *)self.tempoSlider).recommendedMin=low; ((TNSlider *)self.tempoSlider).recommendedMax=high; self.tempoSlider.needsDisplay=YES;
    self.tempoSlider.toolTip=hands?[NSString stringWithFormat:T(@"Темп, четверти в минуту · для стиля «%@» обычно %d–%d"),S(kv_pattern_russian(self.pianoPattern)),low,high]:arp?[NSString stringWithFormat:T(@"Темп, четверти в минуту · для арпеджио %@ обычно %d–%d"),[S(kv_division_name(self.division)) lowercaseString],low,high]:T(@"Темп, четверти в минуту");
    for(NSUInteger i=0;i<self.progressionButtons.count;i++) self.progressionButtons[i].state=(NSInteger)i==self.selectedChip?NSControlStateValueOn:NSControlStateValueOff;
    [self updateTransport]; self.clearButton.enabled=self.progression.count>0; self.undoSequenceButton.enabled=self.sequenceUndo!=nil;
    self.hint.stringValue=T(@"▶ послушать (1–7) · + добавить (⇧1–7)");
    self.scaleButton.enabled=self.audio!=NULL; self.soundButton.enabled=self.audio!=NULL;
    NSMutableArray<NSString *> *visibleNotes=[NSMutableArray array];
    if(self.keyboardMode.selectedSegment==1) {
        KvChord chord;
        if(kv_code_chord(self.key,(int)self.selectedDegree,(int)self.chordExtension,&chord)) {
            self.keyboardHeading.stringValue=kv_code_base((int)self.selectedDegree)<=6?[NSString stringWithFormat:T(@"Аккорд %@ · %@ ступень"),S(chord.name),S(chord.degree)]:[NSString stringWithFormat:T(@"Аккорд %@ · %@ · вне лада"),S(chord.name),S(chord.degree)];
            for(size_t i=0;i<chord.count;i++) [visibleNotes addObject:[self noteDescription:chord.midi[i]]];
        }
    } else {
        int scale[8]; int n=kv_scale_used(self.key,scale);
        self.keyboardHeading.stringValue=[NSString stringWithFormat:T(@"%@ · %d нот"),[self keyTitle],n];
        for(int i=0;i<n;i++) [visibleNotes addObject:[self noteDescription:scale[i]]];
    }
    self.keyboardNotes.stringValue=[visibleNotes componentsJoinedByString:@"     "];
    self.circle.needsDisplay=YES; self.piano.needsDisplay=YES; self.needsDisplay=YES; self.needsLayout=YES;
}
- (void)selectIndex:(int)index minor:(BOOL)minor { [self selectIndex:index minor:minor spelling:0]; }
/* Applies the seven-accidental rule and tells the user when the tonic had to be respelled. */
- (KvKey)normalizedKey:(KvKey)key {
    KvKey written=kv_key_normalize(key); self.respelledFrom=nil;
    if(written.spelling!=key.spelling) {
        int signs=kv_written_signature(key);
        NSString *root=[[S(kv_key_title(key)) componentsSeparatedByString:@" "] firstObject]; // "Ре-бемоль" from "Ре-бемоль минор" or "Ре-бемоль · Фригийский"
        self.respelledFrom=[NSString stringWithFormat:T(@"вместо %@ (%d %@)"),root.lowercaseString,abs(signs),signs>0?@"♯":@"♭"];
        self.status.stringValue=[NSString stringWithFormat:T(@"Записано как %@ · %d %@ · %@"),S(kv_key_title(written)),abs(kv_written_signature(written)),kv_written_signature(written)>0?@"♯":@"♭",self.respelledFrom];
        self.respelledNote=YES;
    }
    return written;
}
- (void)selectIndex:(int)index minor:(BOOL)minor spelling:(int)spelling {
    self.requestedSpelling=spelling;
    KvKey key=[self normalizedKey:(KvKey){kv_mod(index,12),minor,self.key.mode,spelling,self.key.pentatonic}];
    BOOL note=self.respelledNote; self.respelledNote=NO;
    if([self isPlayingProgression]) { [self changeArrangement:^{ self.key=key; if(!note) self.status.stringValue=[self keyTitle]; }]; return; }
    kv_audio_stop(self.audio); self.playbackGeneration++; self.key=key;
    if(self.trackEdited) { [self pushTrackUndo]; self.trackEdited=NO; }
    [self buildTrack]; [self refresh]; [self saveState]; if(!note) self.status.stringValue=[self keyTitle];
}
- (BOOL)isPlayingProgression { return self.playingPerformance && self.playingDegrees.count>0 && kv_audio_is_playing(self.audio); }
/* When the scheduled performance has finished on its own (no loop), forget it: a later auditioned note
   must not look like the progression playing from its first beat. */
- (void)reconcilePlayback {
    if((self.playingPerformance || self.playingDegrees) && !kv_audio_is_playing(self.audio)) {
        self.playingPerformance=NO; self.playingDegrees=nil; self.playingTwoHand=NO; [self highlightChip:-1];
    }
}
/* A texture or pattern chosen in the arranger with several sections selected (⌘A, ⇧-click) goes to all of them. */
- (void)changeTexture:(void(^)(void))change {
    if(self.viewMode==2 && self.editingSection>=0) [self pushSongUndo];   // one ⌘Z brings every section's back
    [self changeArrangement:change];
    NSRange range=self.arranger.selection; NSInteger editing=self.editingSection; KvSong *song=self.song;
    if(self.viewMode!=2 || editing<0 || editing>=(NSInteger)song->count) return;
    [self storeWorking]; NSUInteger others=0; BOOL whole=range.length<=1;   // one section selected: the texture is the song's; a range: theirs alone
    if(whole) range=NSMakeRange(0,song->count);
    for(NSUInteger i=range.location;i<NSMaxRange(range) && i<song->count;i++) if((NSInteger)i!=editing && song->sections[i].kind!=KV_SECTION_TRANSITION) {
        double was=kv_section_pass_beats(song,&song->sections[i]); KvArrangement a=song->sections[editing].arrangement; a.seed=song->sections[i].arrangement.seed; a.generated=song->sections[i].arrangement.generated;   // each keeps its own variation
        song->sections[i].arrangement=a; kv_section_keep_passes(song,&song->sections[i],was); others++; }
    if(others) { kv_song_refresh_transitions(song); self.songPlans=nil; [self.arranger reload]; [self saveState]; }
    self.status.stringValue=whole?[NSString stringWithFormat:T(@"Рисунок «%@» — у всей песни · выделите несколько секций, чтобы поменять только у них"),[self textureName]]
        :[NSString stringWithFormat:T(@"Рисунок «%@» — у выделенных секций: %lu"),[self textureName],(unsigned long)others+1];
}
/* Any change that alters the notes restarts a running progression from the current chord with the new settings. */
- (void)changeArrangement:(void(^)(void))change { [self changeArrangement:change remap:nil]; }
/* remap translates the sounding chord's index through an edit of the progression (remove, move). */
- (void)changeArrangement:(void(^)(void))change remap:(NSInteger(^)(NSInteger))remap {
    if(self.songPlaying) {   // the song goes on from where it is, with the change (the sections' row follows in followSongEdit)
        double beat=fmax(0,[self arrangerPlayheadBeat]); if(self.trackEdited) { [self pushTrackUndo]; self.trackEdited=NO; }
        change(); [self buildTrack]; [self refresh]; [self saveState]; [self restartSongAt:beat]; return;
    }
    BOOL resume=[self isPlayingProgression]; NSInteger at=MAX(0,self.currentChip); if(remap) at=remap(at);
    if(resume) { kv_audio_stop(self.audio); self.playbackGeneration++; self.visualPlayback=NO; }
    if(self.trackEdited) { [self pushTrackUndo]; self.trackEdited=NO; self.status.stringValue=T(@"Правки дорожки заменены рисунком · ⌘Z в пиано-ролле вернёт их"); }
    change(); [self buildTrack]; [self refresh]; [self saveState];
    if(resume && self.progression.count) {
        [self playProgressionFrom:(NSUInteger)MIN(MAX(0,at),(NSInteger)self.progression.count-1)];
        if(![self isPlayingProgression]) [self abandonPlayback]; // the error stays in the status line
    } else if(resume) [self stopPlayback:nil];
}
- (void)abandonPlayback {
    kv_audio_stop(self.audio); self.playingDegrees=nil; self.playingPerformance=NO; self.playingTwoHand=NO; self.visualPlayback=NO;
    [self highlightChip:-1]; [self.piano setActiveNotes:@[]];
    if(self.playbackActivity) { [NSProcessInfo.processInfo endActivity:self.playbackActivity]; self.playbackActivity=nil; }
    [self updateTransport];
}
- (void)modeChanged:(NSPopUpButton *)sender {
    NSInteger choice=sender.indexOfSelectedItem;
    [self changeArrangement:^{
        KvKey key=self.key; key.mode=choice>=2 && choice<=8?(int)choice-1:0; key.pentatonic=choice>=9; key.spelling=self.requestedSpelling;
        BOOL wantMinor=choice==1 || choice==10;
        if((choice<2 || choice>=9) && key.minor!=wantMinor) {
            // Parallel major/minor: same tonic and letter, the other ring of the circle.
            int tonic=kv_tonic(key); const char *root=kv_key_root(key); NSRange letter=[@"CDEFGAB" rangeOfString:[S(root) substringToIndex:1]];
            key.minor=wantMinor; for(int i=0;i<12;i++) if(kv_tonic((KvKey){i,key.minor,0,0})==tonic) key.circle_index=i;
            key.spelling=letter.location==NSNotFound?0:(int)letter.location+1; self.requestedSpelling=key.spelling;
        }
        key=[self normalizedKey:key]; BOOL note=self.respelledNote; self.respelledNote=NO;
        self.key=key; self.keyboardMode.selectedSegment=0; if(!note) self.status.stringValue=[self keyTitle];
    }];
}
- (void)playNotes:(const int *)notes count:(size_t)count voices:(size_t)voices duration:(double)duration {
    self.playbackGeneration++; self.visualPlayback=NO; self.playingDegrees=nil; self.playingTwoHand=NO; self.playingPerformance=NO; [self highlightChip:-1];
    if(count==1 && notes && [self isPlayingProgression]) {
        // A key pressed while the progression plays simply joins it.
        int note=notes[0]+self.keyboardBase-60; while(note>108) note-=12; while(note<21) note+=12;
        if(kv_audio_audition(self.audio,note,duration)) [self.piano flashNotes:@[@(note)]];
        return;
    }
    if(count!=1) [self.piano setActiveNotes:@[]];
    if(!notes || !voices || count>256 || count%voices) return;
    BOOL hands=self.performanceMode>=1 && voices>=3 && count==voices; // two hands and arpeggio audition one bar of their texture
    int shifted[256]; NSMutableArray<NSArray<NSNumber *> *> *events=[NSMutableArray array];
    for(size_t i=0;i<count;i++) {
        int note=notes[i]+self.keyboardBase-60;
        if(!hands) { while(note>108) note-=12; while(note<21) note+=12; }
        shifted[i]=note;
    }
    for(size_t i=0;i<count;i+=voices) { NSMutableArray *event=[NSMutableArray array]; for(size_t v=0;v<voices;v++) [event addObject:@(shifted[i+v])]; [events addObject:event]; }
    if(hands) { KvChord chord={0}; chord.count=count; memcpy(chord.midi,shifted,count*sizeof(int)); [self previewChord:&chord]; return; }
    if(events.count) [self.piano flashNotes:events[0]];
    if(!kv_audio_play(self.audio,shifted,count,voices,duration)) self.status.stringValue=T(@"⚠ Не удалось включить звук. Проверьте аудиовыход macOS.");
    else {
        if(!self.playbackActivity) self.playbackActivity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Tonora audio playback"];
        self.visualEvents=events; self.visualEventSeconds=duration; self.visualEvent=-1; self.visualPlayback=YES;
        if(count==1) _visualCount=0; else [self fingerSequence:shifted count:count voices:voices]; // a key pressed by hand: no fingers
        self.status.stringValue=T(@"Воспроизведение · Esc — стоп"); [self updatePlaybackVisualization]; [self updateTransport];
    }
}
- (void)highlightChip:(NSInteger)index {
    self.currentChip=index;
    for(NSUInteger i=0;i<self.progressionButtons.count;i++) {
        KvChip *chip=(KvChip *)self.progressionButtons[i]; BOOL current=(NSInteger)i==index;
        if(chip.current!=current) { chip.current=current; chip.needsDisplay=YES; }
    }
}
- (void)updatePlaybackVisualization {
    if(!self.visualPlayback) return;
    if(!kv_audio_is_playing(self.audio)) { self.visualPlayback=NO; [self.piano setActiveNotes:@[]]; [self highlightChip:-1]; return; }
    double time=0;
    kv_audio_playhead(self.audio,&time);
    NSInteger event=kv_audio_event(self.audio);
    BOOL newEvent=event>=0 && event!=self.visualEvent; self.visualEvent=event;
    if(newEvent && self.playingDegrees.count) {
        NSUInteger at=(NSUInteger)event%self.playingDegrees.count;
        self.selectedDegree=self.playingDegrees[at].integerValue; self.keyboardMode.selectedSegment=1;
        BOOL shown=!self.songPlaying || (self.songPart<(NSInteger)self.songOrder.count && self.songOrder[self.songPart].integerValue==self.editingSection);
        [self highlightChip:shown?(NSInteger)((at+self.playOffset)%self.playingDegrees.count):-1]; [self refresh];
    }
    int active[KV_ACTIVE_NOTES]; unsigned count=kv_audio_active_notes(self.audio,active);
    NSMutableArray<NSNumber *> *notes=[NSMutableArray array]; for(unsigned i=0;i<count;i++) [notes addObject:@(active[i])];
    if(count || time>.025) [self.piano setActiveNotes:notes];
    unsigned char roles[128]={0}; long now[128]; for(int m=0;m<128;m++) now[m]=-1;
    if(self.playingPerformance) for(unsigned i=0;i<count;i++) {
        int m=active[i]; long e=[self planEventForMidi:m]; if(e<0 || m<0 || m>127) continue;
        roles[m]=_planRoles[e]; now[m]=e;
        // The same key struck again by the next event: key and finger lift and press anew, in step with the sound.
        if(_soundingEvent[m]>=0 && _soundingEvent[m]!=e) { [self.piano retrigger:m]; [self.circle retriggerNote:m]; }
    }
    memcpy(_soundingEvent,now,sizeof(now));
    [self.piano setRoles:roles];
    if(newEvent && count) [self.piano flashNotes:notes];
}
- (void)registerChanged:(NSSegmentedControl *)sender {
    int base=(int)(sender.selectedSegment+3)*12;
    if(base==self.keyboardBase) return;
    [self changeArrangement:^{ [self.piano setActiveNotes:@[]]; self.keyboardBase=MAX(36,MIN(84,base)); }];
}
- (void)circleSelected:(int)index minor:(BOOL)minor { [self circleSelected:index minor:minor spelling:0]; }
- (void)circleSelected:(int)index minor:(BOOL)minor spelling:(int)spelling {
    self.keyboardMode.selectedSegment=0; [self selectIndex:index minor:minor spelling:spelling];
    [self playTonic:nil];
}
- (void)shiftOctave:(NSInteger)delta {
    int base=MAX(36,MIN(84,self.keyboardBase+(int)delta*12)); if(base==self.keyboardBase) return;
    [self changeArrangement:^{ [self.piano setActiveNotes:@[]]; self.keyboardBase=base; }];
}
- (void)playTonic:(id)sender {
    (void)sender; self.selectedDegree=0; [self refresh]; [self saveState]; KvChord chord; if(kv_chord_extended(self.key,0,(int)self.chordExtension,&chord)) [self playNotes:chord.midi count:chord.count voices:chord.count duration:1.0];
}
- (void)playScale:(id)sender { (void)sender; self.keyboardMode.selectedSegment=0; [self refresh]; [self saveState]; int notes[8]; int n=kv_scale_used(self.key,notes); [self playNotes:notes count:(size_t)n+1 voices:1 duration:30.0/self.tempo]; }
- (void)chordClicked:(NSButton *)sender {
    KvChord chord; if(!kv_chord_extended(self.key,(int)sender.tag,(int)self.chordExtension,&chord)) return;
    self.keyboardMode.selectedSegment=1; self.selectedDegree=sender.tag; [self saveState]; [self playNotes:chord.midi count:chord.count voices:chord.count duration:1.0]; [self refresh];
}
- (void)retagChips {
    for(NSUInteger j=0;j<self.progressionButtons.count;j++) { self.progressionButtons[j].tag=j; self.progressionButtons[j].menu.itemArray.firstObject.tag=j; }
}
- (void)addChord:(NSButton *)sender { [self addChordCode:(int)sender.tag]; }
- (void)addChordCode:(int)code {
    if(self.progression.count>=8 || !kv_code_valid(code)) return;
    [self changeArrangement:^{ self.sequenceUndo=[self.progression copy]; [self appendDegree:code]; }];
}
- (void)appendDegree:(NSInteger)degree {
    [self.window invalidateCursorRectsForView:self];
    {
        [self.progression addObject:@(degree)];
        KvChip *button=[KvChip buttonWithTitle:@"" target:self action:@selector(progressionClicked:)]; button.bezelStyle=NSBezelStyleRounded; button.bordered=NO; button.tag=self.progression.count-1;
        NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Аккорд")];
        NSMenuItem *remove=[[NSMenuItem alloc] initWithTitle:T(@"Удалить аккорд") action:@selector(removeChord:) keyEquivalent:@""]; remove.target=self; remove.tag=button.tag;
        [menu addItem:remove];
        for(NSString *title in @[T(@"Переместить влево"),T(@"Переместить вправо")]) {
            NSMenuItem *move=[[NSMenuItem alloc] initWithTitle:title action:@selector(moveChord:) keyEquivalent:@""]; move.target=self; move.representedObject=button; [menu addItem:move];
        }
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *inversions=[[NSMenuItem alloc] initWithTitle:T(@"Обращение") action:nil keyEquivalent:@""]; NSMenu *sub=[[NSMenu alloc] initWithTitle:T(@"Обращение")];
        NSArray *titles=@[T(@"Основной вид"),T(@"Терция в басу"),T(@"Квинта в басу"),T(@"Септима в басу")];
        for(NSInteger k=0;k<4;k++) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:titles[k] action:@selector(setInversion:) keyEquivalent:@""]; item.target=self; item.tag=k; item.representedObject=button; [sub addItem:item]; }
        inversions.submenu=sub; [menu addItem:inversions];
        button.menu=menu;
        [self.progressionButtons addObject:button]; [self addSubview:button];
        self.needsLayout=YES;
    }
}
- (void)progressionClicked:(NSButton *)sender {
    if(sender.tag<0 || sender.tag>=(NSInteger)self.progression.count) return;
    self.selectedChip=sender.tag; [self.window makeFirstResponder:self]; [self refreshChromatic];
    self.selectedDegree=self.progression[sender.tag].integerValue; self.keyboardMode.selectedSegment=1; [self refresh]; [self saveState];
    if([self isPlayingProgression]) return; // selecting while the progression plays must not interrupt it
    KvChord chord; if(kv_code_chord(self.key,self.progression[sender.tag].intValue,(int)self.chordExtension,&chord)) { int voiced[8]; size_t n=kv_chord_voiced(&chord,voiced); [self playNotes:voiced count:n voices:n duration:1]; }
}
- (void)removeChordAtIndex:(NSUInteger)i {
    if(i>=self.progressionButtons.count) return;
    NSInteger removed=(NSInteger)i;
    [self changeArrangement:^{
        self.sequenceUndo=[self.progression copy];
        [self.progressionButtons[i] removeFromSuperview]; [self.progressionButtons removeObjectAtIndex:i]; [self.progression removeObjectAtIndex:i];
        [self retagChips];
        if(self.selectedChip>removed) self.selectedChip--; // keep the same chord selected
        if(self.selectedChip>=(NSInteger)self.progression.count) self.selectedChip=(NSInteger)self.progression.count-1;
        self.needsLayout=YES; self.status.stringValue=T(@"Аккорд удалён · ⌘Z — вернуть");
    } remap:^NSInteger(NSInteger index) { return index>removed?index-1:index; }];
}
- (void)removeChord:(NSMenuItem *)sender { [self removeChordAtIndex:(NSUInteger)sender.tag]; }
/* The bass of one chord of the progression: root position, third, fifth or seventh (C, C/E, C/G, C7/B♭). */
- (void)setInversion:(NSMenuItem *)sender {
    NSInteger index=((NSButton *)sender.representedObject).tag; if(index<0 || index>=(NSInteger)self.progression.count) return;
    int code=kv_code_with_inversion(self.progression[index].intValue,(int)sender.tag);
    [self changeArrangement:^{ self.sequenceUndo=[self.progression copy]; self.progression[index]=@(code); self.selectedDegree=code; self.keyboardMode.selectedSegment=1; }];
    KvChord chord; if(![self isPlayingProgression] && kv_code_chord(self.key,code,(int)self.chordExtension,&chord)) { int voiced[8]; size_t n=kv_chord_voiced(&chord,voiced); [self playNotes:voiced count:n voices:n duration:1]; }
    self.status.stringValue=[NSString stringWithFormat:T(@"%@ · %@ · ⌘Z — вернуть"),S(chord.name),sender.title];
}
- (void)removeSelectedChord:(id)sender { (void)sender; if(self.selectedChip>=0) [self removeChordAtIndex:(NSUInteger)self.selectedChip]; }
- (void)undoSequence:(id)sender {
    if(self.viewMode==1) { [self pianoRollUndo:self.roll]; return; }
    if(self.viewMode==2 && self.songUndo.count) { [self undoSong]; return; }
    (void)sender; if(!self.sequenceUndo) return;
    NSArray *restore=self.sequenceUndo, *current=[self.progression copy]; BOOL resume=[self isPlayingProgression];
    [self clearProgression:nil];
    for(NSNumber *code in restore) [self addChordCode:code.intValue];
    self.sequenceUndo=current; [self refresh];
    self.status.stringValue=T(@"Предыдущая последовательность восстановлена");
    if(resume && self.progression.count) [self playProgressionFrom:0];
}
- (void)moveChordFrom:(NSInteger)from to:(NSInteger)to {
    NSInteger count=(NSInteger)self.progression.count; if(from<0 || from>=count) return;
    to=MAX(0,MIN(count-1,to)); if(from==to) { self.needsLayout=YES; return; }
    [self changeArrangement:^{
        self.sequenceUndo=[self.progression copy];
        NSNumber *degree=self.progression[from]; [self.progression removeObjectAtIndex:from]; [self.progression insertObject:degree atIndex:to];
        self.selectedChip=to; self.needsLayout=YES;
    } remap:^NSInteger(NSInteger index) {
        if(index==from) return to;
        if(from<index && index<=to) return index-1;
        if(to<=index && index<from) return index+1;
        return index;
    }];
}
- (void)moveChord:(NSMenuItem *)sender {
    NSButton *button=sender.representedObject;
    [self moveChordFrom:button.tag to:button.tag+([sender.title hasSuffix:T(@"влево")]?-1:1)];
}
- (void)chip:(NSButton *)chip droppedAt:(CGFloat)x {
    KvMetrics m=self.metrics; NSInteger slot=(NSInteger)floor((x-m.cx)/(m.slotW+KvSlotGap));
    [self moveChordFrom:chip.tag to:slot]; self.needsLayout=YES;
}
- (void)clearProgression:(id)sender {
    (void)sender; self.sequenceUndo=[self.progression copy];
    if([self isPlayingProgression]) [self stopPlayback:nil]; else { kv_audio_stop(self.audio); self.playbackGeneration++; }
    for(NSButton *button in self.progressionButtons) [button removeFromSuperview];
    [self.progressionButtons removeAllObjects]; [self.progression removeAllObjects]; self.selectedChip=-1;
    if(self.trackEdited) { [self pushTrackUndo]; self.trackEdited=NO; } [self buildTrack]; [self refresh]; [self saveState];
}
- (KvChordLength)chordLength { return self.performanceMode>=3?self.chordLengthStrings:self.performanceMode==1?self.chordLengthHands:self.performanceMode==2?self.chordLengthArp:self.chordLengthBlocks; }
- (BOOL)stringsChosen { return self.instrument==KV_INSTRUMENT_STRINGS && self.stringsAvailable; }
/* The texture's name for titles and files: «аккорды», «арпеджио вверх», a style, «струнные · хорал». */
- (NSString *)textureName {
    if(self.performanceMode>=3) return [T(@"струнные · ") stringByAppendingString:[S(kv_string_texture_name((KvStringTexture)(self.performanceMode-2))) lowercaseString]];
    return self.performanceMode==0?T(@"аккорды"):self.performanceMode==2?[NSString stringWithFormat:T(@"арпеджио %@"),[S(kv_arpeggio_name(self.arpeggioPattern)) lowercaseString]]:S(kv_pattern_russian(self.pianoPattern));
}
- (KvArrangement)arrangementForPreview:(BOOL)preview {
    return (KvArrangement){.style=self.pianoPattern,.meter=self.meter,.length=[self chordLength],.fills=self.fillRate,.seed=self.arrangementSeed,
        .generated=self.generatedRhythm,.blocks=self.performanceMode==0,.arpeggio=self.performanceMode==2,.arpeggio_pattern=self.arpeggioPattern,.division=self.division,.preview=preview,.seconds_per_beat=60.0/self.tempo,
        .strings=self.performanceMode>=3?(KvStringTexture)(self.performanceMode-2):KV_STRINGS_NONE};
}
/* The plan the keyboard and the hands follow: its fingering and each note's role, worked out once when it starts. */
- (void)adoptPlan:(const KvPerformance *)plan chords:(const KvChord *)chords count:(size_t)count {
    if(!self.currentPlan) self.currentPlan=malloc(sizeof(KvPerformance)); if(!self.currentPlan) return;
    *self.currentPlan=*plan; kv_finger_performance(self.currentPlan,_planFingers);
    unsigned masks[64]={0}; size_t n=MIN(count,(size_t)64); for(size_t i=0;i<n;i++) for(size_t v=0;v<chords[i].count;v++) masks[i]|=1u<<(((chords[i].midi[v]%12)+12)%12);
    kv_note_roles(self.currentPlan,masks,n,_planRoles);
}
- (void)startPerformance:(const KvPerformance *)plan chords:(const KvChord *)chords count:(size_t)count degrees:(NSArray<NSNumber *> *)degrees offset:(NSUInteger)offset {
    if(self.songPlaying) [self endSong];   // anything else that starts replaces the song
    [self applyTrackGains];   // 1: a section or the circle's progression plays as built
    self.playbackGeneration++; self.visualPlayback=NO; [self.piano setActiveNotes:@[]];
    if(!kv_audio_performance(self.audio,plan,60.0/(self.tempo*self.speed))) { self.status.stringValue=T(@"⚠ Не удалось включить звук. Проверьте аудиовыход macOS."); return; }
    self.playingDegrees=[degrees copy]; self.playOffset=offset; self.playingPerformance=YES; self.playingTwoHand=self.performanceMode==1; self.playingBeatsPerChord=plan->beats_per_chord;
    [self adoptPlan:plan chords:chords count:count];
    _visualCount=0;
    self.rateBeat=0; self.rateSeconds=0;
    NSMutableArray *events=[NSMutableArray array];
    for(size_t i=0;i<count;i++) { NSMutableArray *notes=[NSMutableArray array]; for(size_t v=0;v<chords[i].count;v++) [notes addObject:@(chords[i].midi[v])]; [events addObject:notes]; }
    self.visualEvents=events; self.visualEventSeconds=plan->beats_per_chord*60.0/(self.tempo*self.speed); self.visualEvent=-1; self.visualPlayback=YES;
    if(!self.playbackActivity) self.playbackActivity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep reason:@"Tonora playback"];
    if(degrees.count && !kv_audio_set_loop(self.audio,self.loopEnabled)) self.status.stringValue=T(@"⚠ Не удалось включить повтор");
    else self.status.stringValue=T(@"Воспроизведение · Esc — стоп");
    [self updatePlaybackVisualization]; [self updateTransport];
}
- (void)previewChord:(const KvChord *)chord {
    KvPerformance plan;
    if(!kv_arrange_with(chord,1,self.keyboardBase,self.key,[self arrangementForPreview:YES],&plan)) { self.status.stringValue=T(@"⚠ Не удалось построить фактуру"); return; }
    [self startPerformance:&plan chords:chord count:1 degrees:nil offset:0];
}
- (void)playProgressionFrom:(NSUInteger)start { [self playNotesFrom:start]; [self applyRhythm]; }   // its drums come in with it
- (void)playNotesFrom:(NSUInteger)start {
    NSUInteger count=self.progression.count; if(!count) return; start%=count;
    if(self.editingSection>=0 && self.editingSection<(NSInteger)self.song->count) {   // a section: its notes, register and level, from its start
        KvChord chords[8]; NSMutableArray *codes=[NSMutableArray array]; KvPerformance plan;
        if(self.trackEdited && !kv_performance_valid(self.track)) { self.status.stringValue=T(@"⚠ Дорожка повреждена · «Из рисунка» пересоберёт её"); return; }
        KvSong *song=[self songWithWorking]; double pass=kv_section_pass_beats(song,&song->sections[self.editingSection]);
        KvPerformance *own=malloc(sizeof(KvPerformance)); BOOL built=own && [self passOfSection:self.editingSection into:own depth:0] && kv_section_part(song,(size_t)self.editingSection,own,0,pass,&plan); free(own);   // its notes: edited, grown from its source, or its pattern
        if(!built) { self.status.stringValue=T(@"⚠ Не удалось построить исполнение"); return; }
        size_t n=[self chordsOfSection:self.editingSection into:chords codes:codes];
        [self startPerformance:&plan chords:chords count:n degrees:codes offset:0]; return;
    }
    KvChord chords[8]; NSMutableArray<NSNumber *> *degrees=[NSMutableArray array];
    for(NSUInteger i=0;i<count;i++) {
        NSNumber *degree=self.progression[(start+i)%count]; KvChord chord;
        if(!kv_code_chord(self.key,degree.intValue,(int)self.chordExtension,&chord)) return;
        for(size_t v=0;v<chord.count;v++) chord.midi[v]+=self.keyboardBase-60;
        chords[i]=chord; [degrees addObject:degree];
    }
    if(self.trackEdited && !self.track->count) { self.status.stringValue=T(@"Дорожка пуста · добавьте ноты или нажмите «Из рисунка»"); return; }
    if(self.trackEdited && self.track->chord_count!=count) { self.trackEdited=NO; self.roll.edited=NO; [self buildTrack]; }
    if(self.trackEdited && self.track->count && self.track->chord_count==count) {
        // An edited track always plays from its first bar; the chips still follow the chords.
        if(start) { degrees=[self.progression mutableCopy]; for(NSUInteger i=0;i<count;i++) { KvChord chord; kv_code_chord(self.key,self.progression[i].intValue,(int)self.chordExtension,&chord); for(size_t v=0;v<chord.count;v++) chord.midi[v]+=self.keyboardBase-60; chords[i]=chord; } }
        if(!kv_performance_valid(self.track)) { self.status.stringValue=T(@"⚠ Дорожка повреждена · «Из рисунка» пересоберёт её"); return; }
        [self startPerformance:self.track chords:chords count:count degrees:degrees offset:0]; return;
    }
    KvPerformance plan;
    if(!kv_arrange_with(chords,count,self.keyboardBase,self.key,[self arrangementForPreview:NO],&plan)) { self.status.stringValue=T(@"⚠ Не удалось построить исполнение"); return; }
    if(!start) { *self.track=plan; [self.roll reload]; }
    [self startPerformance:&plan chords:chords count:count degrees:degrees offset:start];
}
/* Fills the track from the current progression and arrangement (unless the user's edits are in force). */
- (BOOL)buildTrack {
    if(self.trackEdited) return YES;
    NSUInteger count=self.progression.count; KvChord chords[8];
    if(!count) { memset(self.track,0,sizeof(KvPerformance)); [self.roll reload]; return NO; }
    for(NSUInteger i=0;i<count;i++) { if(!kv_code_chord(self.key,self.progression[i].intValue,(int)self.chordExtension,&chords[i])) return NO; for(size_t v=0;v<chords[i].count;v++) chords[i].midi[v]+=self.keyboardBase-60; }
    KvPerformance plan;
    if(self.editingSection>=0 && self.editingSection<(NSInteger)self.song->count) { if(![self passOfSection:self.editingSection into:&plan depth:0]) return NO; }   // the section's notes: its register, or grown from its source
    else if(!kv_arrange_with(chords,count,self.keyboardBase,self.key,[self arrangementForPreview:NO],&plan)) return NO;
    *self.track=plan; self.roll.edited=NO; self.roll.splitNote=[self keyboardStart]+12; [self.roll reload]; return YES;
}
- (NSData *)trackData { return [NSData dataWithBytes:self.track length:sizeof(KvPerformance)]; }
- (NSData *)trackSnapshot { NSMutableData *data=[NSMutableData dataWithBytes:self.track length:sizeof(KvPerformance)]; uint8_t edited=self.trackEdited?1:0; [data appendBytes:&edited length:1]; return data; }
- (void)restoreTrack {
    NSUserDefaults *defaults=Defaults(); self.viewMode=MIN(2,MAX(0,[defaults integerForKey:@"viewMode"])); self.viewSwitch.selectedSegment=self.viewMode;
    NSData *data=[defaults dataForKey:@"trackData"];
    if([defaults boolForKey:@"trackEdited"] && data.length==sizeof(KvPerformance)) {
        KvPerformance restored; memcpy(&restored,data.bytes,sizeof(restored));
        if(kv_performance_valid(&restored) && restored.chord_count==self.progression.count && fabs(restored.beats_per_chord-kv_chord_beats(self.meter,[self chordLength]))<1e-9) { *self.track=restored; self.trackEdited=YES; self.roll.edited=YES; [self.roll reload]; return; }
    }
    self.trackEdited=NO; [self buildTrack];
}
- (void)pushTrackUndo { [self.trackUndo addObject:[self trackSnapshot]]; if(self.trackUndo.count>60) [self.trackUndo removeObjectAtIndex:0]; [self.trackRedo removeAllObjects]; }
- (BOOL)snapshotFitsProgression:(NSData *)snapshot {
    if(snapshot.length<sizeof(KvPerformance)) return NO; const KvPerformance *p=snapshot.bytes;
    return p->chord_count==self.progression.count && fabs(p->beats_per_chord-kv_chord_beats(self.meter,[self chordLength]))<1e-9;
}
- (void)restartTrackIfPlaying {
    if(self.songPlaying) { [self restartSongAt:fmax(0,[self arrangerPlayheadBeat])]; return; }
    if(![self isPlayingProgression]) { [self refreshMidiDevices]; return; }
    kv_audio_stop(self.audio); self.playbackGeneration++; self.visualPlayback=NO;
    [self playProgressionFrom:0]; if(![self isPlayingProgression]) [self abandonPlayback];
}
- (void)applyTrackSnapshot:(NSData *)snapshot {
    memcpy(self.track,snapshot.bytes,sizeof(KvPerformance));
    BOOL edited=snapshot.length>sizeof(KvPerformance)?((const uint8_t *)snapshot.bytes)[sizeof(KvPerformance)]!=0:YES;
    self.trackEdited=edited; self.roll.edited=edited; [self.roll reload]; [self saveState]; [self updateTransport]; [self restartTrackIfPlaying];
}
// ---- KvPianoRollOwner ----
- (void)pianoRollWillEdit:(KvPianoRoll *)roll { (void)roll; [self pushTrackUndo]; }
- (void)pianoRollDidEdit:(KvPianoRoll *)roll {
    (void)roll;
    // A drag that ends where it began, or a transposition stopped by the keyboard's edge, is not an edit.
    NSData *last=self.trackUndo.lastObject;
    if(last && last.length>sizeof(KvPerformance) && memcmp(last.bytes,self.track,sizeof(KvPerformance))==0) {
        BOOL edited=((const uint8_t *)last.bytes)[sizeof(KvPerformance)]!=0; [self.trackUndo removeLastObject];
        self.trackEdited=edited; self.roll.edited=edited; [self.roll updateToolbar]; return;
    }
    self.trackEdited=YES; [self saveState]; [self updateTransport]; [self restartTrackIfPlaying];
}
- (void)pianoRoll:(KvPianoRoll *)roll audition:(int)midi { (void)roll; if(self.audio && midi>=21 && midi<=108) { kv_audio_preview(self.audio,midi,.5); [self.piano flashNotes:@[@(midi)]]; } }
- (NSString *)pianoRoll:(KvPianoRoll *)roll nameForMidi:(int)midi { (void)roll; return [self keyboardName:midi]; }
- (NSArray<NSString *> *)pianoRollChordNames:(KvPianoRoll *)roll {
    (void)roll; NSMutableArray *names=[NSMutableArray array];
    for(NSNumber *degree in self.progression) { KvChord chord; if(kv_code_chord(self.key,degree.intValue,(int)self.chordExtension,&chord)) [names addObject:[NSString stringWithFormat:@"%@ · %@",S(chord.degree),S(chord.name)]]; }
    return names;
}
- (double)pianoRollBeatsPerBar:(KvPianoRoll *)roll { (void)roll; return kv_meter_bar(self.meter); }
- (NSArray<NSNumber *> *)pianoRollChordMasks:(KvPianoRoll *)roll {
    (void)roll; NSMutableArray *masks=[NSMutableArray array];
    for(NSNumber *degree in self.progression) { KvChord chord; unsigned mask=0;
        if(kv_code_chord(self.key,degree.intValue,(int)self.chordExtension,&chord)) for(size_t v=0;v<chord.count;v++) mask|=1u<<(((chord.midi[v]%12)+12)%12);
        [masks addObject:@(mask)]; }
    return masks;
}
- (unsigned)pianoRollScale:(KvPianoRoll *)roll tonic:(int *)tonic {
    (void)roll; int scale[8]; kv_scale(self.key,scale); unsigned mask=0;
    for(int i=0;i<7;i++) if(kv_in_scale(self.key,scale[i])) mask|=1u<<(((scale[i]%12)+12)%12);
    if(tonic) *tonic=((scale[0]%12)+12)%12; return mask;
}
- (NSString *)pianoRollScaleName:(KvPianoRoll *)roll { (void)roll; return self.heading.stringValue; }
- (NSArray<NSString *> *)pianoRollSections:(KvPianoRoll *)roll {
    (void)roll; if(self.editingSection<0) return nil;
    const KvSong *song=[self songWithWorking]; double bar=kv_meter_bar(song->meter); NSMutableArray *names=[NSMutableArray array];
    for(size_t i=0;i<song->count;i++) {
        int first=(int)floor(kv_section_start(song,i)/bar+1e-9)+1,last=(int)ceil((kv_section_start(song,i)+kv_section_beats(song,i))/bar-1e-9);
        [names addObject:[NSString stringWithFormat:@"%@ · %@",[self arrangerName:(NSInteger)i],first==last?[NSString stringWithFormat:T(@"такт %d"),first]:[NSString stringWithFormat:T(@"такты %d–%d"),first,last]]];
    }
    return names;
}
- (NSInteger)pianoRollSection:(KvPianoRoll *)roll { (void)roll; return self.editingSection; }
- (void)pianoRoll:(KvPianoRoll *)roll openSection:(NSInteger)index {
    (void)roll; if(index<0) { if(self.viewMode==2) { self.rollDocked=NO; self.needsLayout=YES; [self layoutSubtreeIfNeeded]; [self.window makeFirstResponder:self.arranger]; } else [self showView:2]; return; }
    [self editSection:index]; [self.roll reload]; [self.window makeFirstResponder:self.roll];
    self.status.stringValue=[NSString stringWithFormat:T(@"Пиано-ролл · секция «%@» · ⇧⌘A — обратно в аранжировщик"),[self arrangerName:index]];
}
- (int)pianoRollFirstBar:(KvPianoRoll *)roll {
    (void)roll; if(self.editingSection<0 || self.editingSection>=(NSInteger)self.song->count) return 1;
    return (int)floor(kv_section_start([self songWithWorking],(size_t)self.editingSection)/kv_meter_bar(self.meter)+1e-9)+1;
}
- (void)pianoRollResetRequested:(KvPianoRoll *)roll {
    (void)roll; if(self.trackEdited) [self pushTrackUndo];
    self.trackEdited=NO; [self buildTrack]; [self saveState]; [self updateTransport]; [self restartTrackIfPlaying];
    self.status.stringValue=self.progression.count?T(@"Дорожка заполнена текущим рисунком"):T(@"Добавьте аккорды — дорожка строится из последовательности");
}
- (void)pianoRoll:(KvPianoRoll *)roll speedChanged:(double)speed {
    (void)roll; [self markRateChange]; self.speed=speed;
    if(self.visualPlayback && self.playingPerformance) {
        double interval=60.0/(self.tempo*self.speed); self.visualEventSeconds=interval*self.playingBeatsPerChord;
        if(!kv_audio_set_interval(self.audio,interval)) self.status.stringValue=T(@"⚠ Не удалось изменить скорость");
    }
    [self updateTransport];
}
- (void)pianoRollUndo:(KvPianoRoll *)roll {
    (void)roll; if(!self.trackUndo.count) return;
    NSData *snapshot=self.trackUndo.lastObject; [self.trackUndo removeLastObject];
    if(![self snapshotFitsProgression:snapshot]) { self.status.stringValue=T(@"Снимок дорожки из другой последовательности пропущен"); [self pianoRollUndo:roll]; return; }
    [self.trackRedo addObject:[self trackSnapshot]]; [self applyTrackSnapshot:snapshot];
}
- (void)pianoRollRedo:(KvPianoRoll *)roll {
    (void)roll; if(!self.trackRedo.count) return;
    NSData *snapshot=self.trackRedo.lastObject; [self.trackRedo removeLastObject];
    if(![self snapshotFitsProgression:snapshot]) { [self pianoRollRedo:roll]; return; }
    [self.trackUndo addObject:[self trackSnapshot]]; [self applyTrackSnapshot:snapshot];
}
- (void)pianoRollForwardKey:(NSEvent *)event { [self keyDown:event]; }
- (BOOL)pianoRollPlayKey:(NSEvent *)event { return [self computerKeyDown:event]; }
/* Strings: a keyswitch (C♯1 legato and sustain, D1 spiccato, D♯1 pizzicato) a 64th before every note whose stroke class
   changes, as orchestral libraries expect. shortcut: keyswitches that do not fit the 512-event clip are left out; a fuller track would need a larger clip. */
- (size_t)addKeyswitches:(KvPianoEvent *)clip count:(size_t)n {
    static KvPerformance sorted; sorted.count=n; memcpy(sorted.events,clip,n*sizeof(KvPianoEvent));
    for(size_t i=1;i<n;i++) { KvPianoEvent e=sorted.events[i]; size_t j=i; while(j && sorted.events[j-1].beat>e.beat) { sorted.events[j]=sorted.events[j-1]; j--; } sorted.events[j]=e; }
    unsigned char strokes[KV_PERFORMANCE_CAPACITY]; kv_string_strokes(&sorted,self.articulation,strokes);
    int current=-1; size_t total=n;
    for(size_t i=0;i<n && total<KV_PERFORMANCE_CAPACITY;i++) {
        int key=strokes[i]==KV_STROKE_SPICCATO?KV_KEYSWITCH_LOW+KV_ARTICULATION_STACCATO:strokes[i]==KV_STROKE_PIZZICATO?KV_KEYSWITCH_LOW+KV_ARTICULATION_PIZZICATO:KV_KEYSWITCH_LOW+KV_ARTICULATION_LEGATO;
        if(key==current) continue; current=key;
        clip[total++]=(KvPianoEvent){key,fmax(0,sorted.events[i].beat-1.0/16),1.0/32,.5f,sorted.events[i].chord,0,0,0};
    }
    return total;
}
/* MIDI clip for a DAW: the roll's selection (from the bar of its first note), or the whole track. */
- (NSData *)midiClipDataSelectionOnly:(BOOL)selectionOnly name:(NSString **)name {
    if(![self buildTrack] && !self.trackEdited) return nil;
    KvPerformance *t=self.track; if(!t->count) return nil;
    static KvPianoEvent clip[KV_PERFORMANCE_CAPACITY]; size_t n=0; double first=INFINITY,end=0,bar=kv_meter_bar(self.meter);
    BOOL some=selectionOnly && [self.roll selectedCount]>0;
    for(size_t i=0;i<t->count;i++) if(!some || [self.roll isSelectedAt:i]) first=fmin(first,t->events[i].beat);
    double offset=some?floor(first/bar+1e-9)*bar:0;
    for(size_t i=0;i<t->count;i++) if(!some || [self.roll isSelectedAt:i]) { KvPianoEvent e=t->events[i]; e.beat-=offset; clip[n++]=e; end=fmax(end,e.beat+e.duration); }
    double length=some?ceil(end/bar-1e-9)*bar:t->total_beats; if(length<bar) length=bar;
    if([self stringsChosen]) n=[self addKeyswitches:clip count:n];
    int numerator=self.meter==KV_METER_4_4?4:self.meter==KV_METER_3_4?3:6,power=self.meter==KV_METER_6_8?3:2;
    int scale[8]; kv_scale(self.key,scale); BOOL minor=scale[2]-scale[0]==3;
    NSString *texture=[self textureName];
    NSString *title=[NSString stringWithFormat:@"Tonora · %@ · %@%@",[self keyTitle],texture,some?[NSString stringWithFormat:T(@" · такты %.0f–%.0f"),offset/bar+1,(offset+length)/bar]:@""];
    if(name) *name=[[title stringByReplacingOccurrencesOfString:@"/" withString:@"-"] stringByAppendingString:@".mid"];
    static uint8_t buffer[1<<17];
    size_t size=kv_midi_encode_events(clip,n,length,self.tempo,numerator,power,[self writtenSignature],minor,[self midiProgram],title.UTF8String,buffer,sizeof(buffer));
    return size?[NSData dataWithBytes:buffer length:size]:nil;
}
- (NSURL *)midiClipURLSelectionOnly:(BOOL)selectionOnly {
    NSString *name=nil; NSData *data=[self midiClipDataSelectionOnly:selectionOnly name:&name]; if(!data) { self.status.stringValue=T(@"Нет нот для MIDI-клипа"); return nil; }
    NSURL *folder=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"Tonora MIDI"] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *url=[folder URLByAppendingPathComponent:name];
    if(![data writeToURL:url atomically:YES]) { self.status.stringValue=T(@"⚠ Не удалось подготовить MIDI-клип"); return nil; }
    return url;
}
- (NSURL *)pianoRollMidiClip:(KvPianoRoll *)roll { (void)roll; return [self midiClipURLSelectionOnly:YES]; }
- (BOOL)copyMidiToPasteboard:(NSPasteboard *)pasteboard {
    NSURL *url=[self midiClipURLSelectionOnly:YES]; NSData *data=url?[NSData dataWithContentsOfURL:url]:nil; if(!data) return NO;
    NSPasteboardItem *item=[NSPasteboardItem new];
    [item setString:url.absoluteString forType:NSPasteboardTypeFileURL];
    [item setData:data forType:@"public.midi-audio"];
    [pasteboard clearContents]; return [pasteboard writeObjects:@[item]];
}
- (void)pianoRollCopyMidi:(KvPianoRoll *)roll {
    (void)roll; BOOL some=[self.roll selectedCount]>0;
    self.status.stringValue=[self copyMidiToPasteboard:NSPasteboard.generalPasteboard]?(some?T(@"MIDI выделенных нот в буфере обмена · вставьте в DAW или Finder"):T(@"MIDI всей дорожки в буфере обмена · вставьте в DAW или Finder")):T(@"⚠ Не удалось скопировать MIDI");
}
- (void)copyMidi:(id)sender { (void)sender; [self pianoRollCopyMidi:self.roll]; }
- (void)redoTrack:(id)sender { (void)sender; if(self.viewMode==2) [self redoSong]; else [self pianoRollRedo:self.roll]; }
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if(item.action==@selector(undoSequence:) && self.viewMode==2 && self.songUndo.count) { item.title=T(@"Отменить правку песни"); return YES; }
    if(item.action==@selector(redoTrack:) && self.viewMode==2) { item.title=T(@"Повторить правку песни"); return self.songRedo.count>0; }
    if(item.action==@selector(redoTrack:)) item.title=T(@"Повторить правку дорожки");
    if(item.action==@selector(undoSequence:)) { item.title=self.viewMode==1?T(@"Отменить правку дорожки"):T(@"Вернуть последовательность"); return self.viewMode==1?self.trackUndo.count>0:self.sequenceUndo!=nil; }
    if(item.action==@selector(redoTrack:)) return self.viewMode==1 && self.trackRedo.count>0;
    if(item.action==@selector(duplicateSection:) || item.action==@selector(cutSection:)) return self.viewMode==2 && self.editingSection>=0;
    if(item.action==@selector(exportSong:)) return self.song->count>0;
    if(item.action==@selector(sendToArranger:)) { item.title=self.editingSection>=0?T(@"Обратно в аранжировщик"):T(@"В аранжировщик"); return self.editingSection>=0 || self.progression.count>0; }
    if(item.action==@selector(showCircle:) || item.action==@selector(showRoll:) || item.action==@selector(showArranger:)) { item.state=self.viewMode==(item.action==@selector(showCircle:)?0:item.action==@selector(showRoll:)?1:2)?NSControlStateValueOn:NSControlStateValueOff; return YES; }
    if(item.action==@selector(continueProgression:)) return [self continueCount]>0;
    if(item.action==@selector(setInversion:)) {
        NSInteger index=((NSButton *)item.representedObject).tag; if(index<0 || index>=(NSInteger)self.progression.count) return NO;
        int code=self.progression[index].intValue; KvChord chord; BOOL ok=kv_code_chord(self.key,kv_code_base(code),(int)self.chordExtension,&chord);
        item.state=kv_code_inversion(code)==item.tag?NSControlStateValueOn:NSControlStateValueOff;
        return ok && item.tag<(NSInteger)chord.count;   // the seventh only for seventh chords and richer
    }
    return YES;
}
- (void)viewChanged:(NSSegmentedControl *)sender {
    self.viewMode=sender.selectedSegment;
    // The circle edits the draft; the arranger edits its selected section; the roll keeps whichever was being edited.
    if(self.viewMode==0) [self editDraft];
    else if(self.viewMode==2) { [self.arranger reload]; if(self.song->count) [self editSection:self.arranger.selected]; }
    if(self.viewMode==1) { self.roll.onlyHand=-1; [self buildTrack]; [self.roll reload]; }
    [self matchInspectorToView];
    [self.window makeFirstResponder:[self viewFocus]];
    self.needsLayout=YES; [self layoutSubtreeIfNeeded]; [self saveState];
    if(self.viewMode==1) self.status.stringValue=self.editingSection>=0?[NSString stringWithFormat:T(@"Пиано-ролл · секция «%@» · ⇧⌘A — обратно в аранжировщик"),[self arrangerName:self.editingSection]]:T(@"Пиано-ролл · двойной щелчок — нота · ⌫ — удалить · ⌘Z — отмена · «Из рисунка» — пересобрать");
    if(self.viewMode==2) self.status.stringValue=self.song->count?T(@"Аранжировщик · Пробел — песня · ⌥Пробел — секция · двойной щелчок — в ролл"):T(@"Аранжировщик · соберите последовательность на круге и нажмите ⇧⌘A");
}
/* The «Секция» tab belongs to the arranger: it opens with it and gives way to «Аккорды» elsewhere. */
- (void)matchInspectorToView {
    NSInteger segments=self.viewMode==2?4:3;   // «Секция» only where there are sections
    if(self.inspectorTabs.segmentCount!=segments) { self.inspectorTabs.segmentCount=segments; if(segments==4) [self.inspectorTabs setLabel:T(@"Секция") forSegment:3]; self.needsLayout=YES; }
    NSInteger tab=self.viewMode==2?3:self.inspectorTab==3?0:self.inspectorTab;
    if(tab!=self.inspectorTab || self.inspectorTabs.selectedSegment!=tab) { self.inspectorTabs.selectedSegment=tab; self.inspectorTab=tab; self.needsLayout=YES; self.needsDisplay=YES; }
}
- (NSView *)viewFocus { return self.viewMode==1?(NSView *)self.roll:self.viewMode==2?(NSView *)self.arranger:self; }
- (void)showView:(NSInteger)mode { [self.viewSwitch setSelectedSegment:mode]; [self viewChanged:self.viewSwitch]; }
- (void)showCircle:(id)sender { (void)sender; [self showView:0]; }
- (void)showRoll:(id)sender { (void)sender; [self showView:1]; }
- (void)showArranger:(id)sender { (void)sender; [self showView:2]; }
- (void)playProgression:(id)sender {
    (void)sender;
    if(self.metronomeOn && self.countIn && ![self isPlayingProgression] && self.progression.count && self.audio) kv_audio_count_in(self.audio,kv_meter_bar(self.meter));   // one bar of clicks first
    [self playProgressionFrom:0];
}
- (int)keyboardStart { return self.performanceMode==1?self.keyboardBase-12:self.keyboardBase; }
- (int)keyboardViewStart {
    int start=[self keyboardStart]; if(!self.computerKeyboard) return start;
    start+=self.computerBase-self.keyboardBase;              // Z / X move the drawn keyboard with the computer keys
    return MAX(24,MIN(108-[self keyboardCount]+1-((108-[self keyboardCount]+1)%12),start));
}
- (int)computerLetterBase { return self.computerKeyboard?self.computerBase:-1; }
/* The register (C2–C6, ⌘↑ ⌘↓) also sets the computer keyboard's octave, so the two never drift apart. */
- (void)setKeyboardBase:(int)keyboardBase { _keyboardBase=keyboardBase; _computerBase=keyboardBase; self.piano.needsDisplay=YES; }
- (int)keyboardCount { return self.performanceMode>=1?36:24; }
static NSString *Seconds(double value) { return [[NSString stringWithFormat:@"%.1f",value] stringByReplacingOccurrencesOfString:@"." withString:@","]; }
- (NSString *)arrangementSummary {
    double beats=kv_chord_beats(self.meter,[self chordLength]);
    NSString *meter=S(kv_meter_name(self.meter)),*length=[NSString stringWithFormat:T(@"аккорд %@ с"),Seconds(beats*60.0/self.tempo)];
    NSString *extra=[NSString stringWithFormat:@"%@%@",self.speed<1?[NSString stringWithFormat:T(@" · скорость ×%@"),self.speed>=.75?@"¾":self.speed>=.5?@"½":@"¼"]:@"",self.trackEdited?T(@" · дорожка изменена"):@""];
    length=[length stringByAppendingString:extra];
    if(self.performanceMode==0) return [NSString stringWithFormat:T(@"%@ · аккорды блоком · %@"),meter,length];
    if(self.performanceMode>=3) return [NSString stringWithFormat:T(@"%@ · %@ · %@ · штрих: %@ · %@"),meter,[self textureName],self.generatedRhythm?[NSString stringWithFormat:T(@"вариация №%u"),self.arrangementSeed%1000]:T(@"шаблон"),[S(kv_articulation_name(self.articulation)) lowercaseString],length];
    if(self.performanceMode==2) return [NSString stringWithFormat:T(@"%@ · арпеджио %@ · %@ · %@ · %@"),meter,[S(kv_arpeggio_name(self.arpeggioPattern)) lowercaseString],[S(kv_division_name(self.division)) lowercaseString],self.generatedRhythm?[NSString stringWithFormat:T(@"вариация №%u"),self.arrangementSeed%1000]:T(@"шаблон"),length];
    NSString *fills[]={@"",T(@"без проигрышей"),T(@"проигрыш раз в 4 такта"),T(@"проигрыш раз в 2 такта"),T(@"проигрыш каждый такт")};
    NSString *variation=self.generatedRhythm?[NSString stringWithFormat:T(@"вариация №%u"),self.arrangementSeed%1000]:T(@"шаблон");
    return [NSString stringWithFormat:@"%@ · %@ · %@ · %@ · %@",meter,S(kv_pattern_russian(self.pianoPattern)),variation,fills[kv_fill_rate(self.pianoPattern,self.fillRate)],length];
}
- (void)updatePatternMenu {
    for(int i=0;i<KV_ARP_COUNT;i++) { NSString *name=S(kv_arpeggio_name((KvArpeggioPattern)i)); [self.arpeggioChoice itemAtIndex:i].representedObject=self.generatedRhythm?[name stringByAppendingString:T(@" · вар.")]:name; }
    [self.arpeggioChoice itemAtIndex:KV_ARP_COUNT+1].state=self.generatedRhythm?NSControlStateValueOff:NSControlStateValueOn;
    NSMenuItem *arpVariation=[self.arpeggioChoice itemAtIndex:KV_ARP_COUNT+2]; arpVariation.state=self.generatedRhythm?NSControlStateValueOn:NSControlStateValueOff;
    arpVariation.title=[NSString stringWithFormat:T(@"Вариация №%u · новая — кубик или ⌘R"),self.arrangementSeed%1000];
    [self.arpeggioChoice selectItemAtIndex:self.arpeggioPattern];
    for(int i=0;i<KV_PATTERN_COUNT;i++) {
        NSString *name=S(kv_pattern_russian((KvPianoPattern)i));
        [self.patternChoice itemAtIndex:i].representedObject=self.generatedRhythm?[name stringByAppendingString:T(@" · вар.")]:name;
    }
    NSMenuItem *written=[self.patternChoice itemAtIndex:KV_PATTERN_COUNT+1],*variation=[self.patternChoice itemAtIndex:KV_PATTERN_COUNT+2];
    written.state=self.generatedRhythm?NSControlStateValueOff:NSControlStateValueOn;
    variation.state=self.generatedRhythm?NSControlStateValueOn:NSControlStateValueOff;
    variation.title=[NSString stringWithFormat:T(@"Вариация №%u · новая — кубик или ⌘R"),self.arrangementSeed%1000];
    [self.patternChoice selectItemAtIndex:self.pianoPattern];
}
- (void)updateTransport {
    BOOL playing=kv_audio_is_playing(self.audio) || self.rhythmAlone;
    self.status.toolTip=self.status.stringValue;
    self.status.textColor=[self.status.stringValue hasPrefix:@"⚠"]?NSColor.systemRedColor:NSColor.secondaryLabelColor;
    NSString *playHint=playing?T(@"Стоп · Пробел"):T(@"Играть · Пробел");
    if(![((TNButton *)self.playButton).hint isEqualToString:playHint]) { NSImage *icon=TNIcon(playing?@"stop.fill":@"play.fill",14); if(icon) self.playButton.image=icon; else self.playButton.title=playing?@"■":@"▶"; Hint(self.playButton,playHint); }
    self.playButton.state=playing?NSControlStateValueOn:NSControlStateValueOff;
    self.playButton.enabled=self.audio && (playing || self.progression.count>0 || self.metronomeOn || self.drumsOn);
    self.arrangeButton.state=NSControlStateValueOff;
    self.arrangeButton.enabled=self.progression.count>0;
    self.undoSequenceButton.enabled=self.sequenceUndo!=nil; self.clearButton.enabled=self.progression.count>0; self.midiExportButton.enabled=self.progression.count>0; self.midiCopyButton.enabled=self.progression.count>0;
    self.loopButton.state=self.loopEnabled?NSControlStateValueOn:NSControlStateValueOff;
    NSString *loopHint=self.loopEnabled?T(@"Повтор включён · L"):T(@"Повтор выключен · L"); if(![((TNButton *)self.loopButton).hint isEqualToString:loopHint]) Hint(self.loopButton,loopHint);
    NSString *summary=[self arrangementSummary],*drums=self.drumsOn?[self drumsName]:nil; if(drums) summary=[summary stringByAppendingFormat:@" · %@",drums];
    if(![self.arrangementInfo.stringValue isEqualToString:summary]) self.arrangementInfo.stringValue=summary;
}
/* The frame clock's share of updateTransport: the play button follows a sequence that ends by itself. Everything else that
   changes the transport calls updateTransport where it changes (it builds the summary line, too dear for every frame). */
- (void)updateTransportIfChanged {
    BOOL playing=kv_audio_is_playing(self.audio); if(playing==self.transportPlaying) return;
    self.transportPlaying=playing; [self updateTransport]; if(!playing) [self applyRhythm];   // a progression that ended by itself takes its drums along
}
- (void)togglePlayback:(id)sender {
    if(kv_audio_is_playing(self.audio) || self.rhythmAlone) [self stopPlayback:sender];
    else if(!self.progression.count && !(self.viewMode==2 && self.song->count) && (self.metronomeOn || self.drumsOn)) {   // nothing to play: the rhythm alone, as a DAW with an empty project
        self.rhythmAlone=YES; [self applyRhythm]; [self updateTransport]; self.status.stringValue=T(@"Метроном и ударные · Пробел — стоп · добавьте аккорды, чтобы играть под них"); }
    else if(self.viewMode==2 && self.song->count && !(NSApp.currentEvent.modifierFlags&NSEventModifierFlagOption)) {   // ↻ with a cycle: from its start, as any DAW; else from the cursor; ⌥: the selected section alone
        double from=0,to=0; [self playSongFromBeat:[self songCycle:&from to:&to]?from:self.arranger.cursorBeat]; }
    else [self playProgression:sender];
}
/* ---- metronome: the rhythm layer of the engine (kv_audio_set_rhythm) driven from here ---- */
- (double)rhythmSecondsPerBeat { return 60.0/(self.tempo*(self.playingPerformance?self.speed:1)); }
/* The draft's drums: the chosen beat, or the one that suits the two hands' style; −1 none. */
- (NSInteger)resolvedBeat { return self.rhythmBeat==KvBeatByStyle?kv_beat_for_style(self.pianoPattern):self.rhythmBeat; }
/* The rhythm layer, as in a DAW: the click and the drums sound only while something plays. The click when the metronome is on;
   the drums when they are on — the playing section's (the roll, ⌥Space) or the circle's by its style. The song's parts set the
   drums themselves. */
- (void)applyRhythm {
    if(!self.songPlaying) {
        KvHit hits[KV_BEAT_HITS]; size_t count=0; NSInteger beat=-1; BOOL electronic=NO,playing=([self isPlayingProgression] && !self.auditioningGhost) || self.rhythmAlone,on=self.metronomeOn && playing;
        if(self.drumsOn && playing) {
            if(self.editingSection>=0 && !self.rhythmAlone) { electronic=[self rhythmOfSection:self.editingSection hits:hits count:&count]==2; beat=count?-3:-1; }
            else { beat=[self resolvedBeat]; if(beat>=0) { count=kv_beat_bar((KvBeat)beat,self.meter,hits); electronic=kv_beat_electronic((KvBeat)beat); } }
        }
        if(self.audio && !kv_audio_set_rhythm(self.audio,on,self.rhythmGrid,self.meter,[self rhythmSecondsPerBeat],self.rhythmVolume)) self.status.stringValue=T(@"⚠ Не удалось включить метроном");
        NSData *sent=[NSData dataWithBytes:hits length:count*sizeof(KvHit)];
        if(self.audio && (beat!=self.sentBeat || (beat>=0 && self.meter!=self.sentBeatMeter) || (beat==-3 && ![sent isEqualToData:self.sentHits]))) {
            if(kv_audio_set_beat(self.audio,hits,count,electronic)) { self.sentBeat=beat; self.sentBeatMeter=self.meter; self.sentHits=sent; }
        }
    }
    self.metronomeButton.state=self.metronomeOn?NSControlStateValueOn:NSControlStateValueOff; self.drumsButton.state=self.drumsOn?NSControlStateValueOn:NSControlStateValueOff;
    for(NSMenuItem *item in self.rhythmChoice.itemArray) item.state=(item.tag==self.rhythmGrid && item.tag>=0 && item.tag<KV_GRID_COUNT) || (item.tag==100 && self.countIn)?NSControlStateValueOn:NSControlStateValueOff;
    for(NSMenuItem *item in self.drumsChoice.itemArray) item.state=self.drumsOn && ((self.rhythmBeat==KvBeatByStyle && item.tag==300) || (self.rhythmBeat>=0 && self.rhythmBeat<KV_BEAT_COUNT && item.tag==200+self.rhythmBeat))?NSControlStateValueOn:NSControlStateValueOff;
}
- (NSString *)rhythmName { NSString *names[KV_GRID_COUNT]={T(@"клик на доли"),T(@"клик восьмыми"),T(@"клик триолями"),T(@"клик шестнадцатыми")}; return names[self.rhythmGrid]; }
- (NSString *)drumsName {
    NSInteger beat=[self resolvedBeat]; if(beat<0) return nil;
    if(self.rhythmBeat==KvBeatByStyle && self.viewMode==2) return T(@"барабаны по стилю каждой секции");
    return [NSString stringWithFormat:self.rhythmBeat==KvBeatByStyle?T(@"ударные по стилю: %@"):T(@"ударные «%@»"),[S(kv_beat_name((KvBeat)beat)) lowercaseString]];
}
- (NSString *)metronomeStatus { return [NSString stringWithFormat:T(@"Метроном · %@%@ · щёлкает, пока идёт игра · ⌘K — выключить"),[self rhythmName],self.countIn?T(@" · отсчёт такта"):@""]; }
/* While the song plays, the metronome or the drums change at once: the part playing now gets its rhythm again, and the part
   queued next (which carries its own) is queued anew. */
- (void)applySongRhythm {
    if(!self.songPlaying || !self.audio) return;
    NSInteger part=(NSInteger)kv_audio_part(self.audio,NULL); if(part!=self.songPart || part<0 || part>=(NSInteger)self.songOrder.count) return;
    KvHit hits[KV_BEAT_HITS]; size_t n=0; int on=[self rhythmOfSection:self.songOrder[part].integerValue hits:hits count:&n]; n=[self scaleHits:hits count:n at:self.songOrderBeats[part].doubleValue];
    kv_audio_set_rhythm(self.audio,self.metronomeOn,self.rhythmGrid,self.meter,60.0/(self.appliedBpm>0?self.appliedBpm*self.speed:self.tempo*self.speed),self.rhythmVolume); kv_audio_set_beat(self.audio,hits,on?n:0,on==2);
    if(self.songQueued>part) { self.songQueued=part; [self queueSongPart:part+1]; }
}
- (void)toggleMetronome:(id)sender {
    (void)sender; self.metronomeOn=!self.metronomeOn; self.beatDot=-1; [self applyRhythm]; [self applySongRhythm]; [self updateTransport]; [self saveState]; self.needsDisplay=YES;
    self.status.stringValue=self.metronomeOn?[self metronomeStatus]:T(@"Метроном выключен · ⌘K — включить");
}
- (void)rhythmChanged:(NSPopUpButton *)sender {
    NSInteger tag=sender.selectedItem.tag;
    if(tag==100) self.countIn=!self.countIn;
    else if(tag>=0 && tag<KV_GRID_COUNT) { self.rhythmGrid=(KvGrid)tag; if(!self.metronomeOn) { [self saveState]; [self toggleMetronome:nil]; return; } }   // choosing a grid switches the click on
    else return;
    [self applyRhythm]; [self applySongRhythm]; [self saveState]; [self updateTransport];
    self.status.stringValue=self.metronomeOn?[self metronomeStatus]:self.countIn?T(@"Отсчёт такта включён: при игре с метрономом сначала звучит такт клика"):T(@"Отсчёт такта выключен");
}
- (NSString *)drumsStatus { return self.drumsOn?[NSString stringWithFormat:T(@"Ударные · %@ · играют под песней и под кругом · ⇧⌘K — выключить"),[self drumsName]]:T(@"Ударные выключены · ⇧⌘K — включить"); }
- (void)toggleDrums:(id)sender {
    (void)sender; self.drumsOn=!self.drumsOn; self.beatDot=-1; [self applyRhythm]; [self applySongRhythm]; [self.arranger reload]; [self updateTransport]; [self saveState]; self.needsDisplay=YES;
    self.status.stringValue=[self drumsStatus];
}
- (void)drumsChanged:(NSPopUpButton *)sender {
    NSInteger tag=sender.selectedItem.tag;
    if(tag==400) { if(self.drumsOn) [self toggleDrums:nil]; return; }
    if(tag!=300 && (tag<200 || tag>=200+KV_BEAT_COUNT)) return;
    self.rhythmBeat=tag==300?KvBeatByStyle:tag-200;
    if(!self.drumsOn) { [self toggleDrums:nil]; return; }   // choosing a beat switches the drums on
    [self applyRhythm]; [self applySongRhythm]; [self.arranger reload]; [self saveState]; [self updateTransport]; self.status.stringValue=[self drumsStatus];
}
- (void)rhythmVolumeChanged:(NSSlider *)sender {
    self.rhythmVolume=MIN(1,MAX(0,sender.doubleValue/100)); self.rhythmVolumeValue.stringValue=[NSString stringWithFormat:@"%.0f %%",self.rhythmVolume*100];
    [self applyRhythm]; [self saveState];
}
/* One dot per count of the bar: 4, 3, or six eighths in 6/8 (the first larger, the second dotted quarter a little larger). */
- (NSUInteger)beatDotCount { return self.meter==KV_METER_4_4?4:self.meter==KV_METER_3_4?3:6; }
- (double)beatDotLength { return self.meter==KV_METER_6_8?.5:1; }
- (NSRect)beatDotsRect { KvMetrics m=self.metrics; return NSMakeRect(m.tempoX,m.transportY+8,40,16); }
- (void)drawBeatDots:(NSRect)rect {
    NSUInteger n=[self beatDotCount]; CGFloat gap=(rect.size.width-2)/n;
    for(NSUInteger i=0;i<n;i++) { CGFloat r=i==0?4.5:(n==6 && i==3)?3.8:3,x=rect.origin.x+gap*i+gap/2-r,y=NSMidY(rect)-r;
        [(self.beatDot>=0 && i==(NSUInteger)self.beatDot?Accent():[NSColor.secondaryLabelColor colorWithAlphaComponent:.35]) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x,y,2*r,2*r)] fill]; }
}
- (void)updateBeatDots {
    if(!self.metronomeOn && !self.drumsOn) return;
    double beat=self.audio?kv_audio_rhythm_beat(self.audio):-1;
    NSInteger dot=beat<0?-1:(NSInteger)floor(fmod(beat+1e-6,kv_meter_bar(self.meter))/[self beatDotLength]);
    if(dot!=self.beatDot) { self.beatDot=dot; [self setNeedsDisplayInRect:NSInsetRect([self beatDotsRect],-2,-2)]; }
}
/* The «Фактура» menu: piano textures for every instrument, strings textures with the strings; items carry their mode in the tag,
   the group headers are disabled items (tag −1), the hint under the piano group (tag −2) says where the strings textures are. */
- (TNPopup *)makeTextureMenu {
    TNPopup *popup=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO]; popup.autoenablesItems=NO;
    NSArray *items=@[@[T(@"Аккорды блоком"),T(@"Аккорды"),@"tonora.blocks"],@[T(@"Фортепиано, две руки"),T(@"Две руки"),@"tonora.hands"],@[T(@"Арпеджио"),T(@"Арпеджио"),@"tonora.arpeggio"],
                     @[T(@"Хорал · пэд, легато"),T(@"Хорал"),@"tonora.chorale"],@[T(@"Кантилена · мелодия над аккордом"),T(@"Кантилена"),@"tonora.cantilena"],
                     @[T(@"Остинато · спиккато"),T(@"Остинато"),@"tonora.ostinato"],@[T(@"Пиццикато · щипком"),T(@"Пиццикато"),@"tonora.pizzicato"]];
    NSMenuItem *(^header)(NSString *)=^NSMenuItem *(NSString *title) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""]; item.enabled=NO; item.tag=-1; item.representedObject=@""; [popup.menu addItem:item]; return item; };
    header(@"");
    for(NSInteger i=0;i<(NSInteger)items.count;i++) {
        if(i==3) { NSMenuItem *gap=NSMenuItem.separatorItem; gap.tag=-1; [popup.menu addItem:gap]; header(T(@"Струнные · свои штрихи")); }   // a separator's tag is 0 by default
        [popup addItemWithTitle:items[i][0]]; NSMenuItem *item=popup.lastItem; item.tag=i; item.representedObject=items[i][1]; item.image=TNIcon(items[i][2],13);
    }
    NSMenuItem *hint=header(T(@"Струнные фактуры — у инструмента «Струнные» (FX)")); hint.tag=-2;
    popup.target=self; popup.action=@selector(performanceChanged:);
    popup.toolTip=T(@"Фактура: аккорды блоком, две руки и арпеджио у любого инструмента; хорал, кантилена, остинато и пиццикато — у струнных"); [popup setAccessibilityLabel:T(@"Фактура")];
    return popup;
}
- (void)refreshTextureMenu {
    BOOL strings=[self stringsChosen]; NSDictionary *small=@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
    for(NSMenuItem *item in self.performanceChoice.itemArray) {
        if(item.tag>=3 || item.isSeparatorItem || (item.tag==-1 && [item.title hasPrefix:T(@"Струнные")])) item.hidden=!strings;   // strings textures with the strings only
        else if(item.tag==-2) item.hidden=strings;
    }
    NSMenuItem *piano=self.performanceChoice.itemArray.firstObject;
    piano.attributedTitle=[[NSAttributedString alloc] initWithString:strings?T(@"Фортепианные · штрих «Авто» по длине нот"):T(@"Фортепиано · любой инструмент") attributes:small];
    for(NSMenuItem *item in self.performanceChoice.itemArray) if(item.tag==-1 && item!=piano && !item.attributedTitle) item.attributedTitle=[[NSAttributedString alloc] initWithString:item.title attributes:small];
    [self.performanceChoice selectItemWithTag:self.performanceMode];
}
- (void)performanceChanged:(NSPopUpButton *)sender { NSInteger mode=sender.selectedTag; if(mode<0) return; [self changeTexture:^{ self.performanceMode=mode; self.needsLayout=YES; }]; }
- (void)harmonyChanged:(NSPopUpButton *)sender { NSInteger extension=sender.indexOfSelectedItem; [self changeTexture:^{ self.chordExtension=extension; }]; }
/* A new meter keeps everything the user made: notes edited in the roll move with their chords (each keeps its place inside its
   chord), and every section keeps its share of passes — the song is the same song in the new meter. */
- (void)meterChanged:(NSPopUpButton *)sender {
    KvMeter meter=(KvMeter)sender.indexOfSelectedItem; if(meter==self.meter) return;
    KvSong *song=[self liveSong]; NSMutableArray<NSNumber *> *passes=[NSMutableArray array]; for(size_t i=0;i<song->count;i++) [passes addObject:@(kv_section_pass_beats(song,&song->sections[i]))];
    BOOL edited=self.trackEdited;
    [self changeArrangement:^{
        self.meter=meter; KvSong *now=[self liveSong];
        if(edited && kv_track_remeter(self.track,kv_chord_beats(meter,[self chordLength]),kv_meter_bar(meter))) { self.trackEdited=YES; self.roll.edited=YES; [self.roll reload]; }
        for(size_t i=0;i<now->count;i++) {
            KvSection *s=&now->sections[i]; NSData *data=self.sectionTracks[@(s->id)];
            if(data.length==sizeof(KvPerformance)) { KvPerformance p; memcpy(&p,data.bytes,sizeof(p)); if(kv_track_remeter(&p,kv_section_chord_beats(now,s),kv_meter_bar(meter))) self.sectionTracks[@(s->id)]=[NSData dataWithBytes:&p length:sizeof(p)]; }
            if(i<passes.count) kv_section_keep_passes(now,s,passes[i].doubleValue);
        }
        now->cycle_from=now->cycle_to=0; self.songPlans=nil; [self.arranger reload];   // the cycle was drawn in the old meter's bars
    }];
    if(edited) self.status.stringValue=[NSString stringWithFormat:T(@"Размер %@ · правки нот сохранены"),S(kv_meter_name(meter))];
}
- (void)lengthChanged:(NSPopUpButton *)sender {
    KvChordLength length=(KvChordLength)sender.indexOfSelectedItem;
    [self changeTexture:^{ if(self.performanceMode>=3) self.chordLengthStrings=length; else if(self.performanceMode==1) self.chordLengthHands=length; else if(self.performanceMode==2) self.chordLengthArp=length; else self.chordLengthBlocks=length; }];
}
- (void)arpeggioChanged:(NSPopUpButton *)sender {
    NSInteger index=sender.indexOfSelectedItem;
    [self changeTexture:^{
        if(index>=0 && index<KV_ARP_COUNT) self.arpeggioPattern=(KvArpeggioPattern)index;
        else if(index==KV_ARP_COUNT+1) self.generatedRhythm=NO;
        else if(index==KV_ARP_COUNT+2) self.generatedRhythm=YES;
    }];
}
- (void)arpeggioDivisionChanged:(NSPopUpButton *)sender { KvDivision division=(KvDivision)sender.indexOfSelectedItem; [self changeTexture:^{ self.division=division; }]; }
- (void)fillChanged:(NSPopUpButton *)sender { KvFillRate rate=(KvFillRate)sender.indexOfSelectedItem; [self changeTexture:^{ self.fillRate=rate; }]; }
- (void)regenerateArrangement:(id)sender {
    if(self.viewMode==2 && self.lastForm) { [self arrangerAnotherForm:sender]; return; }   // right after a form: another variant of it
    if(!self.progression.count) return;
    [self changeTexture:^{
        self.arrangementSeed=arc4random_uniform(UINT32_MAX-1)+1; self.generatedRhythm=YES; if(self.performanceMode==0) self.performanceMode=1; self.needsLayout=YES;
    }];
    if(![self isPlayingProgression]) self.status.stringValue=[NSString stringWithFormat:T(@"Вариация №%u готова · аккорды сохранены · Пробел — играть"),self.arrangementSeed%1000];
}
- (void)patternChanged:(NSPopUpButton *)sender {
    NSInteger index=sender.indexOfSelectedItem;
    [self changeTexture:^{
        if(index>=0 && index<KV_PATTERN_COUNT) self.pianoPattern=(KvPianoPattern)index; // a style change keeps the variation mode
        else if(index==KV_PATTERN_COUNT+1) self.generatedRhythm=NO;
        else if(index==KV_PATTERN_COUNT+2) self.generatedRhythm=YES;
    }];
}
- (void)stopPlayback:(id)sender {
    (void)sender;
    if(self.songPlaying) { double at=[self arrangerPlayheadBeat]; if(at>=0) self.arranger.cursorBeat=at; }   // the playhead stays where the song stopped
    kv_audio_stop(self.audio); if(self.songPlaying) [self endSong]; self.playbackGeneration++; self.visualPlayback=NO; self.playingDegrees=nil; self.playingTwoHand=NO; self.playingPerformance=NO; self.rhythmAlone=NO;
    [self.piano setActiveNotes:@[]]; [self highlightChip:-1]; self.status.stringValue=T(@"Остановлено · Пробел — играть · ⌘/ — все сочетания клавиш");
    [self.piano setRoles:NULL];
    self.roll.playheadBeat=-1; self.roll.needsDisplay=YES; // at once, so a zoom right after Stop is not taken for one during playback
    [self.midi allNotesOff]; memset(_midiSounding,0,sizeof(_midiSounding));
    if(self.playbackActivity) { [NSProcessInfo.processInfo endActivity:self.playbackActivity]; self.playbackActivity=nil; }
    [self applyRhythm]; if(self.metronomeOn) self.status.stringValue=T(@"Остановлено · метроном взведён и щёлкнет при игре · ⌘K — выключить");
    [self updateTransport];
}
- (void)loopChanged:(NSButton *)sender {
    self.loopEnabled=sender.state==NSControlStateValueOn;
    if(!self.songPlaying && self.playingDegrees.count && kv_audio_is_playing(self.audio) && !kv_audio_set_loop(self.audio,self.loopEnabled)) self.status.stringValue=T(@"⚠ Не удалось изменить повтор");
    self.arranger.needsDisplay=YES;   // the cycle on the ruler turns orange or grey
    [self saveState];
}
- (void)toggleLoop:(id)sender { (void)sender; self.loopButton.state=self.loopEnabled?NSControlStateValueOff:NSControlStateValueOn; [self loopChanged:self.loopButton]; [self updateTransport]; }
- (void)showSoundSettings:(id)sender {
    (void)sender; if(self.window.attachedSheet) return;
    if(!self.soundPanel) {
        self.soundPanel=Panel(@"FX · Tonora",490,600); NSView *view=self.soundPanel.contentView;
        PanelLabel(view,T(@"Инструмент и эффекты"),NSMakeRect(24,20,440,28),20);
        self.instrumentChoice=[[TNPopup alloc] initWithFrame:NSMakeRect(24,78,440,34) pullsDown:NO];
        [self.instrumentChoice addItemsWithTitles:@[T(@"Рояль · Salamander Grand"),T(@"Электропиано · Yamaha CP80"),T(@"Электропиано · Hohner Pianet T"),T(@"Струнные · виолончели и скрипки (VSCO 2)")]];
        if(!self.stringsAvailable) { self.instrumentChoice.autoenablesItems=NO; NSMenuItem *strings=[self.instrumentChoice itemAtIndex:KV_INSTRUMENT_STRINGS]; strings.enabled=NO; strings.title=[strings.title stringByAppendingString:T(@" — нет записей")]; }
        self.instrumentChoice.target=self; self.instrumentChoice.action=@selector(instrumentChanged:); [view addSubview:self.instrumentChoice];
        PanelLabel(view,T(@"Сэмплы акустических и электрических клавишных · стерео"),NSMakeRect(24,52,440,20),12);
        self.articulationLabel=PanelLabel(view,T(@"Штрих"),NSMakeRect(24,129,48,24),13);
        self.articulationControl=[TNSegmented segmentedControlWithLabels:@[T(@"Авто"),T(@"Легато"),T(@"Стаккато"),T(@"Пиццикато")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(articulationChanged:)];
        self.articulationControl.frame=NSMakeRect(72,124,394,30); [view addSubview:self.articulationControl];
        { NSArray *icons=@[@"tonora.auto",@"tonora.legato",@"tonora.staccato",@"tonora.pluck"]; for(NSInteger i=0;i<4;i++) [self.articulationControl setImage:TNIcon(icons[i],12) forSegment:i]; }
        self.articulationHint=PanelLabel(view,T(@"Авто — по длине ноты: короче восьмой — спиккато, слитные — легато, остальные — смычком. Ручной штрих — для всех нот."),NSMakeRect(24,158,440,32),11);
        self.articulationHint.textColor=NSColor.secondaryLabelColor; self.articulationHint.maximumNumberOfLines=2; self.articulationHint.lineBreakMode=NSLineBreakByWordWrapping; self.articulationHint.cell.wraps=YES;
        self.articulationControl.toolTip=T(@"Авто: легато, долгая нота или спиккато по длине нот · на MIDI-клавиатуре — клавиши C1–D♯1");
        PanelLabel(view,T(@"Хуманизация"),NSMakeRect(24,129,135,24),13);
        self.humanizeControl=[TNSegmented segmentedControlWithLabels:@[T(@"Живая"),T(@"Ровная")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(humanizeChanged:)];
        self.humanizeControl.frame=NSMakeRect(164,124,300,30); self.humanizeControl.toolTip=T(@"Свинг до 12 мс, микротайминг ±5 мс, динамика ±6%"); [view addSubview:self.humanizeControl];
        NSArray<NSString *> *labels=@[T(@"Реверб · микс"),T(@"Дилей"),T(@"Время дилея")];
        NSMutableArray<NSSlider *> *sliders=[NSMutableArray array]; NSMutableArray<NSTextField *> *values=[NSMutableArray array];
        for(int i=0;i<2;i++) {
            CGFloat y=184+i*51; PanelLabel(view,labels[i],NSMakeRect(24,y,140,22),13);
            NSSlider *slider=[TNSlider sliderWithValue:0 minValue:i==2?80:0 maxValue:i==2?1200:(i==0?100:60) target:self action:@selector(effectsChanged:)];
            slider.continuous=YES; slider.frame=NSMakeRect(164,y-2,210,26); [slider setAccessibilityLabel:labels[i]]; [view addSubview:slider]; [sliders addObject:slider];
            NSTextField *value=Label(@"",12,NSFontWeightMedium); value.frame=NSMakeRect(385,y,82,22); [view addSubview:value]; [values addObject:value];
        }
        self.reverbSlider=sliders[0]; self.delaySlider=sliders[1];
        self.reverbSlider.toolTip=T(@"0% — сухое пианино; 100% — только реверберация");
        self.delayTimeSlider=[TNSlider sliderWithValue:self.freeDelaySeconds*1000 minValue:80 maxValue:1200 target:self action:@selector(effectsChanged:)];
        self.delayTimeSlider.frame=NSMakeRect(164,334,210,30); self.delayTimeSlider.continuous=YES; [view addSubview:self.delayTimeSlider];
        self.delayTimeValue=Label(@"",12,NSFontWeightMedium); self.delayTimeValue.frame=NSMakeRect(385,340,82,22); [view addSubview:self.delayTimeValue];
        self.delayMode=[TNSegmented segmentedControlWithLabels:@[T(@"Доли"),T(@"мс")] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(delayModeChanged:)];
        self.delayMode.frame=NSMakeRect(164,282,300,30); [view addSubview:self.delayMode];
        PanelLabel(view,T(@"Ритм дилея"),NSMakeRect(24,286,135,22),13);
        self.reverbValue=values[0]; self.delayValue=values[1];
        self.delayDivision=[[TNPopup alloc] initWithFrame:NSMakeRect(164,334,300,32) pullsDown:NO];
        [self.delayDivision addItemsWithTitles:@[@"1/4",@"1/8",@"1/16",T(@"1/8 · пунктир"),T(@"1/8 · триоль")]];
        self.delayDivision.target=self; self.delayDivision.action=@selector(divisionChanged:); [view addSubview:self.delayDivision];
        self.delayUnitLabel=PanelLabel(view,T(@"Длительность"),NSMakeRect(24,340,135,22),13);
        self.fxTempoValue=Label(@"",12,NSFontWeightRegular); self.fxTempoValue.textColor=NSColor.secondaryLabelColor; self.fxTempoValue.frame=NSMakeRect(164,374,300,20); self.fxTempoValue.toolTip=T(@"Темп задаётся под последовательностью"); [view addSubview:self.fxTempoValue];
        // The interface language sits here too: the one window of settings (⌘,). Its label reads in both languages.
        PanelLabel(view,@"Язык · Language",NSMakeRect(24,414,135,22),13);
        self.languageControl=[TNSegmented segmentedControlWithLabels:@[@"English",@"Русский"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(languageChanged:)];
        self.languageControl.frame=NSMakeRect(164,410,300,30); self.languageControl.toolTip=T(@"Интерфейс перестраивается сразу. Последовательность, звук и тональность сохраняются.");
        [self.languageControl setAccessibilityLabel:@"Язык · Language"]; [view addSubview:self.languageControl];
        // The metronome and the beat: their level, apart from the instrument's.
        PanelLabel(view,T(@"Ритм · громкость"),NSMakeRect(24,462,135,22),13);
        self.rhythmVolumeSlider=[TNSlider sliderWithValue:self.rhythmVolume*100 minValue:0 maxValue:100 target:self action:@selector(rhythmVolumeChanged:)];
        self.rhythmVolumeSlider.continuous=YES; self.rhythmVolumeSlider.frame=NSMakeRect(164,458,210,26); [self.rhythmVolumeSlider setAccessibilityLabel:T(@"Ритм · громкость")];
        self.rhythmVolumeSlider.toolTip=T(@"Громкость метронома и ударных; ритм идёт мимо реверберации и дилея"); [view addSubview:self.rhythmVolumeSlider];
        self.rhythmVolumeValue=Label(@"",12,NSFontWeightMedium); self.rhythmVolumeValue.frame=NSMakeRect(385,462,82,22); [view addSubview:self.rhythmVolumeValue];
        PanelLabel(view,T(@"A. Holm / G. Sullivan · CC BY 3.0 · VSCO · Karoryfer · VCSL · CC0 · лицензии — в меню Tonora"),NSMakeRect(24,500,450,20),10);
        NSButton *preview=Button(T(@"▶  Послушать"),self,@selector(previewSound:)); preview.frame=NSMakeRect(24,546,112,32); [view addSubview:preview];
        NSButton *reset=Button(T(@"По умолчанию"),self,@selector(defaultSound:)); reset.frame=NSMakeRect(144,546,124,32); Hint(reset,T(@"Рояль, реверб 10 %, дилей 10 % на 1/8, ритм 60 %")); [view addSubview:reset];
        NSButton *dry=Button(T(@"Без эффектов"),self,@selector(drySound:)); dry.frame=NSMakeRect(276,546,116,32); [view addSubview:dry];
        NSButton *done=Button(T(@"Готово"),self,@selector(closeSound:)); done.keyEquivalent=@"\r"; done.frame=NSMakeRect(400,546,66,32); done.bezelColor=Accent(); [view addSubview:done];
    }
    self.languageControl.selectedSegment=TNEnglish()?0:1;
    self.rhythmVolumeSlider.doubleValue=self.rhythmVolume*100; self.rhythmVolumeValue.stringValue=[NSString stringWithFormat:@"%.0f %%",self.rhythmVolume*100];
    [self.delayDivision selectItemAtIndex:self.delayDivisionIndex==5?1:self.delayDivisionIndex];
    self.delayMode.selectedSegment=self.delayDivisionIndex==5?1:0;
    self.humanizeControl.selectedSegment=self.humanize?0:1;
    [self.instrumentChoice selectItemAtIndex:self.instrument];
    { CGFloat shift=self.soundPanelShift; self.soundPanelShift=0; if(shift) for(NSView *view in self.soundPanel.contentView.subviews) if(view!=self.articulationControl && view!=self.articulationLabel && view!=self.articulationHint && NSMinY(view.frame)>=120) view.frame=NSOffsetRect(view.frame,0,-shift);
      if(shift) { NSRect f=self.soundPanel.frame; f.size.height-=shift; f.origin.y+=shift; [self.soundPanel setFrame:f display:NO]; } [self updateSoundPanelRows]; }
    self.reverbSlider.doubleValue=self.effects.reverb*100; self.delaySlider.doubleValue=self.effects.delay*100; self.delayTimeSlider.doubleValue=self.freeDelaySeconds*1000;
    [self updateEffectLabels]; [self.window beginSheet:self.soundPanel completionHandler:nil];
}
- (void)languageChanged:(NSSegmentedControl *)sender {
    NSString *language=sender.selectedSegment==0?@"en":@"ru"; if([language isEqualToString:TNLanguage()]) return;
    TNSetLanguage(language);
    // After this action returns: the rebuild replaces this view, the control's owner.
    id<KvInterfaceHost> host=(id<KvInterfaceHost>)NSApp.delegate; if([host respondsToSelector:@selector(rebuildInterface)]) dispatch_async(dispatch_get_main_queue(),^{ [host rebuildInterface]; });
}
- (void)humanizeChanged:(NSSegmentedControl *)sender {
    BOOL humanize=sender.selectedSegment==0;
    if(kv_audio_set_humanize(self.audio,humanize)) { self.humanize=humanize; [self saveState]; }
}
- (void)instrumentChanged:(NSPopUpButton *)sender {
    NSInteger instrument=sender.indexOfSelectedItem;
    if(kv_audio_set_instrument(self.audio,(int)instrument)) {
        // Like a new key or chord, a new instrument does not stop the music: playback goes on from the current chord.
        BOOL wasStrings=[self stringsChosen],stringsTexture=self.performanceMode>=3;
        [self changeArrangement:^{
            self.instrument=instrument;
            // The strings start with their most telling texture, the spiccato ostinato; another instrument leaves the strings textures for two hands.
            if([self stringsChosen] && !wasStrings) {   // the section being edited gets its own strings texture back; the draft starts with the spiccato ostinato
                KvStringTexture own=self.editingSection>=0 && self.editingSection<(NSInteger)self.song->count?self.song->sections[self.editingSection].arrangement.strings:KV_STRINGS_NONE;
                self.performanceMode=own?2+own:3+KV_STRINGS_OSTINATO-KV_STRINGS_CHORALE; }
            else if(self.performanceMode>=3 && ![self stringsChosen]) self.performanceMode=1;
        }];
        if([self stringsChosen] && !wasStrings) self.status.stringValue=T(@"Струнные · остинато спиккато — другие струнные фактуры в списке «Фактура»");
        else if(stringsTexture && ![self stringsChosen]) self.status.stringValue=T(@"Струнная фактура доступна только у струнных — включено фортепиано, две руки");
        [self updateSoundPanelRows]; self.needsLayout=YES; [self refresh]; [self saveState];
    }
    else self.status.stringValue=T(@"Не удалось выбрать инструмент");
}
/* The «Штрих» row is there for the strings only; the rows under it move down to make room and the panel grows. */
- (void)updateSoundPanelRows {
    if(!self.soundPanel) return;
    CGFloat want=[self stringsChosen]?KvStrokeRowHeight:0,delta=want-self.soundPanelShift; self.articulationControl.hidden=self.articulationLabel.hidden=self.articulationHint.hidden=!want;
    self.articulationControl.selectedSegment=self.articulation;
    if(!delta) return;
    for(NSView *view in self.soundPanel.contentView.subviews) if(view!=self.articulationControl && view!=self.articulationLabel && view!=self.articulationHint && NSMinY(view.frame)>=120) view.frame=NSOffsetRect(view.frame,0,delta);
    NSRect frame=self.soundPanel.frame; frame.size.height+=delta; frame.origin.y-=delta; [self.soundPanel setFrame:frame display:YES animate:NO];
    self.soundPanelShift=want;
}
- (void)articulationChanged:(NSSegmentedControl *)sender { [self setArticulationTo:(KvArticulation)sender.selectedSegment]; }
- (void)setArticulationTo:(KvArticulation)articulation {
    if(articulation<0 || articulation>=KV_ARTICULATION_COUNT) return;
    self.articulation=articulation; self.articulationControl.selectedSegment=articulation;
    if(self.audio && !kv_audio_set_articulation(self.audio,articulation)) self.status.stringValue=T(@"Не удалось сменить штрих");
    else self.status.stringValue=[NSString stringWithFormat:T(@"Штрих струнных: %@"),[S(kv_articulation_name(articulation)) lowercaseString]];
    self.arrangementInfo.stringValue=[self arrangementSummary]; [self saveState];
}
- (void)dynamicsChanged:(NSSlider *)sender { [self applyStringDynamics:sender.doubleValue expression:self.stringExpression]; [self saveState]; }
- (void)applyStringDynamics:(double)dynamics expression:(double)expression {
    self.stringDynamics=MIN(1,MAX(0,dynamics)); self.stringExpression=MIN(1,MAX(0,expression)); self.dynamicsSlider.doubleValue=self.stringDynamics;
    if(self.audio) kv_audio_set_dynamics(self.audio,self.stringDynamics,self.stringExpression);
}
/* MIDI controllers: the mod wheel (CC1) is the strings' dynamics, CC11 their expression; the sustain pedal (CC64) holds every instrument. */
- (void)midiControl:(int)controller value:(int)value {
    if(controller==1) [self applyStringDynamics:value/127.0 expression:self.stringExpression];
    else if(controller==11) [self applyStringDynamics:self.stringDynamics expression:value/127.0];
    else if(controller==64) {
        BOOL down=value>=64; if(down==self.pedalDown) return; self.pedalDown=down; if(self.audio) kv_audio_set_pedal(self.audio,down);
        if(!down) for(int m=0;m<128;m++) if(_pedalHeld[m]) { _pedalHeld[m]=NO; if(_soundCount[m]==0 && self.audio) kv_audio_release(self.audio,m); }
    }
}
- (BOOL)isPedalHeld:(int)midi { return midi>=0 && midi<128 && _pedalHeld[midi]; }
- (void)updateEffectLabels {
    self.reverbValue.stringValue=[NSString stringWithFormat:@"%.0f %%",self.reverbSlider.doubleValue];
    self.delayValue.stringValue=[NSString stringWithFormat:@"%.0f %%",self.delaySlider.doubleValue];
    self.delayTimeValue.stringValue=[NSString stringWithFormat:T(@"%.0f мс"),self.effects.delay_seconds*1000];
    BOOL freeTime=self.delayDivisionIndex==5;
    self.delayTimeSlider.hidden=!freeTime; self.delayTimeValue.hidden=!freeTime;
    self.delayDivision.hidden=freeTime; self.delayTimeSlider.enabled=YES;
    self.delayUnitLabel.stringValue=freeTime?T(@"Время дилея"):T(@"Длительность");
    self.fxTempoValue.hidden=freeTime;
    if(!freeTime) self.fxTempoValue.stringValue=[NSString stringWithFormat:T(@"= %.0f мс при %.0f BPM"),self.effects.delay_seconds*1000,self.tempo];
}
- (void)effectsChanged:(id)sender {
    if(sender==self.delayTimeSlider) self.freeDelaySeconds=self.delayTimeSlider.doubleValue/1000;
    KvEffects effects={(float)(self.reverbSlider.doubleValue/100),(float)(self.delaySlider.doubleValue/100),self.delayTimeSlider.doubleValue/1000};
    if(self.delayDivisionIndex==5) self.freeDelaySeconds=effects.delay_seconds;
    if(self.delayDivisionIndex<5) { const double beats[]={1,.5,.25,.75,1.0/3}; effects.delay_seconds=60.0/self.tempo*beats[self.delayDivisionIndex]; }
    if(!kv_effects_valid(effects)) return;
    self.effects=effects; [self updateEffectLabels];
    if(self.audio && !kv_audio_set_effects(self.audio,effects)) self.status.stringValue=T(@"Не удалось применить эффекты");
    [self saveState];
}
- (void)previewSound:(id)sender { (void)sender; KvChord chord; if(kv_code_chord(self.key,(int)self.selectedDegree,(int)self.chordExtension,&chord)) [self playNotes:chord.midi count:chord.count voices:chord.count duration:1.2]; }
/* The first-launch sound: piano, reverb 10 %, delay 10 % on 1/8. */
- (void)defaultSound:(id)sender {
    [self.instrumentChoice selectItemAtIndex:self.stringsAvailable?KV_INSTRUMENT_STRINGS:0]; [self instrumentChanged:self.instrumentChoice];   // the default sound: the strings
    self.delayDivisionIndex=1; [self.delayDivision selectItemAtIndex:1]; self.delayMode.selectedSegment=0;
    self.reverbSlider.doubleValue=10; self.delaySlider.doubleValue=10; [self effectsChanged:sender];
    self.rhythmVolumeSlider.doubleValue=60; [self rhythmVolumeChanged:(NSSlider *)self.rhythmVolumeSlider];
}
- (void)drySound:(id)sender { self.reverbSlider.doubleValue=0; self.delaySlider.doubleValue=0; [self effectsChanged:sender]; }
- (void)closeSound:(id)sender { (void)sender; [self.window endSheet:self.soundPanel]; [self.soundPanel orderOut:nil]; }
- (void)applyTempo:(double)bpm {
    [self markRateChange];
    self.tempo=MAX(50,MIN(240,round(bpm))); self.tempoSlider.doubleValue=self.tempo;
    self.tempoValue.stringValue=[NSString stringWithFormat:@"%.0f BPM",self.tempo];
    if(self.visualPlayback && self.playingPerformance) {
        double interval=60.0/(self.tempo*self.speed); self.visualEventSeconds=interval*self.playingBeatsPerChord;
        if(!kv_audio_set_interval(self.audio,interval)) self.status.stringValue=T(@"⚠ Не удалось изменить темп");
    } else if(self.visualPlayback && self.visualEvents.count>1) {
        double interval=30.0/self.tempo; self.visualEventSeconds=interval;
        if(!kv_audio_set_interval(self.audio,interval)) self.status.stringValue=T(@"⚠ Не удалось изменить темп");
    }
    if(self.delayDivision) [self effectsChanged:nil];
    else if(self.delayDivisionIndex<5) {
        const double beats[]={1,.5,.25,.75,1.0/3}; KvEffects settings=self.effects;
        settings.delay_seconds=60.0/self.tempo*beats[self.delayDivisionIndex]; self.effects=settings;
        if(!kv_audio_set_effects(self.audio,settings)) self.status.stringValue=T(@"Не удалось синхронизировать дилей");
    }
    [self saveState]; [self applyRhythm];
}
- (void)tempoChanged:(id)sender { if(sender) [self applyTempo:self.tempoSlider.doubleValue]; else self.tempoValue.stringValue=[NSString stringWithFormat:@"%.0f BPM",self.tempo]; }
- (void)delayModeChanged:(NSSegmentedControl *)sender {
    self.delayDivisionIndex=sender.selectedSegment==1?5:self.delayDivision.indexOfSelectedItem;
    self.delayTimeSlider.doubleValue=self.freeDelaySeconds*1000; [self effectsChanged:sender];
}
- (void)divisionChanged:(NSPopUpButton *)sender { self.delayDivisionIndex=sender.indexOfSelectedItem; [self effectsChanged:nil]; }
/* Progression character follows what is already chosen: the texture and its style. */
- (int)generatorCharacter {
    if(self.performanceMode!=1) return self.performanceMode>=2?2:0;   // arpeggio and strings: calm motion
    static const int by_style[KV_PATTERN_COUNT]={0,2,1,0,1,1,0,2,1}; // pop, classical cadences, calm
    return by_style[self.pianoPattern];
}
/* One click: a new progression in the current key and mode, same length as now (4 by default; ⌥ toggles 4/8). */
/* Named progressions, written in chord codes of a natural major (family 0) or minor (family 1) key. */
typedef struct { const char *group,*name,*numerals; int family,count,codes[8]; } KvPreset;
#define B_(d) (KV_CODE_BORROWED+(d))
#define V_(t) (KV_CODE_SECONDARY+(t))
static const KvPreset KvPresets[]={
    {"Поп и рок","Поп-канон","I–V–vi–IV",0,4,{0,4,5,3}},
    {"Поп и рок","Пятидесятые","I–vi–IV–V",0,4,{0,5,3,4}},
    {"Поп и рок","Эпическая","vi–IV–I–V",0,4,{5,3,0,4}},
    {"Поп и рок","Героическая","I–♭VI–♭VII–I",0,4,{0,B_(5),B_(6),0}},
    {"Поп и рок","Минорная субдоминанта","I–IV–iv–I",0,4,{0,3,B_(3),0}},
    {"Джаз","Два-пять-один","ii–V–I–vi",0,4,{1,4,0,5}},
    {"Джаз","Турнэраунд","I–vi–ii–V",0,4,{0,5,1,4}},
    {"Джаз","Ритм-чейнджес","I–VI7–ii–V",0,4,{0,V_(1),1,4}},
    {"Джаз","Тритоновая замена","ii–♭II7–I–I",0,4,{1,KV_CODE_TRITONE+0,0,0}},
    {"Джаз","Цепочка доминант","I–V7/vi–vi–V7/V–V–I",0,6,{0,V_(5),5,V_(4),4,0}},
    {"Классика","Каденция","I–IV–V–I",0,4,{0,3,4,0}},
    {"Классика","Канон Пахельбеля","I–V–vi–iii–IV–I–IV–V",0,8,{0,4,5,2,3,0,3,4}},
    {"Классика","Квинтовый круг","vi–ii–V–I",0,4,{5,1,4,0}},
    {"Классика","Неаполитанская","i–♭II–V–i",1,4,{0,KV_CODE_NEAPOLITAN,B_(4),0}},
    {"Минор","Андалузская каденция","i–♭VII–♭VI–V",1,4,{0,6,5,B_(4)}},
    {"Минор","Меланхолия","i–VI–III–VII",1,4,{0,5,2,6}},
    {"Минор","Минорная баллада","i–iv–V–i",1,4,{0,3,B_(4),0}},
    {"Минор","Пикардийская терция","iv–V–i–I",1,4,{3,B_(4),0,B_(0)}},
};
#undef B_
#undef V_
/* The key a preset is played in: the current one if it already is a natural major/minor of that family, else the
   natural major/minor on the same tonic. */
- (KvKey)keyForPreset:(const KvPreset *)p {
    KvKey key=self.key; if(!key.mode && !key.pentatonic && key.minor==(p->family==1)) return key;
    int tonic=kv_tonic(key); KvKey target=key; target.mode=0; target.pentatonic=NO; target.minor=p->family==1;
    for(int i=0;i<12;i++) if(kv_tonic((KvKey){i,target.minor,0,0,NO})==tonic) target.circle_index=i;
    return kv_key_normalize(target);
}
- (NSString *)chordsOfPreset:(const KvPreset *)p inKey:(KvKey)key {
    NSMutableArray *names=[NSMutableArray array];
    for(int i=0;i<p->count;i++) { KvChord chord; if(kv_code_chord(key,p->codes[i],(int)self.chordExtension,&chord)) [names addObject:S(chord.name)]; }
    return [names componentsJoinedByString:@" "];
}
- (void)showPresets:(id)sender {
    NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Прогрессии")]; NSMenu *group=nil; NSString *groupName=nil;
    for(NSInteger i=0;i<(NSInteger)(sizeof(KvPresets)/sizeof(KvPresets[0]));i++) {
        const KvPreset *p=&KvPresets[i];
        if(![groupName isEqualToString:S(p->group)]) { groupName=S(p->group); NSMenuItem *g=[[NSMenuItem alloc] initWithTitle:groupName action:nil keyEquivalent:@""]; group=[[NSMenu alloc] initWithTitle:groupName]; g.submenu=group; [menu addItem:g]; }
        KvKey key=[self keyForPreset:p];
        NSString *title=[NSString stringWithFormat:@"%@   %@   %@",S(p->name),S(p->numerals),[self chordsOfPreset:p inKey:key]];
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:@selector(applyPreset:) keyEquivalent:@""]; item.target=self; item.tag=i;
        if(key.minor!=self.key.minor || key.mode!=self.key.mode || key.pentatonic!=self.key.pentatonic) item.toolTip=[NSString stringWithFormat:T(@"Переключит лад: %@"),S(kv_key_title(key))];
        [group addItem:item];
    }
    NSView *anchor=[sender isKindOfClass:NSView.class]?sender:self.presetsButton;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0,NSHeight(anchor.bounds)+4) inView:anchor];
}
- (void)applyPreset:(NSMenuItem *)item {
    if(item.tag<0 || item.tag>=(NSInteger)(sizeof(KvPresets)/sizeof(KvPresets[0]))) return;
    const KvPreset *p=&KvPresets[item.tag]; KvKey key=[self keyForPreset:p]; BOOL switched=NO;
    if(key.minor!=self.key.minor || key.mode!=self.key.mode || key.pentatonic!=self.key.pentatonic) { [self.mode selectItemAtIndex:p->family]; [self modeChanged:self.mode]; switched=YES; }
    NSArray *previous=[self.progression copy];
    [self changeArrangement:^{
        for(NSButton *button in self.progressionButtons) [button removeFromSuperview];
        [self.progressionButtons removeAllObjects]; [self.progression removeAllObjects];
        for(int i=0;i<p->count;i++) [self appendDegree:p->codes[i]];
        self.keyboardMode.selectedSegment=1; self.selectedDegree=p->codes[0]; self.selectedChip=-1; self.needsLayout=YES;
    }];
    self.sequenceUndo=previous; [self updateTransport];
    self.status.stringValue=[NSString stringWithFormat:T(@"«%@» · %@%@ · ⌘Z — вернуть"),S(p->name),[self chordsOfPreset:p inKey:self.key],switched?[NSString stringWithFormat:T(@" · лад: %@"),[[self keyTitle] lowercaseString]]:@""];
}
- (void)generateCountChanged:(NSPopUpButton *)sender { self.generateCount=(int)(sender.indexOfSelectedItem+2)*2; [self saveState]; }
/* Fill the free slots by continuing from the last chord: up to four when the sequence is shorter, else to eight. */
- (NSUInteger)continueCount { NSUInteger n=self.progression.count; return n==0 || n>=8?0:n<4?4-n:8-n; }
- (void)continueProgression:(id)sender {
    (void)sender; NSUInteger add=[self continueCount]; if(!add) return;
    int existing[8],more[8]; size_t n=self.progression.count; for(size_t i=0;i<n;i++) { int b=kv_code_base(self.progression[i].intValue); existing[i]=b<=6?b:-1; }
    if(!kv_generate_more(self.key,[self generatorCharacter],existing,n,add,arc4random(),more)) return;
    NSArray *previous=[self.progression copy]; NSMutableArray *added=[NSMutableArray array]; for(size_t i=0;i<add;i++) [added addObject:@(more[i])];
    [self changeArrangement:^{ for(NSNumber *code in added) [self appendDegree:code.intValue]; self.needsLayout=YES; }];
    self.sequenceUndo=previous; [self updateTransport];
    NSMutableArray *names=[NSMutableArray array]; for(NSNumber *code in added) { KvChord chord; if(kv_code_chord(self.key,code.intValue,(int)self.chordExtension,&chord)) [names addObject:S(chord.name)]; }
    if(![self isPlayingProgression]) self.status.stringValue=[NSString stringWithFormat:T(@"Дополнено: %@ · ⌘Z — вернуть"),[names componentsJoinedByString:@" "]];
}
- (void)generateProgression:(id)sender {
    (void)sender; size_t count=(size_t)self.generateCount;
    int character=[self generatorCharacter],degrees[8],*picked=degrees;
    if(!kv_generate_more(self.key,character,NULL,0,count,arc4random(),degrees)) { self.status.stringValue=T(@"⚠ Не удалось создать последовательность"); return; }
    NSArray *previous=[self.progression copy];
    [self changeArrangement:^{
        for(NSButton *button in self.progressionButtons) [button removeFromSuperview];
        [self.progressionButtons removeAllObjects]; [self.progression removeAllObjects];
        for(size_t i=0;i<count;i++) [self appendDegree:picked[i]];
        self.keyboardMode.selectedSegment=1; self.selectedDegree=picked[0]; self.selectedChip=-1; self.needsLayout=YES;
        // New chords come with a new arrangement too (as if the dice were rolled), so no two takes open the same way.
        self.arrangementSeed=arc4random_uniform(UINT32_MAX-1)+1; self.generatedRhythm=YES;
    }];
    self.sequenceUndo=previous; [self updateTransport];
    NSString *characters[]={T(@"поп"),T(@"классика"),T(@"спокойная")};
    if(![self isPlayingProgression]) self.status.stringValue=[NSString stringWithFormat:T(@"Новые аккорды: %zu · %@ · %@ · вариация №%u · ⌘Z — вернуть%@"),count,characters[character],[self keyTitle],self.arrangementSeed%1000,[self continueCount]?[NSString stringWithFormat:T(@" · ⇧⌘N — дополнить ещё %lu"),(unsigned long)[self continueCount]]:@""];
}
- (void)inspectorTabChanged:(NSSegmentedControl *)sender {
    self.inspectorTab=sender.selectedSegment; [self refreshMidiDevices]; self.needsLayout=YES; [self layoutSubtreeIfNeeded]; self.needsDisplay=YES;
}
- (void)refreshMidiDevices {
    NSArray *names=[self.midi destinationNames]; NSInteger selected=MIN(self.midi.destinationIndex,(NSInteger)names.count-1);
    [self.midiDestination removeAllItems]; [self.midiDestination addItemsWithTitles:names]; [self.midiDestination selectItemAtIndex:MAX(0,selected)];
    self.midi.destinationIndex=MAX(0,selected);
    NSUInteger sources=[self.midi sourceCount];
    self.midiInToggle.title=sources?[NSString stringWithFormat:T(@"Принимать ноты · %lu %@"),(unsigned long)sources,sources==1?T(@"устройство"):sources<5?T(@"устройства"):T(@"устройств")]:T(@"Принимать ноты · устройств нет");
    self.midiInToggle.toolTip=T(@"Ноты с любой подключённой MIDI-клавиатуры звучат роялем Tonora, подсвечиваются и называются аккордом");
    self.midiExportInfo.stringValue=[NSString stringWithFormat:T(@"Что сохранится: %@ · %.0f BPM · %@ · две дорожки (левая и правая рука)"),[self keyTitle],self.tempo,[self arrangementSummary]];
    self.midiStatus.stringValue=self.midi.available?T(@"Порт «Tonora» виден в DAW как MIDI-вход."):T(@"⚠ CoreMIDI недоступен: работает только файл.");
    self.midiExportButton.enabled=self.progression.count>0; self.midiCopyButton.enabled=self.progression.count>0; self.midiOutToggle.enabled=self.midi.available; self.midiInToggle.enabled=self.midi.available;
    [self configurePlaceButton:self.midiAddChordButton available:self.detectedDegree>=0];
}
- (void)midiDestinationChanged:(NSPopUpButton *)sender { [self.midi allNotesOff]; memset(_midiSounding,0,sizeof(_midiSounding)); self.midi.destinationIndex=sender.indexOfSelectedItem; }
- (void)midiOutToggled:(NSButton *)sender { self.midiOutEnabled=sender.state==NSControlStateValueOn; [self.midi allNotesOff]; memset(_midiSounding,0,sizeof(_midiSounding)); [self saveState]; }
- (void)silenceMidi { [self.midi allNotesOff]; memset(_midiSounding,0,sizeof(_midiSounding)); }
- (void)chordKeysToggled:(NSButton *)sender { [self releaseManualKeys]; self.chordKeys=sender.state==NSControlStateValueOn; [self saveState]; }
- (void)releaseManualKeys { for(int m=0;m<128;m++) if(_held[m]) [self midiNote:m velocity:0 on:NO]; }
- (void)midiInToggled:(NSButton *)sender { self.midi.inputEnabled=sender.state==NSControlStateValueOn; if(!self.midi.inputEnabled) [self releaseManualKeys]; [self saveState]; }
- (int)midiProgram { return self.instrument==1?2:self.instrument==2?4:self.instrument==KV_INSTRUMENT_STRINGS?48:0; }   // GM: piano, electric grand, e-piano, string ensemble
/* How to move from the current key to another: the chords they share (with their degree in each), a pivot — preferably
   ii, then IV, then vi of the new key — and the cadence that confirms the arrival. masks[ring] marks shared sectors. */
- (NSString *)modulationTo:(int)index minor:(BOOL)minor masks:(unsigned *)masks {
    NSString *label=[self circleLabelAt:index minor:minor]; NSRange letter=[@"CDEFGAB" rangeOfString:[label substringToIndex:1]];
    KvKey to=kv_key_normalize((KvKey){index,minor,0,letter.location==NSNotFound?0:(int)letter.location+1,NO});
    int fd[7],td[7]; size_t n=kv_common_chords(self.key,to,fd,td,7); masks[0]=masks[1]=0;
    KvChord dominant,tonic; kv_chord_extended(to,4,1,&dominant); kv_chord(to,0,&tonic);
    char toName[64]; snprintf(toName,sizeof(toName),"%s",kv_key_title(to));
    if(!n) return [NSString stringWithFormat:T(@"Переход в %@: общих аккордов нет — можно прийти прямо через её доминанту %@ → %@."),S(toName),S(dominant.name),S(tonic.name)];
    NSMutableArray *parts=[NSMutableArray array]; int pivot=-1;
    for(size_t i=0;i<n;i++) {
        KvChord here,there; kv_chord(self.key,fd[i],&here); kv_chord(to,td[i],&there);
        [parts addObject:[NSString stringWithFormat:@"%@ (%@ → %@)",S(here.name),S(here.degree),S(there.degree)]];
        int third=here.midi[1]-here.midi[0],fifth=here.midi[2]-here.midi[0];
        if(fifth==7) for(int s=0;s<12;s++) if(kv_tonic((KvKey){s,third==3,0,0,NO})==here.midi[0]%12) masks[third==3?1:0]|=1u<<s;
        int rank=td[i]==1?3:td[i]==3?2:td[i]==5?1:0; if(pivot<0 || rank>(td[pivot]==1?3:td[pivot]==3?2:td[pivot]==5?1:0)) pivot=(int)i;
    }
    KvChord here,there; kv_chord(self.key,fd[pivot],&here); kv_chord(to,td[pivot],&there);
    return [NSString stringWithFormat:T(@"Переход в %@. Общие аккорды: %@. Опорный: %@ — %@ здесь, %@ там; дальше %@ → %@."),S(toName),[parts componentsJoinedByString:@", "],S(here.name),S(here.degree),S(there.degree),S(dominant.name),S(tonic.name)];
}
/* ---- MIDI import: a .mid file becomes key, meter, tempo, chords and an edited track ---- */
- (void)importMidi:(id)sender {
    (void)sender; NSOpenPanel *panel=[NSOpenPanel openPanel]; panel.allowsMultipleSelection=NO; panel.message=T(@"MIDI-файл: тональность, размер, темп и аккорды определятся сами");
    panel.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"mid"],[UTType typeWithFilenameExtension:@"midi"]];
    __weak KvRoot *weakSelf=self;
    void (^done)(NSModalResponse)=^(NSModalResponse result) { if(result!=NSModalResponseOK || !panel.URL) return; KvRoot *root=weakSelf; [root importMidiData:[NSData dataWithContentsOfURL:panel.URL] name:panel.URL.lastPathComponent]; };
    if(self.window) [panel beginSheetModalForWindow:self.window completionHandler:done]; else done([panel runModal]);
}
static NSString *KvBars(int n) { int t=n%100,u=n%10; return t>=11 && t<=14?T(@"тактов"):u==1?T(@"такт"):u>=2 && u<=4?T(@"такта"):T(@"тактов"); }
static BOOL KvIsMidiURL(NSURL *url) { NSString *ext=url.pathExtension.lowercaseString; return [ext isEqualToString:@"mid"] || [ext isEqualToString:@"midi"]; }
- (NSURL *)draggedMidi:(id<NSDraggingInfo>)info {
    NSArray<NSURL *> *urls=[info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    for(NSURL *url in urls) if(KvIsMidiURL(url)) return url; return nil;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return info.draggingSource==nil && [self draggedMidi:info]?NSDragOperationCopy:NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info { NSURL *url=[self draggedMidi:info]; return url && [self importMidiData:[NSData dataWithContentsOfURL:url] name:url.lastPathComponent]; }
- (BOOL)importMidiData:(NSData *)data name:(NSString *)name {
    if(self.editingSection>=0) [self showView:0];   // a file goes into the draft, never over a section of the song
    KvMidiSong *song=calloc(1,sizeof(KvMidiSong)); if(!song) return NO;
    if(!data || data.length>(8u<<20) || !kv_midi_decode(data.bytes,data.length,song)) { self.status.stringValue=[NSString stringWithFormat:T(@"⚠ «%@» не читается как MIDI-файл"),name?:T(@"файл")]; free(song); return NO; }
    if(!song->count) { self.status.stringValue=[NSString stringWithFormat:T(@"В «%@» нет нот"),name]; free(song); return NO; }
    // Meter as written (other meters play as 4/4); the music starts at the bar of its first note.
    KvMeter meter=song->numerator==3 && song->denominator==4?KV_METER_3_4:song->numerator==6 && song->denominator==8?KV_METER_6_8:KV_METER_4_4;
    double bar=kv_meter_bar(meter),first=floor(song->notes[0].beat/bar+1e-9)*bar,span=song->length-first;
    int bars=MAX(1,(int)ceil(span/bar-1e-9));
    // Up to eight chords: one per bar up to eight bars, one per two bars up to sixteen; longer music is cut there.
    KvChordLength length=bars<=8?KV_LENGTH_BAR:KV_LENGTH_TWO_BARS; double perChord=kv_chord_beats(meter,length);
    int count=MIN(8,MAX(1,(int)ceil(bars*bar/perChord-1e-9))); double total=count*perChord;
    double weights[12]={0}; int segmentBass[8]; double segment[8][12]; memset(segment,0,sizeof(segment)); for(int c=0;c<8;c++) segmentBass[c]=-1;
    for(size_t i=0;i<song->count;i++) {
        const KvPianoEvent *e=&song->notes[i]; double at=e->beat-first,end=fmin(total,at+e->duration); if(at>=total || end<=at) continue;
        weights[e->midi%12]+=end-at;
        for(int c=0;c<count;c++) { double from=fmax(at,c*perChord),to=fmin(end,(c+1)*perChord); if(to<=from) continue;
            segment[c][e->midi%12]+=to-from;
            if(at<c*perChord+perChord/2 && (segmentBass[c]<0 || e->midi<segmentBass[c])) segmentBass[c]=e->midi; }   // the lowest note of the chord's first half
    }
    KvKey key=kv_detect_key(weights,song->has_key,song->sharps,NULL); int codes[8];
    for(int c=0;c<count;c++) { codes[c]=kv_detect_chord(key,segment[c],segmentBass[c]<0?-1:segmentBass[c]%12); if(codes[c]<0) codes[c]=c?codes[c-1]:0; }
    [self stopPlayback:nil];
    if(self.viewMode!=1) { [self.viewSwitch setSelectedSegment:1]; [self viewChanged:self.viewSwitch]; }
    [self applyTempo:song->bpm];
    [self.meterChoice selectItemAtIndex:meter]; [self meterChanged:self.meterChoice];
    [self.lengthChoice selectItemAtIndex:length]; [self lengthChanged:self.lengthChoice];
    [self.mode selectItemAtIndex:key.minor?1:0]; [self modeChanged:self.mode]; [self selectIndex:key.circle_index minor:key.minor];
    NSArray *previous=[self.progression copy]; NSMutableArray<NSNumber *> *found=[NSMutableArray array]; for(int c=0;c<count;c++) [found addObject:@(codes[c])];
    [self changeArrangement:^{
        for(NSButton *button in self.progressionButtons) [button removeFromSuperview];
        [self.progressionButtons removeAllObjects]; [self.progression removeAllObjects];
        for(NSNumber *code in found) [self appendDegree:code.intValue];
        self.selectedDegree=found.firstObject.intValue; self.selectedChip=-1; self.needsLayout=YES;
    }];
    self.sequenceUndo=previous;
    // The file's own notes become the track, so it plays as written over the found chords.
    KvPerformance *track=calloc(1,sizeof(KvPerformance)); if(!track) { free(song); return NO; }
    track->chord_count=(size_t)count; track->beats_per_chord=perChord; track->beats_per_bar=bar; track->total_beats=total;
    for(size_t i=0;i<song->count && track->count<KV_PERFORMANCE_CAPACITY;i++) {
        KvPianoEvent e=song->notes[i]; e.beat-=first; if(e.beat<0 || e.beat>=total-.02 || e.midi<21 || e.midi>108) continue;
        if(e.midi>=KV_KEYSWITCH_LOW && e.midi<KV_KEYSWITCH_LOW+KV_ARTICULATION_COUNT && e.duration<=.25) continue;   // a strings keyswitch, not a note
        e.duration=fmin(e.duration,total-e.beat); if(e.duration<.05) continue;
        e.velocity=fminf(1,.45f+.55f*e.velocity); e.chord=(unsigned)MIN(count-1,(int)floor(e.beat/perChord+1e-9)); e.fill=0;
        track->events[track->count++]=e;
    }
    kv_performance_resolve_overlaps(track);
    BOOL valid=track->count && kv_performance_valid(track);
    if(valid) { [self pushTrackUndo]; *self.track=*track; self.trackEdited=YES; self.roll.edited=YES; [self.roll reload]; [self.roll resetView]; [self saveState]; [self updateTransport]; }
    char keyName[64]; snprintf(keyName,sizeof(keyName),"%s",kv_key_title(self.key));
    self.status.stringValue=valid?[NSString stringWithFormat:T(@"Импорт «%@»: %zu нот · %@ · %@ · %d %@%@"),name,track->count,S(keyName),S(kv_meter_name(meter)),MIN(bars,16),KvBars(MIN(bars,16)),bars>16?[NSString stringWithFormat:T(@" (из %d)"),bars]:@""]
                                 :[NSString stringWithFormat:T(@"⚠ «%@»: ноты не уложились в дорожку"),name];
    free(track); free(song); return valid;
}
- (BOOL)exportMidiToPath:(NSString *)path {
    NSUInteger count=self.progression.count; if(!count || !path) return NO;
    KvChord chords[8];
    for(NSUInteger i=0;i<count;i++) { if(!kv_code_chord(self.key,self.progression[i].intValue,(int)self.chordExtension,&chords[i])) return NO; for(size_t v=0;v<chords[i].count;v++) chords[i].midi[v]+=self.keyboardBase-60; }
    KvPerformance plan;
    if(self.trackEdited && self.track->chord_count==count && kv_performance_valid(self.track)) plan=*self.track;
    else if(!kv_arrange_with(chords,count,self.keyboardBase,self.key,[self arrangementForPreview:NO],&plan)) return NO;
    int numerator=self.meter==KV_METER_4_4?4:self.meter==KV_METER_3_4?3:6,power=self.meter==KV_METER_6_8?3:2;
    int scale[8]; kv_scale(self.key,scale); BOOL minor=scale[2]-scale[0]==3;
    NSString *title=[NSString stringWithFormat:@"Tonora · %@ · %@",[self keyTitle],[self arrangementSummary]];
    return kv_midi_write(&plan,self.tempo,numerator,power,[self writtenSignature],minor,[self midiProgram],title.UTF8String,path.fileSystemRepresentation);
}
- (void)exportMidi:(id)sender {
    (void)sender; if(!self.progression.count || !self.window) return;
    NSSavePanel *panel=[NSSavePanel savePanel]; panel.title=T(@"Сохранить MIDI"); panel.prompt=T(@"Сохранить");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes=@[@"mid",@"midi"];
#pragma clang diagnostic pop
    NSString *texture=[self textureName];
    panel.nameFieldStringValue=[NSString stringWithFormat:@"Tonora · %@ · %@.mid",[self keyTitle],texture];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if(response!=NSModalResponseOK || !panel.URL) return;
        BOOL ok=[self exportMidiToPath:panel.URL.path];
        self.status.stringValue=ok?[NSString stringWithFormat:T(@"MIDI сохранён: %@"),panel.URL.lastPathComponent]:T(@"⚠ Не удалось сохранить MIDI");
        self.midiStatus.stringValue=self.status.stringValue;
    }];
}
/* Notes from an external keyboard: sound through the piano, light the keys, and name the chord being held. */
/* What one key plays: the note, or with «Аккорд одной клавишей» the key's chord built on it when it is a degree root. */
- (int)notesForKey:(int)midi notes:(int *)notes {
    int note=midi; while(note>108) note-=12; while(note<21) note+=12;
    if(self.chordKeys) for(int d=0;d<7;d++) {
        KvChord chord; if(!kv_code_chord(self.key,d,(int)self.chordExtension,&chord) || kv_mod(chord.midi[0],12)!=kv_mod(note,12)) continue;
        int n=0; for(size_t v=0;v<chord.count && n<8;v++) { int m=note+chord.midi[v]-chord.midi[0]; if(m<=108) notes[n++]=m; }
        return n;
    }
    notes[0]=note; return 1;
}
- (void)midiNote:(int)midi velocity:(int)velocity on:(BOOL)on {
    if(midi<0 || midi>127) return;
    // Keyswitches below the strings' range (C1–D♯1) pick the articulation, as in orchestral libraries, and do not sound.
    if([self stringsChosen] && midi>=KV_KEYSWITCH_LOW && midi<KV_KEYSWITCH_LOW+KV_ARTICULATION_COUNT) { if(on) [self setArticulationTo:(KvArticulation)(midi-KV_KEYSWITCH_LOW)]; return; }
    if(on && _held[midi]) [self midiNote:midi velocity:0 on:NO];   // a second note-on without its note-off restrikes the key
    if(!on && !_held[midi]) return;
    _held[midi]=on;
    // A key sounds while it is held, as on a piano (and as Ableton plays a MIDI or computer keyboard). Several keys may
    // share a note (two chords with a common tone): it sounds until the last of them is let go.
    if(on) {
        int notes[8],n=[self notesForKey:midi notes:notes]; NSMutableArray *flash=[NSMutableArray array];
        _keyNoteCount[midi]=n; memcpy(_keyNotes[midi],notes,(size_t)n*sizeof(int));
        for(int i=0;i<n;i++) { int m=notes[i]; if(_soundCount[m]++==0 && self.audio) kv_audio_hold(self.audio,m,velocity/127.0); [flash addObject:@(m)]; }
        if(self.audio) [self.piano flashNotes:flash];
    } else {
        for(int i=0;i<_keyNoteCount[midi];i++) { int m=_keyNotes[midi][i];
            if(_soundCount[m]>0 && --_soundCount[m]==0 && self.audio) { if(self.pedalDown) _pedalHeld[m]=YES; else kv_audio_release(self.audio,m); } }
        _keyNoteCount[midi]=0;
    }
    if(!self.visualPlayback) { NSMutableArray *down=[NSMutableArray array]; for(int m=0;m<128;m++) if(_soundCount[m]>0) [down addObject:@(m)]; [self.piano setActiveNotes:down]; }
    [self updateDetectedChord];
}
- (BOOL)isSounding:(int)midi { return midi>=0 && midi<128 && _soundCount[midi]>0; }
/* Computer keyboard as in Ableton: the middle row plays white keys from C (A … '), the row above black keys
   (W E · T Y U · O P); Z / X move an octave, C / V change the velocity by 20; M switches it on and off. Keys go by
   position, so any input language works. */
static int ComputerKeyOffset(unsigned short code) {
    switch(code) { case 0: return 0; case 13: return 1; case 1: return 2; case 14: return 3; case 2: return 4; case 3: return 5; case 17: return 6;
        case 5: return 7; case 16: return 8; case 4: return 9; case 32: return 10; case 38: return 11; case 40: return 12; case 31: return 13;
        case 37: return 14; case 35: return 15; case 41: return 16; case 39: return 17; default: return -1; }
}
- (BOOL)isHeld:(int)midi { return midi>=0 && midi<128 && _held[midi]; }
- (void)showComputerKeyboardStatus {
    NSString *low=[NSString stringWithFormat:@"%@%d",[self keyboardName:self.computerBase],self.computerBase/12-1];
    self.status.stringValue=self.computerKeyboard?[NSString stringWithFormat:T(@"Клавиатура компьютера · A = %@ · сила %d · Z X — октава · C V — сила · M — выключить"),low,self.computerVelocity]:T(@"Клавиатура компьютера выключена · M — включить");
    Hint(self.computerKeyboardButton,self.computerKeyboard?[NSString stringWithFormat:T(@"Клавиатура компьютера включена · A = %@ · M — выключить"),low]:T(@"Играть с клавиатуры компьютера · M"));
}
- (void)setComputerKeyboard:(BOOL)computerKeyboard {
    if(!computerKeyboard) [self releaseComputerKeys];
    if(computerKeyboard && !_computerKeyboard) _computerBase=self.keyboardBase;
    _computerKeyboard=computerKeyboard; self.computerKeyboardButton.state=computerKeyboard?NSControlStateValueOn:NSControlStateValueOff;
    self.piano.needsDisplay=YES; self.needsDisplay=YES;
    [Defaults() setBool:computerKeyboard forKey:@"computerKeyboard"];
}
- (void)toggleComputerKeyboard:(id)sender { (void)sender; self.computerKeyboard=!self.computerKeyboard; [self showComputerKeyboardStatus]; }
- (BOOL)computerKeyDown:(NSEvent *)event {
    if(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption)) return NO;
    unsigned short code=event.keyCode;
    if(code==46) { if(!event.isARepeat) [self toggleComputerKeyboard:nil]; return YES; }   // M
    if(!self.computerKeyboard || code>=128) return NO;
    int offset=ComputerKeyOffset(code);
    if(offset>=0) {
        if(!event.isARepeat && _computerKey[code]<0) { int midi=self.computerBase+offset; if(midi>=21 && midi<=108) { _computerKey[code]=midi; [self midiNote:midi velocity:self.computerVelocity on:YES]; } }
        return YES;
    }
    if(code==6 || code==7) { if(!event.isARepeat) { self.computerBase=MAX(24,MIN(96,self.computerBase+(code==6?-12:12))); [self showComputerKeyboardStatus]; self.piano.needsDisplay=YES; self.needsDisplay=YES; } return YES; } // Z X — the drawn keyboard moves too
    if(code==8 || code==9) { if(!event.isARepeat) { self.computerVelocity=MAX(1,MIN(127,self.computerVelocity+(code==8?-20:20))); [self showComputerKeyboardStatus]; } return YES; } // C V
    return NO;
}
- (BOOL)computerKeyUp:(NSEvent *)event {
    unsigned short code=event.keyCode; if(code>=128 || _computerKey[code]<0) return NO;
    int midi=_computerKey[code]; _computerKey[code]=-1; [self midiNote:midi velocity:0 on:NO]; return YES;
}
/* Focus left the window: nothing may stay stuck down. */
- (void)releaseComputerKeys { for(int code=0;code<128;code++) if(_computerKey[code]>=0) { int midi=_computerKey[code]; _computerKey[code]=-1; [self midiNote:midi velocity:0 on:NO]; } }
- (void)keyUp:(NSEvent *)event { if(![self computerKeyUp:event]) [super keyUp:event]; }
- (void)updateDetectedChord {
    int notes[128],n=0; for(int m=0;m<128;m++) if(_soundCount[m]>0) notes[n++]=m;   // what sounds, so a one-key chord is named too
    self.detectedDegree=-1; char name[32]; int root=-1;
    if(n>=2 && kv_midi_chord_name(notes,n,name,&root)) {
        unsigned mask=0; for(int i=0;i<n;i++) mask|=1u<<(notes[i]%12);
        int candidates[40],nc=0,outside[24]; for(int d=0;d<7;d++) candidates[nc++]=d;
        size_t no=kv_chromatic_codes(self.key,0,outside,NULL,24); for(size_t i=0;i<no;i++) candidates[nc++]=outside[i];
        for(int i=0;i<nc && self.detectedDegree<0;i++) for(int ext=0;ext<=1;ext++) {
            KvChord chord; if(!kv_code_chord(self.key,candidates[i],ext,&chord)) continue;
            unsigned cm=0; for(size_t v=0;v<chord.count;v++) cm|=1u<<(chord.midi[v]%12);
            if(cm==mask) { self.detectedDegree=candidates[i]; break; }
        }
        NSString *degreeText=@"";
        if(self.detectedDegree>=0) { KvChord chord; kv_code_chord(self.key,(int)self.detectedDegree,0,&chord); degreeText=[NSString stringWithFormat:@" · %@",S(chord.degree)]; }
        self.midiChordLabel.stringValue=[S(name) stringByAppendingString:degreeText];
    } else self.midiChordLabel.stringValue=n==1?[NSString stringWithFormat:@"%@%d",[self keyboardName:notes[0]],notes[0]/12-1]:@"—";
    NSMutableArray *held=[NSMutableArray array]; for(int i=0;i<n;i++) [held addObject:[NSString stringWithFormat:@"%@%d",[self keyboardName:notes[i]],notes[i]/12-1]];
    self.midiHeldLabel.stringValue=n?[T(@"Звучит: ") stringByAppendingString:[held componentsJoinedByString:@"  "]]:T(@"Сыгранные ноты звучат роялем Tonora и подсвечиваются на клавиатуре; аккорд из двух и более нот называется здесь.");
    [self configurePlaceButton:self.midiAddChordButton available:self.detectedDegree>=0];
}
- (void)addDetectedChord:(id)sender { (void)sender; if(self.detectedDegree>=0) [self placeCode:(int)self.detectedDegree]; }
/* Which hand of the current plan a sounding note belongs to; outside a plan the lower octave is the left hand. */
/* Beat position inside the current plan (wrapped by its length), consistent with the mixer after tempo and speed changes. */
- (double)playheadBeatUnwrapped {
    if(self.songPlaying) { double seconds=0; if(!kv_audio_is_playing(self.audio)) return -1; kv_audio_part(self.audio,&seconds); return seconds*self.tempo*self.speed/60.0; }
    double seconds=0; if(!kv_audio_playhead(self.audio,&seconds)) return -1;
    return self.rateBeat+fmax(0,seconds-self.rateSeconds)*self.tempo*self.speed/60.0;
}
- (double)playheadBeat {
    if(!self.currentPlan || !self.playingPerformance || self.currentPlan->total_beats<=0) return -1;
    double beat=[self playheadBeatUnwrapped]; return beat<0?-1:fmod(beat,self.currentPlan->total_beats);
}
/* Call before changing tempo or speed while playing: pins the current beat so the new rate continues from it. */
- (void)markRateChange {
    if(!self.playingPerformance) return;
    double seconds=0; if(!kv_audio_playhead(self.audio,&seconds)) return;
    self.rateBeat=[self playheadBeatUnwrapped]; self.rateSeconds=seconds;
}
/* The event of the current plan that is sounding `midi` at the playhead, or −1. */
- (long)planEventForMidi:(int)midi {
    if(!self.currentPlan || !self.playingPerformance) return -1;
    double total=self.currentPlan->total_beats,beat=[self playheadBeat]; if(beat<0) beat=0;
    long best=-1; double bestStart=-INFINITY;
    for(size_t i=0;i<self.currentPlan->count;i++) {
        KvPianoEvent e=self.currentPlan->events[i]; if(e.midi!=midi) continue;
        for(int wrap=-1;wrap<=1;wrap++) { double b=beat+wrap*total; if(b>=e.beat-.12 && b<=e.beat+e.duration+.45 && e.beat+wrap*total>bestStart) { best=(long)i; bestStart=e.beat+wrap*total; } }
    }
    return best;
}
- (BOOL)planNote:(int)midi hand:(int *)hand finger:(int *)finger {
    long best=[self planEventForMidi:midi]; if(best<0) return NO;
    *hand=(int)self.currentPlan->events[best].hand; *finger=_planFingers[best]; return YES;
}
- (int)handForMidi:(int)midi {
    int hand=0,finger=0; if([self planNote:midi hand:&hand finger:&finger]) return hand;
    return midi<60?0:1;
}
- (int)velocityForMidi:(int)midi {
    if(self.currentPlan && self.playingPerformance) {
        double total=self.currentPlan->total_beats,beat=[self playheadBeat]; if(beat<0) beat=0;
        for(size_t i=0;i<self.currentPlan->count;i++) { KvPianoEvent e=self.currentPlan->events[i]; if(e.midi==midi && fabs(fmod(beat-e.beat+total,total))<.2) return (int)lround(e.velocity*127); }
    }
    return 90;
}
/* A scale or a chord preview: a melodic line goes to one hand (the right one unless it lies below middle C);
   a chord within an octave goes to one hand, a wider one splits at its largest gap. Then the line is fingered as a whole. */
- (void)fingerSequence:(const int *)notes count:(size_t)count voices:(size_t)voices {
    _visualCount=0; _visualVoices=voices; if(!notes || !voices || count>256 || count%voices) return;
    KvPianoEvent events[256]; unsigned char fingers[256]={0};
    int low=127,high=0; for(size_t i=0;i<count;i++) { if(notes[i]<low) low=notes[i]; if(notes[i]>high) high=notes[i]; }
    for(size_t i=0;i<count;i++) {
        unsigned hand;
        if(voices==1) hand=high<60?0:1;
        else {
            const int *chord=notes+(i/voices)*voices; int lo=127,hi=0; for(size_t v=0;v<voices;v++) { if(chord[v]<lo) lo=chord[v]; if(chord[v]>hi) hi=chord[v]; }
            if(hi-lo<=12) hand=hi<60?0:1;
            else { int sorted[64]; size_t n=MIN(voices,(size_t)64); memcpy(sorted,chord,n*sizeof(int));
                for(size_t x=1;x<n;x++) for(size_t y=x;y>0 && sorted[y]<sorted[y-1];y--) { int t=sorted[y]; sorted[y]=sorted[y-1]; sorted[y-1]=t; }
                int split=sorted[0]+1,gap=-1; for(size_t x=1;x<n;x++) if(sorted[x]-sorted[x-1]>gap) { gap=sorted[x]-sorted[x-1]; split=sorted[x]; }
                hand=notes[i]>=split?1:0; }
        }
        events[i]=(KvPianoEvent){notes[i],(double)(i/voices),1,.8f,(unsigned)(i/voices),hand,0};
    }
    kv_finger_events(events,count,0,fingers); kv_finger_events(events,count,1,fingers);
    for(size_t i=0;i<count;i++) { _visualMidi[i]=notes[i]; _visualHand[i]=(unsigned char)events[i].hand; _visualFinger[i]=fingers[i]; }
    _visualCount=count;
}
/* For self-tests: "L"/"R" per note and the fingers of the last scale or chord preview, e.g. "RRRRRRRR 12312345". */
- (NSString *)visualFingering {
    NSMutableString *hands=[NSMutableString string],*fingers=[NSMutableString string];
    for(size_t i=0;i<_visualCount;i++) { [hands appendString:_visualHand[i]?@"R":@"L"]; [fingers appendFormat:@"%d",_visualFinger[i]]; }
    return [NSString stringWithFormat:@"%@ %@",hands,fingers];
}
- (BOOL)visualNote:(int)midi hand:(int *)hand finger:(int *)finger {
    if(!self.visualPlayback || !_visualCount || !_visualVoices) return NO;
    long event=kv_audio_event(self.audio); if(event<0) event=0;
    for(long e=event;e>=0 && e>=event-2;e--) for(size_t v=0;v<_visualVoices;v++) {
        size_t i=(size_t)e*_visualVoices+v; if(i<_visualCount && _visualMidi[i]==midi) { *hand=_visualHand[i]; *finger=_visualFinger[i]; return YES; }
    }
    return NO;
}
/* A key pressed on the MIDI keyboard (or on the screen): finger it from the hand's previous position.
   Keys below middle C belong to the left hand. */
/* Fingers for the hands beside the circle: each sounding note gets the finger its source assigned — the fingered
   performance, or the fingered scale or chord. Keys pressed by hand (MIDI or on-screen keyboard) move no fingers. 1 = thumb. */
- (void)updateHands {
    if(![self.circle handsVisible]) return;
    int active[KV_ACTIVE_NOTES]; unsigned count=kv_audio_active_notes(self.audio,active);
    int fingers[2][5]; for(int h=0;h<2;h++) for(int f=0;f<5;f++) fingers[h][f]=-1;
    BOOL sounding[128]={NO};
    for(unsigned i=0;i<count;i++) {
        int midi=active[i],hand=-1,finger=0; if(midi<0 || midi>127) continue; sounding[midi]=YES;
        BOOL known=[self planNote:midi hand:&hand finger:&finger];
        if(!known) known=[self visualNote:midi hand:&hand finger:&finger];
        if(!known) continue;
        if(hand<0 || hand>1 || finger<1 || finger>5) continue;
        fingers[hand][finger-1]=midi;
    }
    for(int hand=0;hand<2;hand++) [self.circle setHand:hand fingers:fingers[hand]];
}
/* Mirror the sounding notes to the MIDI output: note-on when a note appears, note-off when the engine releases it. */
- (void)updateMidiOut {
    if(!self.midiOutEnabled || !self.midi.available) return;
    BOOL now[2][128]; memset(now,0,sizeof(now));
    if(kv_audio_is_playing(self.audio)) { int active[KV_ACTIVE_NOTES]; unsigned count=kv_audio_active_notes(self.audio,active); for(unsigned i=0;i<count;i++) now[[self handForMidi:active[i]]][active[i]]=YES; }
    for(int hand=0;hand<2;hand++) for(int midi=21;midi<=108;midi++) {
        if(now[hand][midi] && !_midiSounding[hand][midi]) [self.midi noteOn:midi velocity:[self velocityForMidi:midi] channel:hand];
        else if(!now[hand][midi] && _midiSounding[hand][midi]) [self.midi noteOff:midi channel:hand];
        _midiSounding[hand][midi]=now[hand][midi];
    }
}
- (void)showCredits:(id)sender {
    (void)sender;
    NSAlert *alert=[NSAlert new]; alert.messageText=T(@"Инструменты Tonora");
    alert.informativeText=T(@"Salamander Grand Piano V3 — Alexander Holm\nhttps://github.com/sfzinstruments/SalamanderGrandPiano\n\nYamaha CP80 / Hohner Pianet T — Greg Sullivan\nhttps://github.com/sfzinstruments/GregSullivan.E-Pianos\n\nСтрунные (виолончели и скрипки, sustain vibrato) — VS Chamber Orchestra 2: Community Edition, Versilian Studios: Sam Gossner, Simon Dalzell. CC0 1.0, общественное достояние.\nhttps://github.com/sgossner/VSCO-2-CE\n\nБарабаны для битов — Big Rusty Drums, Karoryfer Samples. CC0 1.0, общественное достояние.\nhttps://github.com/sfzinstruments/karoryfer.big-rusty-drums\n\nRoland TR-808 — Michael Fischer (Technopolis, 1994), CC0 1.0 через Tidal Cycles.\nhttps://github.com/tidalcycles/sounds-tr808-fischer\n\nПеркуссия (хлопки, тамбурин, конги, шейкер) — Versilian Community Sample Library, Versilian Studios. CC0 1.0, общественное достояние.\nhttps://github.com/sgossner/VCSL\n\nРеверберация: Verblib / Freeverb — Philip Bennefall, Jezar at Dreampoint. Public domain / Unlicense.\nhttps://github.com/blastbay/verblib\n\nЗаписи роялей и электропиано: Creative Commons Attribution 3.0\nhttps://creativecommons.org/licenses/by/3.0/\n\nИспользуются компактные наборы записей. Полные тексты лицензий, авторство и контрольные суммы включены в ресурсы приложения.");
    [alert addButtonWithTitle:T(@"Готово")]; [alert runModal];
}
- (BOOL)shortcutsVisible { return self.shortcutsCard && !self.shortcutsCard.hidden; }
- (void)toggleShortcuts:(id)sender {
    (void)sender;
    if(!self.shortcutsCard) { KvShortcutsCard *card=[[KvShortcutsCard alloc] initWithFrame:self.bounds]; card.owner=self; card.hidden=YES; self.shortcutsCard=card; }
    if(self.shortcutsCard.superview!=self || self.subviews.lastObject!=self.shortcutsCard) [self addSubview:self.shortcutsCard positioned:NSWindowAbove relativeTo:nil]; // above everything
    self.shortcutsCard.frame=self.bounds; self.shortcutsCard.hidden=!self.shortcutsCard.hidden; self.shortcutsCard.needsDisplay=YES;
    if(!self.shortcutsCard.hidden) { ((KvShortcutsCard *)self.shortcutsCard).tab=0; TNHintHide(nil); [self silenceToolTips]; }
    else { for(NSView *view in self.silencedToolTips) if(!view.toolTip.length) view.toolTip=[self.silencedToolTips objectForKey:view]; self.silencedToolTips=nil; }
}
/* AppKit shows a view's tooltip even under the card, so the card takes them off while it is open (a refreshed one is kept). */
- (void)silenceToolTips {
    if(!self.silencedToolTips) self.silencedToolTips=[NSMapTable weakToStrongObjectsMapTable];
    NSMutableArray<NSView *> *views=[self.subviews mutableCopy];
    while(views.count) { NSView *view=views.lastObject; [views removeLastObject]; if(view==self.shortcutsCard) continue;
        if(view.toolTip.length) { [self.silencedToolTips setObject:view.toolTip forKey:view]; view.toolTip=nil; }
        [views addObjectsFromArray:view.subviews]; }
}
- (void)showCircleHelp:(id)sender {
    if(!self.shortcutsVisible) [self toggleShortcuts:sender];
    ((KvShortcutsCard *)self.shortcutsCard).tab=1; self.shortcutsCard.needsDisplay=YES;
}
- (void)pianoRollToggleShortcuts:(KvPianoRoll *)roll { (void)roll; [self toggleShortcuts:nil]; }
- (BOOL)pianoRollShortcutsVisible:(KvPianoRoll *)roll { (void)roll; return self.shortcutsVisible; }
// ---- the song (spec 1.4): sections made from the circle's progressions, edited through the same working state ----
- (KvSong *)liveSong {
    KvSong *s=self.song; s->key=self.key; s->meter=self.meter; s->bpm=self.tempo; s->keyboard_base=self.keyboardBase; s->extension=(int)self.chordExtension; return s;
}
- (NSDictionary *)captureWorking {
    NSMutableDictionary *d=[@{@"progression":[self.progression copy],@"texture":@(self.performanceMode),@"pianoPattern":@(self.pianoPattern),
        @"chordLengthBlocks":@(self.chordLengthBlocks),@"chordLengthHands":@(self.chordLengthHands),@"chordLengthArp":@(self.chordLengthArp),@"chordLengthStrings":@(self.chordLengthStrings),
        @"fillRate":@(self.fillRate),@"arrangementSeed":@(self.arrangementSeed),@"generatedRhythm":@(self.generatedRhythm),@"arpeggioPattern":@(self.arpeggioPattern),@"division":@(self.division),
        @"trackEdited":@(self.trackEdited),@"trackUndo":[self.trackUndo copy]?:@[],@"trackRedo":[self.trackRedo copy]?:@[],@"selectedChip":@(self.selectedChip)} mutableCopy];
    if(self.trackEdited) d[@"trackData"]=[self trackData];
    if(self.sequenceUndo) d[@"sequenceUndo"]=self.sequenceUndo;
    return d;
}
- (void)replaceProgression:(NSArray<NSNumber *> *)codes {
    for(NSButton *button in self.progressionButtons) [button removeFromSuperview];
    [self.progressionButtons removeAllObjects]; [self.progression removeAllObjects];
    for(NSNumber *code in codes) if(kv_code_valid(code.intValue) && self.progression.count<8) [self appendDegree:code.intValue];
}
- (void)applyWorking:(NSDictionary *)d {
    self.performanceMode=MIN(6,MAX(0,[d[@"texture"] integerValue])); self.pianoPattern=(KvPianoPattern)MIN(KV_PATTERN_COUNT-1,MAX(0,[d[@"pianoPattern"] intValue]));
    self.chordLengthBlocks=(KvChordLength)[d[@"chordLengthBlocks"] intValue]; self.chordLengthHands=(KvChordLength)[d[@"chordLengthHands"] intValue];
    self.chordLengthArp=(KvChordLength)[d[@"chordLengthArp"] intValue]; self.chordLengthStrings=(KvChordLength)[d[@"chordLengthStrings"] intValue];
    self.fillRate=(KvFillRate)[d[@"fillRate"] intValue]; self.arrangementSeed=(uint32_t)[d[@"arrangementSeed"] unsignedIntValue]; self.generatedRhythm=[d[@"generatedRhythm"] boolValue];
    self.arpeggioPattern=(KvArpeggioPattern)[d[@"arpeggioPattern"] intValue]; self.division=(KvDivision)[d[@"division"] intValue];
    [self replaceProgression:d[@"progression"]];
    self.trackUndo=[d[@"trackUndo"] mutableCopy]?:[NSMutableArray array]; self.trackRedo=[d[@"trackRedo"] mutableCopy]?:[NSMutableArray array];
    self.sequenceUndo=d[@"sequenceUndo"]; self.selectedChip=MIN([d[@"selectedChip"] integerValue],(NSInteger)self.progression.count-1);
    NSData *track=d[@"trackData"]; BOOL restored=NO;
    if([d[@"trackEdited"] boolValue] && track.length==sizeof(KvPerformance)) {
        const KvPerformance *p=track.bytes;
        if(kv_performance_valid(p) && p->chord_count==self.progression.count && fabs(p->beats_per_chord-kv_chord_beats(self.meter,[self chordLength]))<1e-9) { *self.track=*p; restored=YES; }
    }
    self.trackEdited=restored; self.roll.edited=restored; if(restored) [self.roll reload]; else [self buildTrack];
    self.needsLayout=YES; [self refresh];
}
/* A section's track, when it still fits the section (a new meter or chord length leaves it behind). */
- (NSData *)trackOfSection:(NSInteger)index {
    if(index<0 || index>=(NSInteger)self.song->count) return nil;
    const KvSection *s=&self.song->sections[index]; NSData *data=self.sectionTracks[@(s->id)];
    if(!s->edited || data.length!=sizeof(KvPerformance)) return nil;
    const KvPerformance *p=data.bytes;
    return kv_performance_valid(p) && p->chord_count==s->count && fabs(p->beats_per_chord-kv_section_chord_beats([self liveSong],s))<1e-9?data:nil;
}
- (NSDictionary *)workingOfSection:(NSInteger)index {
    const KvSection *s=&self.song->sections[index]; KvArrangement a=[self playable:s->arrangement];
    NSInteger texture=a.strings?2+a.strings:a.arpeggio?2:a.blocks?0:1;
    NSMutableArray *codes=[NSMutableArray array]; for(size_t i=0;i<s->count;i++) [codes addObject:@(s->codes[i])];
    NSMutableDictionary *d=[(self.draftState?:[self captureWorking]) mutableCopy];   // the other textures keep the draft's lengths
    d[@"progression"]=codes; d[@"texture"]=@(texture); d[@"pianoPattern"]=@(a.style);
    d[texture>=3?@"chordLengthStrings":texture==1?@"chordLengthHands":texture==2?@"chordLengthArp":@"chordLengthBlocks"]=@(a.length);
    d[@"fillRate"]=@(a.fills); d[@"arrangementSeed"]=@(a.seed); d[@"generatedRhythm"]=@(a.generated); d[@"arpeggioPattern"]=@(a.arpeggio_pattern); d[@"division"]=@(a.division);
    NSData *track=[self trackOfSection:index]; d[@"trackEdited"]=@(track!=nil); if(track) d[@"trackData"]=track; else [d removeObjectForKey:@"trackData"];
    d[@"trackUndo"]=@[]; d[@"trackRedo"]=@[]; [d removeObjectForKey:@"sequenceUndo"]; d[@"selectedChip"]=@-1;
    return d;
}
/* The working state written back into the section being edited (an empty progression is not a section: it keeps its chords). */
- (void)storeWorking {
    if(self.editingSection<0 || self.editingSection>=(NSInteger)self.song->count || !self.progression.count) return;
    KvSection *s=&self.song->sections[self.editingSection]; double was=kv_section_pass_beats(self.song,s); [self detachIfChanged:s];
    s->count=self.progression.count; for(NSUInteger i=0;i<self.progression.count;i++) s->codes[i]=self.progression[i].intValue;
    KvArrangement a=[self arrangementForPreview:NO]; if(!a.strings && s->arrangement.strings && ![self stringsChosen] && self.performanceMode==1) a.strings=s->arrangement.strings;   // the piano shows two hands for a strings texture: keep it for the strings
    s->arrangement=a; s->edited=self.trackEdited; kv_section_keep_passes(self.song,s,was);
    if(self.trackEdited) self.sectionTracks[@(s->id)]=[self trackData]; else [self.sectionTracks removeObjectForKey:@(s->id)];
    kv_song_rederive(self.song); self.songPlans=nil;   // the sections grown from this one follow; parts are cheap to build again
    [self.arranger reload];
}
- (void)editSection:(NSInteger)index {
    if(!self.song->count) { [self editDraft]; return; }
    index=MAX(0,MIN((NSInteger)self.song->count-1,index));
    if(index==self.editingSection) { self.arranger.selected=index; [self.arranger reload]; return; }
    if(self.editingSection<0) self.draftState=[self captureWorking]; else [self storeWorking];
    if([self isPlayingProgression] && !self.songPlaying) [self stopPlayback:nil];
    BOOL was=self.restoring; self.restoring=YES; self.editingSection=index; [self applyWorking:[self workingOfSection:index]]; self.restoring=was;
    self.arranger.selected=index; [self.arranger reload];
}
/* After an edit of the song that changed the section being edited: load it again without storing the old working state. */
- (void)reloadEditing:(NSInteger)index {
    if(!self.song->count) { self.editingSection=-1; BOOL was=self.restoring; self.restoring=YES; if(self.draftState) [self applyWorking:self.draftState]; self.restoring=was; self.draftState=nil; self.arranger.selected=-1; [self.arranger reload]; return; }
    if(self.editingSection==-1) self.draftState=[self captureWorking];   // −2: the section was removed, the draft is kept already
    index=MAX(0,MIN((NSInteger)self.song->count-1,index));
    BOOL was=self.restoring; self.restoring=YES; self.editingSection=index; [self applyWorking:[self workingOfSection:index]]; self.restoring=was;
    self.arranger.selected=index; [self.arranger reload];
}
- (void)editDraft {
    if(self.editingSection<0) return;
    [self storeWorking]; if([self isPlayingProgression]) [self stopPlayback:nil];
    self.editingSection=-1; BOOL was=self.restoring; self.restoring=YES; if(self.draftState) [self applyWorking:self.draftState]; self.restoring=was; self.draftState=nil;
}
/* The song with the section being edited as the working state has it now (before saveState writes it back). */
- (KvSong *)songWithWorking {
    KvSong *s=[self liveSong]; NSInteger i=self.editingSection;
    if(i>=0 && i<(NSInteger)s->count && self.progression.count) {
        KvSection *x=&s->sections[i]; double was=kv_section_pass_beats(s,x); [self detachIfChanged:x];
        x->count=self.progression.count; for(NSUInteger k=0;k<self.progression.count;k++) x->codes[k]=self.progression[k].intValue;
        KvArrangement a=[self arrangementForPreview:NO]; if(!a.strings && x->arrangement.strings && ![self stringsChosen] && self.performanceMode==1) a.strings=x->arrangement.strings;
        x->arrangement=a; x->edited=self.trackEdited; kv_section_keep_passes(s,x,was);
        kv_song_rederive(s);   // the sections grown from this one follow its chords
    }
    return s;
}
/* A section that grows from another one becomes its own when its chords are changed by hand. */
- (void)detachIfChanged:(KvSection *)x {
    if(!x->source || x->derive==KV_DERIVE_NONE || x->derive==KV_DERIVE_TRANSITION) return;
    BOOL same=x->count==self.progression.count; for(NSUInteger k=0;same && k<self.progression.count;k++) if(x->codes[k]!=self.progression[k].intValue) same=NO;
    if(!same) { x->source=0; x->derive=KV_DERIVE_NONE; }
}
static BOOL SameTexture(KvArrangement a,KvArrangement b) {
    return a.style==b.style && a.length==b.length && a.fills==b.fills && a.seed==b.seed && a.generated==b.generated && a.blocks==b.blocks && a.arpeggio==b.arpeggio && a.arpeggio_pattern==b.arpeggio_pattern && a.division==b.division && a.strings==b.strings;
}
// ---- undo of the song: snapshots of the sections and the tracks ----
- (NSDictionary *)songSnapshot { [self storeWorking]; return @{@"song":[NSData dataWithBytes:self.song length:sizeof(KvSong)],@"tracks":[self.sectionTracks copy],@"editing":@(self.editingSection)}; }
/* After a row edit that moves the time: the automation's points go with their sections (the song before it is the last undo). */
- (void)followSections { NSData *was=self.songUndo.lastObject[@"song"]; if(was.length==sizeof(KvSong)) kv_song_follow(self.song,was.bytes); }
- (void)pushSongUndo { self.lastForm=nil; [self.songUndo addObject:[self songSnapshot]]; if(self.songUndo.count>60) [self.songUndo removeObjectAtIndex:0]; [self.songRedo removeAllObjects]; }
- (void)applySongSnapshot:(NSDictionary *)snapshot {
    if([self isPlayingProgression]) [self stopPlayback:nil];
    memcpy(self.song,[snapshot[@"song"] bytes],sizeof(KvSong)); self.sectionTracks=[snapshot[@"tracks"] mutableCopy]; self.songPlans=nil;
    [self reloadEditing:[snapshot[@"editing"] integerValue]]; [self saveState];
}
- (void)undoSong { if(!self.songUndo.count) return; [self.songRedo addObject:[self songSnapshot]]; NSDictionary *last=self.songUndo.lastObject; [self.songUndo removeLastObject]; [self applySongSnapshot:last]; self.status.stringValue=T(@"Правка песни отменена · ⇧⌘Z — повторить"); }
- (void)redoSong { if(!self.songRedo.count) return; [self.songUndo addObject:[self songSnapshot]]; NSDictionary *last=self.songRedo.lastObject; [self.songRedo removeLastObject]; [self applySongSnapshot:last]; self.status.stringValue=T(@"Правка песни повторена"); }
// ---- saved with the settings, and later in a .tonora file ----
- (NSDictionary *)songPlist {
    NSMutableArray *sections=[NSMutableArray array]; NSMutableDictionary *tracks=[NSMutableDictionary dictionary];
    for(size_t i=0;i<self.song->count;i++) {
        const KvSection *s=&self.song->sections[i]; const KvArrangement *a=&s->arrangement;
        NSMutableArray *codes=[NSMutableArray array]; for(size_t k=0;k<s->count;k++) [codes addObject:@(s->codes[k])];
        [sections addObject:@{@"id":@(s->id),@"kind":@(s->kind),@"name":[NSString stringWithUTF8String:s->name]?:@"",@"codes":codes,@"repeats":@(s->repeats),
            @"style":@(a->style),@"length":@(a->length),@"fills":@(a->fills),@"seed":@(a->seed),@"generated":@(a->generated),@"blocks":@(a->blocks),@"arpeggio":@(a->arpeggio),
            @"arpeggioPattern":@(a->arpeggio_pattern),@"division":@(a->division),@"strings":@(a->strings),@"level":@(s->level),@"beat":@(s->beat),@"beatFixed":@(s->beat_fixed),
            @"lift":@(s->lift),@"transition":@(s->transition),@"edited":@(s->edited),@"beats":@(s->length),@"start":@(s->start),
            @"source":@(s->source),@"derive":@(s->derive),@"vary":@(s->vary),@"map":@[@(s->map[0]),@(s->map[1]),@(s->map[2]),@(s->map[3]),@(s->map[4]),@(s->map[5]),@(s->map[6]),@(s->map[7])],
            @"regions":@[RegionPlist(&s->regions[0]),RegionPlist(&s->regions[1]),RegionPlist(&s->regions[2])]}];
        NSData *track=self.sectionTracks[@(s->id)]; if(s->edited && track) tracks[[NSString stringWithFormat:@"%u",s->id]]=track;
    }
    NSMutableArray *lanes=[NSMutableArray array];
    for(int t=0;t<KV_TRACKS;t++) [lanes addObject:@{@"level":@(self.song->track_level[t]),@"mute":@(self.song->track_mute[t]),@"solo":@(self.song->track_solo[t])}];
    return @{@"version":@2,@"nextId":@(self.song->next_id),@"sections":sections,@"tracks":tracks,@"selected":@(self.arranger.selected),@"lanes":lanes,
             @"cycleFrom":@(self.song->cycle_from),@"cycleTo":@(self.song->cycle_to),@"tempoCurve":CurvePlist(&self.song->tempo),
             @"volumeCurves":@[CurvePlist(&self.song->volume[0]),CurvePlist(&self.song->volume[1]),CurvePlist(&self.song->volume[2])]};
}
static NSDictionary *RegionPlist(const KvRegion *r) { return @{@"mute":@(r->mute),@"level":@(r->level),@"shift":@(r->shift)}; }
/* A curve as [[beat, value], …], and back (whatever does not fit is left out; the song's check refuses values out of range). */
static NSArray *CurvePlist(const KvCurve *c) { NSMutableArray *list=[NSMutableArray array]; for(size_t i=0;i<c->count;i++) [list addObject:@[@(c->points[i].beat),@(c->points[i].value)]]; return list; }
static void CurveFrom(id list,KvCurve *c) {
    memset(c,0,sizeof(*c)); if(![list isKindOfClass:NSArray.class]) return;
    for(id point in list) if([point isKindOfClass:NSArray.class] && [point count]==2 && [point[0] isKindOfClass:NSNumber.class] && [point[1] isKindOfClass:NSNumber.class]) kv_curve_set(c,[point[0] doubleValue],[point[1] floatValue]);
}
static double Real(NSDictionary *d,NSString *key,double fallback) { id v=d[key]; return [v isKindOfClass:NSNumber.class]?[v doubleValue]:fallback; }
static NSInteger Number(NSDictionary *d,NSString *key) { id v=d[key]; return [v isKindOfClass:NSNumber.class]?[v integerValue]:0; }
/* Reads a saved song; anything malformed leaves the song as it was and returns NO. */
- (BOOL)loadSongPlist:(NSDictionary *)plist {
    // Version 1 (Tonora 1.4) has no regions, lanes, lengths or cycle: everything at full level, whole passes.
    if(![plist isKindOfClass:NSDictionary.class] || (Number(plist,@"version")!=1 && Number(plist,@"version")!=2) || ![plist[@"sections"] isKindOfClass:NSArray.class]) return NO;
    KvSong *song=calloc(1,sizeof(KvSong)); if(!song) return NO;
    *song=*[self liveSong]; kv_song_reset(song); song->next_id=(uint32_t)Number(plist,@"nextId");
    NSArray *lanes=[plist[@"lanes"] isKindOfClass:NSArray.class]?plist[@"lanes"]:@[];
    for(int t=0;t<KV_TRACKS && t<(int)lanes.count;t++) if([lanes[t] isKindOfClass:NSDictionary.class]) {
        song->track_level[t]=(float)Real(lanes[t],@"level",1); song->track_mute[t]=Number(lanes[t],@"mute")!=0; song->track_solo[t]=Number(lanes[t],@"solo")!=0; }
    song->cycle_from=Real(plist,@"cycleFrom",0); song->cycle_to=Real(plist,@"cycleTo",0);
    CurveFrom(plist[@"tempoCurve"],&song->tempo); NSArray *volumes=[plist[@"volumeCurves"] isKindOfClass:NSArray.class]?plist[@"volumeCurves"]:@[];
    for(int t=0;t<KV_TRACKS;t++) CurveFrom(t<(int)volumes.count?volumes[t]:nil,&song->volume[t]);
    NSMutableDictionary<NSNumber *,NSData *> *tracks=[NSMutableDictionary dictionary]; NSDictionary *saved=[plist[@"tracks"] isKindOfClass:NSDictionary.class]?plist[@"tracks"]:@{};
    for(NSDictionary *d in plist[@"sections"]) {
        if(![d isKindOfClass:NSDictionary.class] || song->count>=KV_SONG_SECTIONS || ![d[@"codes"] isKindOfClass:NSArray.class]) { free(song); return NO; }
        KvSection s; memset(&s,0,sizeof(s)); s.id=(uint32_t)Number(d,@"id"); s.kind=(KvSectionKind)Number(d,@"kind");
        NSString *name=[d[@"name"] isKindOfClass:NSString.class]?d[@"name"]:@""; [name getCString:s.name maxLength:sizeof(s.name) encoding:NSUTF8StringEncoding];
        for(id code in d[@"codes"]) if([code isKindOfClass:NSNumber.class] && s.count<8) s.codes[s.count++]=[code intValue];
        s.repeats=(int)Number(d,@"repeats");
        s.arrangement=(KvArrangement){.style=(KvPianoPattern)Number(d,@"style"),.length=(KvChordLength)Number(d,@"length"),.fills=(KvFillRate)Number(d,@"fills"),.seed=(uint32_t)Number(d,@"seed"),
            .generated=Number(d,@"generated")!=0,.blocks=Number(d,@"blocks")!=0,.arpeggio=Number(d,@"arpeggio")!=0,.arpeggio_pattern=(KvArpeggioPattern)Number(d,@"arpeggioPattern"),
            .division=(KvDivision)Number(d,@"division"),.strings=(KvStringTexture)Number(d,@"strings")};
        s.level=[d[@"level"] isKindOfClass:NSNumber.class]?[d[@"level"] floatValue]:1; s.beat=(KvSectionBeat)Number(d,@"beat"); s.beat_fixed=(KvBeat)Number(d,@"beatFixed");
        s.source=(uint32_t)Number(d,@"source"); s.derive=(KvDerive)Number(d,@"derive"); s.vary=(uint32_t)Number(d,@"vary");
        { NSArray *map=[d[@"map"] isKindOfClass:NSArray.class]?d[@"map"]:@[]; for(int k=0;k<8;k++) s.map[k]=k<(int)map.count && [map[k] isKindOfClass:NSNumber.class]?MAX(0,MIN(7,[map[k] intValue])):0; }
        if(s.derive<0 || s.derive>=KV_DERIVE_KINDS) { s.derive=KV_DERIVE_NONE; s.source=0; }
        s.lift=(int)Number(d,@"lift"); s.transition=(KvTransitionKind)Number(d,@"transition"); s.edited=Number(d,@"edited")!=0;
        s.length=Real(d,@"beats",0); s.start=Real(d,@"start",0); if(!(s.length==0 || (s.length>=.125 && s.length<=512))) s.length=0; if(!(s.start>=0 && s.start<64)) s.start=0; NSArray *regions=[d[@"regions"] isKindOfClass:NSArray.class]?d[@"regions"]:@[];   // a section damaged by builds 31–35 (a transition's length could run away) plays whole again
        for(int t=0;t<KV_TRACKS;t++) { NSDictionary *r=t<(int)regions.count && [regions[t] isKindOfClass:NSDictionary.class]?regions[t]:@{};
            s.regions[t]=(KvRegion){.mute=Number(r,@"mute")!=0,.level=(float)Real(r,@"level",1),.shift=Real(r,@"shift",0)}; }
        NSData *track=saved[[NSString stringWithFormat:@"%u",s.id]];
        if(s.edited && [track isKindOfClass:NSData.class] && track.length==sizeof(KvPerformance)) tracks[@(s.id)]=track; else s.edited=NO;
        if(!kv_section_valid(&s) || s.id>song->next_id) { free(song); return NO; }
        song->sections[song->count++]=s;
    }
    if(!kv_song_valid(song)) { free(song); return NO; }
    memcpy(self.song,song,sizeof(KvSong)); free(song);
    self.sectionTracks=tracks; self.songPlans=nil; self.arranger.selected=self.song->count?MIN(MAX(0,Number(plist,@"selected")),(NSInteger)self.song->count-1):-1;
    [self.arranger reload]; return YES;
}
- (void)saveSong { if(!self.restoring) [Defaults() setObject:[self songPlist] forKey:@"song"]; }
- (void)restoreSong { NSDictionary *saved=[Defaults() dictionaryForKey:@"song"]; if(saved && ![self loadSongPlist:saved]) self.status.stringValue=T(@"⚠ Сохранённая песня повреждена и не открыта"); }
/* A new key carries the sections the user edited by hand: their notes move by the same interval (the working one follows the draft's rule). */
- (void)setKey:(KvKey)key {
    int shift=kv_mod(kv_tonic(key)-kv_tonic(_key),12); if(shift>6) shift-=12;
    _key=key;
    for(size_t i=0;shift && self.song && i<self.song->count;i++) {
        const KvSection *s=&self.song->sections[i]; NSData *data=self.sectionTracks[@(s->id)];
        if((NSInteger)i==self.editingSection || !s->edited || data.length!=sizeof(KvPerformance)) continue;
        KvPerformance p; memcpy(&p,data.bytes,sizeof(p)); kv_track_transpose(&p,shift); self.sectionTracks[@(s->id)]=[NSData dataWithBytes:&p length:sizeof(p)];
    }
    self.songPlans=nil;
}
// ---- KvArrangerOwner ----
- (const KvSong *)arrangerSong { return [self songWithWorking]; }
- (NSString *)arrangerName:(NSInteger)index {
    if(index<0 || index>=(NSInteger)self.song->count) return @"";
    const KvSection *s=&self.song->sections[index];
    if(s->name[0]) return [NSString stringWithUTF8String:s->name]?:@"";
    if(s->kind==KV_SECTION_TRANSITION) return S(kv_transition_name(s->transition));
    NSInteger number=0,total=0; for(size_t i=0;i<self.song->count;i++) if(self.song->sections[i].kind==s->kind) { total++; if((NSInteger)i<=index) number=total; }
    NSString *kind=S(kv_section_kind_name(s->kind)); return total>1?[NSString stringWithFormat:@"%@ %ld",kind,(long)number]:kind;
}
- (NSString *)arrangerChords:(NSInteger)index {
    const KvSong *song=[self songWithWorking]; if(index<0 || index>=(NSInteger)song->count) return @"";
    const KvSection *s=&song->sections[index]; NSMutableArray *names=[NSMutableArray array];
    double pass=kv_section_pass_beats(song,s),length=kv_section_beats(song,(size_t)index),chord_beats=kv_section_chord_beats(song,s),begin=fmod(s->start,pass);
    for(size_t i=0;i<s->count;i++) { KvChord chord; if(!kv_code_chord(song->key,s->codes[i],song->extension,&chord)) continue;
        BOOL sounds=length>=pass-1e-9; for(double at=i*chord_beats;!sounds && at<begin+length;at+=pass) sounds=at+chord_beats>begin+1e-9 && at<begin+length-1e-9;
        if(sounds) [names addObject:S(chord.name)]; }
    return [names componentsJoinedByString:@" "];
}
/* A section's texture as it plays on the instrument chosen: a strings texture on the piano plays as two hands, but stays in the song
   (the strings get it back) — the model keeps what the user chose, the sound fits the instrument. */
- (KvArrangement)playable:(KvArrangement)a { if(a.strings && ![self stringsChosen]) a.strings=KV_STRINGS_NONE; return a; }
- (NSString *)textureOf:(const KvArrangement *)a {
    if(a->strings) return [T(@"струнные · ") stringByAppendingString:[S(kv_string_texture_name(a->strings)) lowercaseString]];
    if(a->arpeggio) return [NSString stringWithFormat:T(@"арпеджио %@"),[S(kv_arpeggio_name(a->arpeggio_pattern)) lowercaseString]];
    return a->blocks?T(@"аккорды"):[S(kv_pattern_russian(a->style)) lowercaseString];
}
- (NSString *)arrangerDetails:(NSInteger)index {
    const KvSong *song=[self songWithWorking]; if(index<0 || index>=(NSInteger)song->count) return @"";
    const KvSection *s=&song->sections[index]; NSMutableArray *parts=[NSMutableArray arrayWithObject:TNBarCount(kv_section_beats(song,(size_t)index)/kv_meter_bar(song->meter))];
    if(s->repeats>1 && s->length==0) [parts addObject:[NSString stringWithFormat:@"×%d",s->repeats]];
    [parts addObject:[self textureOf:&s->arrangement]];
    if(fabsf(s->level-1)>.01f) [parts addObject:[NSString stringWithFormat:@"%d %%",(int)lroundf(s->level*100)]];
    if(s->beat==KV_SECTION_BEAT_OFF) [parts addObject:T(@"без бита")]; else if(s->beat==KV_SECTION_BEAT_QUIET) [parts addObject:T(@"бит тихо")];
    else if(s->beat==KV_SECTION_BEAT_STYLE) [parts addObject:T(@"бит по стилю")]; else if(s->beat==KV_SECTION_BEAT_FIXED) [parts addObject:[NSString stringWithFormat:T(@"бит «%@»"),[S(kv_beat_name(s->beat_fixed)) lowercaseString]]];
    return [parts componentsJoinedByString:@" · "];
}
- (BOOL)arrangerEdited:(NSInteger)index { return index==self.editingSection?self.trackEdited:[self trackOfSection:index]!=nil; }
- (double)arrangerPlayheadBeat {
    const KvSong *song=self.song; double total=kv_song_beats(song); if(total<=0 || !kv_audio_is_playing(self.audio)) return -1;
    if(self.songPlaying && self.songPart>=0 && self.songPart<(NSInteger)self.songOrderBeats.count) {
        double seconds=0; NSInteger part=(NSInteger)kv_audio_part(self.audio,&seconds);
        if(part==self.tempoPart && part<(NSInteger)self.songOrderBeats.count)   // counted at the tempo each moment had
            return fmod(self.songOrderBeats[part].doubleValue+self.tempoBeats+MAX(0,seconds-self.tempoSeconds)*self.appliedBpm*self.speed/60,total);
        return fmod(self.songOrderBeats[self.songPart].doubleValue+seconds*self.tempo*self.speed/60,total);
    }
    if(self.editingSection>=0 && [self isPlayingProgression]) { double beat=[self playheadBeat]; if(beat>=0) return kv_section_start(song,(size_t)self.editingSection)+beat; }
    return -1;
}
- (void)arrangerSelect:(NSInteger)index { [self editSection:index]; [self saveState]; }
/* «Открыть в ролле», a double click, Enter: the roll comes up under the tracks with the section, zoomed to the stretch that sounds;
   from a melody or bass region, on that hand alone. */
- (void)arrangerOpenInRoll:(NSInteger)index { [self arrangerOpenInRoll:index track:-1]; }
- (BOOL)pianoRollDocked:(KvPianoRoll *)roll { (void)roll; return self.viewMode==2 && self.rollDocked; }
- (void)arrangerOpenInRoll:(NSInteger)index track:(int)track {
    self.roll.onlyHand=track==KV_TRACK_MELODY?1:track==KV_TRACK_BASS?0:-1;
    if(self.viewMode!=2) { [self editSection:index]; [self showView:1]; return; }
    [self editSection:index]; self.rollDocked=YES; [self buildTrack]; [self.roll reload]; self.needsLayout=YES; [self layoutSubtreeIfNeeded]; [self.roll layoutSubtreeIfNeeded];
    const KvSong *song=[self songWithWorking]; const KvSection *s=&song->sections[self.editingSection]; double length=kv_section_beats(song,(size_t)self.editingSection);
    [self.roll resetView]; double visible=[self.roll visibleBeats];
    if(length>0 && visible>0) { [self.roll zoomBy:visible/length aroundX:NSMinX([self.roll noteAreaRect])]; self.roll.scrollBeat=s->start; self.roll.needsDisplay=YES; }
    [self.window makeFirstResponder:self.roll];
    self.status.stringValue=[NSString stringWithFormat:T(@"Пиано-ролл · секция «%@» · ⇧⌘A — обратно в аранжировщик"),[self arrangerName:self.editingSection]];
}
/* The roll's playhead: the plan's beat, or, in the song, where the sounding part lies in the open section's pass (−1 elsewhere). */
- (double)rollPlayheadBeat {
    if(!self.songPlaying) return [self isPlayingProgression]?[self playheadBeat]:-1;
    NSInteger i=self.editingSection; if(i<0 || self.songPart<0 || self.songPart>=(NSInteger)self.songOrder.count || self.songOrder[self.songPart].integerValue!=i) return -1;
    double beat=[self arrangerPlayheadBeat]; if(beat<0) return -1; const KvSong *song=self.song; double pass=kv_section_pass_beats(song,&song->sections[i]);
    return pass>0?fmod(fmax(0,song->sections[i].start+beat-kv_section_start(song,(size_t)i)),pass):-1;
}
- (void)arrangerForwardKey:(NSEvent *)event { [self keyDown:event]; }
- (NSInteger)indexOfSection:(uint32_t)identifier { for(size_t i=0;i<self.song->count;i++) if(self.song->sections[i].id==identifier) return (NSInteger)i; return -1; }
- (void)arrangerMove:(NSInteger)from to:(NSInteger)to copy:(BOOL)copy {
    NSInteger count=(NSInteger)self.song->count; if(from<0 || from>=count) return;
    [self pushSongUndo]; uint32_t keep=self.song->sections[from].id;
    if(copy) {
        uint32_t made=kv_song_duplicate(self.song,(size_t)from); if(!made) { [self.songUndo removeLastObject]; self.status.stringValue=T(@"В песне уже 32 секции"); return; }
        NSData *track=self.sectionTracks[@(keep)]; if(track) self.sectionTracks[@(made)]=track;
        // `to` is an insertion point among the original sections; the copy (now at from+1) ends at index `to` either way.
        kv_song_move(self.song,(size_t)from+1,(size_t)MIN((NSInteger)self.song->count-1,MAX(0,to)));
        keep=made;
    } else kv_song_move(self.song,(size_t)from,(size_t)MAX(0,MIN(count-1,to)));
    [self followSections]; self.songPlans=nil; [self reloadEditing:[self indexOfSection:keep]]; [self saveState];
    self.status.stringValue=copy?T(@"Секция скопирована · ⌘Z — отменить"):T(@"Секция переставлена · ⌘Z — отменить");
}
/* Sections [range] to the seam `to` (0…count), or copies of them there (with their edited notes). */
- (void)arrangerMoveRange:(NSRange)range to:(NSInteger)to copy:(BOOL)copy {
    KvSong *song=self.song; NSInteger count=(NSInteger)song->count,first=(NSInteger)range.location,length=(NSInteger)range.length;
    if(length<1 || first<0 || first+length>count || to<0 || to>count) return;
    if(!copy && to>=first && to<=first+length) return;   // onto itself
    if(copy && count+length>KV_SONG_SECTIONS) { self.status.stringValue=T(@"В песне уже 32 секции"); return; }
    [self pushSongUndo]; uint32_t lead=song->sections[first].id;
    if(copy) {
        KvSection copies[KV_SONG_SECTIONS]; for(NSInteger k=0;k<length;k++) { copies[k]=song->sections[first+k]; copies[k].name[0]=0; }
        for(NSInteger k=0;k<length;k++) {
            uint32_t made=kv_song_insert(song,(size_t)(to+k),&copies[k]); if(!made) break;
            NSData *track=self.sectionTracks[@(copies[k].id)]; if(track) self.sectionTracks[@(made)]=track;
            if(!k) lead=made;
        }
    } else if(to>first) { for(NSInteger k=0;k<length;k++) kv_song_move(song,(size_t)first,(size_t)(to-1)); }
    else { for(NSInteger k=0;k<length;k++) kv_song_move(song,(size_t)(first+k),(size_t)(to+k)); }
    [self followSections]; self.songPlans=nil; [self reloadEditing:[self indexOfSection:lead]]; [self saveState];
    self.status.stringValue=copy?(length>1?T(@"Секции скопированы · ⌘Z — отменить"):T(@"Секция скопирована · ⌘Z — отменить")):(length>1?T(@"Секции переставлены · ⌘Z — отменить"):T(@"Секция переставлена · ⌘Z — отменить"));
}
- (void)arrangerRemoveRange:(NSRange)range {
    NSInteger count=(NSInteger)self.song->count,first=(NSInteger)range.location,length=(NSInteger)range.length;
    if(length<1 || first<0 || first+length>count) return;
    if(length==1) { [self arrangerRemove:first]; return; }
    [self pushSongUndo]; if([self isPlayingProgression]) [self stopPlayback:nil];
    for(NSInteger k=first+length-1;k>=first;k--) { [self.sectionTracks removeObjectForKey:@(self.song->sections[k].id)]; kv_song_remove(self.song,(size_t)k); }
    [self followSections];
    self.songPlans=nil; if(self.editingSection>=0) self.editingSection=-2;   // the song holds the working state already (pushSongUndo stored it)
    [self reloadEditing:MIN(first,(NSInteger)self.song->count-1)]; [self saveState];
    self.status.stringValue=[NSString stringWithFormat:T(@"Удалено секций: %ld · ⌘Z — вернуть"),(long)length];
}
/* A section dropped on another: they trade places. */
- (void)arrangerSwap:(NSInteger)a with:(NSInteger)b {
    NSInteger count=(NSInteger)self.song->count; if(a<0 || b<0 || a>=count || b>=count || a==b) return;
    [self pushSongUndo]; uint32_t moved=self.song->sections[a].id; NSInteger low=MIN(a,b),high=MAX(a,b);
    kv_song_move(self.song,(size_t)high,(size_t)low); kv_song_move(self.song,(size_t)low+1,(size_t)high);
    [self followSections]; self.songPlans=nil; [self reloadEditing:[self indexOfSection:moved]]; [self saveState];
    self.status.stringValue=T(@"Секции поменялись местами · ⌘Z — отменить");
}
- (void)arrangerSetLength:(NSInteger)index beats:(double)beats {
    if(index<0 || index>=(NSInteger)self.song->count) return;
    [self pushSongUndo];
    if(!kv_song_set_length([self liveSong],(size_t)index,beats)) { [self.songUndo removeLastObject]; self.status.stringValue=T(@"Такая длина не подходит"); return; }
    [self followSections];
    self.songPlans=nil; [self.arranger reload]; [self saveState];
    self.status.stringValue=[NSString stringWithFormat:T(@"Длина «%@»: %@ · ⌘Z — отменить"),[self arrangerName:index],TNBarCount(kv_section_beats(self.song,(size_t)index)/kv_meter_bar(self.song->meter))];
}
- (void)arrangerTrimStart:(NSInteger)index beats:(double)beats {
    if(index<0 || index>=(NSInteger)self.song->count) return;
    [self pushSongUndo];
    if(!kv_song_trim_start([self liveSong],(size_t)index,beats)) { [self.songUndo removeLastObject]; self.status.stringValue=T(@"Так не обрезать: секция стала бы слишком короткой"); return; }
    [self followSections];
    self.songPlans=nil; [self.arranger reload]; [self saveState];
    self.status.stringValue=[NSString stringWithFormat:beats>0?T(@"«%@» начинается позже в прогрессии · ⌘Z — отменить"):T(@"«%@» начинается раньше в прогрессии · ⌘Z — отменить"),[self arrangerName:index]];
}
/* Automation (spec 1.5 §6а): the tempo curve (−1) or a track's volume curve, as the lane leaves it; refused when out of range. */
- (void)arrangerSetCurve:(int)curve to:(const KvCurve *)points {
    if(curve<-1 || curve>=KV_TRACKS || !points) return;
    KvCurve *target=curve<0?&self.song->tempo:&self.song->volume[curve],was=*target; *target=*points; BOOL ok=kv_song_valid(self.song); *target=was;
    if(!ok) { self.status.stringValue=T(@"⚠ Такую кривую не взять"); [self.arranger reload]; return; }
    [self pushSongUndo]; *target=*points; self.songPlans=nil; [self.arranger reload]; [self saveState];
    NSArray *names=@[T(@"Мелодия"),T(@"Бас"),T(@"Ударные")];
    self.status.stringValue=curve<0?[NSString stringWithFormat:T(@"Темп: точек %lu · ⌘Z — отменить"),(unsigned long)points->count]
        :[NSString stringWithFormat:T(@"Громкость «%@»: точек %lu · ⌘Z — отменить"),names[curve],(unsigned long)points->count];
}
/* A region dragged on its track (spec 1.5 §3, answer 2): its notes (or its beat) move in time inside the section. */
- (void)arrangerShiftRegion:(NSInteger)index track:(int)track shift:(double)shift {
    if(index<0 || index>=(NSInteger)self.song->count || track<0 || track>=KV_TRACKS || !isfinite(shift)) return;
    [self pushSongUndo]; self.song->sections[index].regions[track].shift=MAX(-32,MIN(32,shift));
    self.songPlans=nil; [self.arranger reload]; [self saveState];
    NSArray *names=@[T(@"Мелодия"),T(@"Бас"),T(@"Ударные")];
    self.status.stringValue=[NSString stringWithFormat:T(@"«%@» в «%@» сдвинута: %+g дол. · ⌘Z — отменить"),names[track],[self arrangerName:index],self.song->sections[index].regions[track].shift];
}
- (void)arrangerCut:(NSInteger)index atBeat:(double)beat {
    if(index<0 || index>=(NSInteger)self.song->count) return;
    [self pushSongUndo]; KvSong *song=[self liveSong]; NSData *track=self.sectionTracks[@(song->sections[index].id)];
    uint32_t made=kv_song_cut(song,(size_t)index,beat);
    if(!made) { [self.songUndo removeLastObject]; self.status.stringValue=T(@"Здесь не разрезать: слишком близко к краю секции"); return; }
    if(track) self.sectionTracks[@(made)]=track;   // both parts keep the edited pass
    self.songPlans=nil; [self reloadEditing:index+1]; [self saveState];
    self.status.stringValue=T(@"Секция разрезана · ⌘Z — отменить");
}
- (void)arrangerRemove:(NSInteger)index {
    if(index<0 || index>=(NSInteger)self.song->count) return;
    [self pushSongUndo]; [self.sectionTracks removeObjectForKey:@(self.song->sections[index].id)];
    if([self isPlayingProgression]) [self stopPlayback:nil];
    kv_song_remove(self.song,(size_t)index); [self followSections]; self.songPlans=nil;
    if(self.editingSection>=0) self.editingSection=-2;   // the song holds the working state already (pushSongUndo stored it)
    [self reloadEditing:MIN(index,(NSInteger)self.song->count-1)]; [self saveState];
    self.status.stringValue=T(@"Секция удалена · ⌘Z — вернуть");
}
- (void)arrangerSet:(KvSectionField)field value:(NSInteger)value {
    NSInteger i=self.editingSection; if(i<0 || i>=(NSInteger)self.song->count) return;
    [self pushSongUndo]; KvSection *s=&self.song->sections[i];
    switch(field) {
        case KvSectionFieldKind: if(value>=0 && value<KV_SECTION_KINDS) s->kind=(KvSectionKind)value; break;
        case KvSectionFieldRepeats: kv_song_set_repeats(self.song,(size_t)i,(int)value); [self followSections]; break;
        case KvSectionFieldLevel: s->level=(float)MAX(50,MIN(120,value))/100; break;
        case KvSectionFieldBeat: if(value<4) s->beat=(KvSectionBeat)value; else { s->beat=KV_SECTION_BEAT_FIXED; s->beat_fixed=(KvBeat)MIN(KV_BEAT_COUNT-1,value-4); } break;
        case KvSectionFieldLift: s->lift=value>0?12:value<0?-12:0; break;
        case KvSectionFieldTransition: if(value>=0 && value<KV_TRANSITION_KINDS) s->transition=(KvTransitionKind)value; break;
    }
    self.songPlans=nil;
    if(field==KvSectionFieldLift || field==KvSectionFieldTransition) { if(self.trackEdited) { [self pushTrackUndo]; self.trackEdited=NO; } [self buildTrack]; }
    [self.arranger reload]; [self saveState];
}
- (void)arrangerPlayFrom:(double)beat { [self playSongFromBeat:beat]; }
- (BOOL)arrangerCycles { return self.loopEnabled; }
- (void)arrangerToggleLoop { [self toggleLoop:nil]; self.arranger.needsDisplay=YES; }
- (void)arrangerSetCycleFrom:(double)from to:(double)to {
    KvSong *song=self.song; BOOL none=!(to>from+1e-6); song->cycle_from=none?0:MAX(0,from); song->cycle_to=none?0:to;
    if(!none && !self.loopEnabled) [self toggleLoop:nil];   // a cycle drawn is a cycle that plays, as in Logic
    if(none) self.status.stringValue=T(@"Цикл снят");
    else self.status.stringValue=[NSString stringWithFormat:T(@"Цикл: такты %d–%d · ↻ или L — играть его по кругу · двойной щелчок по циклу — снять"),(int)floor(song->cycle_from/kv_meter_bar(song->meter)+1e-9)+1,MAX(1,(int)ceil(song->cycle_to/kv_meter_bar(song->meter)-1e-9))];
    self.arranger.needsDisplay=YES; [self saveState];
}
/* Pencil: the circle's progression (the draft) becomes a section at index. */
- (void)arrangerDrawAt:(NSInteger)index {
    if(self.song->count>=KV_SONG_SECTIONS) { self.status.stringValue=T(@"В песне уже 32 секции"); return; }
    NSDictionary *draft=self.editingSection>=0?self.draftState:[self captureWorking]; NSArray *codes=draft[@"progression"];
    if(!codes.count) { self.status.stringValue=T(@"Сначала соберите последовательность на круге"); return; }
    [self pushSongUndo]; NSInteger editing=self.editingSection; [self editDraft];   // the working state is the draft now
    uint32_t made=[self insertWorkingAt:(size_t)MAX(0,MIN((NSInteger)self.song->count,index))];
    if(!made) { [self.songUndo removeLastObject]; [self reloadEditing:editing]; self.status.stringValue=T(@"⚠ Последовательность не стала секцией"); return; }
    [self reloadEditing:index]; [self saveState];
    self.status.stringValue=[NSString stringWithFormat:T(@"«%@» нарисована карандашом · ⌘Z — отменить"),[self arrangerName:index]];
}
/* The working state (the circle's progression, its texture and edited notes) as a new verse at `at`; its id, 0 when it fails. */
- (uint32_t)insertWorkingAt:(size_t)at {
    KvSong *song=[self liveSong]; KvArrangement texture=[self arrangementForPreview:NO];
    int codes[8]; for(NSUInteger i=0;i<self.progression.count;i++) codes[i]=self.progression[i].intValue;
    KvSection section=kv_section_from_draft(KV_SECTION_VERSE,codes,self.progression.count,texture); section.edited=self.trackEdited;
    section.beat=KV_SECTION_BEAT_SONG;   // drums as the metronome plays them
    uint32_t made=kv_song_insert(song,at,&section);
    if(made && self.trackEdited) self.sectionTracks[@(made)]=[self trackData];
    if(made) [self followSections];
    self.songPlans=nil; return made;
}
// ---- song forms (spec 1.5 §6) ----
static NSString *FormLetters(NSArray<NSNumber *> *slots) {
    NSMutableArray *letters=[NSMutableArray array];
    for(NSNumber *slot in slots) { int x=slot.intValue; NSString *letter=nil;
        switch(x) { case KV_SECTION_INTRO: letter=T(@"И"); break; case KV_SECTION_VERSE: letter=T(@"К"); break; case KV_SECTION_CHORUS: letter=T(@"Пр"); break;
            case KV_SECTION_PIT: letter=T(@"Я"); break; case KV_SECTION_BRIDGE: letter=T(@"Б"); break; case KV_SECTION_OUTRO: letter=T(@"Кц"); break;
            case KV_FORM_BUILD: letter=T(@"Билд"); break; case KV_FORM_DROP: letter=T(@"Дроп"); break; default: break; }   // transitions: the form puts them itself
        if(letter) [letters addObject:letter]; }
    return [letters componentsJoinedByString:@"–"];
}
- (NSArray<NSDictionary *> *)arrangerForms {
    NSMutableArray *list=[NSMutableArray array]; const KvForm *forms; size_t n=kv_song_forms(&forms);
    for(size_t i=0;i<n;i++) { NSMutableArray *slots=[NSMutableArray array]; for(size_t k=0;k<forms[i].count;k++) [slots addObject:@(forms[i].slots[k])];
        [list addObject:@{@"name":S(kv_form_name(i)),@"letters":FormLetters(slots),@"slots":slots,@"user":@NO}]; }
    for(NSDictionary *form in [Defaults() arrayForKey:@"userForms"]) {   // the user's, from the settings: kept only when whole
        if(![form isKindOfClass:NSDictionary.class] || ![form[@"name"] isKindOfClass:NSString.class] || ![form[@"slots"] isKindOfClass:NSArray.class]) continue;
        NSArray *slots=form[@"slots"]; BOOL ok=slots.count>0 && slots.count<=KV_FORM_SLOTS;
        for(id slot in slots) if(![slot isKindOfClass:NSNumber.class] || !kv_form_slot_valid([slot intValue])) ok=NO;
        if(ok) [list addObject:@{@"name":form[@"name"],@"letters":FormLetters(slots),@"slots":slots,@"user":@YES}];
    }
    return list;
}
/* The song in a form around its verse: the selected section when it is a verse, else the song's first verse (or the selected one).
   Again (⌘R): the generated sections go first, so the chorus, bridge and the rest come anew from another seed. */
- (void)applyForm:(NSDictionary *)form again:(BOOL)again {
    NSArray<NSNumber *> *list=form[@"slots"]; if(!self.song->count || !list.count) return;
    int slots[KV_FORM_SLOTS]; size_t count=MIN(list.count,(NSUInteger)KV_FORM_SLOTS); for(size_t k=0;k<count;k++) slots[k]=list[k].intValue;
    [self pushSongUndo]; KvSong *song=[self liveSong]; NSInteger editing=self.editingSection; size_t verse=0; BOOL found=NO;
    if(editing>=0 && editing<(NSInteger)song->count && song->sections[editing].kind==KV_SECTION_VERSE) { verse=(size_t)editing; found=YES; }
    for(size_t i=0;!found && i<song->count;i++) if(song->sections[i].kind==KV_SECTION_VERSE) { verse=i; found=YES; }
    if(!found) verse=(size_t)MAX(0,MIN((NSInteger)song->count-1,editing));
    KvSong *work=malloc(sizeof(KvSong)); if(!work) { [self.songUndo removeLastObject]; return; }
    *work=*song; uint32_t verseId=song->sections[verse].id;
    if(again) { work->count=0; for(size_t i=0;i<song->count;i++) if(song->sections[i].id==verseId || song->sections[i].edited) work->sections[work->count++]=song->sections[i]; }
    size_t at=0; for(size_t i=0;i<work->count;i++) if(work->sections[i].id==verseId) at=i;
    uint32_t copy_of[KV_SONG_SECTIONS]; self.formSeed=arc4random();   // a fresh variant each time, never the same sequence from launch to launch
    if(!kv_song_apply_form(work,slots,count,at,self.formSeed,copy_of)) { free(work); [self.songUndo removeLastObject]; self.status.stringValue=T(@"⚠ Форма не собралась"); return; }
    *song=*work; free(work); song->cycle_from=song->cycle_to=0;   // the cycle was drawn on the old row
    NSMutableDictionary *tracks=[NSMutableDictionary dictionary];   // edited notes: the kept sections keep theirs, the repeats take their source's
    for(size_t i=0;i<song->count;i++) { NSData *track=self.sectionTracks[@(copy_of[i]?copy_of[i]:song->sections[i].id)]; if(track && song->sections[i].edited) tracks[@(song->sections[i].id)]=track; else song->sections[i].edited=NO; }
    self.sectionTracks=tracks; self.songPlans=nil; if(self.editingSection>=0) self.editingSection=-2;   // the snapshot holds the working state
    NSInteger first=0; for(size_t i=0;i<song->count;i++) if(song->sections[i].kind==KV_SECTION_VERSE) { first=(NSInteger)i; break; }
    [self reloadEditing:first]; [self saveState]; self.lastForm=form;
    self.status.stringValue=[NSString stringWithFormat:T(@"Форма «%@»: секций %lu · ⌘R — другой вариант · ⌘Z — вернуть"),form[@"name"],(unsigned long)song->count];
}
- (void)arrangerApplyForm:(NSDictionary *)form { [self applyForm:form again:NO]; }
/* «Припев на новых аккордах»: every chorus not edited by hand takes one new turn of chords (the 1.4 generator) and its own
   pattern; again, another turn. ⌘Z brings the verse's chords back. */
- (void)arrangerNewChorusChords:(id)sender {
    (void)sender; KvSong *song=[self liveSong]; const KvSection *verse=NULL;
    for(size_t i=0;i<song->count && !verse;i++) if(song->sections[i].kind==KV_SECTION_VERSE && !song->sections[i].source) verse=&song->sections[i];
    if(!verse) { self.status.stringValue=T(@"В песне нет куплета, от которого строить припев"); return; }
    [self pushSongUndo]; self.formSeed=arc4random(); KvSection fresh=kv_section_chorus_turn(song,verse,self.formSeed); NSUInteger changed=0;
    for(size_t i=0;i<song->count;i++) { KvSection *s=&song->sections[i]; if(s->kind!=KV_SECTION_CHORUS || s->edited) continue;
        s->count=fresh.count; memcpy(s->codes,fresh.codes,sizeof(s->codes)); s->arrangement=fresh.arrangement; s->repeats=fresh.repeats; s->length=0; s->start=0;
        s->source=0; s->derive=KV_DERIVE_NONE; memset(s->map,0,sizeof(s->map)); changed++; }
    if(!changed) { [self.songUndo removeLastObject]; self.status.stringValue=T(@"Нет припевов, которые можно поменять: их ноты правлены вручную"); return; }
    kv_song_refresh_transitions(song); [self followSections]; self.songPlans=nil; NSInteger editing=self.editingSection;
    if(editing>=0) self.editingSection=-2; [self reloadEditing:MAX(0,editing)]; [self saveState];
    self.status.stringValue=[NSString stringWithFormat:T(@"Припевы на новых аккордах: %@ · ещё раз — другие · ⌘Z — вернуть аккорды куплета"),[self chordLine:&fresh song:song limit:8]];
}
- (void)arrangerAnotherForm:(id)sender { (void)sender; if(self.lastForm) [self applyForm:self.lastForm again:YES]; else self.status.stringValue=T(@"Сначала выберите форму в меню «Структура»"); }
/* The current song's kinds as a form of the user's, under a name (the same name replaces it); NO when the song is empty. */
- (BOOL)saveFormNamed:(NSString *)name {
    name=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; const KvSong *song=[self songWithWorking]; if(!name.length || !song->count) return NO;
    NSMutableArray *slots=[NSMutableArray array];
    for(size_t i=0;i<song->count && slots.count<KV_FORM_SLOTS;i++) { const KvSection *x=&song->sections[i]; int slot=x->kind;
        if(x->kind==KV_SECTION_TRANSITION) slot=!strcmp(x->name,kv_form_label(KV_FORM_BUILD))?KV_FORM_BUILD:KV_FORM_TRANSITION+x->transition;
        else if(x->kind==KV_SECTION_CHORUS && !strcmp(x->name,kv_form_label(KV_FORM_DROP))) slot=KV_FORM_DROP;
        [slots addObject:@(slot)]; }
    NSMutableArray *forms=[NSMutableArray array];
    for(NSDictionary *form in [Defaults() arrayForKey:@"userForms"]) if([form isKindOfClass:NSDictionary.class] && ![form[@"name"] isEqual:name]) [forms addObject:form];
    [forms addObject:@{@"name":name,@"slots":slots}]; [Defaults() setObject:forms forKey:@"userForms"];
    [self.arranger reload]; self.status.stringValue=[NSString stringWithFormat:T(@"Форма «%@» сохранена: %@ · есть в меню «Структура» во всех песнях"),name,FormLetters(slots)];
    return YES;
}
- (void)arrangerSaveForm:(id)sender {
    (void)sender; if(!self.song->count || !self.window) return;
    NSAlert *alert=[NSAlert new]; alert.messageText=T(@"Сохранить форму этой песни"); alert.informativeText=T(@"Типы секций по порядку станут формой в меню «Структура» — для всех песен.");
    NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(0,0,240,24)]; field.stringValue=T(@"Моя форма"); alert.accessoryView=field;
    [alert addButtonWithTitle:T(@"Сохранить")]; [alert addButtonWithTitle:T(@"Отмена")]; alert.window.initialFirstResponder=field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) { if(response==NSAlertFirstButtonReturn) [self saveFormNamed:field.stringValue]; }];
}
- (void)arrangerDeleteForm:(NSString *)name {
    NSMutableArray *forms=[NSMutableArray array];
    for(NSDictionary *form in [Defaults() arrayForKey:@"userForms"]) if([form isKindOfClass:NSDictionary.class] && ![form[@"name"] isEqual:name]) [forms addObject:form];
    [Defaults() setObject:forms forKey:@"userForms"]; [self.arranger reload];
    self.status.stringValue=[NSString stringWithFormat:T(@"Форма «%@» удалена"),name];
}
- (void)arrangerSetTrack:(int)track mute:(int)mute solo:(int)solo level:(double)level {
    if(track<0 || track>=KV_TRACKS) return;
    [self pushSongUndo]; KvSong *song=self.song;
    if(mute>=0) song->track_mute[track]=mute; if(solo>=0) song->track_solo[track]=solo; if(level>=0) song->track_level[track]=(float)MIN(1.2,level);
    self.songPlans=nil; [self.arranger reload]; [self saveState]; [self applyTrackGains]; [self applySongRhythm];   // at once: the hands' gains, the drums' rhythm and the part queued next
}
- (void)arrangerSetRegion:(int)track mute:(int)mute level:(double)level {
    NSInteger i=self.editingSection; if(track<0 || track>=KV_TRACKS || i<0 || i>=(NSInteger)self.song->count) return;
    [self pushSongUndo]; KvRegion *r=&self.song->sections[i].regions[track];
    if(mute>=0) r->mute=mute; if(level>=0) r->level=(float)MAX(.5,MIN(1.2,level));
    self.songPlans=nil; [self.arranger reload]; [self saveState]; [self applySongRhythm];   // shortcut: a region's own M and level reach the melody and bass from the next part, the drums at once; upgrade when the parts carry the regions live
}
/* A section's notes as they sound, pass by pass, beats from its start (nil: it cannot be built). */
- (NSData *)arrangerNotes:(NSInteger)index {
    KvSong *song=[self songWithWorking]; if(index<0 || index>=(NSInteger)song->count) return nil;
    double length=kv_section_beats(song,(size_t)index),pass=kv_section_pass_beats(song,&song->sections[index]); NSMutableData *notes=[NSMutableData data]; KvPerformance plan;
    for(double from=0;from<length-1e-9;from+=pass) {
        if(![self songPart:index from:from length:fmin(pass,length-from) into:&plan]) return nil;
        for(size_t k=0;k<plan.count;k++) { KvPianoEvent e=plan.events[k]; e.beat+=from; [notes appendBytes:&e length:sizeof(e)]; }
    }
    return notes;
}
/* Its beat, on the song's bars wherever the section begins, beats from its start. */
- (NSData *)arrangerHits:(NSInteger)index {
    const KvSong *song=[self songWithWorking]; if(index<0 || index>=(NSInteger)song->count) return nil;
    KvHit hits[KV_BEAT_HITS]; size_t n=0; NSMutableData *out=[NSMutableData data]; if(![self rhythmOfSection:index hits:hits count:&n]) return out;
    double bar=kv_meter_bar(song->meter),start=kv_section_start(song,(size_t)index),end=start+kv_section_beats(song,(size_t)index);
    for(double b=floor(start/bar+1e-9)*bar;n && b<end-1e-9;b+=bar) for(size_t h=0;h<n;h++) {
        double t=b+hits[h].beat; if(t<start-1e-9 || t>=end-1e-9) continue;
        KvHit hit=hits[h]; hit.beat=t-start; if(![self scaleHits:&hit count:1 at:t]) continue; [out appendBytes:&hit length:sizeof(hit)]; }
    return out;
}
- (void)arrangerRevert:(id)sender { (void)sender; if(self.trackEdited) [self pianoRollResetRequested:self.roll]; [self.arranger reload]; }
- (void)arrangerTakeDraft:(id)sender { [self sendToArranger:sender]; }
- (NSString *)arrangerDrumsHint {
    return self.drumsOn?nil:T(@"Ударные выключены — кнопка ♩♩ в транспорте или ⇧⌘K");
}
/* The empty song's «Сгенерировать песню»: the circle's chords (made first when there are none) as a verse, its drums by the style
   when none are chosen, then the song in the «Поп» form around it — every track has something to play. */
- (void)arrangerGenerateSong:(id)sender {
    (void)sender; if(self.song->count) return;
    if(!self.progression.count) [self generateProgression:nil];
    if(!self.progression.count) { self.status.stringValue=T(@"Сначала соберите последовательность на круге"); return; }
    [self sendToArranger:nil]; if(!self.song->count) return;
    NSDictionary *form=[self arrangerForms].firstObject; [self applyForm:form again:NO];
    self.arranger.cursorBeat=0; [self.arranger showWholeSong:nil];
    self.status.stringValue=[NSString stringWithFormat:T(@"Песня собрана из аккордов круга: форма «%@», секций %lu · ⌘R — другой вариант · ⌘Z — вернуть · Пробел — слушать"),form[@"name"],(unsigned long)self.song->count];
}
/* ⇧⌘A: the circle's progression and texture become a verse at the end of the song (or, from a section's roll, back to the arranger). */
- (void)sendToArranger:(id)sender {
    (void)sender;
    if(self.editingSection>=0) { if(self.viewMode==2 && self.rollDocked) [self pianoRoll:self.roll openSection:-1]; else [self showView:2]; return; }
    if(!self.progression.count) { self.status.stringValue=T(@"Сначала соберите последовательность на круге"); return; }
    KvSong *song=[self liveSong]; KvArrangement texture=[self arrangementForPreview:NO]; NSInteger last=(NSInteger)song->count-1;
    if(last>=0 && !self.trackEdited && !song->sections[last].edited && song->sections[last].count==self.progression.count && SameTexture(song->sections[last].arrangement,texture)) {
        BOOL same=YES; for(NSUInteger i=0;i<self.progression.count;i++) if(song->sections[last].codes[i]!=self.progression[i].intValue) same=NO;
        if(same) { self.arranger.selected=last; [self showView:2]; self.status.stringValue=T(@"Эта последовательность уже в песне — выбрана её секция"); return; }
    }
    if(song->count>=KV_SONG_SECTIONS) { self.status.stringValue=T(@"В песне уже 32 секции"); return; }
    [self pushSongUndo];
    if(![self insertWorkingAt:song->count]) { [self.songUndo removeLastObject]; self.status.stringValue=T(@"⚠ Последовательность не стала секцией"); return; }
    self.arranger.selected=(NSInteger)song->count-1; [self saveState]; [self showView:2];
    self.status.stringValue=[NSString stringWithFormat:T(@"«%@» в аранжировщике · двойной щелчок — в ролл · ⌘Z — отменить"),[self arrangerName:self.arranger.selected]];
}
- (void)duplicateSection:(id)sender {
    (void)sender; NSInteger i=self.editingSection; if(self.viewMode!=2 || i<0) return;
    NSRange range=self.arranger.selection; if(!NSLocationInRange((NSUInteger)i,range)) range=NSMakeRange((NSUInteger)i,1);
    [self arrangerMoveRange:range to:(NSInteger)NSMaxRange(range) copy:YES];
    NSUInteger at=(NSUInteger)MAX(0,self.arranger.selected); self.arranger.selection=NSMakeRange(at,MIN(range.length,self.song->count-at)); self.arranger.needsDisplay=YES;
}
- (void)cutSection:(id)sender {
    (void)sender; NSInteger i=self.editingSection; if(self.viewMode!=2 || i<0) return;
    const KvSong *song=[self songWithWorking]; double cursor=self.arranger.cursorBeat;
    for(size_t k=0;k<song->count;k++) {   // the playhead inside a section: cut there
        double start=kv_section_start(song,k),cut=kv_song_snap_cut(song,k,cursor-start,0);
        if(cursor>start+1e-9 && cursor<start+kv_section_beats(song,k)-1e-9) { if(cut>0) { [self arrangerCut:(NSInteger)k atBeat:cut]; return; } break; }
    }
    NSPoint mouse=[self.arranger convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    double start=kv_section_start(song,(size_t)i),length=kv_section_beats(song,(size_t)i),at=[self.arranger beatAtX:mouse.x]-start;
    if(at<=0 || at>=length) at=length/2;
    double cut=kv_song_snap_cut(song,(size_t)i,at,kv_meter_bar(song->meter)); if(cut<0) cut=kv_song_snap_cut(song,(size_t)i,at,0);
    if(cut<0) { self.status.stringValue=T(@"Здесь не разрезать: слишком близко к краю секции"); return; }
    [self arrangerCut:i atBeat:cut];
}
// ---- suggestions: what usually comes next (spec 1.4 §3.2) ----
- (size_t)suggestionsAfter:(NSInteger)index into:(KvSuggestion *)out {
    const KvSong *song=[self songWithWorking]; if(index<0 || index>=(NSInteger)song->count) return 0;
    return kv_song_suggest(song,(size_t)index,self.suggestSeed,out);
}
- (NSString *)chordLine:(const KvSection *)s song:(const KvSong *)song limit:(size_t)limit {
    NSMutableArray *names=[NSMutableArray array];
    for(size_t i=0;i<s->count && i<limit;i++) { KvChord chord; if(kv_code_chord(song->key,s->codes[i],song->extension,&chord)) [names addObject:S(chord.name)]; }
    return [names componentsJoinedByString:@" – "];
}
/* «F – G – Am – C – …, 8 тактов, баллада, проигрыш раз в 2 такта, правая рука на октаву выше, громкость 115 %, бит по стилю» */
- (NSString *)describeSection:(const KvSection *)s song:(const KvSong *)song {
    NSMutableArray *parts=[NSMutableArray arrayWithObject:[self chordLine:s song:song limit:8]];
    [parts addObject:TNBarCount(kv_section_pass_beats(song,s)*s->repeats/kv_meter_bar(song->meter))];
    [parts addObject:[self textureOf:&s->arrangement]];
    if(!s->arrangement.blocks && !s->arrangement.arpeggio && !s->arrangement.strings) {
        NSString *fills[]={@"",T(@"без проигрышей"),T(@"проигрыш раз в 4 такта"),T(@"проигрыш раз в 2 такта"),T(@"проигрыш каждый такт")};
        NSString *rate=fills[kv_fill_rate(s->arrangement.style,s->arrangement.fills)]; if(rate.length) [parts addObject:rate];
    }
    if(s->lift>0) [parts addObject:[T(@"Правая рука на октаву выше") lowercaseString]]; else if(s->lift<0) [parts addObject:[T(@"Обе руки на октаву ниже") lowercaseString]];
    if(fabsf(s->level-1)>.01f) [parts addObject:[NSString stringWithFormat:T(@"громкость %d %%"),(int)lroundf(s->level*100)]];
    if(s->beat==KV_SECTION_BEAT_OFF) [parts addObject:T(@"без бита")]; else if(s->beat==KV_SECTION_BEAT_QUIET) [parts addObject:T(@"бит тихо")];
    else if(s->beat==KV_SECTION_BEAT_STYLE) [parts addObject:T(@"бит по стилю")]; else if(s->beat==KV_SECTION_BEAT_FIXED) [parts addObject:[NSString stringWithFormat:T(@"бит «%@»"),[S(kv_beat_name(s->beat_fixed)) lowercaseString]]];
    return [parts componentsJoinedByString:@", "];
}
- (NSString *)describeTransition:(const KvSection *)t song:(const KvSong *)song {
    NSString *chord=[self chordLine:t song:song limit:1];
    switch(t->transition) {
        case KV_TRANSITION_RISE: return [NSString stringWithFormat:T(@"такт на %@ — арпеджио вверх с нарастанием и дробь малого барабана"),chord];
        case KV_TRANSITION_DOMINANT: return [NSString stringWithFormat:T(@"такт на %@ с проигрышем"),chord];
        case KV_TRANSITION_FILL: return [NSString stringWithFormat:T(@"проигрыш на %@"),chord];
        default: return [NSString stringWithFormat:T(@"удар %@, тишина и затакт в следующую секцию"),chord];
    }
}
- (NSArray<NSDictionary *> *)arrangerSuggestions:(NSInteger)index {
    KvSuggestion g[4]; size_t n=[self suggestionsAfter:index into:g]; const KvSong *song=[self songWithWorking]; NSMutableArray *ghosts=[NSMutableArray array];
    for(size_t i=0;i<n;i++) {
        const KvSection *s=&g[i].section; double beats=s->length>0?s->length:kv_section_pass_beats(song,s)*s->repeats,bar=kv_meter_bar(song->meter);
        NSString *kind=s->kind==KV_SECTION_TRANSITION?[NSString stringWithFormat:T(@"Переход: %@"),[S(kv_transition_name(s->transition)) lowercaseString]]:S(kv_section_kind_name(s->kind));
        NSString *title=[NSString stringWithFormat:g[i].before?T(@"+ %@ в начало · %@"):g[i].copy_of?T(@"+ %@ ещё раз · %@"):T(@"+ %@ · %@"),kind,TNBarCount(beats/bar)];
        NSMutableString *tip=[NSMutableString string];
        if(g[i].lead_in) [tip appendFormat:T(@"%@ → %@\nПереход: %@.\n"),S(kv_transition_name(g[i].transition.transition)),kind,[self describeTransition:&g[i].transition song:song]];
        else [tip appendFormat:@"%@\n",kind];
        [tip appendFormat:@"%@.\n",[self describeSection:s song:song]];
        BOOL chorus=s->kind==KV_SECTION_CHORUS && !g[i].copy_of;
        [tip appendString:chorus?T(@"Щелчок — вставить · Пробел — послушать · ⌥-щелчок — другой припев"):T(@"Щелчок — вставить · Пробел — послушать")];
        [ghosts addObject:@{@"title":title,@"tip":tip,@"beats":@(beats),@"leadBeats":@(g[i].lead_in?kv_section_pass_beats(song,&g[i].transition):0),@"kind":@(s->kind),@"chorus":@(chorus),@"leadKind":@(g[i].transition.transition)}];
    }
    return ghosts;
}
- (void)insertSuggestion:(const KvSuggestion *)g after:(NSInteger)index {
    if(self.song->count+(g->lead_in?2:1)>KV_SONG_SECTIONS) { self.status.stringValue=T(@"В песне уже 32 секции"); return; }
    [self pushSongUndo]; KvSong *song=[self liveSong]; size_t at=g->before?0:(size_t)index+1;
    if(g->lead_in && !kv_song_insert(song,at++,&g->transition)) { [self.songUndo removeLastObject]; return; }
    uint32_t made=kv_song_insert(song,at,&g->section);
    if(!made) { [self applySongSnapshot:self.songUndo.lastObject]; [self.songUndo removeLastObject]; self.status.stringValue=T(@"⚠ Последовательность не стала секцией"); return; }
    NSData *track=g->copy_of?self.sectionTracks[@(g->copy_of)]:nil;
    if(track && song->sections[at].edited) self.sectionTracks[@(made)]=track; else song->sections[at].edited=NO;
    [self followSections]; self.songPlans=nil; self.suggestSeed=arc4random(); [self reloadEditing:(NSInteger)at]; [self saveState];
    self.status.stringValue=[NSString stringWithFormat:T(@"«%@» в песне · ⌘Z — отменить"),[self arrangerName:(NSInteger)at]];
}
- (void)arrangerAccept:(NSInteger)suggestion after:(NSInteger)index {
    KvSuggestion g[4]; size_t n=[self suggestionsAfter:index into:g]; if(suggestion<0 || suggestion>=(NSInteger)n) return;
    [self insertSuggestion:&g[suggestion] after:index];
}
- (const KvSection *)verseFor:(NSInteger)index song:(const KvSong *)song {
    if(song->sections[index].kind==KV_SECTION_VERSE) return &song->sections[index];
    for(size_t i=0;i<song->count;i++) if(song->sections[i].kind==KV_SECTION_VERSE) return &song->sections[i];
    return &song->sections[index];
}
- (NSArray<NSString *> *)arrangerChorusVariants:(NSInteger)index {
    const KvSong *song=[self songWithWorking]; if(index<0 || index>=(NSInteger)song->count) return @[];
    const KvSection *verse=[self verseFor:index song:song]; KvSection shown=kv_section_chorus_turn(song,verse,self.suggestSeed);
    NSMutableArray<NSData *> *made=[NSMutableArray array]; NSMutableArray<NSString *> *names=[NSMutableArray array];
    for(uint32_t k=1;k<=24 && made.count<3;k++) {
        KvSection c=kv_section_chorus_turn(song,verse,self.suggestSeed+k); BOOL seen=!memcmp(c.codes,shown.codes,sizeof(c.codes));
        for(NSData *d in made) if(!memcmp(((const KvSection *)d.bytes)->codes,c.codes,sizeof(c.codes))) seen=YES;
        if(seen) continue;
        [made addObject:[NSData dataWithBytes:&c length:sizeof(c)]]; [names addObject:[self chordLine:&c song:song limit:4]];
    }
    self.chorusVariants=made; return names;
}
- (void)arrangerAcceptVariant:(NSInteger)variant after:(NSInteger)index {
    if(variant<0 || variant>=(NSInteger)self.chorusVariants.count || index<0 || index>=(NSInteger)self.song->count) return;
    const KvSong *song=[self songWithWorking]; KvSuggestion g; memset(&g,0,sizeof(g)); memcpy(&g.section,self.chorusVariants[variant].bytes,sizeof(KvSection));
    g.lead_in=song->sections[index].kind!=KV_SECTION_TRANSITION; if(g.lead_in) g.transition=kv_section_transition(song,&song->sections[index],&g.section,KV_TRANSITION_RISE);
    [self insertSuggestion:&g after:index];
}
- (void)arrangerTransitionAfter:(NSInteger)index kind:(NSInteger)kind {
    KvSong *song=[self songWithWorking]; if(index<0 || index+1>=(NSInteger)song->count) return;
    if(song->count>=KV_SONG_SECTIONS) { self.status.stringValue=T(@"В песне уже 32 секции"); return; }
    KvTransitionKind way=kind>=0 && kind<KV_TRANSITION_KINDS?(KvTransitionKind)kind:kv_transition_for(&song->sections[index],&song->sections[index+1]);
    [self pushSongUndo]; song=[self liveSong];
    KvSection t=kv_section_transition(song,&song->sections[index],&song->sections[index+1],way);
    if(!kv_song_insert(song,(size_t)index+1,&t)) { [self.songUndo removeLastObject]; return; }
    [self followSections]; self.songPlans=nil; [self reloadEditing:index+1]; [self saveState];
    self.status.stringValue=[NSString stringWithFormat:T(@"Переход «%@» вставлен · ⌘Z — отменить"),[S(kv_transition_name(way)) lowercaseString]];
}
- (void)arrangerAudition:(NSInteger)suggestion after:(NSInteger)index {
    if(suggestion<0) { if(self.auditioningGhost) { self.auditioningGhost=NO; [self stopPlayback:nil]; } return; }
    KvSuggestion g[4]; size_t n=[self suggestionsAfter:index into:g]; if(suggestion>=(NSInteger)n) return;
    KvSong *trial=malloc(sizeof(KvSong)); if(!trial) return; *trial=*[self songWithWorking];
    size_t at=g[suggestion].before?0:(size_t)index+1; BOOL ok=YES;
    if(g[suggestion].lead_in) ok=kv_song_insert(trial,at++,&g[suggestion].transition)!=0;
    ok=ok && kv_song_insert(trial,at,&g[suggestion].section)!=0;
    NSData *track=g[suggestion].copy_of?self.sectionTracks[@(g[suggestion].copy_of)]:nil; KvPerformance plan;
    ok=ok && kv_section_part(trial,at,track && trial->sections[at].edited?track.bytes:NULL,0,kv_section_pass_beats(trial,&trial->sections[at]),&plan);
    KvChord chords[8]; NSMutableArray *codes=[NSMutableArray array]; size_t count=0;
    for(size_t i=0;ok && i<trial->sections[at].count;i++) if(kv_code_chord(trial->key,trial->sections[at].codes[i],trial->extension,&chords[count])) {
        for(size_t v=0;v<chords[count].count;v++) chords[count].midi[v]+=trial->keyboard_base-60; [codes addObject:@(trial->sections[at].codes[i])]; count++; }
    free(trial); if(!ok) return;
    [self startPerformance:&plan chords:chords count:count degrees:codes offset:0]; kv_audio_set_loop(self.audio,true);
    self.auditioningGhost=YES; self.status.stringValue=T(@"Слушаем подсказку · Пробел или уход курсора — стоп");
}
// ---- the song as a MIDI file: every section and repeat, its level, its drums on channel 10, a marker per section ----
- (BOOL)exportSongToPath:(NSString *)path { return [self exportSongToPath:path tracks:0]; }
/* what: 0 the whole song, 1 only the melody (right hand), 2 only the bass (left hand), 3 only the drums. */
- (BOOL)exportSongToPath:(NSString *)path tracks:(NSInteger)what {
    [self storeWorking]; const KvSong *song=[self songWithWorking]; if(!song->count || !path) return NO;
    NSMutableData *notes=[NSMutableData data],*drums=[NSMutableData data]; NSMutableArray<NSString *> *names=[NSMutableArray array];
    KvMidiMarker *marks=calloc(song->count,sizeof(KvMidiMarker)); if(!marks) return NO;
    double at=0;
    for(size_t i=0;i<song->count;i++) {
        [names addObject:[self arrangerName:(NSInteger)i]]; marks[i]=(KvMidiMarker){at,names.lastObject.UTF8String};
        NSData *part=[self arrangerNotes:(NSInteger)i],*beat=[self arrangerHits:(NSInteger)i]; if(!part) { free(marks); return NO; }
        const KvPianoEvent *e=part.bytes; for(size_t k=0;k<part.length/sizeof(*e);k++) { KvPianoEvent x=e[k]; x.beat+=at;
            if(what==0 || (what==1 && x.hand) || (what==2 && !x.hand)) [notes appendBytes:&x length:sizeof(x)]; }
        const KvHit *h=beat.bytes; for(size_t k=0;k<beat.length/sizeof(*h) && (what==0 || what==3);k++) { KvHit x=h[k]; x.beat+=at; [drums appendBytes:&x length:sizeof(x)]; }
        double length=kv_section_beats(song,i);
        at+=length;
    }
    if(!notes.length && !drums.length) { KvPianoEvent quiet={.midi=60,.beat=0,.duration=.01,.velocity=0,.hand=1}; [notes appendBytes:&quiet length:sizeof(quiet)]; }   // every track muted: an inaudible note keeps the file valid
    size_t count=notes.length/sizeof(KvPianoEvent),drumCount=drums.length/sizeof(KvHit),capacity=4096+count*24+drumCount*24+song->count*96;
    uint8_t *file=malloc(capacity); if(!file) { free(marks); return NO; }
    int numerator=song->meter==KV_METER_4_4?4:song->meter==KV_METER_3_4?3:6,power=song->meter==KV_METER_6_8?3:2;
    int scale[8]; kv_scale(song->key,scale); BOOL minor=scale[2]-scale[0]==3;
    NSString *title=[NSString stringWithFormat:T(@"Tonora · песня · %@"),[self keyTitle]];
    // The tempo curve as the conductor's changes: at its points, and every beat along a ramp between two.
    NSMutableData *tempos=[NSMutableData data]; const KvCurve *curve=&song->tempo; double startBpm=kv_curve_at(curve,0,(float)song->bpm);
    for(size_t i=0;i<curve->count;i++) {
        const KvPoint *p=&curve->points[i]; KvMidiTempo t={p->beat,p->value}; if(t.beat>0) [tempos appendBytes:&t length:sizeof(t)];
        if(i+1<curve->count && curve->points[i+1].value!=p->value) for(double b=floor(p->beat)+1;b<curve->points[i+1].beat-1e-9;b+=1) {
            KvMidiTempo step={b,kv_curve_at(curve,b,(float)song->bpm)}; [tempos appendBytes:&step length:sizeof(step)]; }
    }
    size_t size=kv_midi_encode_song(notes.bytes,count,drums.bytes,drumCount,marks,song->count,at,startBpm,tempos.bytes,tempos.length/sizeof(KvMidiTempo),numerator,power,[self writtenSignature],minor,[self midiProgram],title.UTF8String,file,capacity);
    BOOL ok=size && [[NSData dataWithBytesNoCopy:file length:size freeWhenDone:NO] writeToFile:path atomically:YES];
    free(file); free(marks); return ok;
}
- (void)exportSong:(id)sender { (void)sender; [self arrangerExport:0]; }
- (void)arrangerExport:(NSInteger)what {
    if(!self.song->count || !self.window || what<0 || what>3) return;
    NSSavePanel *panel=[NSSavePanel savePanel]; panel.title=T(@"Экспорт MIDI песни"); panel.prompt=T(@"Сохранить");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes=@[@"mid",@"midi"];
#pragma clang diagnostic pop
    NSArray *parts=@[@"",T(@" · мелодия"),T(@" · бас"),T(@" · ударные")];
    panel.nameFieldStringValue=[NSString stringWithFormat:T(@"Tonora · песня · %@%@.mid"),[self keyTitle],parts[what]];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if(response!=NSModalResponseOK || !panel.URL) return;
        self.status.stringValue=[self exportSongToPath:panel.URL.path tracks:what]?[NSString stringWithFormat:T(@"Песня сохранена в MIDI: %@"),panel.URL.lastPathComponent]:T(@"⚠ Не удалось сохранить MIDI");
    }];
}
// ---- the .tonora file: the state that makes the work, as the settings keep it (spec 1.4 §3.8) ----
/* Key, meter, tempo, instrument, sound, the draft with its edited track, the song and the view; not the MIDI ports, the
   language or the window, which belong to this Mac. */
static NSArray<NSString *> *KvDocumentKeys(void) {
    return @[@"circleIndex",@"minor",@"scaleMode",@"pentatonic",@"spelling",@"showChord",@"selectedDegree",@"keyboardBase",@"instrument",@"humanize",@"progression",
             @"reverb",@"delay",@"fxEngineVersion",@"freeDelaySeconds",@"delayDivision",@"delaySeconds",@"chordExtension",@"arrangementSeed",@"generatedRhythm",@"twoHandPiano",
             @"texture",@"arpeggioPattern",@"division",@"chordLengthArp",@"pianoPattern",@"meter",@"chordLengthBlocks",@"chordLengthHands",@"chordLengthStrings",@"articulation",
             @"stringDynamics",@"fillRate",@"trackEdited",@"trackData",@"viewMode",@"loopEnabled",@"rhythmGrid",@"countIn",@"rhythmBeat",@"drumsOn",@"rhythmVolume",@"tempo",@"song"];
}
- (NSDictionary *)documentStateFromDefaults {
    NSUserDefaults *defaults=Defaults(); NSMutableDictionary *state=[NSMutableDictionary dictionary];
    for(NSString *name in KvDocumentKeys()) { id value=[defaults objectForKey:name]; if(value) state[name]=value; }
    return state;
}
- (NSData *)documentData {
    [self saveState];
    NSDictionary *file=@{@"format":@"tonora",@"version":@1,@"app":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"",@"state":[self documentStateFromDefaults]};
    return [NSPropertyListSerialization dataWithPropertyList:file format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
}
/* The state inside a .tonora file, or nil when it is not one. Values are checked again when the window restores them. */
+ (NSDictionary *)documentStateFromData:(NSData *)data {
    if(!data.length || data.length>(32u<<20)) return nil;
    NSDictionary *file=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if(![file isKindOfClass:NSDictionary.class] || ![file[@"format"] isEqual:@"tonora"] || ![file[@"version"] isEqual:@1] || ![file[@"state"] isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *state=[NSMutableDictionary dictionary]; NSArray *types=@[NSNumber.class,NSString.class,NSArray.class,NSData.class,NSDictionary.class];
    for(NSString *name in KvDocumentKeys()) { id value=file[@"state"][name]; if(!value) continue; BOOL known=NO; for(Class type in types) if([value isKindOfClass:type]) known=YES; if(known) state[name]=value; }
    return state;
}
/* Puts a file's state in the settings, ready for a new window to restore it; keys the file lacks go back to their defaults. */
+ (void)loadDocumentState:(NSDictionary *)state {
    NSUserDefaults *defaults=Defaults();
    for(NSString *name in KvDocumentKeys()) { if(state[name]) [defaults setObject:state[name] forKey:name]; else [defaults removeObjectForKey:name]; }
}
// ---- song playback: the song in parts (stretches of a section, a pass long at most), the next queued while one plays ----
- (BOOL)songPart:(NSInteger)section from:(double)from length:(double)length into:(KvPerformance *)out { return [self songPart:section from:from length:length live:NO into:out]; }
/* live: for playback — the tracks' mute, solo and level are left out of the part and applied live (applyTrackGains), so M, S and the
   faders act at once; the thumbnails and the MIDI export take the part as it sounds. */
/* The pass a section plays (spec 1.6): its notes edited by hand; else, when it grows from another section, that section's pass
   changed by its role; else its own pattern (a strings texture on the piano as two hands). A chain of sources goes four deep. */
- (BOOL)passOfSection:(NSInteger)i into:(KvPerformance *)out depth:(int)depth {
    KvSong *song=[self songWithWorking]; if(i<0 || i>=(NSInteger)song->count) return NO;
    if(i==self.editingSection && self.trackEdited) { *out=*self.track; return kv_performance_valid(out) && out->chord_count==song->sections[i].count; }
    NSData *own=i==self.editingSection?nil:[self trackOfSection:i]; if(own) { memcpy(out,own.bytes,sizeof(*out)); return YES; }
    const KvSection *s=&song->sections[i];
    if(s->source && s->derive!=KV_DERIVE_NONE && !s->edited && depth<4) {
        NSInteger j=-1; for(size_t k=0;k<song->count;k++) if(song->sections[k].id==s->source) j=(NSInteger)k;
        KvPerformance *src=j>=0 && j!=i?malloc(sizeof(KvPerformance)):NULL;
        BOOL derived=src && [self passOfSection:j into:src depth:depth+1] && kv_section_derive(song,(size_t)i,&song->sections[j],src,out); free(src);
        if(derived) return YES;
    }
    KvArrangement kept=song->sections[i].arrangement; song->sections[i].arrangement=[self playable:kept];
    BOOL ok=kv_section_notes(song,(size_t)i,out); song->sections[i].arrangement=kept; return ok;
}
- (BOOL)songPart:(NSInteger)section from:(double)from length:(double)length live:(BOOL)live into:(KvPerformance *)out {
    NSString *key=[NSString stringWithFormat:@"%@%ld:%.6f:%.6f",live?@"live ":@"",(long)section,from,length];
    NSData *cached=self.songPlans[key]; if(cached.length==sizeof(KvPerformance)) { memcpy(out,cached.bytes,sizeof(*out)); return YES; }
    KvSong *song=[self songWithWorking]; if(section<0 || section>=(NSInteger)song->count) return NO;
    KvPerformance *pass=malloc(sizeof(KvPerformance)); if(!pass) return NO;
    if(![self passOfSection:section into:pass depth:0]) { free(pass); return NO; }
    bool mute[KV_TRACKS],solo[KV_TRACKS]; float level[KV_TRACKS]; memcpy(mute,song->track_mute,sizeof(mute)); memcpy(solo,song->track_solo,sizeof(solo)); memcpy(level,song->track_level,sizeof(level));
    if(live) for(int t=0;t<KV_TRACKS;t++) { song->track_mute[t]=song->track_solo[t]=false; if(t<KV_TRACK_DRUMS) song->track_level[t]=1; }
    BOOL ok=kv_section_part(song,(size_t)section,pass,from,length,out); free(pass);
    memcpy(song->track_mute,mute,sizeof(mute)); memcpy(song->track_solo,solo,sizeof(solo)); memcpy(song->track_level,level,sizeof(level));
    if(!ok) return NO;
    if(!self.songPlans) self.songPlans=[NSMutableDictionary dictionary];
    self.songPlans[key]=[NSData dataWithBytes:out length:sizeof(*out)]; return YES;
}
- (BOOL)songPartAt:(NSInteger)position into:(KvPerformance *)out {
    return position>=0 && position<(NSInteger)self.songOrder.count && [self songPart:self.songOrder[position].integerValue from:self.songOrderFrom[position].doubleValue length:self.songOrderLength[position].doubleValue live:YES into:out];
}
/* The tracks' M, S and level, live on the engine's hands while the song plays (its parts are built without them); 1 otherwise. */
- (void)applyTrackGains {
    const KvSong *s=self.song; float gain[2]={1,1};
    if(self.songPlaying) { BOOL solo=s->track_solo[0] || s->track_solo[1] || s->track_solo[2];
        for(int t=KV_TRACK_MELODY;t<=KV_TRACK_BASS;t++) gain[t==KV_TRACK_MELODY?1:0]=s->track_mute[t] || (solo && !s->track_solo[t])?0:s->track_level[t]; }
    if(self.audio) kv_audio_set_hands(self.audio,gain[0],gain[1]);
}
/* The drums under a section at the «Ударные» track's level: 0 none, 1 these hits. */
- (int)rhythmOfSection:(NSInteger)index hits:(KvHit *)hits count:(size_t *)count {
    int on=[self beatOfSection:index hits:hits count:count]; float level=[self songWithWorking]->track_level[KV_TRACK_DRUMS];
    for(size_t i=0;on && i<*count;i++) hits[i].velocity=fminf(1,hits[i].velocity*level);   // the «Ударные» track's level
    return on;
}
/* A section's own beat setting as hits (0: none; «as the section before it» the caller resolves). */
- (size_t)hitsOfBeat:(const KvSection *)s into:(KvHit *)hits {
    const KvArrangement *a=&s->arrangement; KvPianoPattern style=a->blocks || a->arpeggio || a->strings?KV_BALLAD:a->style;
    switch(s->beat) {
        case KV_SECTION_BEAT_STYLE: return kv_beat_bar(kv_beat_for_style(style),self.meter,hits);
        case KV_SECTION_BEAT_FIXED: return kv_beat_bar(s->beat_fixed,self.meter,hits);
        case KV_SECTION_BEAT_QUIET: {   // the ballad's hi-hats and shakers, softer
            KvHit all[KV_BEAT_HITS]; size_t n=kv_beat_bar(KV_BEAT_BALLAD,self.meter,all),count=0;
            for(size_t i=0;i<n;i++) if(all[i].drum==KV_DRUM_HAT || all[i].drum==KV_DRUM_HAT_OPEN || all[i].drum==KV_DRUM_SHAKER || all[i].drum==KV_DRUM_TAMBOURINE) hits[count++]=(KvHit){all[i].beat,all[i].drum,all[i].velocity*.6f};
            if(!count) hits[count++]=(KvHit){0,KV_DRUM_HAT,.4f};
            return count;
        }
        default: return 0;
    }
}
/* The drums under a section: 0 none, 1 these hits. Only while the drums are on: the section's — «as the song» (by the section's
   style or the song's beat), its own beat, quiet, or none; a rise or a break plays its own fill. */
static KvPianoPattern a_style(const KvSection *s) { const KvArrangement *a=&s->arrangement; return a->blocks || a->arpeggio || a->strings?KV_BALLAD:a->style; }
- (int)beatOfSection:(NSInteger)index hits:(KvHit *)hits count:(size_t *)count {
    *count=0; const KvSong *song=[self songWithWorking]; if(index<0 || index>=(NSInteger)song->count || !self.drumsOn) return 0;
    if(!kv_region_audible(song,(size_t)index,KV_TRACK_DRUMS)) return 0;
    const KvSection *s=&song->sections[index];
    if(s->kind==KV_SECTION_TRANSITION && s->beat!=KV_SECTION_BEAT_OFF) *count=kv_transition_hits(s->transition,self.meter,hits);
    if(!*count) {
        if(s->beat==KV_SECTION_BEAT_SONG) {
            const KvArrangement *a=&s->arrangement; KvPianoPattern style=a->blocks || a->arpeggio || a->strings?KV_BALLAD:a->style;
            NSInteger beat=self.rhythmBeat==KvBeatByStyle?kv_beat_for_style(style):self.rhythmBeat; *count=kv_beat_bar((KvBeat)beat,self.meter,hits);
        } else *count=[self hitsOfBeat:s into:hits];
    }
    NSInteger played=s->beat==KV_SECTION_BEAT_FIXED?s->beat_fixed:s->beat==KV_SECTION_BEAT_STYLE?kv_beat_for_style(a_style(s)):s->beat==KV_SECTION_BEAT_SONG?(self.rhythmBeat==KvBeatByStyle?kv_beat_for_style(a_style(s)):self.rhythmBeat):-1;
    double shift=s->regions[KV_TRACK_DRUMS].shift,bar=kv_meter_bar(self.meter);
    if(*count && fabs(shift)>1e-9) {   // a shifted drums region: the bar's pattern turns by the shift, in order again
        for(size_t i=0;i<*count;i++) { double at=fmod(hits[i].beat+shift,bar); if(at<0) at+=bar; if(at>bar-1e-9) at=0; hits[i].beat=at; }
        for(size_t i=1;i<*count;i++) for(size_t j=i;j>0 && hits[j].beat<hits[j-1].beat;j--) { KvHit t=hits[j]; hits[j]=hits[j-1]; hits[j-1]=t; }
    }
    return *count?(played>=0 && kv_beat_electronic((KvBeat)played)?2:1):0;
}
- (size_t)chordsOfSection:(NSInteger)section into:(KvChord *)chords codes:(NSMutableArray<NSNumber *> *)codes {
    const KvSong *song=[self songWithWorking]; const KvSection *s=&song->sections[section]; size_t n=0;
    for(size_t i=0;i<s->count;i++) { if(!kv_code_chord(song->key,s->codes[i],song->extension,&chords[n])) continue; for(size_t v=0;v<chords[n].count;v++) chords[n].midi[v]+=song->keyboard_base-60; n++; [codes addObject:@(s->codes[i])]; }
    return n;
}
/* Appends the song between two beats to the play order: each section in stretches of a pass at most (cut where the stretch
   begins and ends), with where each begins in the section and in the song. */
- (void)appendSongOrderFrom:(double)begin to:(double)end {
    const KvSong *song=[self songWithWorking];
    for(NSInteger i=0;i<(NSInteger)song->count;i++) {
        double start=kv_section_start(song,(size_t)i),length=kv_section_beats(song,(size_t)i),pass=kv_section_pass_beats(song,&song->sections[i]);
        for(double at=0;at<length-1e-9;at+=pass) {
            double from=fmax(at,begin-start),to=fmin(fmin(at+pass,length),end-start); if(to-from<1e-3) continue;
            [self.songOrder addObject:@(i)]; [self.songOrderFrom addObject:@(from)]; [self.songOrderLength addObject:@(to-from)]; [self.songOrderBeats addObject:@(start+from)]; }
    }
}
/* The cycle when ↻ is on and one is drawn inside the song: its beats, else NO. */
- (BOOL)songCycle:(double *)from to:(double *)to {
    const KvSong *song=self.song; double total=kv_song_beats(song);
    if(!self.loopEnabled || song->cycle_to<=song->cycle_from+1e-6 || song->cycle_from>=total-1e-6) return NO;
    *from=song->cycle_from; *to=fmin(total,song->cycle_to); return YES;
}
- (double)barPhaseOf:(NSInteger)position { double bar=kv_meter_bar(self.meter),at=fmod(self.songOrderBeats[position].doubleValue,bar); return at>bar-1e-6?0:at; }
- (void)queueSongPart:(NSInteger)position {
    if(position<=self.songQueued) return;
    if(position>=(NSInteger)self.songOrder.count) {   // the end: again from the cycle's start (or the song's) while ↻ is on
        if(!self.loopEnabled) return;
        double from=0,to=kv_song_beats([self songWithWorking]); [self songCycle:&from to:&to]; [self appendSongOrderFrom:from to:to];
        if(position>=(NSInteger)self.songOrder.count) return;
    }
    NSInteger section=self.songOrder[position].integerValue; KvPerformance plan; KvHit hits[KV_BEAT_HITS]; size_t n=0;
    if(![self songPartAt:position into:&plan]) { self.status.stringValue=T(@"⚠ Не удалось построить секцию песни"); return; }
    int rhythm=[self rhythmOfSection:section hits:hits count:&n]; n=[self scaleHits:hits count:n at:self.songOrderBeats[position].doubleValue];
    if(kv_audio_queue(self.audio,&plan,rhythm,hits,n,[self barPhaseOf:position])) self.songQueued=position;
}
- (void)playSongFrom:(NSInteger)first {
    const KvSong *song=self.song; if(!song->count) return;
    [self playSongFromBeat:kv_section_start(song,(size_t)MAX(0,MIN((NSInteger)song->count-1,first)))];
}
/* The song from a beat (the playhead) to its end; with ↻ and a cycle, inside the cycle (from its start when the beat is outside). */
- (void)playSongFromBeat:(double)beat {
    [self storeWorking]; const KvSong *song=[self songWithWorking]; if(!song->count || !self.audio) return;
    double total=kv_song_beats(song),end=total,from=0,to=0; beat=MAX(0,MIN(total,beat)); if(beat>=total-1e-6) beat=0;
    if([self songCycle:&from to:&to] && beat<to-1e-9) end=to;   // from the playhead, always; the cycle catches it when it gets there
    if(kv_audio_is_playing(self.audio)) [self stopPlayback:nil];
    self.songOrder=[NSMutableArray array]; self.songOrderBeats=[NSMutableArray array]; self.songOrderFrom=[NSMutableArray array]; self.songOrderLength=[NSMutableArray array];
    [self appendSongOrderFrom:beat to:end]; if(!self.songOrder.count) return;
    NSInteger section=self.songOrder.firstObject.integerValue; KvPerformance plan; KvHit hits[KV_BEAT_HITS]; size_t n=0;
    if(![self songPartAt:0 into:&plan]) { self.status.stringValue=T(@"⚠ Не удалось построить секцию песни"); return; }
    int rhythm=[self rhythmOfSection:section hits:hits count:&n]; n=[self scaleHits:hits count:n at:self.songOrderBeats[0].doubleValue];
    kv_audio_phase(self.audio,[self barPhaseOf:0]);
    kv_audio_set_rhythm(self.audio,self.metronomeOn,self.rhythmGrid,self.meter,60.0/(self.tempo*self.speed),self.rhythmVolume); kv_audio_set_beat(self.audio,hits,rhythm?n:0,rhythm==2); self.sentBeat=-2;
    if(self.metronomeOn && self.countIn && !self.songRestart) kv_audio_count_in(self.audio,kv_meter_bar(self.meter));
    KvChord chords[8]; NSMutableArray *codes=[NSMutableArray array]; size_t count=[self chordsOfSection:section into:chords codes:codes];
    [self startPerformance:&plan chords:chords count:count degrees:codes offset:0];
    if(!self.playingPerformance) return;
    kv_audio_set_loop(self.audio,false);   // the song loops by queueing its start again, never a single part
    self.songPlaying=YES; self.songPart=0; self.songQueued=0; self.tempoPart=0; self.tempoSeconds=self.tempoBeats=0; self.appliedBpm=self.tempo; self.playingTimeline=[self songTimeline]; [self updateSongTempo]; [self applyTrackGains]; [self queueSongPart:1];
    self.status.stringValue=T(@"Песня · Esc — стоп · ⌥Пробел — только выбранная секция");
}
- (void)playSong:(id)sender { (void)sender; [self playSongFrom:0]; }
/* The song again from `beat` after an edit while it played: at once, without a count-in. */
- (void)restartSongAt:(double)beat { NSString *status=self.status.stringValue; self.songRestart=YES; [self playSongFromBeat:fmin(beat,kv_song_beats([self songWithWorking]))]; self.songRestart=NO; self.status.stringValue=status; }
/* The song's timeline in one string: what the play order depends on. */
- (NSString *)songTimeline {
    const KvSong *s=[self songWithWorking]; NSMutableString *t=[NSMutableString string];
    for(size_t i=0;i<s->count;i++) [t appendFormat:@"%u:%.3f:%.3f:%.3f;",s->sections[i].id,kv_section_beats(s,i),kv_section_pass_beats(s,&s->sections[i]),s->sections[i].start];
    return t;
}
/* The song was edited while it plays (a generated section, a new length, more chords…): the part playing goes on to its end, the
   order after it is built again from the song as it is now, and the next part is queued anew. A part whose section is gone starts over. */
- (void)followSongEdit {
    NSInteger part=self.songPart; const KvSong *song=[self songWithWorking]; if(part<0 || part>=(NSInteger)self.songOrder.count) return;
    if(self.songOrder[part].integerValue>=(NSInteger)song->count) { [self playSongFromBeat:fmax(0,[self arrangerPlayheadBeat])]; return; }
    double end=self.songOrderBeats[part].doubleValue+self.songOrderLength[part].doubleValue,from=0,to=0,total=kv_song_beats(song);
    double stop=[self songCycle:&from to:&to] && end<to-1e-9?to:total;
    for(NSMutableArray *list in @[self.songOrder,self.songOrderBeats,self.songOrderFrom,self.songOrderLength]) [list removeObjectsInRange:NSMakeRange((NSUInteger)part+1,list.count-(NSUInteger)part-1)];
    if(end<stop-1e-9) [self appendSongOrderFrom:end to:stop];
    self.songQueued=part; [self queueSongPart:part+1];
}
- (void)updateSongPlayback {
    if(!self.songPlaying) return;
    if(!kv_audio_is_playing(self.audio)) { self.arranger.cursorBeat=0; [self endSong]; return; }   // played to its end: back to the start
    NSString *timeline=[self songTimeline]; if(![timeline isEqualToString:self.playingTimeline]) { self.playingTimeline=timeline; [self followSongEdit]; if(!self.songPlaying) return; }
    NSInteger part=(NSInteger)kv_audio_part(self.audio,NULL);
    if(part!=self.songPart && part<(NSInteger)self.songOrder.count) {
        self.songPart=part; NSInteger section=self.songOrder[part].integerValue; KvPerformance plan;
        if([self songPartAt:part into:&plan]) {
            KvChord chords[8]; NSMutableArray *codes=[NSMutableArray array]; size_t count=[self chordsOfSection:section into:chords codes:codes];
            [self adoptPlan:&plan chords:chords count:count]; self.playingDegrees=codes; self.playOffset=0; self.visualEvent=-1;
        }
    }
    [self queueSongPart:self.songPart+1];
}
/* Each frame while the song plays: the beats into the part (counted at the tempo each moment had) and, with a tempo curve, the
   tempo it asks for there (the engine keeps the beat when the tempo changes). */
- (void)updateSongTempo {
    if(!self.songPlaying || !self.audio) return;
    double seconds=0; NSInteger part=(NSInteger)kv_audio_part(self.audio,&seconds);
    if(part!=self.tempoPart) { self.tempoPart=part; self.tempoSeconds=0; self.tempoBeats=0; }
    if(seconds>self.tempoSeconds) { self.tempoBeats+=(seconds-self.tempoSeconds)*self.appliedBpm*self.speed/60; self.tempoSeconds=seconds; }
    const KvSong *song=self.song;
    if(!song->tempo.count) { self.appliedBpm=self.tempo; return; }   // the slider's tempo (applyTempo sends it)
    if(part<0 || part>=(NSInteger)self.songOrderBeats.count) return;
    double bpm=MAX(20,MIN(300,kv_curve_at(&song->tempo,self.songOrderBeats[part].doubleValue+self.tempoBeats,(float)self.tempo)));
    if(fabs(bpm-self.appliedBpm)>.05 && kv_audio_set_interval(self.audio,60.0/(bpm*self.speed))) { self.appliedBpm=bpm; self.tempoValue.stringValue=[NSString stringWithFormat:T(@"%.0f BPM ⌁"),bpm]; }   // the curve's tempo, shown
}
/* The drums' volume curve over a stretch of hits starting at `beat` in the song (the bar's pattern takes the curve at its start). */
- (size_t)scaleHits:(KvHit *)hits count:(size_t)n at:(double)beat {
    float level=kv_curve_at(&self.song->volume[KV_TRACK_DRUMS],beat,1); if(level<.02f) return 0;
    for(size_t i=0;i<n;i++) hits[i].velocity=fminf(1,hits[i].velocity*level);
    return n;
}
- (void)endSong { self.tempoValue.stringValue=[NSString stringWithFormat:@"%.0f BPM",self.tempo]; self.songPlaying=NO; self.songOrder=nil; self.songOrderBeats=nil; self.songOrderFrom=nil; self.songOrderLength=nil; self.songPart=0; self.songQueued=0; self.sentBeat=-2; [self applyRhythm]; if(self.viewMode==2) self.arranger.needsDisplay=YES; }
- (void)keyDown:(NSEvent *)event {
    if(self.shortcutsVisible && event.keyCode==48) { KvShortcutsCard *card=(KvShortcutsCard *)self.shortcutsCard; card.tab=(card.tab+1)%3; card.needsDisplay=YES; return; }   // Tab
    if(self.shortcutsVisible && (event.keyCode==53 || (event.keyCode==44 && (event.modifierFlags&NSEventModifierFlagCommand)))) { [self toggleShortcuts:nil]; return; }
    if((event.modifierFlags&NSEventModifierFlagCommand) && event.keyCode==44) { [self toggleShortcuts:nil]; return; } // ⌘/
    if([self computerKeyDown:event]) return;
    NSEventModifierFlags flags=event.modifierFlags;
    if(flags&NSEventModifierFlagCommand) {
        if(event.keyCode==125) { [self shiftOctave:-1]; return; }
        if(event.keyCode==126) { [self shiftOctave:1]; return; }
        if((event.keyCode==123 || event.keyCode==124) && self.selectedChip>=0) { [self moveChordFrom:self.selectedChip to:self.selectedChip+(event.keyCode==123?-1:1)]; return; }
        [super keyDown:event]; return;
    }
    if(flags&NSEventModifierFlagOption && (event.keyCode==125 || event.keyCode==126)) {
        NSInteger count=self.mode.numberOfItems,index=(self.mode.indexOfSelectedItem+(event.keyCode==125?1:-1)+count)%count;
        [self.mode selectItemAtIndex:index]; [self modeChanged:self.mode]; return;
    }
    // Number row 1–7 plays a degree; with Shift it adds the degree to the progression.
    static const unsigned short digits[7]={18,19,20,21,23,22,26};
    for(int degree=0;degree<7;degree++) if(event.keyCode==digits[degree]) {
        if(flags&NSEventModifierFlagShift) [self addChord:self.addButtons[degree]]; else [self chordClicked:self.chordButtons[degree]];
        return;
    }
    switch(event.keyCode) {
        case 51: case 117: [self removeSelectedChord:nil]; break;
        case 37: [self toggleLoop:nil]; break;
        case 123: case 124: {
            int index=kv_mod(self.key.circle_index+(event.keyCode==123?-1:1),12);
            NSRange letter=[@"CDEFGAB" rangeOfString:[[self circleLabelAt:index minor:self.key.minor] substringToIndex:1]];
            [self selectIndex:index minor:self.key.minor spelling:letter.location==NSNotFound?0:(int)letter.location+1]; break;
        }
        case 125: [self.mode selectItemAtIndex:1]; [self modeChanged:self.mode]; break;
        case 126: [self.mode selectItemAtIndex:0]; [self modeChanged:self.mode]; break;
        case 49: [self togglePlayback:self]; break;
        case 17: [self playTonic:self]; break;
        case 53:   // Esc: stop everything; in a section's roll with nothing playing, back to the arranger
            if(self.viewMode==1 && self.editingSection>=0 && !kv_audio_is_playing(self.audio)) { [self showView:2]; break; }
            [self stopPlayback:nil]; break;
        default: [super keyDown:event];
    }
}
@end

/* The «Последовательность» menu: title, key equivalent, KvRoot action (a lone "-" is a separator). */
static NSArray<NSArray<NSString *> *> *KvSequenceMenu(void) {
    return @[@[T(@"Новые аккорды"),@"n",@"generateProgression:"],@[T(@"Дополнить аккордами"),@"N",@"continueProgression:"],@[T(@"Вернуть последовательность"),@"z",@"undoSequence:"],
             @[T(@"Повторить правку дорожки"),@"Z",@"redoTrack:"],@[T(@"Скопировать MIDI"),@"c",@"copyMidi:"],@[T(@"Импортировать MIDI…"),@"O",@"importMidi:"],@[T(@"Новая вариация рисунка"),@"r",@"regenerateArrangement:"],@[@"-"],
             @[T(@"Круг"),@"1",@"showCircle:"],@[T(@"Пиано-ролл"),@"2",@"showRoll:"],@[T(@"Аранжировщик"),@"3",@"showArranger:"],@[T(@"В аранжировщик"),@"A",@"sendToArranger:"],
             @[T(@"Дублировать секцию"),@"d",@"duplicateSection:"],@[T(@"Разрезать секцию по плейхеду"),@"t",@"cutSection:"],@[T(@"Экспорт MIDI песни…"),@"E",@"exportSong:"],@[@"-"],
             @[T(@"Играть / стоп    Пробел"),@"",@"togglePlayback:"],@[T(@"Повтор    L"),@"",@"toggleLoop:"],@[T(@"Метроном"),@"k",@"toggleMetronome:"],@[T(@"Ударные"),@"K",@"toggleDrums:"],@[T(@"Удалить выбранный аккорд    ⌫"),@"",@"removeSelectedChord:"]];
}
@interface KvDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, KvInterfaceHost>
@property(nonatomic) NSWindow *window;
@property(nonatomic) KvRoot *root;
@property(nonatomic) NSURL *documentURL,*pendingURL;      /* the open .tonora file; one asked for before the window was up */
@property(nonatomic) NSDictionary *savedDocument;         /* its state as last opened or saved, to tell unsaved changes */
- (void)stateSaved;
@end
@implementation KvDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSString *iconPath=[NSBundle.mainBundle pathForResource:@"Tonora" ofType:@"icns"];
    NSImage *icon=iconPath?[[NSImage alloc] initWithContentsOfFile:iconPath]:nil;
    if(icon) NSApp.applicationIconImage=icon;
    else NSLog(@"Tonora: application icon missing from bundle");
    self.root=[[KvRoot alloc] initWithFrame:NSMakeRect(0,0,1240,760)];
    [self buildMenus];
    // A fixed window sized for a MacBook: 1240×760, or 1120×680 when the screen (minus menu bar and Dock) is shorter.
    // The size follows the screen the window is on, so moving it from an external monitor to the laptop still fits.
    NSString *saved=[Defaults() stringForKey:@"windowOrigin"];
    NSScreen *screen=NSScreen.mainScreen;
    if(saved) { NSPoint origin=NSPointFromString(saved); for(NSScreen *candidate in NSScreen.screens) if(NSPointInRect(NSMakePoint(origin.x+40,origin.y+40),candidate.frame)) screen=candidate; }
    NSSize content=[KvDelegate contentSizeForScreen:screen];
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,content.width,content.height) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Tonora"; self.window.acceptsMouseMovedEvents=YES; self.window.delegate=self; self.window.releasedWhenClosed=NO;
    self.window.contentView=self.root;
    NSRect frame=self.window.frame; if(saved) frame.origin=NSPointFromString(saved);
    [self.window setFrame:[KvDelegate frame:frame clampedTo:screen] display:NO];
    if(!saved) [self.window center];
    [self.window makeKeyAndOrderFront:nil]; [self.window makeFirstResponder:[self.root viewFocus]];
    [NSApp activateIgnoringOtherApps:YES];
    if(self.pendingURL) { NSURL *url=self.pendingURL; self.pendingURL=nil; [self openDocumentURL:url]; }
}
/* The menu bar in the interface language; its items act on the current root view. */
- (void)buildMenus {
    NSMenu *menubar=[NSMenu new]; NSMenuItem *appItem=[NSMenuItem new]; [menubar addItem:appItem];
    NSMenu *appMenu=[[NSMenu alloc] initWithTitle:@"Tonora"];
    [appMenu addItemWithTitle:T(@"О программе «Tonora»") action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    NSMenuItem *credits=[[NSMenuItem alloc] initWithTitle:T(@"Инструменты — авторство и лицензии") action:@selector(showCredits:) keyEquivalent:@""]; credits.target=self; [appMenu addItem:credits];
    [appMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *settings=[[NSMenuItem alloc] initWithTitle:T(@"Настройки…") action:@selector(showSoundSettings:) keyEquivalent:@","]; settings.target=self.root; [appMenu addItem:settings];   // FX holds every setting
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:T(@"Скрыть «Tonora»") action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:T(@"Завершить «Tonora»") action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu=appMenu;
    NSMenuItem *fileItem=[NSMenuItem new]; [menubar addItem:fileItem]; NSMenu *fileMenu=[[NSMenu alloc] initWithTitle:T(@"Файл")]; fileItem.submenu=fileMenu;
    NSMenuItem *open=[[NSMenuItem alloc] initWithTitle:T(@"Открыть…") action:@selector(openDocument:) keyEquivalent:@"o"]; open.target=self; [fileMenu addItem:open];
    NSMenuItem *recentItem=[[NSMenuItem alloc] initWithTitle:T(@"Открыть недавние") action:nil keyEquivalent:@""]; NSMenu *recent=[[NSMenu alloc] initWithTitle:T(@"Открыть недавние")];
    for(NSString *path in [Defaults() arrayForKey:@"recentDocuments"]) if([path isKindOfClass:NSString.class] && [NSFileManager.defaultManager fileExistsAtPath:path]) {
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:path.lastPathComponent.stringByDeletingPathExtension action:@selector(openRecent:) keyEquivalent:@""]; item.target=self; item.representedObject=path; item.toolTip=path; [recent addItem:item]; }
    if(recent.numberOfItems) [recent addItem:NSMenuItem.separatorItem];
    NSMenuItem *clear=[[NSMenuItem alloc] initWithTitle:T(@"Очистить список") action:@selector(clearRecent:) keyEquivalent:@""]; clear.target=self; [recent addItem:clear];
    recentItem.submenu=recent; [fileMenu addItem:recentItem]; [fileMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *save=[[NSMenuItem alloc] initWithTitle:T(@"Сохранить") action:@selector(saveDocument:) keyEquivalent:@"s"]; save.target=self; [fileMenu addItem:save];
    NSMenuItem *saveAs=[[NSMenuItem alloc] initWithTitle:T(@"Сохранить как…") action:@selector(saveDocumentAs:) keyEquivalent:@"S"]; saveAs.target=self; [fileMenu addItem:saveAs];
    NSMenuItem *sequenceItem=[NSMenuItem new]; [menubar addItem:sequenceItem];
    NSMenu *sequenceMenu=[[NSMenu alloc] initWithTitle:T(@"Последовательность")]; sequenceItem.submenu=sequenceMenu;
    for(NSArray *entry in KvSequenceMenu()) {
        if(entry.count==1) { [sequenceMenu addItem:NSMenuItem.separatorItem]; continue; }
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:entry[0] action:NSSelectorFromString(entry[2]) keyEquivalent:entry[1]]; item.target=self.root; [sequenceMenu addItem:item];
    }
    NSMenuItem *windowItem=[NSMenuItem new]; [menubar addItem:windowItem]; NSMenu *windowMenu=[[NSMenu alloc] initWithTitle:T(@"Окно")]; windowItem.submenu=windowMenu;
    [windowMenu addItemWithTitle:T(@"Свернуть") action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:T(@"Масштаб") action:@selector(performZoom:) keyEquivalent:@""];
    NSMenuItem *helpItem=[NSMenuItem new]; [menubar addItem:helpItem]; NSMenu *helpMenu=[[NSMenu alloc] initWithTitle:T(@"Справка")]; helpItem.submenu=helpMenu;
    NSMenuItem *shortcuts=[[NSMenuItem alloc] initWithTitle:T(@"Сочетания клавиш") action:@selector(toggleShortcuts:) keyEquivalent:@"/"]; shortcuts.target=self.root; [helpMenu addItem:shortcuts];
    NSMenuItem *circleHelp=[[NSMenuItem alloc] initWithTitle:T(@"Квинтовый круг") action:@selector(showCircleHelp:) keyEquivalent:@""]; circleHelp.target=self.root; [helpMenu addItem:circleHelp];
    NSApp.mainMenu=menubar; NSApp.windowsMenu=windowMenu; NSApp.helpMenu=helpMenu;
}
/* A new language builds the window's view and the menus anew from the saved state; the window stays where it is. */
- (void)rebuildInterface {
    [self.root saveState];
    BOOL fx=[self replaceRoot];
    if(fx) [self.root showSoundSettings:nil];   // the language was switched in FX: it stays open, now in the new language
}
/* A new window view from the saved state (a new language, an opened file); returns whether FX was open. */
- (BOOL)replaceRoot {
    KvRoot *old=self.root; [old stopPlayback:nil]; [old silenceMidi];
    BOOL fx=old.soundPanel && old.window.attachedSheet==old.soundPanel; [old closeSound:nil];
    if(old.window.attachedSheet) [old.window endSheet:old.window.attachedSheet];
    self.root=[[KvRoot alloc] initWithFrame:old.frame];
    self.window.contentView=self.root; [self buildMenus];
    [self.window makeFirstResponder:[self.root viewFocus]];
    return fx;
}
// ---- .tonora files: open, save, recent, unsaved changes ----
- (void)stateSaved {
    if(!self.documentURL || !self.savedDocument) return;
    BOOL edited=![[self.root documentStateFromDefaults] isEqualToDictionary:self.savedDocument];
    if(self.window.documentEdited!=edited) self.window.documentEdited=edited;
}
- (void)showDocumentTitle {
    self.window.title=self.documentURL?self.documentURL.lastPathComponent.stringByDeletingPathExtension:@"Tonora"; self.window.representedURL=self.documentURL;
    self.window.documentEdited=NO;
}
- (void)rememberRecent:(NSURL *)url {
    NSMutableArray *recent=[[Defaults() arrayForKey:@"recentDocuments"] mutableCopy]?:[NSMutableArray array];
    [recent removeObject:url.path]; [recent insertObject:url.path atIndex:0]; while(recent.count>8) [recent removeLastObject];
    [Defaults() setObject:recent forKey:@"recentDocuments"]; [self buildMenus];
}
/* Unsaved changes to the open file: save them, drop them, or stay. NO means stay. */
- (BOOL)confirmDiscard {
    if(!self.documentURL || !self.window.documentEdited) return YES;
    NSAlert *alert=[NSAlert new]; alert.messageText=[NSString stringWithFormat:T(@"Сохранить изменения в «%@»?"),self.documentURL.lastPathComponent.stringByDeletingPathExtension];
    alert.informativeText=T(@"Если не сохранить, изменения после последнего сохранения пропадут."); [alert addButtonWithTitle:T(@"Сохранить")]; [alert addButtonWithTitle:T(@"Не сохранять")]; [alert addButtonWithTitle:T(@"Отмена")];
    NSModalResponse answer=[alert runModal];
    if(answer==NSAlertFirstButtonReturn) return [self writeDocumentTo:self.documentURL];
    return answer==NSAlertSecondButtonReturn;
}
- (BOOL)writeDocumentTo:(NSURL *)url {
    NSData *data=[self.root documentData];
    if(!data || ![data writeToURL:url atomically:YES]) { self.root.status.stringValue=[NSString stringWithFormat:T(@"⚠ Не удалось сохранить «%@»"),url.lastPathComponent]; return NO; }
    self.documentURL=url; self.savedDocument=[self.root documentStateFromDefaults]; [self showDocumentTitle]; [self rememberRecent:url];
    self.root.status.stringValue=[NSString stringWithFormat:T(@"Сохранено: %@"),url.lastPathComponent]; return YES;
}
- (BOOL)openDocumentURL:(NSURL *)url {
    if(!self.root) { self.pendingURL=url; return YES; }   // launched by the file: open it once the window is up
    NSDictionary *state=[KvRoot documentStateFromData:[NSData dataWithContentsOfURL:url options:0 error:NULL]];
    if(!state) { self.root.status.stringValue=[NSString stringWithFormat:T(@"⚠ «%@» не открывается как песня Tonora"),url.lastPathComponent]; return NO; }
    if(![self confirmDiscard]) return NO;
    [self.root saveState]; [KvRoot loadDocumentState:state]; [self replaceRoot];
    self.documentURL=url; self.savedDocument=[self.root documentStateFromDefaults]; [self showDocumentTitle]; [self rememberRecent:url];
    self.root.status.stringValue=[NSString stringWithFormat:T(@"Открыто: %@"),url.lastPathComponent]; return YES;
}
- (void)openDocument:(id)sender {
    (void)sender; NSOpenPanel *panel=[NSOpenPanel openPanel]; panel.title=T(@"Открыть песню Tonora");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes=@[@"tonora"];
#pragma clang diagnostic pop
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) { if(response==NSModalResponseOK && panel.URL) dispatch_async(dispatch_get_main_queue(),^{ [self openDocumentURL:panel.URL]; }); }];
}
- (void)openRecent:(NSMenuItem *)item { NSString *path=item.representedObject; if(path) [self openDocumentURL:[NSURL fileURLWithPath:path]]; }
- (void)clearRecent:(id)sender { (void)sender; [Defaults() removeObjectForKey:@"recentDocuments"]; [self buildMenus]; }
- (void)saveDocument:(id)sender { if(self.documentURL) [self writeDocumentTo:self.documentURL]; else [self saveDocumentAs:sender]; }
- (void)saveDocumentAs:(id)sender {
    (void)sender; NSSavePanel *panel=[NSSavePanel savePanel]; panel.title=T(@"Сохранить песню Tonora"); panel.prompt=T(@"Сохранить");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    panel.allowedFileTypes=@[@"tonora"];
#pragma clang diagnostic pop
    panel.nameFieldStringValue=self.documentURL.lastPathComponent?:[NSString stringWithFormat:@"Tonora · %@.tonora",[self.root keyTitle]];
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) { if(response==NSModalResponseOK && panel.URL) [self writeDocumentTo:panel.URL]; }];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item { (void)item; return YES; }
- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename { (void)sender; return [self openDocumentURL:[NSURL fileURLWithPath:filename]]; }
- (BOOL)windowShouldClose:(NSWindow *)window { (void)window; return [self confirmDiscard]; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender { (void)sender; return [self confirmDiscard]?NSTerminateNow:NSTerminateCancel; }

- (void)showCredits:(id)sender { [self.root showCredits:sender]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; [self.root silenceMidi]; [Defaults() setObject:NSStringFromPoint(self.window.frame.origin) forKey:@"windowOrigin"]; }
- (void)windowDidMove:(NSNotification *)notification { (void)notification; [Defaults() setObject:NSStringFromPoint(self.window.frame.origin) forKey:@"windowOrigin"]; }
/* Usable height below the menu bar and above the Dock; a hidden Dock still covers its strip when it pops up. */
+ (NSRect)usableFrameOfScreen:(NSScreen *)screen {
    NSRect visible=screen.visibleFrame;
    Boolean valid=false; BOOL autohide=CFPreferencesGetAppBooleanValue(CFSTR("autohide"),CFSTR("com.apple.dock"),&valid) && valid;
    CFPropertyListRef orientation=CFPreferencesCopyAppValue(CFSTR("orientation"),CFSTR("com.apple.dock"));
    BOOL bottom=!orientation || (CFGetTypeID(orientation)==CFStringGetTypeID() && CFStringCompare(orientation,CFSTR("bottom"),0)==kCFCompareEqualTo);
    if(orientation) CFRelease(orientation);
    if(autohide && bottom) { CFIndex tile=CFPreferencesGetAppIntegerValue(CFSTR("tilesize"),CFSTR("com.apple.dock"),&valid); CGFloat dock=(valid && tile>0?tile:48)+16; visible.origin.y+=dock; visible.size.height-=dock; }
    return NSInsetRect(visible,0,4);
}
+ (NSSize)contentSizeForScreen:(NSScreen *)screen {
    NSRect usable=[self usableFrameOfScreen:screen?:NSScreen.mainScreen]; CGFloat titlebar=28;
    if(1240<=usable.size.width && 760+titlebar<=usable.size.height) return NSMakeSize(1240,760);
    return NSMakeSize(KvMinWidth,KvMinHeight);
}
+ (NSRect)frame:(NSRect)frame clampedTo:(NSScreen *)screen {
    NSRect usable=[self usableFrameOfScreen:screen?:NSScreen.mainScreen];
    frame.origin.x=MAX(NSMinX(usable),MIN(frame.origin.x,NSMaxX(usable)-frame.size.width));
    frame.origin.y=MAX(NSMinY(usable),MIN(frame.origin.y,NSMaxY(usable)-frame.size.height));
    return frame;
}
- (void)windowDidResignKey:(NSNotification *)notification { (void)notification; [self.root releaseComputerKeys]; }
/* Moving the window to another display picks the size for that display (the window itself is never user-resizable). */
- (void)windowDidChangeScreen:(NSNotification *)notification {
    (void)notification; NSScreen *screen=self.window.screen; if(!screen) return;
    NSSize content=[KvDelegate contentSizeForScreen:screen]; NSRect current=[self.window contentRectForFrameRect:self.window.frame];
    if(fabs(current.size.width-content.width)<1 && fabs(current.size.height-content.height)<1) return;
    NSRect frame=[self.window frameRectForContentRect:NSMakeRect(current.origin.x,NSMaxY(current)-content.height,content.width,content.height)];
    [self.window setFrame:[KvDelegate frame:frame clampedTo:screen] display:YES animate:NO];
}
- (void)windowWillClose:(NSNotification *)notification { (void)notification; [self.root silenceMidi]; }

@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if(argc==2 && strcmp(argv[1],"--self-test")==0) {
            [NSApplication sharedApplication];
            NSString *suite=[@"ru.kvarta.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
            TNPreferences=[[NSUserDefaults alloc] initWithSuiteName:suite]; TNSetLanguage(@"ru");   // the checks below read Russian titles
            KvRoot *root=[[KvRoot alloc] initWithFrame:NSMakeRect(0,0,1120,900)];
            [root layoutSubtreeIfNeeded];
            KV_CHECK((root.instrument==KV_INSTRUMENT_STRINGS && root.performanceMode==3+KV_STRINGS_PIZZICATO-KV_STRINGS_CHORALE) || !root.stringsAvailable,@"First launch: the strings and their pizzicato");
            KV_CHECK(root.meter==KV_METER_6_8 && root.drumsOn && !root.metronomeOn,@"First launch: 6/8, the drums on, the click off");
            [root.meterChoice selectItemAtIndex:KV_METER_4_4]; [root meterChanged:root.meterChoice]; [root showSoundSettings:nil]; [root.instrumentChoice selectItemAtIndex:0]; [root instrumentChanged:root.instrumentChoice]; [root closeSound:nil];   // the checks below count in 4/4 on the piano
            for(NSNumber *height in @[@680,@760]) for(NSNumber *width in @[@1120,@1240]) {
                root.frame=NSMakeRect(0,0,width.doubleValue,height.doubleValue); NSString *problem=[root layoutProblem];
                KV_CHECK(!problem,([NSString stringWithFormat:@"Empty layout %@x%@: %@",width,height,problem]));
            }
            root.frame=NSMakeRect(0,0,1120,900); [root layout];
            KV_CHECK([root.heading.stringValue isEqualToString:@"До мажор"],@"Initial key");
            [root addChord:root.addButtons[0]]; [root addChord:root.addButtons[5]];
            [root addChord:root.addButtons[3]]; [root addChord:root.addButtons[4]];
            KV_CHECK(root.progression.count==4 && root.playButton.enabled,@"Progression enabled");
            [root selectIndex:2 minor:YES];
            KV_CHECK([root.heading.stringValue isEqualToString:@"Си минор"],@"Relative minor selection");
            KV_CHECK([root.progressionButtons[1].title isEqualToString:@"G"],@"Progression transposes by degree");
            KvRoot *restored=[[KvRoot alloc] initWithFrame:root.frame];
            KV_CHECK(restored.key.circle_index==2 && restored.key.minor && restored.progression.count==4,@"TNPreferences round trip");
            KV_CHECK([restored.progressionButtons[3].title isEqualToString:@"F♯m"],@"Restored chord");
            int tonicBefore=kv_tonic(root.key);
            [root.mode selectItemAtIndex:2]; [root modeChanged:root.mode];
            KV_CHECK(root.key.mode==1 && kv_tonic(root.key)==tonicBefore,@"Dorian preserves tonic");
            int modalScale[8]; kv_scale(root.key,modalScale);
            KV_CHECK(modalScale[5]-modalScale[0]==9 && [root.heading.stringValue containsString:@"дорийский"] && [root.signature.stringValue hasPrefix:@"При ключе"],@"Modal notes and title update");
            KvRoot *modalRestored=[[KvRoot alloc] initWithFrame:root.frame];
            KV_CHECK(modalRestored.key.mode==1 && kv_tonic(modalRestored.key)==tonicBefore,@"Mode persists across restart");
            [root.mode selectItemAtIndex:1]; [root modeChanged:root.mode];
            // User acceptance: A minor scale shows seven notes; Am shows exactly A-C-E.
            [root selectIndex:0 minor:YES]; root.keyboardMode.selectedSegment=0; [root refresh];
            KV_CHECK([root.keyboardHeading.stringValue isEqualToString:@"Ля минор · 7 нот"],@"Explicit scale heading");
            KV_CHECK([root.keyboardNotes.stringValue containsString:@"A · ля"],@"Russian and letter note names");
            int scaleKeys=0; for(int n=60;n<84;n++) scaleKeys+=[root keyboardHighlights:n];
            KV_CHECK(scaleKeys==14 && [root keyboardRoot]==9,@"Seven A minor notes in both octaves");
            KV_CHECK(![root keyboardHighlights:61],@"C sharp excluded from A minor");
            [root chordClicked:root.chordButtons[0]];
            KV_CHECK(root.keyboardMode.selectedSegment==1,@"Chord selection opens chord mode");
            int chordKeys=0; for(int n=60;n<84;n++) chordKeys+=[root keyboardHighlights:n];
            KV_CHECK(chordKeys==6 && [root keyboardHighlights:69] && [root keyboardHighlights:60] && [root keyboardHighlights:64] && ![root keyboardHighlights:62],@"Only A-C-E highlighted in both octaves");
            KV_CHECK([root.keyboardNotes.stringValue isEqualToString:@"A · ля     C · до     E · ми"],@"Exact chord note list");
            [root selectIndex:6 minor:NO]; [root chordClicked:root.chordButtons[6]];
            KV_CHECK([[root keyboardName:65] isEqualToString:@"E♯"] && [root keyboardHighlights:65],@"Enharmonic black and white key labels");
            root.keyboardMode.selectedSegment=0; [root keyboardModeChanged:nil];
            [root.mode selectItemAtIndex:1]; [root modeChanged:root.mode];
            KV_CHECK(root.key.minor && kv_tonic(root.key)==6 && [root.heading.stringValue isEqualToString:@"Фа-диез минор"],@"Minor from F-sharp major keeps the tonic (parallel minor)");
            KV_CHECK(root.audio!=NULL,@"Audio output initializes");
            KV_CHECK(kv_audio_set_effects(root.audio,(KvEffects){0,0,0.3}),@"Dry playback settings");
            // Stop must remain reliable even when no queue slot is available.
            unsigned queued=0; while(queued<128 && kv_audio_set_effects(root.audio,(KvEffects){0,0,.3})) queued++;
            KV_CHECK(queued<128,@"Command queue reaches capacity");
            kv_audio_stop(root.audio); KV_CHECK(!kv_audio_is_playing(root.audio) && kv_audio_error(root.audio)==0,@"Stop bypasses full command queue");
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.04]];
            int note=60;
            KV_CHECK(kv_audio_play(root.audio,&note,1,1,0.08),@"Short note playback starts");
            KV_CHECK(kv_audio_is_playing(root.audio),@"Short note marked playing");
            NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
            while(kv_audio_is_playing(root.audio) && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            KV_CHECK(!kv_audio_is_playing(root.audio),@"Playback completion");
            KV_CHECK(kv_audio_set_effects(root.audio,(KvEffects){.5,.3,.2}),@"Wet playback settings");
            KV_CHECK(kv_audio_play(root.audio,&note,1,1,.08),@"Wet note begins");
            NSDate *wetDeadline=[NSDate dateWithTimeIntervalSinceNow:.45];
            while(kv_audio_is_playing(root.audio) && wetDeadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
            KV_CHECK(!kv_audio_is_playing(root.audio),@"FX tail does not hold transport in Stop state");
            for(int i=0;i<24;i++) {
                KvChord chord; KV_CHECK(kv_chord((KvKey){i%12,i>=12,0,0},0,&chord),@"Chord builds");
                KV_CHECK(kv_audio_play(root.audio,chord.midi,3,3,0.1),@"Rapid replacement playback");
            }
            kv_audio_stop(root.audio); KV_CHECK(!kv_audio_is_playing(root.audio),@"Stop playback");
            for(int burst=0;burst<40;burst++) {
                KV_CHECK(kv_audio_play(root.audio,&note,1,1,.08),@"Rapid restart accepted"); kv_audio_stop(root.audio);
                KV_CHECK(!kv_audio_is_playing(root.audio),@"Rapid stop is immediate");
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
            }
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]];
            int stoppedNotes[KV_ACTIVE_NOTES]; KV_CHECK(!kv_audio_is_playing(root.audio) && kv_audio_active_notes(root.audio,stoppedNotes)==0,@"Queued playback cannot resurrect after Stop");
            KV_CHECK(!kv_audio_play(root.audio,&note,1,0,0.1),@"Reject invalid voices");
            KV_CHECK(!kv_audio_play(root.audio,&note,1,1,NAN),@"Reject invalid duration");
            NSMenuItem *remove=root.progressionButtons[1].menu.itemArray.firstObject;
            [root removeChord:remove]; KV_CHECK(root.progression.count==3,@"Remove chord");
            NSArray *beforeClear=[root.progression copy];
            [root clearProgression:nil]; BOOL drumsWere=root.drumsOn,clickWas=root.metronomeOn; if(root.drumsOn) [root toggleDrums:nil]; if(root.metronomeOn) [root toggleMetronome:nil]; [root updateTransport];
            KV_CHECK(root.progression.count==0 && !root.playButton.enabled,@"Empty progression");
            { [root toggleDrums:nil]; KV_CHECK(root.playButton.enabled,@"Empty progression: with the drums on, Play is there");   // the rhythm alone, as a DAW with an empty project
              [root togglePlayback:nil]; NSDate *until=[NSDate dateWithTimeIntervalSinceNow:1.5]; while(kv_audio_rhythm_beat(root.audio)<0 && until.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
              KV_CHECK(root.rhythmAlone && kv_audio_rhythm_beat(root.audio)>=0 && root.playButton.state==NSControlStateValueOn,@"Empty progression: Play runs the drums alone");
              [root togglePlayback:nil]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.15]]; KV_CHECK(!root.rhythmAlone && kv_audio_rhythm_beat(root.audio)<0,@"Empty progression: Space stops the rhythm");
              [root toggleDrums:nil]; }
            if(drumsWere) [root toggleDrums:nil]; if(clickWas) [root toggleMetronome:nil];
            [root undoSequence:nil]; KV_CHECK([root.progression isEqualToArray:beforeClear],@"Undo restores sequence");
            [root clearProgression:nil];
            [root showSoundSettings:nil];
            [root defaultSound:nil];
            KV_CHECK(root.instrument==(root.stringsAvailable?KV_INSTRUMENT_STRINGS:0) && root.delayDivisionIndex==1 && fabs(root.effects.reverb-.1)<.001 && fabs(root.effects.delay-.1)<.001 && fabs(root.effects.delay_seconds-30/root.tempo)<.001,@"«По умолчанию» gives piano, reverb and delay 10 % on 1/8");
            root.reverbSlider.doubleValue=23; root.delaySlider.doubleValue=31; root.delayTimeSlider.doubleValue=420;
            root.delayDivisionIndex=5; [root effectsChanged:nil];
            KV_CHECK(fabs(root.effects.reverb-0.23)<0.001 && fabs(root.effects.delay-0.31)<0.001 && fabs(root.effects.delay_seconds-0.42)<0.001,@"Effects controls apply values");
            [root selectIndex:0 minor:YES]; [root applyTempo:88]; [root clearProgression:nil];
            for(int i=0;i<8;i++) [root addChord:root.addButtons[i%7]];
            [root.generateCountChoice selectItemAtIndex:2]; [root generateCountChanged:root.generateCountChoice];
            [root generateProgression:nil];
            KV_CHECK(root.progression.count==8 && root.key.circle_index==0 && root.key.minor && root.tempo==88,@"One-click generation keeps key, length and tempo");
            NSArray *firstTake=[root.progression copy]; [root generateProgression:nil];
            KV_CHECK(root.progression.count==8 && root.sequenceUndo.count==8 && [root.sequenceUndo isEqualToArray:firstTake],@"Second click makes a new progression and keeps undo");
            for(NSNumber *degree in root.progression) {
                KvChord generated; KV_CHECK(kv_chord(root.key,degree.intValue,&generated),@"Generated chord valid");
                for(int v=0;v<3;v++) KV_CHECK(kv_contains(root.key,generated.midi[v]),@"Generated chord stays in key");
            }
            KvRoot *settingsRestored=[[KvRoot alloc] initWithFrame:root.frame];
            KV_CHECK(settingsRestored.progression.count==8 && settingsRestored.tempo==88 && fabs(settingsRestored.effects.delay-0.31)<0.001,@"Generated sequence and effects persist");
            [root shiftOctave:-1];
            KV_CHECK(root.keyboardBase==48 && root.registerControl.selectedSegment==1,@"Octave down moves keyboard");
            [root shiftOctave:1]; KV_CHECK(root.keyboardBase==60 && root.registerControl.selectedSegment==2,@"Octave up restores keyboard");
            for(int i=0;i<8;i++) [root shiftOctave:1];
            KV_CHECK(root.keyboardBase==84 && root.registerControl.selectedSegment==4,@"Upper octave bound");
            for(int i=0;i<8;i++) [root shiftOctave:-1];
            KV_CHECK(root.keyboardBase==36 && root.registerControl.selectedSegment==0,@"Lower octave bound");
            root.keyboardBase=60;
            KV_CHECK(kv_audio_set_effects(root.audio,(KvEffects){0,0,0.3}),@"Animation dry test settings");
            [root playScale:nil];
            KV_CHECK(root.visualEvents.count==8 && root.visualEvents[0].count==1,@"Scale has eight visual note events");
            { NSString *fingering=[root visualFingering]; NSArray *parts=[fingering componentsSeparatedByString:@" "];
              KV_CHECK(parts.count==2 && ([parts[0] isEqualToString:@"RRRRRRRR"] || [parts[0] isEqualToString:@"LLLLLLLL"]),@"A scale is played by one hand, not split between them");
              KV_CHECK(![parts[1] containsString:@"0"] && ([parts[1] containsString:@"31"] || [parts[1] containsString:@"41"] || [parts[1] containsString:@"13"] || [parts[1] containsString:@"14"]),@"The scale crosses the thumb instead of stopping at the second finger");
              if(root.key.circle_index==0 && !root.key.minor && root.key.mode==0 && [parts[0] hasPrefix:@"R"]) KV_CHECK([parts[1] isEqualToString:@"12312345"],@"C major scale: 1-2-3-1-2-3-4-5"); }
            NSDate *visualDeadline=[NSDate dateWithTimeIntervalSinceNow:0.5];
            while(root.visualEvent<0 && visualDeadline.timeIntervalSinceNow>0) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]]; [root updatePlaybackVisualization];
            }
            KV_CHECK(root.visualEvent>=0 && root.visualEvent<8,@"Scale animation follows audio playhead");
            [root.piano advanceAnimation];
            KV_CHECK([root.piano.accessibilityValue hasPrefix:@"Звучит:"],@"Active played key exposed");
            kv_audio_stop(root.audio); [root updatePlaybackVisualization];
            KV_CHECK([root.piano.accessibilityValue isEqualToString:@"Нет активных клавиш"],@"Stop clears animated keys");
            root.registerControl.selectedSegment=1; [root registerChanged:root.registerControl];
            KV_CHECK(root.keyboardBase==48,@"Register control selects register");
            [root circleSelected:0 minor:YES];
            KV_CHECK(root.keyboardMode.selectedSegment==0 && root.key.minor && kv_audio_is_playing(root.audio),@"Circle selects tonality mode and sounds tonic");
            [root progressionClicked:root.progressionButtons[0]];
            KV_CHECK(root.keyboardMode.selectedSegment==1,@"Progression click selects chord mode");
            [root showSoundSettings:nil];
            for(int instrument=0;instrument<KV_INSTRUMENTS;instrument++) {
                [root.instrumentChoice selectItemAtIndex:instrument]; [root instrumentChanged:root.instrumentChoice];
                KV_CHECK(root.instrument==instrument || (instrument==KV_INSTRUMENT_STRINGS && !root.stringsAvailable),@"Every instrument is available in FX");
            }
            KV_CHECK(root.stringsAvailable || getenv("TONORA_NO_STRINGS"),@"Bowed strings are bundled");
            if(root.stringsAvailable) { [root.instrumentChoice selectItemAtIndex:KV_INSTRUMENT_STRINGS]; [root instrumentChanged:root.instrumentChoice];
                KvRoot *again=[[KvRoot alloc] initWithFrame:root.frame]; KV_CHECK(again.instrument==KV_INSTRUMENT_STRINGS,@"Strings stay chosen after a restart"); [again stopPlayback:nil];
                [root.instrumentChoice selectItemAtIndex:0]; [root instrumentChanged:root.instrumentChoice];
                // A new instrument while playing: the music goes on in the new sound; the strings come in as the spiccato ostinato.
                [root.performanceChoice selectItemWithTag:1]; [root performanceChanged:root.performanceChoice]; [root playProgression:nil];
                KV_CHECK([root isPlayingProgression],@"Instrument switch: playback starts");
                [root.instrumentChoice selectItemAtIndex:KV_INSTRUMENT_STRINGS]; [root instrumentChanged:root.instrumentChoice];
                KV_CHECK([root isPlayingProgression] && root.instrument==KV_INSTRUMENT_STRINGS && root.performanceMode==3+KV_STRINGS_OSTINATO-KV_STRINGS_CHORALE,@"Instrument switch: the strings keep playing, as the spiccato ostinato");
                KV_CHECK([root.status.stringValue containsString:@"остинато"],@"Instrument switch: the status says the strings play the ostinato");
                [root.instrumentChoice selectItemAtIndex:1]; [root instrumentChanged:root.instrumentChoice];
                KV_CHECK([root isPlayingProgression] && root.instrument==1 && root.performanceMode==1,@"Instrument switch: back to a keyboard, still playing, as two hands");
                [root.instrumentChoice selectItemAtIndex:0]; [root instrumentChanged:root.instrumentChoice]; [root stopPlayback:nil]; }
            root.humanizeControl.selectedSegment=0; [root humanizeChanged:root.humanizeControl];
            KV_CHECK(root.humanize,@"Humanization enabled by default / control");
            KV_CHECK(kv_audio_error(root.audio)==0,@"Realtime engine has no callback errors");
            [root applyTempo:80]; [root playScale:nil]; double slow=root.visualEventSeconds;
            [root applyTempo:160]; KV_CHECK(fabs(slow/root.visualEventSeconds-2)<.001,@"160 BPM doubles scale speed");
            [root.delayDivision selectItemAtIndex:0]; [root divisionChanged:root.delayDivision];
            KV_CHECK(fabs(root.effects.delay_seconds-.375)<.001,@"Quarter delay at 160 BPM");
            [root.delayDivision selectItemAtIndex:2]; [root divisionChanged:root.delayDivision];
            KV_CHECK(fabs(root.effects.delay_seconds-.09375)<.001,@"Sixteenth delay at 160 BPM");
            root.delayMode.selectedSegment=1; [root delayModeChanged:root.delayMode];
            root.delayTimeSlider.doubleValue=420; [root effectsChanged:root.delayTimeSlider];
            KV_CHECK(root.delayDivision.hidden && !root.delayTimeSlider.hidden && fabs(root.effects.delay_seconds-.42)<.001,@"Milliseconds mode exposes only milliseconds");
            root.delayMode.selectedSegment=0; [root delayModeChanged:root.delayMode];
            KV_CHECK(!root.delayDivision.hidden && root.delayTimeSlider.hidden && root.delayTimeValue.hidden,@"Beats mode hides milliseconds");
            [root clearProgression:nil]; [root addChord:root.addButtons[0]]; [root addChord:root.addButtons[4]];
            [root applyTempo:160]; root.loopButton.state=NSControlStateValueOn; [root loopChanged:root.loopButton];
            KV_CHECK(root.performanceMode==1 && root.instrument<KV_INSTRUMENT_STRINGS && root.meter==KV_METER_4_4,@"The piano plays two hands in 4/4");
            [root.performanceChoice selectItemWithTag:0]; [root performanceChanged:root.performanceChoice];   // block chords: one beat each
            [root playProgression:nil];
            KV_CHECK(fabs(root.visualEventSeconds-.375)<.000001,@"160 BPM progression is one chord per 375 ms");
            KV_CHECK(root.playbackActivity!=nil,@"Playback holds background activity");
            NSDate *loopDeadline=[NSDate dateWithTimeIntervalSinceNow:2];
            while(kv_audio_event(root.audio)<4 && loopDeadline.timeIntervalSinceNow>0) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]]; [root updatePlaybackVisualization];
            }
            KV_CHECK(kv_audio_event(root.audio)>=4 && kv_audio_is_playing(root.audio),@"Loop passes two cycles without a visible window");
            KV_CHECK(root.selectedDegree==root.playingDegrees[kv_audio_event(root.audio)%2].integerValue,@"Loop visualization wraps by chord");
            [root applyTempo:80]; KV_CHECK(fabs(root.visualEventSeconds-.75)<.000001,@"80 BPM progression is one chord per 750 ms");
            [root stopPlayback:nil];
            KV_CHECK(!kv_audio_is_playing(root.audio) && root.playbackActivity==nil,@"Stop ends background playback");
            [root.playButton performClick:nil];
            KV_CHECK([((TNButton *)root.playButton).hint hasPrefix:@"Стоп"] && kv_audio_is_playing(root.audio),@"Play button transforms to Stop");
            [root.playButton performClick:nil];
            KV_CHECK([((TNButton *)root.playButton).hint hasPrefix:@"Играть"] && !kv_audio_is_playing(root.audio),@"Second click stops instead of restarting");
            KV_CHECK([root.playButton.accessibilityLabel hasPrefix:@"Играть"] && root.playButton.image!=nil && !root.playButton.title.length,@"Play is an icon whose label is read by VoiceOver");
            TNHintShow(root.playButton,root.playButton.bounds,@"Проба",YES); KV_CHECK(TNHintVisibleText()==nil,@"No hover label for a window that is not on screen"); TNHintHide(nil);
            [root.performanceChoice selectItemWithTag:1]; [root performanceChanged:root.performanceChoice];
            [root.patternChoice selectItemAtIndex:KV_WALTZ]; [root patternChanged:root.patternChoice];
            [root.meterChoice selectItemAtIndex:KV_METER_3_4]; [root meterChanged:root.meterChoice];
            KV_CHECK(!root.patternChoice.hidden && !root.fillChoice.hidden && [root keyboardCount]==36,@"Two-hand selection exposes patterns and both registers");
            [root.playButton performClick:nil];
            KV_CHECK(root.playingTwoHand && root.playingBeatsPerChord==3 && fabs(root.visualEventSeconds-2.25)<.001,@"Waltz uses three beats per chord at 80 BPM");
            [root applyTempo:160]; KV_CHECK(fabs(root.visualEventSeconds-1.125)<.001,@"Two-hand tempo changes retain meter");
            [root.playButton performClick:nil]; KV_CHECK(!kv_audio_is_playing(root.audio),@"Two-hand playback stops with the same button");
            KvRoot *performanceRestored=[[KvRoot alloc] initWithFrame:root.frame];
            KV_CHECK(performanceRestored.performanceMode==1 && performanceRestored.pianoPattern==KV_WALTZ,@"Performance settings persist");
            [root.patternChoice selectItemAtIndex:KV_DARK_JAZZ]; [root patternChanged:root.patternChoice];
            [root.playButton performClick:nil]; KV_CHECK(root.playingTwoHand && [root.arrangementInfo.stringValue containsString:@"Дарк-джаз"],@"Melodic pattern plays through existing transport");
            [root.playButton performClick:nil];
            [root.performanceChoice selectItemWithTag:0]; [root performanceChanged:root.performanceChoice];
            KV_CHECK([root keyboardCount]==24 && root.patternChoice.hidden && root.fillChoice.hidden && root.arrangeButton.hidden && root.arpeggioChoice.hidden && root.divisionChoice.hidden,@"Legacy layout restored");
            [root.harmonyChoice selectItemAtIndex:4]; [root harmonyChanged:root.harmonyChoice];
            KvChord full; KV_CHECK(kv_chord_extended(root.key,(int)root.selectedDegree,4,&full),@"Extended chord builds");
            root.keyboardMode.selectedSegment=1; [root refresh];
            for(size_t v=0;v<full.count;v++) KV_CHECK([root keyboardHighlights:full.midi[v]],@"All extension pitches are highlighted");
            NSArray *savedDegrees=[root.progression copy]; [root regenerateArrangement:nil]; uint32_t arrangementSeed=root.arrangementSeed;
            KV_CHECK(root.generatedRhythm && root.performanceMode==1 && [root.progression isEqualToArray:savedDegrees],@"Independent arrangement generation preserves harmony");
            [root.playButton performClick:nil]; KV_CHECK(root.playingTwoHand && kv_audio_is_playing(root.audio),@"Seven-note harmony plays in generated arrangement");
            [root.playButton performClick:nil]; [root.playButton performClick:nil];
            KV_CHECK(root.arrangementSeed==arrangementSeed,@"Replay preserves generated performance"); [root.playButton performClick:nil];
            KvRoot *arrangementRestored=[[KvRoot alloc] initWithFrame:root.frame];
            KV_CHECK(arrangementRestored.chordExtension==4 && arrangementRestored.generatedRhythm && arrangementRestored.arrangementSeed==arrangementSeed,@"Harmony and arrangement settings persist");
            [root.performanceChoice selectItemWithTag:0]; [root performanceChanged:root.performanceChoice];
            [root playProgression:nil]; KV_CHECK(root.visualEvents.firstObject.count==7,@"Block mode plays all seven chord tones"); [root stopPlayback:nil];
            [root selectIndex:0 minor:NO]; [root.mode selectItemAtIndex:4]; [root modeChanged:root.mode]; [root clearProgression:nil]; [root generateProgression:nil];
            KV_CHECK(root.key.mode==3 && root.mode.indexOfSelectedItem==4 && root.progression.count==(NSUInteger)root.generateCount,@"Generation uses the current modal scale and the chosen chord count");
            for(NSNumber *degree in root.progression) { KvChord generated; KV_CHECK(kv_chord(root.key,degree.intValue,&generated),@"Generated modal chord"); for(int v=0;v<3;v++) KV_CHECK(kv_contains(root.key,generated.midi[v]),@"Modal chord stays in the mode"); }
            // Arpeggio texture: three octaves from the keyboard base, one bar per chord, pattern and division persist.
            [root.performanceChoice selectItemWithTag:2]; [root performanceChanged:root.performanceChoice];
            KV_CHECK(root.performanceMode==2 && [root keyboardStart]==root.keyboardBase && [root keyboardCount]==36 && !root.arpeggioChoice.hidden && !root.divisionChoice.hidden && root.patternChoice.hidden && root.fillChoice.hidden,@"Arpeggio texture exposes its controls");
            [root.meterChoice selectItemAtIndex:KV_METER_4_4]; [root meterChanged:root.meterChoice];
            [root.arpeggioChoice selectItemAtIndex:KV_ARP_DOWN]; [root arpeggioChanged:root.arpeggioChoice];
            [root.divisionChoice selectItemAtIndex:KV_DIV_TRIPLET]; [root arpeggioDivisionChanged:root.divisionChoice];
            [root applyTempo:120]; [root.playButton performClick:nil];
            KV_CHECK(root.playingPerformance && fabs(root.visualEventSeconds-2.0)<.001 && [root.arrangementInfo.stringValue containsString:@"арпеджио вниз"] && [root.arrangementInfo.stringValue containsString:@"триоли"],@"Arpeggio plays one 4/4 bar per chord");
            [root regenerateArrangement:nil]; KV_CHECK(root.performanceMode==2 && root.generatedRhythm && kv_audio_is_playing(root.audio),@"Dice makes an arpeggio variation without leaving the texture");
            [root.playButton performClick:nil];
            KvRoot *arpRestored=[[KvRoot alloc] initWithFrame:root.frame];
            KV_CHECK(arpRestored.performanceMode==2 && arpRestored.arpeggioPattern==KV_ARP_DOWN && arpRestored.division==KV_DIV_TRIPLET,@"Arpeggio settings persist");
            [root.performanceChoice selectItemWithTag:0]; [root performanceChanged:root.performanceChoice];
            NSEvent *(^key)(unsigned short,NSEventModifierFlags)=^NSEvent *(unsigned short code,NSEventModifierFlags flags) {
                return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
            };
            // The whole circle follows the selected key: A-flat harmonic minor chosen from the outer A-flat.
            [root stopPlayback:nil]; [root circleSelected:8 minor:NO spelling:6]; [root.mode selectItemAtIndex:7]; [root modeChanged:root.mode];
            KV_CHECK([root.heading.stringValue isEqualToString:@"Ля-бемоль · гарм. минор"],@"A-flat harmonic minor heading");
            KV_CHECK([[root circleLabelAt:5 minor:YES] isEqualToString:@"A♭m"] && [[root circleLabelAt:4 minor:YES] isEqualToString:@"D♭m"] && [[root circleLabelAt:4 minor:NO] isEqualToString:@"F♭"] && [[root circleLabelAt:9 minor:NO] isEqualToString:@"E♭"],@"Circle spells the key's own chords");
            KV_CHECK([[root circleLabelAt:6 minor:YES] isEqualToString:@"E♭m"] && [[root circleLabelAt:6 minor:NO] isEqualToString:@"G♭"],@"Other black-key roots follow the flat signature");
            KV_CHECK([root.signature.stringValue hasPrefix:@"При ключе: 7 ♭"] && [root.signature.stringValue containsString:@"VII повышена: G"],@"Harmonic minor keeps the natural minor signature");
            [root circleSelected:5 minor:YES spelling:6];
            KV_CHECK(root.key.spelling==6 && [S(kv_key_root(root.key)) isEqualToString:@"A♭"] && [root.heading.stringValue isEqualToString:@"Ля-бемоль · гарм. минор"],@"Clicking the A♭m sector keeps A-flat spelling");
            KV_CHECK([[root keyboardName:66] isEqualToString:@"G♭"] && [root.keyboardHeading.stringValue isEqualToString:@"Ля-бемоль · гарм. минор · 7 нот"],@"Keyboard follows the flat key");
            [root.mode selectItemAtIndex:1]; [root modeChanged:root.mode];
            KV_CHECK([root.heading.stringValue isEqualToString:@"Ля-бемоль минор"] && [root.signature.stringValue isEqualToString:@"При ключе: 7 ♭"],@"A-flat natural minor, seven flats");
            KvRoot *spellingRestored=[[KvRoot alloc] initWithFrame:root.frame];
            KV_CHECK([spellingRestored.heading.stringValue isEqualToString:@"Ля-бемоль минор"],@"Spelling persists");
            [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; KV_CHECK([root.heading.stringValue isEqualToString:@"Ля-бемоль мажор"] && root.key.circle_index==8 && !root.key.minor,@"Major from A-flat minor is A-flat major");
            // Sharp keys spell the whole circle with sharps: F♯ melodic minor (inner F♯m picked).
            [root circleSelected:3 minor:YES spelling:0]; [root.mode selectItemAtIndex:8]; [root modeChanged:root.mode];
            KV_CHECK([[root circleLabelAt:3 minor:YES] isEqualToString:@"F♯m"] && [[root circleLabelAt:5 minor:YES] isEqualToString:@"G♯m"] && [[root circleLabelAt:5 minor:NO] isEqualToString:@"B"] && [[root circleLabelAt:7 minor:NO] isEqualToString:@"C♯"],@"F♯ melodic minor chords spelled with sharps");
            KV_CHECK([[root circleLabelAt:9 minor:NO] isEqualToString:@"D♯"] && [[root circleLabelAt:7 minor:YES] isEqualToString:@"A♯m"] && [[root circleLabelAt:8 minor:NO] isEqualToString:@"G♯"],@"Other black-key sectors follow the sharp signature");
            // Seven-accidental rule counts the written signature: D♯ melodic minor stays (6 ♯ plus accidentals B♯, C𝄪);
            // D♭ phrygian (9 ♭) is written as C♯ phrygian; D♭ melodic minor (8 ♭) as C♯ melodic minor.
            [root circleSelected:6 minor:YES spelling:0];
            KV_CHECK([root.heading.stringValue isEqualToString:@"Ре-диез · мелод. минор"] && [root.signature.stringValue isEqualToString:@"При ключе: 6 ♯ · VI, VII повышены: B♯, C𝄪"],([NSString stringWithFormat:@"D♯ melodic minor is a written key: [%@] [%@]",root.heading.stringValue,root.signature.stringValue]));
            [root circleSelected:4 minor:YES spelling:2];
            KV_CHECK([root.heading.stringValue isEqualToString:@"До-диез · мелод. минор"] && [root.signature.stringValue containsString:@"вместо ре-бемоль (8 ♭)"],@"D♭ melodic minor respelled as C♯");
            [root.mode selectItemAtIndex:1]; [root modeChanged:root.mode];
            KV_CHECK([root.heading.stringValue isEqualToString:@"До-диез минор"] && [root.signature.stringValue isEqualToString:@"При ключе: 4 ♯ · вместо ре-бемоль (8 ♭)"],@"Natural minor is still written as C♯, with the note");
            [root circleSelected:7 minor:NO spelling:0]; [root.mode selectItemAtIndex:3]; [root modeChanged:root.mode];
            KV_CHECK([root.heading.stringValue isEqualToString:@"До-диез · фригийский"] && [root.signature.stringValue isEqualToString:@"При ключе: 3 ♯ · вместо ре-бемоль (9 ♭)"],@"D♭ phrygian respelled as C♯ (A major signature)");
            KV_CHECK([root.heading.stringValue isEqualToString:@"До-диез · фригийский"],@"Still C♯ phrygian");
            [root circleSelected:5 minor:YES spelling:6];
            KV_CHECK([root.heading.stringValue isEqualToString:@"Соль-диез · фригийский"],@"A♭ phrygian (8 ♭) is written as G♯ phrygian");
            [root.mode selectItemAtIndex:1]; [root modeChanged:root.mode]; [root circleSelected:5 minor:YES spelling:6];
            KV_CHECK([root.heading.stringValue isEqualToString:@"Ля-бемоль минор"] && [root.signature.stringValue isEqualToString:@"При ключе: 7 ♭"],@"A♭ minor (7 ♭) is kept as chosen");
            [root keyDown:key(124,0)]; KV_CHECK([root.heading.stringValue isEqualToString:@"Ми-бемоль минор"],@"Right arrow lands on the sector as labelled (E♭m, not D♯m)");
            { // 0.17: chords outside the key, inversions, presets, one-key chords, MIDI import, modulation hints.
              [root.viewSwitch setSelectedSegment:0]; [root viewChanged:root.viewSwitch];
              [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; [root selectIndex:0 minor:NO];
              [root.harmonyChoice selectItemAtIndex:0]; [root harmonyChanged:root.harmonyChoice]; [root clearProgression:nil];
              // «Вне лада»: tiles, layout at the extreme sizes, selection with its story, adding.
              [root.inspectorTabs setSelectedSegment:1]; [root inspectorTabChanged:root.inspectorTabs];
              KV_CHECK(root.chromaticChips.count>=12,@"C major offers a dozen chords outside the key");
              KvChip *a7=nil; for(KvChip *chip in root.chromaticChips) if([chip.title isEqualToString:@"A7"]) a7=chip;
              KV_CHECK(a7 && !a7.hidden && [a7.degreeText isEqualToString:@"V7/ii"],@"A7 · V7/ii is a tile");
              for(NSNumber *width in @[@1120,@1728]) for(NSNumber *height in @[@680,@1000]) { root.frame=NSMakeRect(0,0,width.doubleValue,height.doubleValue); NSString *problem=[root layoutProblem];
                  KV_CHECK(!problem,([NSString stringWithFormat:@"«Вне лада» %@x%@: %@",width,height,problem])); }
              root.frame=NSMakeRect(0,0,1240,760); [root layout];
              [root chromaticClicked:a7];
              KV_CHECK(root.selectedDegree==KV_CODE_SECONDARY+1 && [root.chromaticStory.stringValue containsString:@"Dm"] && [root.keyboardHeading.stringValue containsString:@"A7"],@"A tile selects, explains and shows its chord");
              KV_CHECK([root keyboardHighlights:61] && ![root keyboardHighlights:60],@"The keyboard shows C♯, not C, for A7");
              [root addChromatic:nil]; KV_CHECK(root.progression.count==1 && root.progression[0].intValue==KV_CODE_SECONDARY+1,@"«Добавить» adds the selected chord outside the key");
              { // A full sequence: «8 из 8» until a slot is picked, then «Заменить N-й» puts the chord there; ⌘Z undoes it.
                NSArray *before=[root.progression copy]; for(int i=1;i<8;i++) [root addChordCode:i%7];
                root.selectedChip=-1; [root chromaticClicked:a7];
                KV_CHECK(root.progression.count==8 && !root.chromaticAddButton.enabled && [root.chromaticAddButton.title isEqualToString:@"8 из 8"],@"Full: the button says 8 of 8 and why");
                [root progressionClicked:(NSButton *)root.progressionButtons[2]]; [root chromaticClicked:a7];
                KV_CHECK(root.chromaticAddButton.enabled && [root.chromaticAddButton.title isEqualToString:@"Заменить 3-й"],@"With a slot picked it offers to replace it");
                [root addChromatic:nil]; KV_CHECK(root.progression.count==8 && root.progression[2].intValue==KV_CODE_SECONDARY+1,@"«Заменить 3-й» puts A7 in slot 3");
                [root undoSequence:nil]; KV_CHECK(root.progression[2].intValue==2,@"⌘Z takes the replacement back");
                [root clearProgression:nil]; for(NSNumber *code in before) [root addChordCode:code.intValue]; root.selectedChip=-1; }
              // Inversion from the chip's menu.
              NSMenuItem *third=nil; for(NSMenuItem *item in root.progressionButtons[0].menu.itemArray) if(item.submenu) third=[item.submenu itemAtIndex:1];
              KV_CHECK(third && [root validateMenuItem:third],@"The chip's menu offers inversions");
              [root setInversion:third]; KV_CHECK(kv_code_inversion(root.progression[0].intValue)==1 && [root.progressionButtons[0].title isEqualToString:@"A7/C♯"],@"Third in the bass: A7/C♯");
              KV_CHECK(root.track->count>0,@"A progression with a chord outside the key arranges");
              [root saveState]; KvRoot *again=[[KvRoot alloc] initWithFrame:root.frame];
              KV_CHECK(again.progression.count==1 && again.progression[0].intValue==root.progression[0].intValue,@"Chords outside the key and inversions survive a restart");
              // Presets: the Andalusian cadence needs minor; ⌘Z brings the previous progression back.
              [root.inspectorTabs setSelectedSegment:0]; [root inspectorTabChanged:root.inspectorTabs];
              NSInteger andalusian=-1; for(NSInteger i=0;i<(NSInteger)(sizeof(KvPresets)/sizeof(KvPresets[0]));i++) if(!strcmp(KvPresets[i].name,"Андалузская каденция")) andalusian=i;
              NSMenuItem *pick=[[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""]; pick.tag=andalusian; [root applyPreset:pick];
              NSMutableArray *names=[NSMutableArray array]; for(NSButton *chip in root.progressionButtons) [names addObject:chip.title];
              KV_CHECK(root.key.minor && kv_tonic(root.key)==0 && [[names componentsJoinedByString:@" "] isEqualToString:@"Cm B♭ A♭ G"],([NSString stringWithFormat:@"Andalusian cadence in C minor: %@",names]));
              [root undoSequence:nil]; KV_CHECK(root.progression.count==1,@"⌘Z returns the previous progression");
              for(NSInteger i=0;i<(NSInteger)(sizeof(KvPresets)/sizeof(KvPresets[0]));i++) { pick.tag=i; [root applyPreset:pick];
                  KV_CHECK(root.progression.count==(NSUInteger)KvPresets[i].count && root.track->count>0,([NSString stringWithFormat:@"Preset «%@» applies and arranges",S(KvPresets[i].name)])); }
              // One key, one chord; shared notes hold until the last key is up.
              [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; [root selectIndex:0 minor:NO];
              root.chordKeys=YES; [root midiNote:62 velocity:100 on:YES];
              KV_CHECK([root isSounding:62] && [root isSounding:65] && [root isSounding:69] && [root.midiChordLabel.stringValue hasPrefix:@"Dm"],@"One key, D, plays and names Dm");
              [root midiNote:65 velocity:100 on:YES]; [root midiNote:62 velocity:0 on:NO];
              KV_CHECK(![root isSounding:62] && [root isSounding:65] && [root isSounding:69] && [root isSounding:72],@"F still holds F A C after D is let go");
              [root midiNote:65 velocity:0 on:NO]; BOOL silent=YES; for(int m=0;m<128;m++) if([root isSounding:m]) silent=NO; KV_CHECK(silent,@"All keys up: silence");
              [root midiNote:61 velocity:100 on:YES]; KV_CHECK([root isSounding:61] && ![root isSounding:65],@"A key outside the scale plays one note"); [root midiNote:61 velocity:0 on:NO];
              root.chordKeys=NO;
              // MIDI import: our own file in A minor, 3/4, 92 BPM comes back as key, meter, tempo, chords and track.
              { KvKey am={0,true,0,0,NO}; KvChord chords[4]; const int degrees[]={0,3,4,0};
                for(int i=0;i<4;i++) { kv_chord_extended(am,degrees[i],0,&chords[i]); for(size_t v=0;v<chords[i].count;v++) chords[i].midi[v]-=12; }
                KvArrangement arr={.style=KV_BALLAD,.meter=KV_METER_3_4,.length=KV_LENGTH_BAR,.fills=KV_FILL_NONE,.seconds_per_beat=.6};
                KvPerformance plan; KV_CHECK(kv_arrange_with(chords,4,48,am,arr,&plan),@"Import fixture arranges");
                static uint8_t file[1<<16]; size_t size=kv_midi_encode(&plan,92,3,2,0,YES,0,"Импорт",file,sizeof(file));
                KV_CHECK([root importMidiData:[NSData dataWithBytes:file length:size] name:@"test.mid"],@"Import succeeds");
                KV_CHECK(kv_tonic(root.key)==9 && root.key.minor && root.meter==KV_METER_3_4 && root.tempo==92 && root.viewMode==1 && root.trackEdited && root.track->count==plan.count,@"Import finds A minor, 3/4, 92 BPM and shows the file's notes in the roll");
                NSMutableArray *found=[NSMutableArray array]; for(NSButton *chip in root.progressionButtons) [found addObject:chip.title];
                KV_CHECK([[found componentsJoinedByString:@" "] isEqualToString:@"Am Dm Em Am"],([NSString stringWithFormat:@"Import finds the chords bar by bar: %@",found]));
                KV_CHECK([root.status.stringValue containsString:@"Ля минор"],([NSString stringWithFormat:@"Import status names the key: %@",root.status.stringValue]));
                KV_CHECK(![root importMidiData:[NSData dataWithBytes:"MThd" length:4] name:@"broken.mid"] && [root.status.stringValue containsString:@"не читается"],@"A broken file is refused with a message");
                { KvPianoEvent events[60]; const int roots[]={60,57,65,67};   // twenty bars of whole-note triads: kept to sixteen, with a note
                  for(int bar=0;bar<20;bar++) for(int v=0;v<3;v++) events[bar*3+v]=(KvPianoEvent){roots[bar%4]+(v==0?0:v==1?(bar%4==1?3:4):7),bar*4.0,4,.8f,0,1,0};
                  size=kv_midi_encode_events(events,60,80,100,4,2,0,NO,0,"Long",file,sizeof(file));
                  KV_CHECK(size && [root importMidiData:[NSData dataWithBytes:file length:size] name:@"long.mid"],@"A twenty-bar file imports");
                  double last=0; for(size_t i=0;i<root.track->count;i++) last=fmax(last,root.track->events[i].beat);
                  KV_CHECK([root.status.stringValue containsString:@"(из 20)"] && root.progression.count==8 && last<64,([NSString stringWithFormat:@"Long file is cut to 16 bars with a note: %@",root.status.stringValue])); }
                [root.viewSwitch setSelectedSegment:0]; [root viewChanged:root.viewSwitch]; }
              // Modulation: from C to G the shared chords are C, Em, G, Am; the pivot is Am (vi → ii), then D7 → G.
              [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; [root selectIndex:0 minor:NO];
              unsigned masks[2]={0}; NSString *how=[root modulationTo:1 minor:NO masks:masks];
              KV_CHECK([how hasPrefix:@"Переход в Соль мажор"] && [how containsString:@"Am (vi → ii)"] && [how containsString:@"Опорный: Am"] && [how containsString:@"D7 → G"],([NSString stringWithFormat:@"Modulation hint: %@",how]));
              KV_CHECK((masks[0]&1u) && (masks[0]&2u) && (masks[1]&1u) && (masks[1]&2u),@"The shared chords' sectors are marked");
              [root clearProgression:nil];
              // Chord count by the wand, and continuing: 4 + «Дополнить: ещё 4» = 8, the first four kept; 6 + 2; ⌘Z back.
              [root.generateCountChoice selectItemAtIndex:0]; [root generateCountChanged:root.generateCountChoice]; [root generateProgression:nil];
              KV_CHECK(root.progression.count==4 && [root continueCount]==4,@"The wand makes 4 and offers 4 more");
              { uint32_t seed=root.arrangementSeed; NSArray *take=[root.progression copy]; [root generateProgression:nil];
                KV_CHECK(root.generatedRhythm && root.arrangementSeed!=seed,@"Each new progression comes with a new arrangement variation");
                NSMutableSet *starts=[NSMutableSet set]; for(int i=0;i<24;i++) { [root generateProgression:nil]; [starts addObject:root.progression[0]]; }
                KV_CHECK(starts.count>=2,@"New progressions do not always open on the same chord"); (void)take; }
              NSArray *four=[root.progression copy]; [root continueProgression:nil];
              KV_CHECK(root.progression.count==8 && [[root.progression subarrayWithRange:NSMakeRange(0,4)] isEqualToArray:four] && [root continueCount]==0,@"«Дополнить» adds four after the first four");
              KV_CHECK(root.progression[4].intValue!=root.progression[3].intValue,@"The continuation does not start on the chord before it");
              [root undoSequence:nil]; KV_CHECK([root.progression isEqualToArray:four],@"⌘Z takes the continuation back");
              [root.generateCountChoice selectItemAtIndex:1]; [root generateCountChanged:root.generateCountChoice]; [root generateProgression:nil];
              KV_CHECK(root.progression.count==6 && [root continueCount]==2,@"Six chords, two more offered"); [root continueProgression:nil]; KV_CHECK(root.progression.count==8,@"…and filled to eight");
              [root clearProgression:nil]; [root.generateCountChoice selectItemAtIndex:0]; [root generateCountChanged:root.generateCountChoice]; }
            // Whole-circle consistency across every reachable key and mode.
            for(int minor=0;minor<2;minor++) for(int index=0;index<12;index++) for(NSInteger choice=0;choice<9;choice++) {
                [root circleSelected:index minor:minor spelling:0]; [root.mode selectItemAtIndex:choice]; [root modeChanged:root.mode];
                KV_CHECK(abs([root writtenSignature])<=7,([NSString stringWithFormat:@"Never more than seven accidentals: %@ %@",root.heading.stringValue,root.signature.stringValue]));
                int signature=[root writtenSignature];
                for(int i=0;i<12;i++) for(int ring=0;ring<2;ring++) {
                    NSString *label=[root circleLabelAt:i minor:ring]; int tonic=kv_tonic((KvKey){i,ring,0,0}); BOOL chord=NO;
                    for(int degree=0;degree<7;degree++) { KvChord c; kv_chord(root.key,degree,&c); if(c.midi[2]-c.midi[0]==7 && c.midi[0]%12==tonic && (c.midi[1]-c.midi[0]==3)==ring) { chord=YES; KV_CHECK([label isEqualToString:S(c.name)],@"Key chord sector carries the chord's own name"); } }
                    if(!chord && signature) { BOOL black=tonic==1||tonic==3||tonic==6||tonic==8||tonic==10; if(black) KV_CHECK([label containsString:signature<0?@"♭":@"♯"],@"Black-key sectors follow the signature direction"); }
                }
                KV_CHECK([[root keyboardName:kv_tonic(root.key)+60] isEqualToString:S(kv_key_root(root.key))],@"Keyboard spells the tonic like the key");
            }
            [root circleSelected:0 minor:NO spelling:0]; [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode];
            [root circleSelected:0 minor:NO spelling:0]; [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode];
            KV_CHECK([[root circleLabelAt:9 minor:NO] isEqualToString:@"E♭"] && [[root circleLabelAt:7 minor:YES] isEqualToString:@"B♭m"] && [[root circleLabelAt:6 minor:NO] isEqualToString:@"F♯"],@"C major keeps the usual circle names");
            [root circleSelected:8 minor:NO spelling:6];
            // In every mode the picked sector stays selected: outer A♭ remains the tonic through all nine modes.
            for(NSInteger choice=2;choice<9;choice++) {
                [root.mode selectItemAtIndex:choice]; [root modeChanged:root.mode];
                BOOL respelled=choice==3 || choice==6; // phrygian and locrian from A♭ would need 8–9 flats, so they are written from G♯
                KV_CHECK(root.key.circle_index==8 && !root.key.minor && kv_tonic(root.key)==8 && [root.heading.stringValue hasPrefix:respelled?@"Соль-диез · ":@"Ля-бемоль · "] && [[root circleLabelAt:8 minor:NO] isEqualToString:respelled?@"G♯":@"A♭"],@"Mode change keeps the picked A♭ sector");
            }
            [root circleSelected:2 minor:YES spelling:0]; KV_CHECK(root.key.circle_index==2 && root.key.minor && root.key.mode==7 && kv_tonic(root.key)==11,@"Clicking inner Bm in melodic minor selects B melodic minor there");
            [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode];
            [root selectIndex:0 minor:NO];
            // 0.15 behaviour: unified tempo, meter/length/fills, chips, restart on change, migration.
            [root stopPlayback:nil]; [root clearProgression:nil];
            [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; [root.harmonyChoice selectItemAtIndex:0]; [root harmonyChanged:root.harmonyChoice];
            [root keyDown:key(18,NSEventModifierFlagShift)]; [root keyDown:key(23,NSEventModifierFlagShift)]; [root keyDown:key(26,NSEventModifierFlagShift)];
            KV_CHECK([root.progression isEqualToArray:(@[@0,@4,@6])],@"Shift+1/5/7 add degrees");
            [root keyDown:key(21,0)]; KV_CHECK(root.selectedDegree==3 && root.keyboardMode.selectedSegment==1,@"Digit 4 plays the fourth degree");
            [root progressionClicked:root.progressionButtons[1]]; KV_CHECK(root.selectedChip==1 && root.progressionButtons[1].state==NSControlStateValueOn,@"Clicking a chip selects it");
            [root keyDown:key(124,NSEventModifierFlagCommand)]; KV_CHECK([root.progression isEqualToArray:(@[@0,@6,@4])] && root.selectedChip==2,@"Cmd+Right moves the selected chord");
            [root applyTempo:120]; [root layout];
            [root chip:root.progressionButtons[2] droppedAt:root.metrics.cx+5]; KV_CHECK([root.progression isEqualToArray:(@[@4,@0,@6])],@"Dragging a chip to the first slot reorders");
            [root keyDown:key(51,0)]; KV_CHECK(root.selectedChip==0 && [root.progression isEqualToArray:(@[@0,@6])],@"Delete removes the selected (dragged) chord");
            [root undoSequence:nil]; KV_CHECK(root.progression.count==3,@"Undo restores a deleted chord");
            [root progressionClicked:root.progressionButtons[2]]; NSNumber *selectedDegree=root.progression[2];
            NSMenuItem *removeFirst=root.progressionButtons[0].menu.itemArray.firstObject; [root removeChord:removeFirst];
            KV_CHECK(root.selectedChip==1 && [root.progression[1] isEqual:selectedDegree],@"Removing a chord to the left keeps the same chord selected");
            [root undoSequence:nil]; KV_CHECK(root.progression.count==3,@"Undo after remove");
            [root.performanceChoice selectItemWithTag:0]; [root performanceChanged:root.performanceChoice];
            [root.meterChoice selectItemAtIndex:KV_METER_4_4]; [root meterChanged:root.meterChoice];
            [root.lengthChoice selectItemAtIndex:KV_LENGTH_BAR]; [root lengthChanged:root.lengthChoice];
            [root playProgression:nil]; KV_CHECK(root.playingPerformance && fabs(root.visualEventSeconds-2.0)<.001,@"Block chords: one bar of 4/4 at 120 BPM lasts 2 s");
            NSDate *chipDeadline=[NSDate dateWithTimeIntervalSinceNow:1];
            while(root.currentChip<0 && chipDeadline.timeIntervalSinceNow>0) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]]; [root updatePlaybackVisualization]; }
            KV_CHECK(root.currentChip==0 && ((KvChip *)root.progressionButtons[0]).current,@"The sounding chord is highlighted in the progression");
            [root.meterChoice selectItemAtIndex:KV_METER_6_8]; [root meterChanged:root.meterChoice];
            KV_CHECK(kv_audio_is_playing(root.audio) && fabs(root.playingBeatsPerChord-3)<1e-9 && fabs(root.visualEventSeconds-1.5)<.001,@"Changing meter restarts playback with the new bar");
            [root.performanceChoice selectItemWithTag:1]; [root performanceChanged:root.performanceChoice];
            [root.lengthChoice selectItemAtIndex:KV_LENGTH_BEAT]; [root lengthChanged:root.lengthChoice];
            KV_CHECK(kv_audio_is_playing(root.audio) && root.playingTwoHand && fabs(root.visualEventSeconds-.75)<.001,@"Two hands, one dotted-quarter beat per chord in 6/8");
            [root.lengthChoice selectItemAtIndex:KV_LENGTH_BAR]; [root lengthChanged:root.lengthChoice];
            // Restart follows the sounding chord through an edit: moving it to the end resumes on it.
            [root highlightChip:1]; NSNumber *sounding=root.progression[1];
            [root moveChordFrom:1 to:2]; KV_CHECK(kv_audio_is_playing(root.audio) && root.playOffset==2 && [root.progression[2] isEqual:sounding],@"Restart after a move resumes on the same chord");
            [root selectIndex:root.key.circle_index+1 minor:root.key.minor]; KV_CHECK(kv_audio_is_playing(root.audio),@"Changing key while playing restarts in the new key");
            [root stopPlayback:nil]; KV_CHECK(root.currentChip==-1 && !((KvChip *)root.progressionButtons[0]).current,@"Stop clears the progression highlight");
            [root regenerateArrangement:nil]; uint32_t seed=root.arrangementSeed;
            [root.patternChoice selectItemAtIndex:KV_TRIP_HOP]; [root patternChanged:root.patternChoice];
            KV_CHECK(root.generatedRhythm && root.arrangementSeed==seed && root.pianoPattern==KV_TRIP_HOP,@"A style change keeps the variation");
            [root.patternChoice selectItemAtIndex:KV_PATTERN_COUNT+1]; [root patternChanged:root.patternChoice];
            KV_CHECK(!root.generatedRhythm && root.patternChoice.indexOfSelectedItem==KV_TRIP_HOP,@"Template item returns to the written style");
            [root.fillChoice selectItemAtIndex:KV_FILL_EVERY_2]; [root fillChanged:root.fillChoice];
            KvRoot *meterRestored=[[KvRoot alloc] initWithFrame:root.frame];
            KV_CHECK(meterRestored.meter==KV_METER_6_8 && meterRestored.chordLengthHands==KV_LENGTH_BAR && meterRestored.chordLengthBlocks==KV_LENGTH_BAR && meterRestored.fillRate==KV_FILL_EVERY_2,@"Meter, chord lengths and fills persist");
            [root toggleLoop:nil]; BOOL loopAfter=root.loopEnabled; [root toggleLoop:nil]; KV_CHECK(loopAfter!=root.loopEnabled,@"L toggles repeat");
            NSUserDefaults *legacy=[[NSUserDefaults alloc] initWithSuiteName:[suite stringByAppendingString:@".legacy"]];
            [legacy setBool:YES forKey:@"twoHandPiano"]; [legacy setInteger:KV_WALTZ forKey:@"pianoPattern"];
            NSUserDefaults *current=TNPreferences; TNPreferences=legacy;
            KvRoot *migrated=[[KvRoot alloc] initWithFrame:root.frame];
            KV_CHECK(migrated.meter==KV_METER_3_4 && migrated.chordLengthHands==KV_LENGTH_BAR && migrated.chordLengthBlocks==KV_LENGTH_BEAT && migrated.fillRate==KV_FILL_STYLE,@"0.14 waltz settings migrate to 3/4");
            TNPreferences=current; [legacy removePersistentDomainForName:[suite stringByAppendingString:@".legacy"]];
            // Layout acceptance: dense harmony, eight chords, both textures, MacBook and external display sizes.
            [root clearProgression:nil]; [root.mode selectItemAtIndex:7]; [root modeChanged:root.mode];
            [root.harmonyChoice selectItemAtIndex:4]; [root harmonyChanged:root.harmonyChoice];
            for(NSNumber *degree in @[@0,@5,@3,@4,@1,@4,@5,@6]) [root addChord:root.addButtons[degree.integerValue]];
            [root chordClicked:root.chordButtons[6]];
            for(NSInteger texture=0;texture<3;texture++) {
                [root.performanceChoice selectItemWithTag:texture]; [root performanceChanged:root.performanceChoice];
                for(NSNumber *width in @[@1120,@1280,@1440,@1512,@1728]) for(NSNumber *height in @[@680,@705,@777,@837,@1000]) {
                    root.frame=NSMakeRect(0,0,width.doubleValue,height.doubleValue); NSString *problem=[root layoutProblem];
                    KV_CHECK(!problem,([NSString stringWithFormat:@"Layout %@x%@ texture %ld: %@",width,height,(long)texture,problem]));
                }
            }
            KV_CHECK(!root.generateSequenceButton.hidden && NSMaxX(root.generateSequenceButton.frame)<=NSMinX(root.undoSequenceButton.frame) && root.generateSequenceButton.action==@selector(generateProgression:),@"Generation is one click in the progression row");
            // MIDI tab: layout at the extremes, export to a file, chord recognition from an external keyboard.
            [root.inspectorTabs setSelectedSegment:2]; [root inspectorTabChanged:root.inspectorTabs];
            KV_CHECK(root.heading.hidden && root.chordButtons[0].hidden && !root.midiExportButton.hidden && !root.midiDestination.hidden,@"MIDI tab replaces the chord list");
            for(NSNumber *width in @[@1120,@1728]) for(NSNumber *height in @[@680,@1000]) {
                root.frame=NSMakeRect(0,0,width.doubleValue,height.doubleValue); NSString *problem=[root layoutProblem];
                KV_CHECK(!problem,([NSString stringWithFormat:@"MIDI tab layout %@x%@: %@",width,height,problem]));
            }
            KV_CHECK([root.midiDestination.itemTitles.firstObject containsString:@"Tonora"],@"Virtual MIDI port is always the first destination");
            NSString *midiPath=[NSTemporaryDirectory() stringByAppendingPathComponent:@"tonora-selftest.mid"];
            KV_CHECK([root exportMidiToPath:midiPath],@"MIDI export writes a file");
            NSData *midiData=[NSData dataWithContentsOfFile:midiPath];
            KV_CHECK(midiData.length>200 && memcmp(midiData.bytes,"MThd",4)==0 && ((const uint8_t *)midiData.bytes)[11]==3,@"Exported file is a three-track SMF");
            [NSFileManager.defaultManager removeItemAtPath:midiPath error:NULL];
            [root selectIndex:0 minor:NO]; [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; [root clearProgression:nil];
            [root midiNote:57 velocity:90 on:YES]; [root midiNote:60 velocity:90 on:YES]; [root midiNote:64 velocity:90 on:YES];
            KV_CHECK([root.midiChordLabel.stringValue hasPrefix:@"Am"] && [root.midiChordLabel.stringValue containsString:@"vi"] && root.detectedDegree==5 && root.midiAddChordButton.enabled,@"Held A–C–E is named Am, degree vi of C major");
            [root addDetectedChord:nil]; KV_CHECK([root.progression isEqualToArray:@[@5]],@"Detected chord is added to the progression");
            [root midiNote:57 velocity:0 on:NO]; [root midiNote:60 velocity:0 on:NO];
            KV_CHECK([root.midiChordLabel.stringValue isEqualToString:@"E4"] && root.detectedDegree==-1 && !root.midiAddChordButton.enabled,@"A single held note shows its name");
            [root midiNote:64 velocity:0 on:NO]; KV_CHECK([root.midiChordLabel.stringValue isEqualToString:@"—"],@"Released notes clear the display");
            [root.inspectorTabs setSelectedSegment:0]; [root inspectorTabChanged:root.inspectorTabs];
            KV_CHECK(!root.heading.hidden && root.midiExportButton.hidden,@"Chord tab restored");
            // Hands: while a two-hand texture plays, both hands press at least one finger.
            root.frame=NSMakeRect(0,0,1240,760); [root layout]; KV_CHECK([root.circle handsVisible],@"Hands fit beside the circle");
            for(NSNumber *degree in @[@0,@3,@4,@0]) [root addChord:root.addButtons[degree.integerValue]];
            [root.performanceChoice selectItemWithTag:1]; [root performanceChanged:root.performanceChoice];
            [root.patternChoice selectItemAtIndex:KV_FLOWING]; [root patternChanged:root.patternChoice]; [root applyTempo:160];
            [root playProgression:nil]; BOOL leftSeen=NO,rightSeen=NO; NSDate *handDeadline=[NSDate dateWithTimeIntervalSinceNow:2.5];
            while((!leftSeen || !rightSeen) && handDeadline.timeIntervalSinceNow>0) {
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]]; [root updateHands];
                if([root.circle pressedFingersForHand:0]) leftSeen=YES; if([root.circle pressedFingersForHand:1]) rightSeen=YES;
            }
            KV_CHECK(leftSeen && rightSeen,@"Both hands animate during a two-hand performance");
            [root stopPlayback:nil]; [root updateHands];
            KV_CHECK([root.circle pressedFingersForHand:0]==0 && [root.circle pressedFingersForHand:1]==0,@"Stop releases every finger");
            { // Arpeggio: keys and fingers follow the sound note by note, and the right hand uses several fingers, not one.
              NSInteger savedTexture=root.performanceChoice.selectedTag;
              [root.performanceChoice selectItemWithTag:2]; [root performanceChanged:root.performanceChoice]; [root playProgression:nil];
              BOOL used[5]={NO},keysInStep=YES,fingersInStep=YES,before[128]={NO},late[128]={NO},bare[128]={NO};   /* late: key up while sounding last frame; bare: no finger last frame */ NSDate *end=[NSDate dateWithTimeIntervalSinceNow:2.5];
              while(end.timeIntervalSinceNow>0) {
                  [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0/60]];
                  [root updatePlaybackVisualization]; [root.piano advanceAnimation]; [root updateHands]; [root.circle advanceFingers];
                  int active[KV_ACTIVE_NOTES]; unsigned n=kv_audio_active_notes(root.audio,active); BOOL now[128]={NO},lateNow[128]={NO},bareNow[128]={NO};
                  // The audio thread is sampled a moment apart from the screen: one frame of mismatch as a note ends is jitter, two are a bug.
                  for(unsigned i=0;i<n;i++) { int m=active[i]; now[m]=YES; if(before[m] && [root.piano levelOf:m]<.5) { if(late[m]) keysInStep=NO; lateNow[m]=YES; }
                      BOOL fingered=NO; for(int h=0;h<2;h++) for(int f=0;f<5;f++) if([root.circle noteOfFinger:f hand:h]==m) fingered=YES;
                      if(!fingered) { if(bare[m]) fingersInStep=NO; bareNow[m]=YES; } }   // a note just struck may wait one frame for its finger
                  for(int f=0;f<5;f++) if([root.circle noteOfFinger:f hand:1]>=0) used[f]=YES;
                  memcpy(before,now,sizeof(now)); memcpy(late,lateNow,sizeof(lateNow)); memcpy(bare,bareNow,sizeof(bareNow));
              }
              int distinct=0; for(int f=0;f<5;f++) if(used[f]) distinct++;
              KV_CHECK(keysInStep,@"A key stays down for as long as its note sounds");
              KV_CHECK(fingersInStep,@"Every sounding note has a finger on it");
              KV_CHECK(distinct>=3,@"The arpeggio's right hand uses at least three fingers");
              [root stopPlayback:nil];
              // The case reported on 22 October: ninth chords, broken pattern, sixteenths, two bars per chord, a seeded
              // variation with a pedal tone — the little finger held the pedal and the thumb played everything else.
              { NSInteger savedHarmony=root.harmonyChoice.indexOfSelectedItem,savedArp=root.arpeggioChoice.indexOfSelectedItem,savedDiv=root.divisionChoice.indexOfSelectedItem,savedLen=root.lengthChoice.indexOfSelectedItem;
                uint32_t savedSeed=root.arrangementSeed; BOOL savedGen=root.generatedRhythm;
                [root.harmonyChoice selectItemAtIndex:2]; [root harmonyChanged:root.harmonyChoice];
                [root.arpeggioChoice selectItemAtIndex:KV_ARP_BROKEN]; [root arpeggioChanged:root.arpeggioChoice];
                [root.divisionChoice selectItemAtIndex:KV_DIV_SIXTEENTH]; [root divisionChanged:root.divisionChoice];
                [root.lengthChoice selectItemAtIndex:KV_LENGTH_TWO_BARS]; [root lengthChanged:root.lengthChoice];
                root.arrangementSeed=2858447401u; root.generatedRhythm=YES; [root buildTrack]; [root playProgression:nil];
                BOOL usedR[5]={NO},all=YES; NSDate *until=[NSDate dateWithTimeIntervalSinceNow:2.5];
                while(until.timeIntervalSinceNow>0) {
                    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0/60]]; [root updatePlaybackVisualization]; [root updateHands];
                    int active[KV_ACTIVE_NOTES]; unsigned n=kv_audio_active_notes(root.audio,active);
                    for(unsigned i=0;i<n;i++) { BOOL fingered=NO; for(int h=0;h<2;h++) for(int f=0;f<5;f++) if([root.circle noteOfFinger:f hand:h]==active[i]) fingered=YES; if(!fingered) all=NO; }
                    for(int f=0;f<5;f++) if([root.circle noteOfFinger:f hand:1]>=0) usedR[f]=YES;
                }
                int d=0; for(int f=0;f<5;f++) if(usedR[f]) d++;
                KV_CHECK(all && d>=3,@"Pedal-tone arpeggio variation: every note fingered, right hand on three or more fingers");
                [root stopPlayback:nil]; root.arrangementSeed=savedSeed; root.generatedRhythm=savedGen;
                [root.harmonyChoice selectItemAtIndex:savedHarmony]; [root harmonyChanged:root.harmonyChoice]; [root.arpeggioChoice selectItemAtIndex:savedArp]; [root arpeggioChanged:root.arpeggioChoice];
                [root.divisionChoice selectItemAtIndex:savedDiv]; [root divisionChanged:root.divisionChoice]; [root.lengthChoice selectItemAtIndex:savedLen]; [root lengthChanged:root.lengthChoice]; }
              [root.performanceChoice selectItemWithTag:savedTexture]; [root performanceChanged:root.performanceChoice]; }
            { // Keys pressed by hand — MIDI or on-screen — sound but move no fingers.
              for(int m=0;m<128;m++) [root midiNote:m velocity:0 on:NO];
              const int keys[3]={60,64,67}; for(int i=0;i<3;i++) [root midiNote:keys[i] velocity:90 on:YES];
              [root updateHands]; KV_CHECK([root.circle pressedFingersForHand:0]==0 && [root.circle pressedFingersForHand:1]==0,@"MIDI keys pressed by hand move no fingers");
              for(int i=0;i<3;i++) [root midiNote:keys[i] velocity:0 on:NO];
              int one=0; [root playNotes:&one count:1 voices:1 duration:.4]; [root updateHands];
              KV_CHECK([root.circle pressedFingersForHand:0]==0 && [root.circle pressedFingersForHand:1]==0,@"An on-screen key moves no fingers"); [root stopPlayback:nil]; }
            { // Computer keyboard as in Ableton.
              BOOL was=root.computerKeyboard; root.computerKeyboard=NO; root.computerBase=60; root.computerVelocity=100;
              NSEvent *(^key)(unsigned short,BOOL)=^NSEvent *(unsigned short code,BOOL down) { return [NSEvent keyEventWithType:down?NSEventTypeKeyDown:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code]; };
              [root keyDown:key(46,YES)]; KV_CHECK(root.computerKeyboard,@"M turns the computer keyboard on");
              KV_CHECK(root.computerBase==root.keyboardBase,@"Switched on, the computer keyboard starts at the register"); root.computerBase=60;
              [root keyDown:key(0,YES)]; KV_CHECK([root isHeld:60],@"A plays C4 and holds it");
              [root keyDown:key(13,YES)]; KV_CHECK([root isHeld:61],@"W plays C♯4");
              [root keyUp:key(0,NO)]; KV_CHECK(![root isHeld:60] && [root isHeld:61],@"Letting go of A releases C4 only");
              [root keyUp:key(13,NO)]; KV_CHECK(![root isHeld:61],@"Letting go of W releases C♯4");
              [root keyDown:key(41,YES)]; KV_CHECK([root isHeld:76],@"; plays E5"); [root keyUp:key(41,NO)];
              { int register0=root.keyboardBase,view0=[root keyboardViewStart]; NSString *range0=[root rangeText];
                KV_CHECK(root.computerBase==register0 || root.computerBase==60,@"The computer keyboard starts at the register");
                root.computerBase=register0; view0=[root keyboardViewStart]; KV_CHECK(view0==[root keyboardStart],@"On, the drawn keyboard starts where the register puts it");
                KV_CHECK([root computerLetterBase]==register0,@"Key letters start at the computer keyboard's A");
                [root keyDown:key(6,YES)]; KV_CHECK([root keyboardViewStart]==view0-12 && root.keyboardBase==register0 && ![[root rangeText] isEqualToString:range0],@"Z moves the drawn keyboard an octave down, not the playback register");
                [root keyDown:key(7,YES)]; KV_CHECK([root keyboardViewStart]==view0,@"X moves it back");
                [root.registerControl setSelectedSegment:3]; [root registerChanged:root.registerControl];
                KV_CHECK(root.computerBase==root.keyboardBase && [root keyboardViewStart]==[root keyboardStart],@"Choosing a register moves the computer keys there too");
                [root.registerControl setSelectedSegment:(register0/12)-3]; [root registerChanged:root.registerControl]; root.computerBase=60; }
              [root keyDown:key(6,YES)]; KV_CHECK(root.computerBase==48,@"Z moves an octave down");
              [root keyDown:key(0,YES)]; KV_CHECK([root isHeld:48],@"After Z, A plays C3"); [root keyUp:key(0,NO)];
              [root keyDown:key(9,YES)]; KV_CHECK(root.computerVelocity==120,@"V raises the velocity by 20");
              [root.roll keyDown:key(3,YES)]; KV_CHECK([root isHeld:53],@"In the piano roll F plays F3 instead of folding");
              [root releaseComputerKeys]; KV_CHECK(![root isHeld:53],@"Losing focus releases every held key");
              // A held key stays lit exactly while it is held — stopped and during playback — and goes dark on release.
              for(int playing=0;playing<2;playing++) {
                  if(playing) [root playProgression:nil];
                  void (^frames)(double)=^(double seconds) { NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
                      while(end.timeIntervalSinceNow>0) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0/60]]; [root updatePlaybackVisualization]; [root.piano advanceAnimation]; } };
                  root.computerBase=96; [root keyDown:key(0,YES)]; frames(.2); float early=[root.piano levelOf:96]; frames(.9); float late=[root.piano levelOf:96];
                  [root keyUp:key(0,NO)]; frames(.15); float after=[root.piano levelOf:96];
                  KV_CHECK(early>.9 && late>.9,playing?@"During playback a held computer key stays lit the whole time":@"A held computer key stays lit the whole time");
                  KV_CHECK(after<.1,playing?@"During playback the key goes dark on release":@"The key goes dark on release");
                  { NSRect r=[root.piano rectFor:72]; NSPoint at=[root.piano convertPoint:NSMakePoint(NSMidX(r),NSMaxY(r)-4) toView:nil]; // C5 is on every register
                NSEvent *down=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:at modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];
                NSEvent *up=[NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:at modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:0];
                [root.piano mouseDown:down]; frames(.9); KV_CHECK([root isHeld:72] && [root.piano levelOf:72]>.9,@"A screen key pressed with the mouse stays lit while the button is down");
                [root.piano mouseUp:up]; frames(.15); KV_CHECK(![root isHeld:72] && [root.piano levelOf:72]<.1,@"…and goes dark as soon as the mouse is released"); }
              [root midiNote:98 velocity:90 on:YES]; frames(1.1); KV_CHECK([root.piano levelOf:98]>.9,@"A held MIDI key stays lit");
                  [root midiNote:98 velocity:0 on:NO]; frames(.15); KV_CHECK([root.piano levelOf:98]<.1,@"…and goes dark when the MIDI key is let go");
                  if(playing) [root stopPlayback:nil];
              }
              root.computerBase=60;
              [root keyDown:key(46,YES)]; KV_CHECK(!root.computerKeyboard,@"M turns it off");
              KV_CHECK([root keyboardViewStart]==[root keyboardStart] && [root computerLetterBase]<0,@"Off, the keyboard shows the register again, without letters");
              [root keyDown:key(0,YES)]; KV_CHECK(![root isHeld:60] && ![root isHeld:48],@"Off, A plays nothing");
              root.computerBase=60; root.computerVelocity=100; root.computerKeyboard=was; }
            [root.performanceChoice selectItemWithTag:0]; [root performanceChanged:root.performanceChoice];
            // Piano roll: the track mirrors the arrangement, edits play and persist, undo works, speed halves the bar.
            [root selectIndex:0 minor:NO]; [root clearProgression:nil]; for(NSNumber *degree in @[@0,@5,@3,@4]) [root addChord:root.addButtons[degree.integerValue]];
            [root.performanceChoice selectItemWithTag:1]; [root performanceChanged:root.performanceChoice];
            [root.meterChoice selectItemAtIndex:KV_METER_4_4]; [root meterChanged:root.meterChoice]; [root.lengthChoice selectItemAtIndex:KV_LENGTH_BAR]; [root lengthChanged:root.lengthChoice];
            [root.viewSwitch setSelectedSegment:1]; [root viewChanged:root.viewSwitch];
            KV_CHECK(root.viewMode==1 && !root.roll.hidden && root.circle.hidden && root.track->count>0 && !root.trackEdited,@"Piano roll shows the arrangement's track");
            for(NSNumber *width in @[@1120,@1728]) for(NSNumber *height in @[@680,@1000]) { root.frame=NSMakeRect(0,0,width.doubleValue,height.doubleValue); NSString *problem=[root layoutProblem]; KV_CHECK(!problem,([NSString stringWithFormat:@"Piano roll layout %@x%@: %@",width,height,problem])); }
            root.frame=NSMakeRect(0,0,1240,760); [root layout]; [root.roll resetView];
            size_t before=root.track->count;
            KV_CHECK([root.roll addNoteAtBeat:1 midi:79 duration:.5] && root.track->count==before+1 && root.trackEdited && root.roll.selectedCount==1,@"Double-click adds a selected note and marks the track edited");
            NSUInteger added=NSNotFound; for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].midi==79 && fabs(root.track->events[i].beat-1)<1e-9) added=i;
            KV_CHECK(added!=NSNotFound && root.track->events[added].chord==0 && root.track->events[added].hand==1,@"New note is tagged with its chord and the right hand");
            KV_CHECK([root.roll resizeNoteAt:added toDuration:6] && fabs(root.track->events[added].duration-6)<1e-9,@"A note may ring across chord boundaries");
            KV_CHECK([root.roll moveNoteAt:added toBeat:9.5 midi:81],@"Move note");
            added=NSNotFound; for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].midi==81 && fabs(root.track->events[i].beat-9.5)<1e-9) added=i;
            KV_CHECK(added!=NSNotFound && root.track->events[added].chord==2 && fabs(root.track->events[added].duration-6)<1e-9,@"Moved note keeps its length and gets the new chord");
            [root playProgression:nil]; KV_CHECK(root.playingPerformance && root.currentPlan->count==root.track->count,@"An edited track is what plays");
            { size_t n=root.track->count; [root.roll deselectAll]; [root.roll setSelected:YES at:added]; [root.roll duplicateSelected];
              KV_CHECK(root.track->count==n || root.track->count==n+1,@"Cmd-D duplicates (or drops a copy past the end)");
              if(root.track->count==n+1) { [root pianoRollUndo:root.roll]; KV_CHECK(root.track->count==n,@"Undo removes the duplicate"); }
              added=NSNotFound; for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].midi==81 && fabs(root.track->events[i].beat-9.5)<1e-9) added=i; }
            { size_t n=root.track->count; [root.roll deselectAll]; double early=.5; [root.roll addNoteAtBeat:early midi:90 duration:1]; [root.roll duplicateSelected];
              size_t copies=0; for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].midi==90) copies++;
              KV_CHECK(root.track->count==n+2 && copies==2,@"Cmd-D places a copy of a new note right after it");
              for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].midi==90 && fabs(root.track->events[i].beat-1.5)<1e-9) copies=99;
              KV_CHECK(copies==99,@"The copy starts where the original ends");
              [root pianoRollUndo:root.roll]; [root pianoRollUndo:root.roll]; KV_CHECK(root.track->count==n,@"Undo both"); }
            [root.roll deselectAll]; [root.roll setSelected:YES at:added]; [root.roll deleteSelected]; KV_CHECK(root.track->count==before,@"Delete removes the selected note");
            [root pianoRollUndo:root.roll]; KV_CHECK(root.track->count==before+1,@"Undo restores the deleted note");
            [root pianoRollRedo:root.roll]; KV_CHECK(root.track->count==before,@"Redo deletes it again");
            // Real mouse and key events on the roll: double-click adds, arrows nudge, ⇧↑ an octave, ⌥↓ softer, drag moves, Delete removes.
            { NSWindow *w=[[NSWindow alloc] initWithContentRect:root.frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES]; w.contentView=root; [root layout];
              KvPianoRoll *roll=root.roll; roll.gridBeats=.25; [roll deselectAll];
              NSEvent *(^mouse)(NSEventType,NSPoint,NSInteger,NSEventModifierFlags)=^NSEvent *(NSEventType type,NSPoint p,NSInteger clicks,NSEventModifierFlags flags) {
                  return [NSEvent mouseEventWithType:type location:[roll convertPoint:p toView:nil] modifierFlags:flags timestamp:0 windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:clicks pressure:1]; };
              NSEvent *(^press)(unsigned short,NSEventModifierFlags)=^NSEvent *(unsigned short code,NSEventModifierFlags flags) {
                  return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:w.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code]; };
              NSUInteger (^only)(void)=^NSUInteger { for(NSUInteger i=0;i<root.track->count;i++) if([roll isSelectedAt:i]) return i; return NSNotFound; };
              NSRect area=[roll noteAreaRect]; NSPoint spot=NSMakePoint(NSMinX(area)+NSWidth(area)*.62,NSMinY(area)+NSHeight(area)*.15);
              while([roll noteIndexAtPoint:spot edge:NULL]!=NSNotFound) spot.y+=roll.rowHeight;   // an empty cell
              int midi=[roll midiAtY:spot.y]; double beat=floor([roll beatAtX:spot.x]/.25+1e-9)*.25; size_t n=root.track->count;
              [roll mouseDown:mouse(NSEventTypeLeftMouseDown,spot,2,0)]; [roll mouseUp:mouse(NSEventTypeLeftMouseUp,spot,2,0)];
              NSUInteger at=only();
              KV_CHECK(root.track->count==n+1 && roll.selectedCount==1 && at!=NSNotFound && root.track->events[at].midi==midi && fabs(root.track->events[at].beat-beat)<1e-9,@"Roll: a double-click on an empty cell adds a note there");
              [roll keyDown:press(124,0)]; at=only(); KV_CHECK(at!=NSNotFound && fabs(root.track->events[at].beat-beat-.25)<1e-9,@"Roll: → moves the selection one grid step later");
              [roll keyDown:press(123,0)]; [roll keyDown:press(126,0)]; at=only(); KV_CHECK(at!=NSNotFound && root.track->events[at].midi==midi+1 && fabs(root.track->events[at].beat-beat)<1e-9,@"Roll: ← back and ↑ a semitone up");
              [roll keyDown:press(125,NSEventModifierFlagShift)]; at=only(); KV_CHECK(at!=NSNotFound && root.track->events[at].midi==midi-11,@"Roll: ⇧↓ moves an octave down");
              float velocity=root.track->events[at].velocity; [roll keyDown:press(125,NSEventModifierFlagOption)]; at=only();
              KV_CHECK(at!=NSNotFound && root.track->events[at].velocity<velocity-.05f,@"Roll: ⌥↓ makes the selection softer");
              [roll setHand:0 forSelected:YES]; at=only(); KV_CHECK(at!=NSNotFound && root.track->events[at].hand==0,@"Roll: the context menu moves notes to the left hand");
              [roll setHand:1 forSelected:YES]; at=only();
              KV_CHECK([roll moveNoteAt:at toBeat:beat+.1 midi:root.track->events[at].midi],@"Roll: off-grid move"); at=only(); if(at==NSNotFound) for(NSUInteger i=0;i<root.track->count;i++) if(fabs(root.track->events[i].beat-beat-.1)<1e-9) { [roll setSelected:YES at:i]; at=i; }
              [roll quantizeSelected]; at=only(); KV_CHECK(at!=NSNotFound && fabs(root.track->events[at].beat-beat)<1e-9,@"Roll: quantize pulls the start to the nearest grid line");
              NSRect note=[roll rectForNote:at]; NSPoint grab=NSMakePoint(NSMinX(note)+2,NSMidY(note)),drop=NSMakePoint(grab.x+NSWidth(area)/[roll visibleBeats],grab.y+roll.rowHeight*2);   // flipped: down the screen is down in pitch
              [roll mouseDown:mouse(NSEventTypeLeftMouseDown,grab,1,0)]; [roll mouseDragged:mouse(NSEventTypeLeftMouseDragged,drop,1,0)]; [roll mouseUp:mouse(NSEventTypeLeftMouseUp,drop,1,0)];
              at=only(); KV_CHECK(at!=NSNotFound && fabs(root.track->events[at].beat-beat-1)<1e-6 && root.track->events[at].midi==midi-13,@"Roll: dragging a note moves it a beat later and two rows down");
              size_t copies=root.track->count; note=[roll rectForNote:at]; grab=NSMakePoint(NSMinX(note)+2,NSMidY(note)); drop=NSMakePoint(grab.x+NSWidth(area)/[roll visibleBeats],grab.y);
              [roll mouseDown:mouse(NSEventTypeLeftMouseDown,grab,1,NSEventModifierFlagOption)]; [roll mouseDragged:mouse(NSEventTypeLeftMouseDragged,drop,1,NSEventModifierFlagOption)]; [roll mouseUp:mouse(NSEventTypeLeftMouseUp,drop,1,NSEventModifierFlagOption)];
              KV_CHECK(root.track->count==copies+1,@"Roll: ⌥-drag leaves the original and drags a copy");
              [roll keyDown:press(51,0)]; KV_CHECK(root.track->count==copies,@"Roll: Delete removes the selection");
              [roll deselectAll]; NSUInteger last=NSNotFound; for(NSUInteger i=0;i<root.track->count;i++) if(root.track->events[i].midi==midi-13) last=i;
              KV_CHECK(last!=NSNotFound,@"Roll: the moved original is still there"); note=[roll rectForNote:last]; grab=NSMakePoint(NSMidX(note),NSMidY(note));
              [roll mouseDown:mouse(NSEventTypeLeftMouseDown,grab,2,0)]; KV_CHECK(root.track->count==copies-1,@"Roll: a double-click on a note removes it");
              NSPoint a=NSMakePoint(NSMinX(area)+2,NSMinY(area)+2),b=NSMakePoint(NSMaxX(area)-2,NSMaxY(area)-2);
              [roll mouseDown:mouse(NSEventTypeLeftMouseDown,a,1,0)]; [roll mouseDragged:mouse(NSEventTypeLeftMouseDragged,b,1,0)]; [roll mouseUp:mouse(NSEventTypeLeftMouseUp,b,1,0)];
              NSUInteger visible=0; for(NSUInteger i=0;i<root.track->count;i++) if(NSIntersectsRect([roll rectForNote:i],area)) visible++;
              KV_CHECK(visible>0 && roll.selectedCount==visible,@"Roll: a box drag selects the notes it covers");
              for(int i=0;i<5;i++) [root pianoRollUndo:root.roll];
              [roll deselectAll]; w.contentView=[[NSView alloc] init]; root.frame=NSMakeRect(0,0,1240,760); [root layout]; }
            [root stopPlayback:nil]; [root pianoRollResetRequested:root.roll]; root.loopButton.state=NSControlStateValueOn; [root loopChanged:root.loopButton]; [root playProgression:nil];   // afresh and looping: the roll's checks may have outlasted or emptied the sequence
            [root applyTempo:120]; for(int tries=0;tries<20 && !(root.visualPlayback && root.playingPerformance);tries++) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]]; if(!(root.visualPlayback && root.playingPerformance)) [root playProgression:nil]; }   // under way before the speed changes
            double normal=root.visualEventSeconds; NSString *state=[NSString stringWithFormat:@"visual %d performance %d playing %d status «%@»",root.visualPlayback,root.playingPerformance,kv_audio_is_playing(root.audio),root.status.stringValue]; [root pianoRoll:root.roll speedChanged:.5];
            KV_CHECK(fabs(root.visualEventSeconds-normal*2)<.001 && [root.arrangementInfo.stringValue containsString:@"×½"],([NSString stringWithFormat:@"Half speed doubles the bar without touching the tempo (%@; %.3f → %.3f)",state,normal,root.visualEventSeconds]));
            [root pianoRoll:root.roll speedChanged:1]; [root stopPlayback:nil];
            // Review fixes: quarter speed at 60 BPM starts; auditioning while playing keeps the sequence; no-op edits leave no undo entry.
            [root pianoRollResetRequested:root.roll]; [root applyTempo:60]; [root pianoRoll:root.roll speedChanged:.25]; [root playProgression:nil];   // the track from the pattern: the roll's edits above may have emptied it
            KV_CHECK(root.playingPerformance && kv_audio_is_playing(root.audio) && fabs(root.visualEventSeconds-16)<.001,([NSString stringWithFormat:@"×¼ at 60 BPM plays (4 s per beat): %.2f s, meter %d, mode %ld, length %d, playing %d",root.visualEventSeconds,(int)root.meter,(long)root.performanceMode,(int)[root chordLength],root.playingPerformance]));
            [root pianoRoll:root.roll audition:72]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
            KV_CHECK([root isPlayingProgression] && root.playingPerformance,@"Auditioning a note does not stop the progression");
            // After the performance ends by itself, placing a note sounds it but shows no running playhead.
            kv_audio_stop(root.audio); [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]]; [root reconcilePlayback];
            KV_CHECK(!root.playingPerformance && ![root isPlayingProgression],@"A finished performance is forgotten");
            [root pianoRoll:root.roll audition:74]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]]; [root reconcilePlayback];
            KV_CHECK(![root isPlayingProgression] && [root playheadBeat]<0,@"An auditioned note does not start the playhead");
            [root playProgression:nil];
            [root pianoRoll:root.roll speedChanged:1]; [root applyTempo:120]; double beatBefore=[root playheadBeat]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.25]];
            [root applyTempo:60]; double atChange=[root playheadBeat]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.25]]; double later=[root playheadBeat];
            KV_CHECK(beatBefore>=0 && later>atChange && later-atChange<.6,@"Playhead continues from the change at the new rate");
            [root stopPlayback:nil];
            NSUInteger undoBefore=root.trackUndo.count; [root pianoRollWillEdit:root.roll]; [root pianoRollDidEdit:root.roll];
            KV_CHECK(root.trackUndo.count==undoBefore,@"An edit that changes nothing is not recorded");
            [root.roll selectAll]; [root.roll deleteSelected]; KV_CHECK(root.track->count==0 && root.trackEdited,@"Track can be emptied");
            [root playProgression:nil]; KV_CHECK(!kv_audio_is_playing(root.audio) && root.track->count==0 && [root.status.stringValue containsString:@"пуста"],@"An empty edited track does not silently revert to the arrangement");
            [root pianoRollUndo:root.roll]; KV_CHECK(root.track->count>0,@"Undo brings the notes back");
            [root undoSequence:nil]; KV_CHECK(root.viewMode==1,@"Cmd-Z in roll view routes to the track undo without touching the view");
            [root selectIndex:root.key.circle_index+1 minor:root.key.minor]; KV_CHECK(!root.trackEdited && root.track->count>0,@"Key change while stopped rebuilds the track");
            [root selectIndex:root.key.circle_index-1 minor:root.key.minor];
            KV_CHECK([root.roll addNoteAtBeat:2 midi:76 duration:.5] && root.trackEdited,@"Edit after the key change");
            KvRoot *trackRestored=[[KvRoot alloc] initWithFrame:root.frame];
            { NSData *saved=[Defaults() dataForKey:@"trackData"]; KvPerformance check; if(saved.length==sizeof(check)) memcpy(&check,saved.bytes,sizeof(check));
              (void)check; KV_CHECK(trackRestored.trackEdited && trackRestored.track->count==root.track->count && trackRestored.viewMode==1,@"Edited track and view persist"); }
            NSString *rollMidi=[NSTemporaryDirectory() stringByAppendingPathComponent:@"tonora-roll.mid"]; KV_CHECK([root exportMidiToPath:rollMidi],@"Export of an edited track"); [NSFileManager.defaultManager removeItemAtPath:rollMidi error:NULL];
            [root pianoRollResetRequested:root.roll]; KV_CHECK(!root.trackEdited && root.track->count>0,@"Reset rebuilds the track from the arrangement");
            [root.roll addNoteAtBeat:0 midi:72 duration:1]; [root.patternChoice selectItemAtIndex:KV_POP]; [root patternChanged:root.patternChoice];
            KV_CHECK(!root.trackEdited && root.trackUndo.count>0,@"Changing the arrangement regenerates the track and keeps the edits in undo");
            // Eight bars: four fit the width at zoom 1, the view follows the playhead into the second half.
            [root clearProgression:nil]; for(NSNumber *degree in @[@0,@5,@3,@4,@0,@5,@3,@4]) [root addChord:root.addButtons[degree.integerValue]];
            [root.roll resetView]; KV_CHECK(fabs([root.roll visibleBeats]-16)<1e-9 && root.track->total_beats==32,@"Default width is four 4/4 bars of an eight-bar track");
            // Starting playback keeps the user's view: zoom, scroll and row height survive Play and Stop.
            { [root.roll zoomBy:2 aroundX:400]; [root.roll zoomRowsBy:1.5 aroundY:300]; root.roll.scrollBeat=4;
              double zoom=root.roll.zoom,scroll=root.roll.scrollBeat,rows=root.roll.rowHeight;
              [root playProgression:nil]; [root stopPlayback:nil]; [root playProgression:nil];
              KV_CHECK(fabs(root.roll.zoom-zoom)<1e-9 && fabs(root.roll.rowHeight-rows)<1e-9 && fabs(root.roll.scrollBeat-scroll)<1e-9,@"Play does not reset the piano roll view");
              [root stopPlayback:nil]; [root.roll resetView]; }
            root.roll.playheadBeat=20; KV_CHECK(fabs(root.roll.scrollBeat-16)<1e-9,@"Playhead in bar 6 pages the view to bars 5–8");
            root.roll.playheadBeat=3; KV_CHECK(fabs(root.roll.scrollBeat)<1e-9,@"Playhead back in bar 1 pages to the start");
            { KV_CHECK(root.roll.follow,@"The roll follows the playhead by default");
              [root.roll zoomBy:1.5 aroundX:400]; KV_CHECK(!root.roll.follow,@"Time zoom during playback stops following");
              double scroll=root.roll.scrollBeat; root.roll.playheadBeat=30; KV_CHECK(fabs(root.roll.scrollBeat-scroll)<1e-9,@"Without follow the view stays where the user put it");
              root.roll.follow=YES; KV_CHECK(root.roll.scrollBeat<=30 && 30<root.roll.scrollBeat+[root.roll visibleBeats],@"Turning follow back on jumps to the playhead");
              NSEvent *cmdF=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0 context:nil characters:@"f" charactersIgnoringModifiers:@"f" isARepeat:NO keyCode:3];
              [root.roll keyDown:cmdF]; KV_CHECK(!root.roll.follow,@"Cmd-F toggles follow off"); [root.roll keyDown:cmdF]; KV_CHECK(root.roll.follow,@"…and on");
              root.roll.playheadBeat=-1; [root.roll zoomBy:1.5 aroundX:400]; KV_CHECK(root.roll.follow,@"Zooming while stopped keeps follow on"); [root.roll resetView]; }
            { // Pentatonic: five highlighted notes, five-note scale, roll mask, melodies inside it, remembered.
              KvKey savedP=root.key; NSInteger savedPMode=root.mode.indexOfSelectedItem; [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; [root selectIndex:0 minor:NO];
              [root.mode selectItemAtIndex:9]; [root modeChanged:root.mode]; KV_CHECK(root.key.pentatonic && !root.key.minor && root.mode.indexOfSelectedItem==9,@"«Мажорная пентатоника» in the mode list switches the key's scale");
              int lit=0; for(int pc=0;pc<12;pc++) if([root keyboardHighlights:60+pc]) lit++; KV_CHECK(lit==5 && ![root keyboardHighlights:65] && ![root keyboardHighlights:71],@"C major pentatonic lights C D E G A");
              int t=0; unsigned mask=[root pianoRollScale:root.roll tonic:&t]; KV_CHECK(mask==((1u<<0)|(1u<<2)|(1u<<4)|(1u<<7)|(1u<<9)),@"The roll highlights the pentatonic");
              KV_CHECK([root.keyboardHeading.stringValue containsString:@"5 нот"] && [[root keyTitle] containsString:@"пентатоника"],@"Heading says five notes and names the pentatonic");
              [root.scaleNames.stringValue componentsSeparatedByString:@"   "]; KV_CHECK([root.scaleNames.stringValue componentsSeparatedByString:@"   "].count==5,@"Five scale names");
              for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].hand) { int m=root.track->events[i].midi; BOOL ok=kv_in_scale(root.key,m);
                  KvChord ch; if(!ok && kv_chord_extended(root.key,root.progression[root.track->events[i].chord%root.progression.count].intValue,(int)root.chordExtension,&ch)) for(size_t v=0;v<ch.count;v++) if(ch.midi[v]%12==m%12) ok=YES;
                  KV_CHECK(ok,@"Right-hand notes of the arrangement stay in the pentatonic or the chord"); }
              KV_CHECK([Defaults() boolForKey:@"pentatonic"],@"Pentatonic is remembered");
              [root.mode selectItemAtIndex:10]; [root modeChanged:root.mode]; KV_CHECK(root.key.pentatonic && root.key.minor && kv_tonic(root.key)==0 && [root keyboardHighlights:63] && ![root keyboardHighlights:62],@"«Минорная пентатоника» keeps the tonic: C minor pentatonic has E♭, no D");
              [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; KV_CHECK(!root.key.pentatonic && [root.keyboardHeading.stringValue containsString:@"7 нот"],@"Back to major: seven notes");
              root.key=savedP; [root.mode selectItemAtIndex:savedPMode]; [root modeChanged:root.mode]; }
            { int tonic=-1; KvKey saved=root.key; NSInteger savedMode=root.mode.indexOfSelectedItem;
              [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; [root selectIndex:3 minor:NO];  // A major: A B C# D E F# G#
              unsigned mask=[root pianoRollScale:root.roll tonic:&tonic];
              KV_CHECK(mask==((1u<<9)|(1u<<11)|(1u<<1)|(1u<<2)|(1u<<4)|(1u<<6)|(1u<<8)) && tonic==9,@"Roll scale mask follows the selected key");
              BOOL was=root.roll.showScale; root.roll.showScale=!was; KV_CHECK([Defaults() boolForKey:@"pianoRollScale"]==!was,@"Scale highlight toggle is remembered");
              root.roll.showScale=was; [root selectIndex:saved.circle_index minor:saved.minor]; [root.mode selectItemAtIndex:savedMode]; [root modeChanged:root.mode]; }
            [root.roll zoomBy:.25 aroundX:0]; KV_CHECK(fabs([root.roll visibleBeats]-32)<1e-9,@"Zooming out stops at the whole track");
            // MIDI clip for a DAW: whole track, then a selection starting at its first bar; copy goes to a private pasteboard here.
            { NSURL *whole=[root midiClipURLSelectionOnly:NO]; NSData *wholeData=[NSData dataWithContentsOfURL:whole];
              KV_CHECK(whole && wholeData.length>100 && memcmp(wholeData.bytes,"MThd",4)==0 && [whole.pathExtension isEqualToString:@"mid"],@"Whole-track MIDI clip file");
              [root.roll deselectAll]; NSUInteger later=NSNotFound; for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].beat>=8) { later=i; break; }
              KV_CHECK(later!=NSNotFound,@"A note after bar 2"); [root.roll setSelected:YES at:later];
              NSURL *part=[root midiClipURLSelectionOnly:YES]; NSData *partData=[NSData dataWithContentsOfURL:part];
              KV_CHECK(part && partData.length>60 && partData.length<wholeData.length && [part.lastPathComponent containsString:@"такты"],@"Selection clip is smaller and named by its bars");
              NSPasteboard *board=[NSPasteboard pasteboardWithUniqueName];
              KV_CHECK([root copyMidiToPasteboard:board] && [board dataForType:@"public.midi-audio"].length==partData.length && [board stringForType:NSPasteboardTypeFileURL].length>0,@"Copy puts the clip and its file on the pasteboard");
              [board releaseGlobally]; [root.roll deselectAll]; }
            // Same pitch never overlaps: a note dropped inside another of its pitch shortens the earlier one.
            { [root.roll deselectAll]; size_t n=root.track->count;
              KV_CHECK([root.roll addNoteAtBeat:4 midi:100 duration:2],@"Long note"); KV_CHECK([root.roll addNoteAtBeat:5 midi:100 duration:.5],@"Note inside it");
              double first=-1; for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].midi==100 && fabs(root.track->events[i].beat-4)<1e-9) first=root.track->events[i].duration;
              KV_CHECK(fabs(first-1)<1e-9 && root.track->count==n+2,@"The earlier note now ends where the later one starts");
              KV_CHECK([root.roll addNoteAtBeat:5 midi:100 duration:1],@"Same onset"); size_t at5=0; for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].midi==100 && fabs(root.track->events[i].beat-5)<1e-9) at5++;
              KV_CHECK(at5==1 && root.track->count==n+2,@"A note on the same onset replaces the old one");
              for(size_t i=0;i<root.track->count;i++) for(size_t j=i+1;j<root.track->count && root.track->events[j].beat<root.track->events[i].beat+root.track->events[i].duration-1e-9;j++) KV_CHECK(root.track->events[j].midi!=root.track->events[i].midi,@"No same-pitch overlaps in the track");
              [root pianoRollUndo:root.roll]; [root pianoRollUndo:root.roll]; [root pianoRollUndo:root.roll]; KV_CHECK(root.track->count==n,@"Undo the three edits"); }
            // Smooth vertical scrolling: small trackpad deltas move the view, not just whole rows.
            { double top=[[root.roll valueForKey:@"topPitch"] doubleValue]; CGEventRef wheel=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitPixel,1,-3);
              NSEvent *scroll=[NSEvent eventWithCGEvent:wheel]; CFRelease(wheel); [root.roll scrollWheel:scroll];
              double after=[[root.roll valueForKey:@"topPitch"] doubleValue]; KV_CHECK(fabs(after-top)>.05 && fabs(after-top)<1,@"A 3-pixel trackpad scroll moves the view by a fraction of a row"); }
            { NSEvent *slash=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0 context:nil characters:@"/" charactersIgnoringModifiers:@"/" isARepeat:NO keyCode:44];
              NSEvent *escape=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:53];
              [root.roll keyDown:slash]; KV_CHECK(root.roll.showHelp && root.shortcutsVisible,@"Cmd-/ in the roll opens the window's shortcuts card"); [root.roll keyDown:escape]; KV_CHECK(!root.roll.showHelp,@"Esc closes it");
              [root keyDown:slash]; KV_CHECK(root.shortcutsVisible && root.subviews.lastObject==root.shortcutsCard,@"Cmd-/ outside the roll opens the same card on top");
              // Nothing under the card reacts to hover: no labels on buttons, no modulation hint on the circle.
              NSWindow *hoverWindow=root.window?nil:[[NSWindow alloc] initWithContentRect:root.frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES]; if(hoverWindow) hoverWindow.contentView=root;
              NSPoint buttonMid=[root.shortcutsButton convertPoint:NSMakePoint(NSMidX(root.shortcutsButton.bounds),NSMidY(root.shortcutsButton.bounds)) toView:nil];
              NSInteger savedViewMode=root.viewMode; root.viewMode=0; [root layout]; [root addSubview:root.shortcutsCard positioned:NSWindowAbove relativeTo:nil];
              NSPoint centre; CGFloat radius; [root.circle geometry:&centre radius:&radius]; NSPoint side=NSMakePoint(centre.x+radius*.85,centre.y);
              KV_CHECK(TNViewCovered(root.shortcutsButton,buttonMid),@"Buttons under the shortcuts card get no hover label");
              KV_CHECK(!root.tempoSlider.toolTip.length && !root.circle.toolTip.length,@"No AppKit tooltips under the shortcuts card");
              KV_CHECK(!root.circle.hidden,@"The circle is shown for the hover check"); { [root.circle hoverAtPoint:side]; KV_CHECK([[root.circle valueForKey:@"hoverIndex"] intValue]<0,@"The circle under the shortcuts card shows no modulation hint"); }
              [root keyDown:slash]; KV_CHECK(!root.shortcutsVisible,@"Cmd-/ again closes it");
              KV_CHECK(!TNViewCovered(root.shortcutsButton,buttonMid),@"Hover labels come back once the card is closed");
              KV_CHECK(root.tempoSlider.toolTip.length && !root.circle.toolTip.length,@"AppKit tooltips come back with the card closed; the circle keeps one hint only");
              { [root.circle hoverAtPoint:side]; KV_CHECK([[root.circle valueForKey:@"hoverIndex"] intValue]>=0,@"The circle hint comes back once the card is closed"); [root.circle hoverAtPoint:centre]; KV_CHECK([[root.circle valueForKey:@"hoverIndex"] intValue]==-2,@"The centre explains the circle"); TNHintHide(nil); } root.viewMode=savedViewMode; [root layout];
              [root.shortcutsButton performClick:nil]; KV_CHECK(root.shortcutsVisible,@"The ? button opens it"); [root keyDown:escape]; KV_CHECK(!root.shortcutsVisible,@"Esc closes it everywhere");
              [root stopPlayback:nil]; KV_CHECK([((TNButton *)root.shortcutsButton).hint containsString:@"⌘/"] && [root.status.stringValue containsString:@"⌘/"],@"The ? button and the status line tell about Cmd-/"); }
            { // Melody notes outside the chord: classified in the roll, lit in their own colours on the keyboard while playing.
              // Seventh chords: with 13ths every scale note is a chord tone and nothing can fall outside.
              NSInteger savedPattern=root.patternChoice.indexOfSelectedItem,savedHarmony=root.harmonyChoice.indexOfSelectedItem; int savedTempo=(int)root.tempo;
              [root.harmonyChoice selectItemAtIndex:1]; [root harmonyChanged:root.harmonyChoice];
              [root.patternChoice selectItemAtIndex:KV_INTERLUDE]; [root patternChanged:root.patternChoice];
              NSUInteger outside=0; BOOL leftOutside=NO;
              for(size_t i=0;i<root.track->count;i++) if([root.roll roleOfNote:i]) { outside++; if(root.track->events[i].hand==0) leftOutside=YES; }
              KV_CHECK(outside>0 && !leftOutside,@"The Interlude melody has passing notes or anticipations, all in the right hand");
              [root applyTempo:180]; [root playProgression:nil]; BOOL lit=NO; NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4];
              while(!lit && deadline.timeIntervalSinceNow>0) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]]; [root updatePlaybackVisualization];
                  for(int m=21;m<=108 && !lit;m++) if([root.piano roleOf:m]) lit=YES; }
              KV_CHECK(lit,@"A passing note or anticipation lights up in its own colour on the keyboard");
              [root stopPlayback:nil]; BOOL cleared=YES; for(int m=21;m<=108;m++) if([root.piano roleOf:m]) cleared=NO; KV_CHECK(cleared,@"Stop clears the note colours");
              [root applyTempo:savedTempo]; [root.patternChoice selectItemAtIndex:savedPattern]; [root patternChanged:root.patternChoice];
              [root.harmonyChoice selectItemAtIndex:savedHarmony]; [root harmonyChanged:root.harmonyChoice]; }
            { // Fold (as in Ableton): only the scale's rows and rows holding notes; ↑ moves by a scale step.
              NSInteger savedMode=root.mode.indexOfSelectedItem; KvKey savedKey=root.key; BOOL savedScale=root.roll.showScale,savedFold=root.roll.fold;
              [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; [root selectIndex:0 minor:NO];
              root.roll.showScale=YES; root.roll.fold=NO; KV_CHECK([root.roll rowCount]==88,@"Unfolded roll has all 88 keys");
              root.roll.fold=YES; NSUInteger rows=[root.roll rowCount];
              KV_CHECK(rows>=52 && rows<88,@"Folded C major keeps the 52 scale rows (and rows with notes) and drops the rest");
              BOOL scaleOnly=YES; NSRect area=[root.roll noteAreaRect];
              for(CGFloat y=NSMinY(area)+2;y<NSMaxY(area);y+=root.roll.rowHeight) { int m=[root.roll midiAtY:y]; BOOL used=NO;
                  for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].midi==m) used=YES;
                  int pc=m%12; if(m>=21 && m<=108 && !used && (pc==1||pc==3||pc==6||pc==8||pc==10)) scaleOnly=NO; }
              KV_CHECK(scaleOnly,@"A folded C major roll shows no empty black-key rows");
              [root.roll deselectAll]; KV_CHECK([root.roll addNoteAtBeat:.75 midi:96 duration:.25],@"Add C7 in the folded roll");
              NSEvent *up=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:126];
              [root.roll keyDown:up]; BOOL moved=NO; for(size_t i=0;i<root.track->count;i++) if([root.roll isSelectedAt:i] && root.track->events[i].midi==98) moved=YES;
              KV_CHECK(moved,@"Folded, ↑ moves C7 to D7 — the next scale step, not C♯7");
              [root.roll deleteSelected];
              NSEvent *f=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"f" charactersIgnoringModifiers:@"f" isARepeat:NO keyCode:3];
              [root.roll keyDown:f]; KV_CHECK(!root.roll.fold && [root.roll rowCount]==88,@"F unfolds the roll");
              root.roll.fold=savedFold; root.roll.showScale=savedScale; [root selectIndex:savedKey.circle_index minor:savedKey.minor]; [root.mode selectItemAtIndex:savedMode]; [root modeChanged:root.mode]; }
            [root.viewSwitch setSelectedSegment:0]; [root viewChanged:root.viewSwitch]; KV_CHECK(!root.circle.hidden && root.roll.hidden,@"Back to the circle");
            [root.performanceChoice selectItemWithTag:0]; [root performanceChanged:root.performanceChoice];
            // The narrowest chip fits every chord name the app can produce.
            root.frame=NSMakeRect(0,0,KvMinWidth,KvMinHeight); [root layout];
            KvChip *narrow=(KvChip *)root.progressionButtons.firstObject; NSString *longest=@"";
            for(int minor=0;minor<2;minor++) for(int index=0;index<12;index++) for(int mode=0;mode<8;mode++) for(int ext=0;ext<5;ext++) for(int degree=0;degree<7;degree++) {
                KvChord chord; if(!kv_chord_extended((KvKey){index,minor,mode,0},degree,ext,&chord)) continue;
                NSString *name=S(chord.name); if(![KvChip fittedFont:name width:narrow.nameWidth]) longest=name;
            }
            KV_CHECK(!longest.length,([@"Chord name does not fit the narrowest chip: " stringByAppendingString:longest]));
            // 1.1 bowed strings: what the strings add appears only with them; textures, strokes, dynamics, pedal, keyswitches, export.
            { KV_CHECK(root.stringsAvailable,@"Strings: the recordings load");
              root.frame=NSMakeRect(0,0,1240,760); [root layout]; [root showSoundSettings:nil];
              [root.instrumentChoice selectItemAtIndex:0]; [root instrumentChanged:root.instrumentChoice]; CGFloat pianoPanel=root.soundPanel.frame.size.height;
              KV_CHECK(root.articulationControl.hidden && root.dynamicsSlider.hidden && [root.performanceChoice.menu itemWithTag:3].hidden,@"Strings: no strokes, dynamics or strings textures with the piano");
              { BOOL icons=YES,hint=NO,header=NO; for(NSMenuItem *item in root.performanceChoice.itemArray) { if(item.tag>=0 && !item.image) icons=NO; if(item.tag==-2 && !item.hidden) hint=YES; if(item.tag==-1 && [item.title hasPrefix:@"Струнные"] && !item.hidden) header=YES; }
                KV_CHECK(icons,@"Textures: every texture has an icon"); KV_CHECK(hint && !header,@"Textures: with the piano the menu points to the strings instead of listing their textures");
                KV_CHECK(root.performanceChoice.selectedItem.image,@"Textures: the collapsed button shows the icon of the chosen texture"); }
              [root.instrumentChoice selectItemAtIndex:KV_INSTRUMENT_STRINGS]; [root instrumentChanged:root.instrumentChoice]; [root layout];
              { BOOL hint=NO,header=NO; for(NSMenuItem *item in root.performanceChoice.itemArray) { if(item.tag==-2 && !item.hidden) hint=YES; if(item.tag==-1 && [item.title hasPrefix:@"Струнные"] && !item.hidden) header=YES; }
                KV_CHECK(!hint && header && !root.articulationHint.hidden && [root.articulationControl imageForSegment:3],@"Strings: the strings group appears with its header, the stroke row has icons and its explanation"); }
              KV_CHECK(!root.articulationControl.hidden && !root.dynamicsSlider.hidden && ![root.performanceChoice.menu itemWithTag:6].hidden && fabs(root.soundPanel.frame.size.height-pianoPanel-KvStrokeRowHeight)<1,@"Strings: the «Штрих» row, the dynamics slider and four textures appear");
              KV_CHECK(NSMaxX(root.dynamicsSlider.frame)<=NSMinX(root.piano.frame),@"Strings: the dynamics slider stands beside the keyboard");
              NSString *names[4]={@"хорал",@"кантилена",@"остинато",@"пиццикато"};
              for(NSInteger mode=3;mode<=6;mode++) {
                  [root.performanceChoice selectItemWithTag:mode]; [root performanceChanged:root.performanceChoice]; [root layout];
                  for(NSNumber *width in @[@1120,@1728]) { root.frame=NSMakeRect(0,0,width.doubleValue,width.doubleValue>1200?1000:680); NSString *problem=[root layoutProblem]; KV_CHECK(!problem,([NSString stringWithFormat:@"Strings texture %ld layout: %@",(long)mode,problem])); }
                  root.frame=NSMakeRect(0,0,1240,760); [root layout];
                  KV_CHECK(root.divisionChoice.hidden==(mode!=5) && !root.arrangeButton.hidden,@"Strings: the ostinato shows its note value, every strings texture its dice");
                  [root playProgression:nil];
                  KV_CHECK(root.playingPerformance && kv_audio_is_playing(root.audio) && [root.arrangementInfo.stringValue containsString:names[mode-3]],([NSString stringWithFormat:@"Strings texture «%@» plays: %@",names[mode-3],root.arrangementInfo.stringValue]));
                  [root stopPlayback:nil];
              }
              root.articulationControl.selectedSegment=KV_ARTICULATION_STACCATO; [root articulationChanged:root.articulationControl];
              KV_CHECK(root.articulation==KV_ARTICULATION_STACCATO && [root.arrangementInfo.stringValue containsString:@"стаккато"],@"Strings: the «Штрих» buttons");
              [root midiNote:KV_KEYSWITCH_LOW+KV_ARTICULATION_PIZZICATO velocity:100 on:YES]; [root midiNote:KV_KEYSWITCH_LOW+KV_ARTICULATION_PIZZICATO velocity:0 on:NO];
              KV_CHECK(root.articulation==KV_ARTICULATION_PIZZICATO && root.articulationControl.selectedSegment==KV_ARTICULATION_PIZZICATO && ![root isSounding:KV_KEYSWITCH_LOW+KV_ARTICULATION_PIZZICATO],@"Strings: D♯1 switches to pizzicato and does not sound");
              [root midiNote:KV_KEYSWITCH_LOW velocity:100 on:YES]; [root midiNote:KV_KEYSWITCH_LOW velocity:0 on:NO]; KV_CHECK(root.articulation==KV_ARTICULATION_AUTO,@"Strings: C1 back to Auto");
              [root midiControl:1 value:127]; KV_CHECK(fabs(root.stringDynamics-1)<1e-9 && fabs(root.dynamicsSlider.doubleValue-1)<1e-9,@"Strings: the mod wheel moves the dynamics");
              [root midiControl:1 value:38]; KV_CHECK(fabs(root.stringDynamics-38/127.0)<1e-9,@"Strings: and back down");
              [root midiControl:64 value:127]; [root midiNote:62 velocity:90 on:YES]; [root midiNote:62 velocity:0 on:NO];
              KV_CHECK([root isPedalHeld:62] && ![root isSounding:62],@"Pedal: a released key sounds on (the key itself is up)");
              [root midiControl:64 value:0]; KV_CHECK(![root isPedalHeld:62],@"Pedal: lifting it lets the note go");
              [root.performanceChoice selectItemWithTag:3]; [root performanceChanged:root.performanceChoice];
              NSString *clipName=nil; NSData *clip=[root midiClipDataSelectionOnly:NO name:&clipName]; static KvMidiSong song;
              KV_CHECK(clip && kv_midi_decode(clip.bytes,clip.length,&song),@"Strings: the chorale exports");
              BOOL legatoSwitch=NO; for(size_t i=0;i<song.count;i++) if(song.notes[i].midi==KV_KEYSWITCH_LOW+KV_ARTICULATION_LEGATO) legatoSwitch=YES;
              KV_CHECK(legatoSwitch && [clipName containsString:@"хорал"],@"Strings: the export carries the legato keyswitch and names the texture");
              KV_CHECK([root importMidiData:clip name:@"strings.mid"],@"Strings: the export imports");
              BOOL switches=NO; for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].midi>=KV_KEYSWITCH_LOW && root.track->events[i].midi<KV_KEYSWITCH_LOW+4) switches=YES;
              KV_CHECK(!switches,@"Strings: import leaves keyswitches out of the notes");
              [root pianoRollResetRequested:root.roll]; [root.viewSwitch setSelectedSegment:0]; [root viewChanged:root.viewSwitch];
              [root.performanceChoice selectItemWithTag:4]; [root performanceChanged:root.performanceChoice];
              KvRoot *again=[[KvRoot alloc] initWithFrame:root.frame];
              KV_CHECK(again.performanceMode==4 && again.instrument==KV_INSTRUMENT_STRINGS && again.articulation==KV_ARTICULATION_AUTO && fabs(again.stringDynamics-38/127.0)<1e-6,@"Strings: texture, stroke and dynamics survive a restart");
              [again stopPlayback:nil];
              [root.instrumentChoice selectItemAtIndex:0]; [root instrumentChanged:root.instrumentChoice];
              KV_CHECK(root.performanceMode==1 && [root.status.stringValue containsString:@"только у струнных"],@"Strings: another instrument falls back to two hands and says so");
              [root midiControl:1 value:76]; [root closeSound:nil]; [root stopPlayback:nil]; }
            // The window's keys as real key events (not method calls), the menu's actions, and options that survive a restart.
            { root.frame=NSMakeRect(0,0,1240,760); [root layout]; root.computerKeyboard=NO; [root stopPlayback:nil];
              NSEvent *(^press)(unsigned short,NSEventModifierFlags)=^NSEvent *(unsigned short code,NSEventModifierFlags flags) {
                  return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code]; };
              [root selectIndex:0 minor:NO]; [root.mode selectItemAtIndex:0]; [root modeChanged:root.mode]; [root clearProgression:nil];
              [root keyDown:press(18,NSEventModifierFlagShift)]; [root keyDown:press(23,NSEventModifierFlagShift)];
              KV_CHECK(root.progression.count==2 && [root.progression[1] intValue]==4,@"Keys: ⇧1 and ⇧5 add I and V");
              root.selectedChip=1; [root keyDown:press(51,0)]; KV_CHECK(root.progression.count==1,@"Keys: ⌫ removes the selected chord");
              [root keyDown:press(124,0)]; KV_CHECK(root.key.circle_index==1,@"Keys: → steps the circle clockwise");
              [root keyDown:press(123,0)]; KV_CHECK(root.key.circle_index==0,@"Keys: ← steps back");
              [root keyDown:press(125,0)]; KV_CHECK(root.mode.indexOfSelectedItem==1,@"Keys: ↓ picks minor");
              [root keyDown:press(126,0)]; KV_CHECK(root.mode.indexOfSelectedItem==0,@"Keys: ↑ picks major");
              [root keyDown:press(125,NSEventModifierFlagOption)]; [root keyDown:press(125,NSEventModifierFlagOption)]; KV_CHECK(root.mode.indexOfSelectedItem==2,@"Keys: ⌥↓ walks the mode list");
              [root keyDown:press(126,NSEventModifierFlagOption)]; [root keyDown:press(126,NSEventModifierFlagOption)]; KV_CHECK(root.mode.indexOfSelectedItem==0,@"Keys: ⌥↑ walks back");
              int base=root.keyboardBase; [root keyDown:press(base<84?126:125,NSEventModifierFlagCommand)]; KV_CHECK(abs(root.keyboardBase-base)==12,@"Keys: ⌘↑/⌘↓ shift the keyboard an octave");
              [root keyDown:press(base<84?125:126,NSEventModifierFlagCommand)]; KV_CHECK(root.keyboardBase==base,@"Keys: and back");
              BOOL loop=root.loopEnabled; [root keyDown:press(37,0)]; KV_CHECK(root.loopEnabled==!loop,@"Keys: L toggles repeat"); [root keyDown:press(37,0)];
              [root keyDown:press(49,0)]; KV_CHECK([root isPlayingProgression],@"Keys: Space plays");
              [root keyDown:press(53,0)]; KV_CHECK(![root isPlayingProgression],@"Keys: Esc stops");
              [root keyDown:press(49,0)]; [root keyDown:press(49,0)]; KV_CHECK(![root isPlayingProgression],@"Keys: Space again stops");
              NSMutableSet *equivalents=[NSMutableSet set];
              for(NSArray<NSString *> *entry in KvSequenceMenu()) { if(entry.count==1) continue;
                  KV_CHECK([root respondsToSelector:NSSelectorFromString(entry[2])],([@"Menu action exists: " stringByAppendingString:entry[2]]));
                  KV_CHECK(!entry[1].length || ![equivalents containsObject:entry[1]],([@"Menu shortcut used once: " stringByAppendingString:entry[0]])); if(entry[1].length) [equivalents addObject:entry[1]]; }
              root.roll.fold=YES; root.computerKeyboard=YES; root.chordKeysToggle.state=NSControlStateValueOn; [root chordKeysToggled:root.chordKeysToggle];
              [root.generateCountChoice selectItemAtIndex:2]; [root generateCountChanged:root.generateCountChoice];
              KvRoot *again=[[KvRoot alloc] initWithFrame:root.frame];
              KV_CHECK(again.roll.fold && again.computerKeyboard && again.chordKeys && again.generateCount==8,@"Fold, computer keyboard, one-key chords and generator count survive a restart");
              root.roll.fold=NO; root.computerKeyboard=NO; root.chordKeysToggle.state=NSControlStateValueOff; [root chordKeysToggled:root.chordKeysToggle];
              [root.generateCountChoice selectItemAtIndex:0]; [root generateCountChanged:root.generateCountChoice]; [again stopPlayback:nil]; }
            // The metronome: off at launch; ⌘K starts clicks without a sequence; with the count-in, Play brings the chords in one bar later;
            // Build 31: the click sounds only while something plays; Stop silences it, the metronome stays armed; the grid and the count-in survive a restart.
            { root.frame=NSMakeRect(0,0,1240,760); [root layout]; [root stopPlayback:nil]; double savedTempo=root.tempo; [root applyTempo:240];   // a 4/4 bar lasts one second
              [root.meterChoice selectItemAtIndex:KV_METER_4_4]; [root meterChanged:root.meterChoice];
              void (^wait)(double)=^(double seconds) { NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds]; while(end.timeIntervalSinceNow>0) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]]; [root updateBeatDots]; } };
              KV_CHECK(!root.metronomeOn && [[KvRoot alloc] initWithFrame:root.frame].metronomeOn==NO,@"Metronome: off at launch");
              if(root.drumsOn) [root toggleDrums:nil];
              [root toggleMetronome:nil]; KV_CHECK(root.metronomeOn && root.metronomeButton.state==NSControlStateValueOn,@"Metronome: ⌘K switches it on");
              wait(.35); KV_CHECK(kv_audio_rhythm_beat(root.audio)<0 && ![root isPlayingProgression],@"Metronome: armed, it is silent until something plays (as in a DAW)");
              [root.rhythmChoice selectItemAtIndex:[root.rhythmChoice indexOfItemWithTag:KV_GRID_EIGHTHS]]; [root rhythmChanged:root.rhythmChoice];
              [root.rhythmChoice selectItemAtIndex:[root.rhythmChoice indexOfItemWithTag:100]]; [root rhythmChanged:root.rhythmChoice];
              KV_CHECK(root.rhythmGrid==KV_GRID_EIGHTHS && root.countIn && [root.rhythmChoice itemAtIndex:[root.rhythmChoice indexOfItemWithTag:100]].state==NSControlStateValueOn,@"Metronome: the menu sets the grid and the count-in");
              [root clearProgression:nil]; [root addChord:root.addButtons[0]]; [root addChord:root.addButtons[4]];
              [root playProgression:nil]; wait(.4);
              KV_CHECK([root isPlayingProgression] && kv_audio_event(root.audio)<0,@"Count-in: a bar of clicks before the first chord");
              wait(.9); KV_CHECK(kv_audio_event(root.audio)>=0,@"Count-in: the chords come in after the bar");
              wait(.3); KV_CHECK(kv_audio_rhythm_beat(root.audio)>=0 && root.beatDot>=0,@"Metronome: it clicks while the progression plays and the beat dots follow");
              [root stopPlayback:nil]; wait(.2);
              KV_CHECK(root.metronomeOn && kv_audio_rhythm_beat(root.audio)<0 && ![root isPlayingProgression],@"Stop silences the click, the metronome stays armed");
              NSEvent *esc=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:53];
              [root playProgression:nil]; wait(.2); [root keyDown:esc]; wait(.1); KV_CHECK(root.metronomeOn && kv_audio_rhythm_beat(root.audio)<0,@"Esc stops the playback and the click, the metronome stays on");
              [root toggleMetronome:nil]; KV_CHECK(!root.metronomeOn && root.metronomeButton.state==NSControlStateValueOff,@"Metronome: ⌘K switches it off");
              KvRoot *again=[[KvRoot alloc] initWithFrame:root.frame]; KV_CHECK(again.countIn && again.rhythmGrid==KV_GRID_EIGHTHS && !again.metronomeOn,@"Metronome: grid and count-in survive a restart, the metronome itself starts off"); [again stopPlayback:nil];
              [root.rhythmChoice selectItemAtIndex:[root.rhythmChoice indexOfItemWithTag:100]]; [root rhythmChanged:root.rhythmChoice];
              root.rhythmGrid=KV_GRID_BEATS; [root applyRhythm]; [root saveState]; [root applyTempo:savedTempo]; }
            // The drums (build 31): their own switch and menu, apart from the click; both may sound together; off, nothing but the
            // progression plays; «По стилю» follows the style; a new meter sends its bar again; the level in FX and its default; all survive a restart.
            { [root stopPlayback:nil]; KV_CHECK(root.drumsAvailable || getenv("TONORA_NO_STRINGS"),@"Percussion recordings are bundled");
              KvPianoPattern savedPattern=root.pianoPattern; NSInteger (^tagged)(NSInteger)=^NSInteger(NSInteger tag) { return [root.drumsChoice indexOfItemWithTag:tag]; };
              if(root.metronomeOn) [root toggleMetronome:nil]; if(root.drumsOn) [root toggleDrums:nil];
              root.rhythmBeat=KV_BEAT_POP; [root playProgression:nil]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];
              KV_CHECK(kv_audio_rhythm_beat(root.audio)<0,@"Drums: off with the metronome off, nothing but the progression plays"); [root stopPlayback:nil];
              [root.drumsChoice selectItemAtIndex:tagged(200+KV_BEAT_POP)]; [root drumsChanged:root.drumsChoice];
              KV_CHECK(root.drumsOn && !root.metronomeOn && root.rhythmBeat==KV_BEAT_POP && root.drumsButton.state==NSControlStateValueOn && [root.drumsChoice itemAtIndex:tagged(200+KV_BEAT_POP)].state==NSControlStateValueOn,@"Drums: choosing Pop switches them on, the metronome untouched");
              KV_CHECK([root.status.stringValue containsString:@"поп"],@"Drums: the status names the beat");
              [root playProgression:nil]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.3]];
              KV_CHECK(kv_audio_rhythm_beat(root.audio)>=0 && root.sentBeat==KV_BEAT_POP,@"Drums: they play under the progression without the click");
              [root toggleMetronome:nil]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];
              KV_CHECK(root.metronomeOn && root.drumsOn && kv_audio_rhythm_beat(root.audio)>=0 && root.sentBeat==KV_BEAT_POP,@"Drums: the click joins them, both on");
              [root toggleMetronome:nil]; [root stopPlayback:nil];
              [root.drumsChoice selectItemAtIndex:tagged(300)]; [root drumsChanged:root.drumsChoice]; [root playProgression:nil];
              root.pianoPattern=KV_TRIP_HOP; [root refresh]; KV_CHECK(root.rhythmBeat==KvBeatByStyle && root.sentBeat==KV_BEAT_TRIPHOP,@"Drums: by the style they play trip-hop under the trip-hop style");
              root.pianoPattern=KV_POP; [root refresh]; KV_CHECK(root.sentBeat==KV_BEAT_POP,@"Metronome: and follow a new style");
              [root.meterChoice selectItemAtIndex:KV_METER_3_4]; [root meterChanged:root.meterChoice]; KV_CHECK(root.sentBeatMeter==KV_METER_3_4,@"Metronome: a new meter sends its bar again");
              [root.meterChoice selectItemAtIndex:KV_METER_4_4]; [root meterChanged:root.meterChoice];
              [root showSoundSettings:nil]; root.rhythmVolumeSlider.doubleValue=35; [root rhythmVolumeChanged:(NSSlider *)root.rhythmVolumeSlider];
              KV_CHECK(fabs(root.rhythmVolume-.35)<1e-9 && [root.rhythmVolumeValue.stringValue isEqualToString:@"35 %"],@"Metronome: FX sets its level");
              KvRoot *again=[[KvRoot alloc] initWithFrame:root.frame]; KV_CHECK(again.rhythmBeat==KvBeatByStyle && again.drumsOn && fabs(again.rhythmVolume-.35)<1e-9 && !again.metronomeOn,@"Drums: the choice and the level survive a restart, the metronome starts off"); [again stopPlayback:nil];
              [root defaultSound:nil]; KV_CHECK(fabs(root.rhythmVolume-.6)<1e-9,@"Metronome: «По умолчанию» puts its level back to 60 %");
              [root closeSound:nil];
              [root.drumsChoice selectItemAtIndex:tagged(400)]; [root drumsChanged:root.drumsChoice]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]]; KV_CHECK(!root.drumsOn && root.sentBeat==-1,@"Drums: «Выключить ударные» leaves the drums");
              [root stopPlayback:nil]; if(!root.drumsOn) [root toggleDrums:nil]; root.pianoPattern=savedPattern; [root refresh]; [root saveState]; }
            // Arranger (spec 1.4): ⇧⌘A turns the circle's progression into a section; the row edits the selected section, never the
            // draft; repeats, cuts, moves, copies, removal and undo; edited notes stay with their section; the song plays part after part.
            { [root stopPlayback:nil]; [root showView:0]; root.loopEnabled=NO; root.rhythmBeat=KvBeatByStyle; if(!root.drumsOn) [root toggleDrums:nil];   // drums by the style: the drums track plays
              kv_song_reset(root.song); [root.sectionTracks removeAllObjects]; [root.songUndo removeAllObjects]; [root.songRedo removeAllObjects];
              [root selectIndex:0 minor:NO]; [root clearProgression:nil]; for(NSNumber *degree in @[@0,@5,@3,@4]) [root addChord:root.addButtons[degree.integerValue]];
              [root.performanceChoice selectItemWithTag:1]; [root performanceChanged:root.performanceChoice];
              [root.meterChoice selectItemAtIndex:KV_METER_4_4]; [root meterChanged:root.meterChoice]; [root.lengthChoice selectItemAtIndex:KV_LENGTH_BAR]; [root lengthChanged:root.lengthChoice];
              NSArray *draft=[root.progression copy];
              [root sendToArranger:nil];
              KV_CHECK(root.viewMode==2 && !root.arranger.hidden && root.circle.hidden && root.roll.hidden && root.song->count==1 && root.editingSection==0 && root.arranger.selected==0,@"Arranger: ⇧⌘A makes the progression a section and shows it");
              KV_CHECK(root.song->sections[0].beat==KV_SECTION_BEAT_SONG,@"Arranger: a section from the circle plays the drums as the metronome does");
              KV_CHECK([root.progression isEqualToArray:draft] && root.song->sections[0].kind==KV_SECTION_VERSE && root.song->sections[0].count==4,@"Arranger: the row shows the section's chords");
              KV_CHECK(root.window.firstResponder==root.arranger || !root.window,@"Arranger: it takes the keys");
              [root showView:0]; [root sendToArranger:nil]; KV_CHECK(root.song->count==1 && root.viewMode==2,@"Arranger: the same progression again selects its section");
              [root showView:0]; [root clearProgression:nil]; for(NSNumber *degree in @[@3,@4,@5,@0]) [root addChord:root.addButtons[degree.integerValue]];
              NSArray *second=[root.progression copy]; [root sendToArranger:nil];
              KV_CHECK(root.song->count==2 && root.editingSection==1 && [root.progression isEqualToArray:second],@"Arranger: a new progression is a new section at the end");
              [root arrangerSelect:0]; KV_CHECK([root.progression isEqualToArray:draft] && root.editingSection==0,@"Arranger: selecting a section loads its chords into the row");
              [root addChord:root.addButtons[1]]; KV_CHECK(root.song->sections[0].count==5,@"Arranger: the row edits the selected section");
              [root showView:0]; KV_CHECK([root.progression isEqualToArray:second] && root.editingSection==-1,@"Arranger: the circle edits the draft, untouched by the section's edit");
              [root showView:2]; KV_CHECK(root.editingSection==0 && root.progression.count==5,@"Arranger: back to the section being edited");
              KV_CHECK([[root arrangerName:0] isEqualToString:@"Куплет 1"] && [[root arrangerName:1] isEqualToString:@"Куплет 2"] && [[root arrangerDetails:0] hasPrefix:@"5 тактов"],@"Arranger: sections are named and measured");
              // Repeats, a cut between passes, a cut that is not allowed, a move, a copy, removal, undo and redo.
              [root arrangerSet:KvSectionFieldRepeats value:2]; KV_CHECK(root.song->sections[0].repeats==2 && fabs(kv_song_beats(root.song)-56)<1e-9,@"Arranger: repeats lengthen the section");
              { double pass=kv_section_pass_beats(root.song,&root.song->sections[0]); [root arrangerSetLength:0 beats:pass]; KvChordLength was=root.chordLength;   // a stretched or cut section keeps its share of passes when the chord length changes
                [root.lengthChoice selectItemAtIndex:KV_LENGTH_TWO_BARS]; [root lengthChanged:root.lengthChoice]; [root storeWorking];
                KV_CHECK(fabs(kv_section_beats(root.song,0)-kv_section_pass_beats(root.song,&root.song->sections[0]))<1e-9 && kv_section_pass_beats(root.song,&root.song->sections[0])>pass,@"Arranger: a section of one pass stays one pass with a longer chord length, not a loop of the old one");
                [root.lengthChoice selectItemAtIndex:was]; [root lengthChanged:root.lengthChoice]; [root storeWorking]; for(int k=0;k<3;k++) [root undoSong]; }   // the length and the two texture changes
              [root arrangerCut:0 atBeat:20]; KV_CHECK(root.song->count==3 && root.song->sections[0].repeats==1 && root.song->sections[1].repeats==1 && fabs(kv_song_beats(root.song)-56)<1e-9 && root.editingSection==1,@"Arranger: a cut between passes splits the repeats");
              [root arrangerCut:0 atBeat:9]; KV_CHECK(root.song->count==4 && fabs(kv_section_beats(root.song,0)-9)<1e-9 && fabs(root.song->sections[1].start-9)<1e-9,@"Arranger: a cut anywhere, inside a chord too");
              [root undoSequence:nil]; KV_CHECK(root.song->count==3,@"Arranger: ⌘Z joins it again");
              [root arrangerCut:0 atBeat:.05]; KV_CHECK(root.song->count==3 && [root.status.stringValue containsString:@"не разрезать"],@"Arranger: a cut at the very edge is refused");
              uint32_t last=root.song->sections[2].id; [root arrangerMove:2 to:0 copy:NO];
              KV_CHECK(root.song->sections[0].id==last && root.editingSection==0 && root.song->sections[0].count==4,@"Arranger: a moved section stays selected");
              [root arrangerMove:0 to:3 copy:YES]; KV_CHECK(root.song->count==4 && root.song->sections[3].count==4 && root.song->sections[3].id!=last && root.editingSection==3,@"Arranger: ⌥-drag copies it to the end");
              [root arrangerRemove:3]; KV_CHECK(root.song->count==3 && root.editingSection==2,@"Arranger: ⌫ removes the section");
              [root undoSequence:nil]; KV_CHECK(root.song->count==4,@"Arranger: ⌘Z brings it back"); [root redoTrack:nil]; KV_CHECK(root.song->count==3,@"Arranger: ⇧⌘Z removes it again");
              // Notes edited in the roll stay with their section.
              [root arrangerOpenInRoll:1]; KV_CHECK(root.viewMode==2 && root.rollDocked && root.editingSection==1 && !root.roll.hidden && !root.arranger.hidden && NSMinY(root.roll.frame)>=NSMaxY(root.arranger.frame),@"Arranger: double-click opens the section in the roll under the tracks");
              KV_CHECK(fabs([root.roll visibleBeats]-kv_section_beats(root.song,1))<1e-6 && root.roll.scrollBeat==root.song->sections[1].start,@"Arranger: the docked roll shows the section from its start to its end");
              KV_CHECK(!root.roll.collapseButton.hidden && root.roll.onlyHand<0,@"Arranger: the docked roll shows «Свернуть» and both hands");
              [root pianoRoll:root.roll openSection:-1]; KV_CHECK(root.viewMode==2 && !root.rollDocked && root.roll.hidden,@"Arranger: «← Аранжировщик» puts the roll away");
              [root arrangerOpenInRoll:1 track:KV_TRACK_BASS]; { size_t left=0,picked=0; [root.roll selectAll]; for(size_t k=0;k<root.track->count;k++) { if(!root.track->events[k].hand) left++; if([root.roll isSelectedAt:k]) picked++; }
                KV_CHECK(root.rollDocked && root.roll.onlyHand==0 && left>0 && picked==left,@"Arranger: the bass region opens the roll on the left hand alone (⌘A takes only it)"); [root.roll deselectAll]; }
              [root.roll keyDown:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@"\x1b" charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53]]; KV_CHECK(!root.rollDocked && root.roll.hidden,@"Arranger: Esc in the docked roll puts it away");
              [root showView:1]; KV_CHECK(root.viewMode==1 && root.editingSection==1 && !root.roll.hidden,@"Arranger: ⌘2 opens the section in the full roll");
              KV_CHECK(!root.roll.sectionChoice.hidden && root.roll.sectionChoice.numberOfItems==(NSInteger)root.song->count+1 && root.roll.sectionChoice.indexOfSelectedItem==2,@"Arranger: the roll lists the song's sections, the open one chosen");
              KV_CHECK([root pianoRollFirstBar:root.roll]==(int)(kv_section_start(root.song,1)/4)+1,@"Arranger: the roll counts the song's bars");
              [root pianoRoll:root.roll openSection:0]; KV_CHECK(root.viewMode==1 && root.editingSection==0 && root.roll.sectionChoice.indexOfSelectedItem==1,@"Arranger: the list opens another section in the roll");
              [root showView:2]; [root arrangerOpenInRoll:1]; KV_CHECK(root.rollDocked && !root.roll.hidden,@"Arranger: the roll docks again"); [root sendToArranger:nil]; KV_CHECK(root.viewMode==2 && !root.rollDocked && root.roll.hidden,@"Arranger: ⇧⌘A puts the docked roll away"); [root showView:1];
              [root pianoRoll:root.roll openSection:1];
              for(NSNumber *width in @[@1120,@1728]) for(NSNumber *height in @[@680,@1000]) { root.frame=NSMakeRect(0,0,width.doubleValue,height.doubleValue); [root layout]; [root.roll layout]; NSString *problem=[root layoutProblem]; KV_CHECK(!problem && NSWidth(root.roll.sectionChoice.frame)>=100,([NSString stringWithFormat:@"Section roll layout %@x%@: %@",width,height,problem])); }
              root.frame=NSMakeRect(0,0,1240,760); [root layout];
              KV_CHECK([root.roll addNoteAtBeat:1 midi:96 duration:.5] && root.trackEdited,@"Arranger: a note added in the roll edits the section");
              [root sendToArranger:nil]; KV_CHECK(root.viewMode==2 && root.song->sections[1].edited && [root arrangerEdited:1],@"Arranger: ⇧⌘A returns to the lane, the section marked edited");
              [root arrangerSelect:0]; KV_CHECK(!root.trackEdited,@"Arranger: another section has its own notes");
              [root arrangerSelect:1]; BOOL found=NO; for(size_t i=0;i<root.track->count;i++) if(root.track->events[i].midi==96) found=YES;
              KV_CHECK(root.trackEdited && found,@"Arranger: the edited notes come back with their section");
              // Lift: the right hand an octave up.
              [root arrangerSelect:0]; KvPerformance *plain=malloc(sizeof(KvPerformance)); *plain=*root.track;
              [root arrangerSet:KvSectionFieldLift value:12]; BOOL lifted=root.track->count==plain->count;
              for(size_t i=0;lifted && i<plain->count;i++) if(plain->events[i].hand && plain->events[i].midi+12<=108 && root.track->events[i].midi!=plain->events[i].midi+12) lifted=NO;
              free(plain); KV_CHECK(lifted,@"Arranger: «right hand an octave up» lifts the right hand in the roll");
              // Layout of the third view at the extreme sizes.
              for(NSNumber *width in @[@1120,@1728]) for(NSNumber *height in @[@680,@1000]) { root.frame=NSMakeRect(0,0,width.doubleValue,height.doubleValue); NSString *problem=[root layoutProblem]?:[root arrangerLayoutProblem]; KV_CHECK(!problem,([NSString stringWithFormat:@"Arranger layout %@x%@: %@",width,height,problem])); }
              KV_CHECK(NSMaxY(root.arranger.frame)>NSHeight(root.bounds)-KvDockHeight()+100,@"Arranger: without the keyboard the tracks take its room");
              root.frame=NSMakeRect(0,0,1240,760); [root layout]; [root.arranger layout];
              NSRect first=[root.arranger rectOfSection:0],next=[root.arranger rectOfSection:1];
              KV_CHECK(NSWidth(first)>20 && NSMinX(next)>NSMaxX(first) && NSMaxX([root.arranger rectOfSection:2])<=NSWidth(root.arranger.bounds),@"Arranger: the lane lays the sections out in order, inside the view");
              // The song plays: the first section, then the next on its own, with the playhead moving through the lane.
              [root applyTempo:240]; [root playSongFrom:0];
              KV_CHECK(root.songPlaying && [root isPlayingProgression] && root.songOrder.count==3,@"Arranger: Space plays the song");
              NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];
              while(root.songPart==0 && kv_audio_is_playing(root.audio) && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
              double beat=[root arrangerPlayheadBeat];
              KV_CHECK(root.songPart==1 && root.songPlaying && beat>=kv_section_start(root.song,1)-.5 && beat<kv_section_start(root.song,2),@"Arranger: the second section follows the first, the playhead in it");
              KV_CHECK(root.playingDegrees.count==root.song->sections[1].count,@"Arranger: the keyboard follows the playing section's chords");
              { double was=kv_section_beats(root.song,2); [root arrangerSetLength:2 beats:was*2]; [root updateSongPlayback];   // edited while it plays: the order after the playing part follows the song
                NSUInteger last=root.songOrder.count-1; double planned=0; for(NSUInteger k=0;k<=last;k++) if(root.songOrder[k].integerValue==2) planned+=root.songOrderLength[k].doubleValue;
                KV_CHECK(root.songPlaying && root.songPart==1 && fabs(planned-was*2)<1e-9,@"Arranger: a section lengthened while the song plays is queued at its new length"); [root undoSong]; [root updateSongPlayback]; }
              { int wasCount=root.generateCount; [root arrangerSelect:2]; [root playSongFromBeat:kv_section_start(root.song,2)+1]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.3]];   // section 2: nothing later depends on its chords
                BOOL before=root.songPlaying; double ph=[root arrangerPlayheadBeat]; NSString *st=root.status.stringValue; root.generateCount=4; [root generateProgression:nil]; root.generateCount=wasCount;   // new chords for the playing section: the song goes on, not the section alone
                KV_CHECK(root.songPlaying && root.songOrder.count>=1 && root.song->sections[root.editingSection].count==4 && [root arrangerPlayheadBeat]>=kv_section_start(root.song,(size_t)root.editingSection)-.5,([NSString stringWithFormat:@"Arranger: ⌘N on the playing section keeps the song going with the new chords (playing %d, order %lu, chords %zu, playhead %.1f, start %.1f, editing %ld; before %d at %.1f «%@», after «%@»)",root.songPlaying,(unsigned long)root.songOrder.count,root.song->sections[MAX(0,root.editingSection)].count,[root arrangerPlayheadBeat],kv_section_start(root.song,(size_t)MAX(0,root.editingSection)),(long)root.editingSection,before,ph,st,root.status.stringValue])); [root stopPlayback:nil]; [root arrangerSelect:1]; }
              [root stopPlayback:nil]; KV_CHECK(!root.songPlaying && !kv_audio_is_playing(root.audio),@"Arranger: Stop ends the song");
              [root applyTempo:100];
              // Tracks and regions (spec 1.5 §2): M on the bass region takes the left hand out, the melody's level softens it,
              // S leaves one track, the beat lies on the drums track and follows its level and M; ⌘Z undoes each.
              { [root arrangerSelect:0]; KvSectionBeat was=root.song->sections[0].beat; NSData *all=[root arrangerNotes:0]; const KvPianoEvent *e=all.bytes; size_t left=0,now=0; float loud=0,soft=0;
                for(size_t k=0;k<all.length/sizeof(*e);k++) { if(!e[k].hand) left++; else loud=fmaxf(loud,e[k].velocity); }
                [root arrangerSetRegion:KV_TRACK_BASS mute:1 level:-1]; NSData *bare=[root arrangerNotes:0]; e=bare.bytes; for(size_t k=0;k<bare.length/sizeof(*e);k++) if(!e[k].hand) now++;
                KV_CHECK(left>0 && !now && bare.length && root.arranger.regionMutes[KV_TRACK_BASS].state==NSControlStateValueOn,@"Tracks: M on the bass region takes the left hand out of the section");
                [root undoSong]; KV_CHECK(!root.song->sections[0].regions[KV_TRACK_BASS].mute && [root arrangerNotes:0].length==all.length,@"Tracks: ⌘Z brings the bass back");
                [root arrangerSetTrack:KV_TRACK_MELODY mute:-1 solo:-1 level:.5]; NSData *quiet=[root arrangerNotes:0]; e=quiet.bytes; for(size_t k=0;k<quiet.length/sizeof(*e);k++) if(e[k].hand) soft=fmaxf(soft,e[k].velocity);
                KV_CHECK(soft>0 && soft<loud*.6f && fabs(root.arranger.trackLevels[KV_TRACK_MELODY].doubleValue-50)<1,@"Tracks: the melody track's level softens its notes");
                [root undoSong]; [root arrangerSetTrack:KV_TRACK_BASS mute:-1 solo:1 level:-1];
                KV_CHECK(!kv_region_audible(root.song,0,KV_TRACK_MELODY) && kv_region_audible(root.song,0,KV_TRACK_BASS) && root.arranger.trackSolos[KV_TRACK_BASS].state==NSControlStateValueOn,@"Tracks: S leaves the soloed track alone");
                [root undoSong]; [root arrangerSet:KvSectionFieldBeat value:4]; NSData *beat=[root arrangerHits:0]; const KvHit *h=beat.bytes; BOOL inside=beat.length>0;
                for(size_t k=0;k<beat.length/sizeof(*h);k++) if(h[k].beat<-1e-9 || h[k].beat>=kv_section_beats(root.song,0)) inside=NO;
                KV_CHECK(inside,@"Tracks: the section's beat lies on the drums track, inside the section");
                { [root arrangerSelect:1]; [root arrangerSet:KvSectionFieldBeat value:KV_SECTION_BEAT_SONG]; NSData *after=[root arrangerHits:1]; size_t per=0; for(size_t k=0;k<beat.length/sizeof(KvHit);k++) if(h[k].beat<kv_meter_bar(root.song->meter)-1e-9) per++;
                  size_t first=0; for(size_t k=0;k<after.length/sizeof(KvHit);k++) if(((const KvHit *)after.bytes)[k].beat<kv_meter_bar(root.song->meter)-1e-9) first++;
                  KV_CHECK(after.length && first==per,@"Tracks: «как перед ней» goes on with the beat of the section before"); [root undoSong]; [root arrangerSelect:0]; }
                [root arrangerSetTrack:KV_TRACK_DRUMS mute:-1 solo:-1 level:.5]; NSData *half=[root arrangerHits:0];
                KV_CHECK(half.length==beat.length && ((const KvHit *)half.bytes)[0].velocity<h[0].velocity,@"Tracks: the drums track's level softens the beat"); [root undoSong];
                [root arrangerSetRegion:KV_TRACK_DRUMS mute:1 level:-1]; KV_CHECK(![root arrangerHits:0].length,@"Tracks: M on the drums region silences its beat"); [root undoSong]; [root undoSong];
                KV_CHECK(root.song->sections[0].beat==was && root.song->track_level[KV_TRACK_DRUMS]==1,@"Tracks: ⌘Z undoes them all"); }
              // Saved with the settings: a restart brings the song, its edited section, its regions, lanes and the view back.
              root.song->sections[2].regions[KV_TRACK_BASS].mute=YES; root.song->sections[2].regions[KV_TRACK_MELODY].shift=.5; root.song->track_level[KV_TRACK_DRUMS]=.8f;
              [root saveState]; KvRoot *again=[[KvRoot alloc] initWithFrame:root.frame];
              KV_CHECK(again.song->count==3 && again.song->sections[1].edited && again.viewMode==2 && again.song->sections[0].lift==12,@"Arranger: the song survives a restart");
              KV_CHECK(again.song->sections[2].regions[KV_TRACK_BASS].mute && fabs(again.song->sections[2].regions[KV_TRACK_MELODY].shift-.5)<1e-9 && fabs(again.song->track_level[KV_TRACK_DRUMS]-.8f)<1e-6,@"Arranger: regions and lanes survive a restart");
              [again stopPlayback:nil];
              { // A song saved by Tonora 1.4 (version 1) opens: whole passes, every region and lane at full level.
                NSDictionary *old=@{@"version":@1,@"nextId":@2,@"sections":@[@{@"id":@1,@"kind":@1,@"name":@"",@"codes":@[@0,@5,@3,@4],@"repeats":@2,@"style":@0,@"length":@2,@"fills":@0,@"seed":@0,
                    @"generated":@NO,@"blocks":@NO,@"arpeggio":@NO,@"arpeggioPattern":@0,@"division":@0,@"strings":@0,@"level":@1,@"beat":@0,@"beatFixed":@0,@"lift":@0,@"transition":@0,@"edited":@NO}],@"tracks":@{},@"selected":@0};
                NSDictionary *now=[root songPlist]; KvSong *kept=malloc(sizeof(KvSong)); memcpy(kept,root.song,sizeof(KvSong));
                KV_CHECK([root loadSongPlist:old] && root.song->count==1 && kv_section_beats(root.song,0)==32 && root.song->sections[0].regions[KV_TRACK_BASS].level==1 && !root.song->sections[0].regions[KV_TRACK_BASS].mute && root.song->track_level[KV_TRACK_MELODY]==1,@"Arranger: a 1.4 song opens with full levels");
                KV_CHECK([root loadSongPlist:now] && root.song->count==kept->count,@"Arranger: and the current one comes back"); free(kept); [root reloadEditing:0]; }
              [root showView:0]; KV_CHECK(root.editingSection==-1 && [root.progression isEqualToArray:second],@"Arranger: the circle has the draft back");
              KV_CHECK(root.inspectorTab==0 && root.arranger.sectionPanel.hidden && !root.piano.hidden && ![root.inspectorTabs isEnabledForSegment:3],@"Arranger: the circle has its keyboard and «Аккорды» back");
              [root showView:1]; KV_CHECK(root.roll.sectionChoice.hidden && ![root pianoRollSections:root.roll] && [root pianoRollFirstBar:root.roll]==1,@"Arranger: the draft's roll has no section list"); [root showView:0]; if(root.metronomeOn) [root toggleMetronome:nil]; root.rhythmBeat=-1; }
            // Arranger suggestions: ghosts under the hovered section, kept while the mouse moves onto them, with an explanation;
            // a click inserts the chorus led in by a rise; a seam takes a transition; other choruses differ; a ghost can be heard.
            { [root stopPlayback:nil]; [root showView:0]; root.rhythmBeat=KvBeatByStyle; if(!root.drumsOn) [root toggleDrums:nil];
              NSWindow *hoverWindow=root.window?nil:[[NSWindow alloc] initWithContentRect:root.frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:YES]; if(hoverWindow) hoverWindow.contentView=root;
              kv_song_reset(root.song); [root.sectionTracks removeAllObjects]; [root.songUndo removeAllObjects];
              [root clearProgression:nil]; for(NSNumber *degree in @[@0,@5,@3,@4]) [root addChord:root.addButtons[degree.integerValue]];
              [root sendToArranger:nil]; root.frame=NSMakeRect(0,0,1240,760); [root layout]; [root.arranger layout]; [root.arranger reload];
              NSRect verse=[root.arranger rectOfSection:0],slot=[root.arranger endSlotRect];
              [root.arranger hoverAtPoint:NSMakePoint(NSMidX(verse),NSMidY(verse))]; KV_CHECK(root.arranger.hoverSection<0,@"Suggestions: a section's marker itself shows no ghosts");
              [root.arranger hoverAtPoint:NSMakePoint(NSMidX(slot),NSMidY(slot))];
              NSArray<NSValue *> *ghosts=[root.arranger ghostRectsAfter:0]; NSArray *offers=[root arrangerSuggestions:0];
              KV_CHECK(root.arranger.hoverSection==0 && ghosts.count==offers.count && offers.count>=3 && NSMinX(slot)>=NSMaxX(verse),@"Suggestions: the «+» after the song shows what may follow");
              KV_CHECK([offers[0][@"kind"] intValue]==KV_SECTION_CHORUS && [offers[0][@"leadBeats"] doubleValue]>0 && [offers[0][@"chorus"] boolValue],@"Suggestions: a chorus led in by a rise comes first");
              NSRect first=ghosts[0].rectValue,second=ghosts[1].rectValue;
              KV_CHECK(NSMinY(first)>NSMaxY(verse) && NSMinX(second)>NSMaxX(first) && NSWidth(first)>NSWidth(second),@"Suggestions: ghosts sit under the section, in a row, as long as what they insert");
              [root.arranger hoverAtPoint:NSMakePoint(NSMidX(first),NSMidY(first))];
              KV_CHECK(root.arranger.hoverSection==0 && root.arranger.hoverGhost==0,@"Suggestions: moving down onto a ghost keeps the row");
              NSString *tip=offers[0][@"tip"];   // the bubble's text (the self-test window is off screen, so no bubble shows)
              KV_CHECK([tip hasPrefix:@"Подъём → Припев"] && [tip containsString:@"арпеджио вверх"] && [tip containsString:@"Щелчок — вставить"] && [tip containsString:@"⌥-щелчок"],@"Suggestions: the explanation names the rise, what it does and the chorus");
              [root.arranger hoverAtPoint:NSMakePoint(NSMidX(first),NSHeight(root.arranger.bounds)-4)]; KV_CHECK(root.arranger.hoverSection<0 && root.arranger.hoverGhost<0,@"Suggestions: they go when the mouse leaves");
              NSArray *variants=[root arrangerChorusVariants:0]; KV_CHECK(variants.count==3 && ![variants[0] isEqualToString:variants[1]] && ![variants[1] isEqualToString:variants[2]],@"Suggestions: ⌥-click offers three other choruses");
              [root arrangerAudition:0 after:0]; KV_CHECK([root isPlayingProgression] && root.auditioningGhost,@"Suggestions: Space over a ghost plays it");
              [root arrangerAudition:-1 after:0]; KV_CHECK(!kv_audio_is_playing(root.audio),@"Suggestions: and stops");
              [root arrangerAccept:0 after:0];
              KV_CHECK(root.song->count==3 && root.song->sections[1].kind==KV_SECTION_TRANSITION && root.song->sections[1].transition==KV_TRANSITION_RISE && root.song->sections[2].kind==KV_SECTION_CHORUS && root.editingSection==2,@"Suggestions: a click inserts the rise and the chorus, the chorus selected");
              KV_CHECK(root.song->sections[1].codes[0]==KV_CODE_SECONDARY+kv_code_base(root.song->sections[2].codes[0]) || kv_code_base(root.song->sections[2].codes[0])==0,@"Suggestions: the rise is the dominant of the chorus's first chord");
              KV_CHECK([[root arrangerName:1] isEqualToString:@"Подъём"] && [[root arrangerName:2] isEqualToString:@"Припев"],@"Suggestions: names of the new sections");
              offers=[root arrangerSuggestions:2]; KV_CHECK([offers[0][@"kind"] intValue]==KV_SECTION_PIT,@"Suggestions: after a chorus, a breakdown first");
              [root arrangerAccept:0 after:2]; KV_CHECK(root.song->count==4 && root.song->sections[3].kind==KV_SECTION_PIT,@"Suggestions: the breakdown follows the chorus");
              [root.arranger layout]; NSRect pit=[root.arranger rectOfSection:3];
              (void)pit; { NSMenu *menu=[root.arranger menuForSection:2 track:-1 beat:0]; NSMenuItem *ways=nil,*next=nil;
                for(NSMenuItem *item in menu.itemArray) { if([item.title isEqualToString:T(@"Вставить переход после")]) ways=item; if([item.title isEqualToString:T(@"Добавить после")]) next=item; }
                KV_CHECK(ways.submenu.numberOfItems==KV_TRANSITION_KINDS && next.submenu.numberOfItems==(NSInteger)[root arrangerSuggestions:2].count,@"Suggestions: a section's menu inserts a transition after it, or what may follow"); }
              [root arrangerTransitionAfter:2 kind:-1]; KV_CHECK(root.song->count==5 && root.song->sections[3].kind==KV_SECTION_TRANSITION && root.song->sections[3].transition==KV_TRANSITION_BREAK,@"Suggestions: chorus → breakdown gets a break");
              { KvHit hits[KV_BEAT_HITS]; size_t n=0; int on=[root rhythmOfSection:3 hits:hits count:&n];
                KV_CHECK(on==1 && n==1 && hits[0].drum==KV_DRUM_KICK,@"Suggestions: a break plays one kick under it");
                on=[root rhythmOfSection:1 hits:hits count:&n]; KV_CHECK(on==1 && n==17 && hits[16].drum==KV_DRUM_SNARE,@"Suggestions: a rise plays a snare roll under it"); }
              [root undoSequence:nil]; KV_CHECK(root.song->count==4,@"Suggestions: ⌘Z takes the transition back");
              KvPerformance plan; for(NSInteger i=0;i<(NSInteger)root.song->count;i++) KV_CHECK([root songPart:i from:0 length:kv_section_beats(root.song,(size_t)i) into:&plan],([NSString stringWithFormat:@"Suggestions: section %ld plays",(long)i]));
              { // The song as MIDI: every section's notes, the chorus's beat on channel 10, a marker per section; imported back, no drums.
                NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"tonora-song.mid"]; KV_CHECK([root exportSongToPath:path],@"Song MIDI: the file is written");
                NSData *file=[NSData dataWithContentsOfFile:path]; const uint8_t *bytes=file.bytes; BOOL drums=NO,marker=NO;
                for(NSUInteger i=0;i+2<file.length;i++) { if(bytes[i]==0x99) drums=YES; if(bytes[i]==0xff && bytes[i+1]==0x06) marker=YES; }
                KV_CHECK(file.length>14 && bytes[11]==4 && drums && marker,@"Song MIDI: four tracks, drums on channel 10, section markers");
                KvMidiSong *back=calloc(1,sizeof(KvMidiSong)); KV_CHECK(back && kv_midi_decode(bytes,file.length,back) && fabs(back->length-kv_song_beats(root.song))<1.01,@"Song MIDI: it reads back as long as the song");
                size_t expected=0; for(NSInteger i=0;i<(NSInteger)root.song->count;i++) { double length=kv_section_beats(root.song,(size_t)i),pass=kv_section_pass_beats(root.song,&root.song->sections[i]);
                    for(double from=0;from<length-1e-9;from+=pass) { [root songPart:i from:from length:fmin(pass,length-from) into:&plan]; expected+=plan.count; } }
                KV_CHECK(back->count+back->dropped==expected,@"Song MIDI: every note of every section and repeat, no drum among them"); free(back);
                // One track: the bass alone (the left hand, no drums), the drums alone (no notes).
                size_t left=0; for(NSInteger i=0;i<(NSInteger)root.song->count;i++) { NSData *d=[root arrangerNotes:i]; const KvPianoEvent *e=d.bytes; for(size_t k=0;k<d.length/sizeof(*e);k++) if(!e[k].hand) left++; }
                KV_CHECK([root exportSongToPath:path tracks:2],@"Song MIDI: the bass alone is written"); file=[NSData dataWithContentsOfFile:path]; bytes=file.bytes; drums=file.length>14 && bytes[11]==4;   // a drum track makes four
                back=calloc(1,sizeof(KvMidiSong));
                KV_CHECK(back && kv_midi_decode(bytes,file.length,back) && back->count+back->dropped==left && !drums,@"Song MIDI: the bass alone holds every left-hand note and no drum"); free(back);
                KV_CHECK([root exportSongToPath:path tracks:3],@"Song MIDI: the drums alone are written"); file=[NSData dataWithContentsOfFile:path]; bytes=file.bytes; drums=file.length>14 && bytes[11]==4;
                back=calloc(1,sizeof(KvMidiSong));
                KV_CHECK(back && kv_midi_decode(bytes,file.length,back) && back->count==0 && drums,@"Song MIDI: the drums alone hold the beat and no note"); free(back);
                [NSFileManager.defaultManager removeItemAtPath:path error:NULL]; }
              { // Tools, snap, zoom, the ruler and the cycle (spec 1.5 §4), by real events on the tracks.
                KvArranger *arr=root.arranger; [root.window makeFirstResponder:arr]; root.loopButton.state=NSControlStateValueOff; [root loopChanged:root.loopButton];
                NSEvent *(^mouse)(NSEventType,NSPoint,NSInteger,NSEventModifierFlags)=^NSEvent *(NSEventType type,NSPoint p,NSInteger clicks,NSEventModifierFlags flags) {
                    return [NSEvent mouseEventWithType:type location:[arr convertPoint:p toView:nil] modifierFlags:flags timestamp:0 windowNumber:arr.window.windowNumber context:nil eventNumber:0 clickCount:clicks pressure:1]; };
                NSEvent *(^key)(unsigned short,NSEventModifierFlags)=^NSEvent *(unsigned short code,NSEventModifierFlags flags) {
                    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:arr.window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code]; };
                void (^click)(NSPoint,NSInteger,NSEventModifierFlags)=^(NSPoint p,NSInteger clicks,NSEventModifierFlags flags) { [arr mouseDown:mouse(NSEventTypeLeftMouseDown,p,clicks,flags)]; [arr mouseUp:mouse(NSEventTypeLeftMouseUp,p,clicks,flags)]; };
                double bar=kv_meter_bar(root.song->meter); CGFloat rulerY=40,melodyY=NSMidY([arr rectOfRegion:0 track:KV_TRACK_MELODY]); size_t count=root.song->count;
                KV_CHECK(kv_section_beats(root.song,0)>=3*bar,@"Tools: the verse is long enough to cut");
                [arr keyDown:key(34,0)]; KV_CHECK(arr.tool==KvToolScissors && arr.toolChoice.selectedSegment==1,@"Tools: I takes the scissors");
                [arr keyDown:key(35,0)]; KV_CHECK(arr.tool==KvToolPencil && arr.toolChoice.selectedSegment==2,@"Tools: P the pencil");
                [arr keyDown:key(53,0)]; KV_CHECK(arr.tool==KvToolPointer && !kv_audio_is_playing(root.audio),@"Tools: Esc goes back to the pointer and stops nothing");
                [arr keyDown:key(17,0)]; KV_CHECK(arr.tool==KvToolPointer && !kv_audio_is_playing(root.audio),@"Tools: T is the pointer here, not the tonic");
                // Zoom: the whole song, closer around the mouse, a step out; the smart snap follows it.
                [arr keyDown:key(6,0)]; KV_CHECK(arr.zoom==1 && arr.scrollBeat==0 && arr.scale*bar>=18-1e-9 && [arr snapGrid:0]==bar,@"Zoom: Z shows the whole song, a bar at least 18 pt, the smart snap on bars");
                CGFloat x=NSMidX([arr rectOfSection:2]); double under=[arr beatAtX:x]; [arr zoomBy:4 aroundX:x];
                KV_CHECK(fabs(arr.zoom-4)<1e-9 && fabs([arr beatAtX:x]-under)<1e-6 && [arr snapGrid:0]<bar && [arr snapGrid:NSEventModifierFlagControl]==0,@"Zoom: closer, the beat under the mouse stays; the snap finer, none with ⌃");
                [arr keyDown:key(123,NSEventModifierFlagCommand)]; KV_CHECK(fabs(arr.zoom-4/1.5)<1e-9,@"Zoom: ⌘← a step out");
                [arr showWholeSong:nil]; arr.snap=KvSnapBar; KV_CHECK(arr.snapChoice.indexOfSelectedItem==KvSnapBar && [arr snapGrid:0]==bar,@"Snap: «Такт» snaps to bars");
                { [root arrangerSelect:0]; [root arrangerSet:KvSectionFieldRepeats value:8]; [arr showWholeSong:nil]; NSRect rise=[arr rectOfSection:1];
                  BOOL inverse=YES; for(double b=0;b<kv_song_beats(root.song);b+=.5) if(fabs([arr beatAtX:[arr xOfBeat:b]]-b)>1e-6) inverse=NO;
                  KV_CHECK(root.song->sections[1].kind==KV_SECTION_TRANSITION && arr.scale*bar<28 && NSWidth(rise)+2>=28-1e-6 && inverse,@"Zoom: a one-bar transition stays 28 pt wide in a long song, beats and points still map both ways");
                  [root undoSong]; [arr showWholeSong:nil]; }
                // The ruler: a click puts the playhead on the bar and nothing starts; Space plays from exactly there; Space stops and the
                // playhead stays; a click while playing goes on from there; a double click plays from there; a drag moves the playhead.
                rulerY=48; CGFloat cycleY=34;
                click(NSMakePoint([arr xOfBeat:2*bar+.3],rulerY),1,0);
                KV_CHECK(fabs(arr.cursorBeat-2*bar)<1e-9 && !root.songPlaying,@"Ruler: a click puts the playhead on the bar, nothing starts");
                [root togglePlayback:nil]; KV_CHECK(root.songPlaying && fabs(root.songOrderBeats[0].doubleValue-2*bar)<1e-9 && [root arrangerPlayheadBeat]>=2*bar-.01 && [root arrangerPlayheadBeat]<2*bar+1,@"Ruler: Space plays from exactly the playhead");
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.3]]; [root togglePlayback:nil];
                KV_CHECK(!root.songPlaying && arr.cursorBeat>2*bar,@"Ruler: Space stops it and the playhead stays where it stopped");
                [root togglePlayback:nil]; KV_CHECK(root.songPlaying && root.songOrderBeats[0].doubleValue>2*bar,@"Ruler: Space goes on from there");
                click(NSMakePoint([arr xOfBeat:bar],rulerY),1,0); KV_CHECK(root.songPlaying && fabs(root.songOrderBeats[0].doubleValue-bar)<1e-9,@"Ruler: a click while it plays goes on from there");
                [root stopPlayback:nil]; click(NSMakePoint([arr xOfBeat:3*bar],rulerY),1,0); click(NSMakePoint([arr xOfBeat:3*bar],rulerY),2,0);
                KV_CHECK(root.songPlaying && fabs(root.songOrderBeats[0].doubleValue-3*bar)<1e-9,@"Ruler: a double click plays from there");
                [root stopPlayback:nil];
                { NSPoint from=NSMakePoint([arr xOfBeat:bar],rulerY),to=NSMakePoint([arr xOfBeat:2*bar+.2],rulerY);
                  [arr mouseDown:mouse(NSEventTypeLeftMouseDown,from,1,0)]; [arr mouseDragged:mouse(NSEventTypeLeftMouseDragged,to,1,0)]; [arr mouseUp:mouse(NSEventTypeLeftMouseUp,to,1,0)];
                  KV_CHECK(fabs(arr.cursorBeat-2*bar)<1e-9 && root.song->cycle_to==0 && !root.songPlaying,@"Ruler: a drag moves the playhead, no cycle, nothing starts"); }
                // The cycle: drawn in the strip over the numbers, which switches ↻ on; a click on it switches ↻; the song still starts at the
                // playhead and comes round to the cycle's start at its end.
                NSPoint a=NSMakePoint([arr xOfBeat:bar+.2],cycleY),b=NSMakePoint([arr xOfBeat:3*bar-.2],cycleY); double kept=arr.cursorBeat;
                [arr mouseDown:mouse(NSEventTypeLeftMouseDown,a,1,0)]; [arr mouseDragged:mouse(NSEventTypeLeftMouseDragged,b,1,0)]; [arr mouseUp:mouse(NSEventTypeLeftMouseUp,b,1,0)];
                KV_CHECK(fabs(root.song->cycle_from-bar)<1e-9 && fabs(root.song->cycle_to-3*bar)<1e-9 && fabs(arr.cursorBeat-kept)<1e-9 && !root.songPlaying && root.loopEnabled,@"Cycle: a drag in the strip draws it on bars and switches ↻ on, the playhead stays");
                click(NSMakePoint([arr xOfBeat:2*bar],cycleY),1,0); KV_CHECK(!root.loopEnabled,@"Cycle: a click on it switches ↻ off");
                click(NSMakePoint([arr xOfBeat:2*bar],cycleY),1,0); KV_CHECK(root.loopEnabled,@"Cycle: and on");
                arr.cursorBeat=0; [root togglePlayback:nil];
                NSUInteger k=0; while(k<root.songOrder.count && root.songOrderBeats[k].doubleValue+root.songOrderLength[k].doubleValue<3*bar-1e-9) k++; k++;   // the part that ends at the cycle's end, then the next
                KV_CHECK(root.songPlaying && fabs(root.songOrderBeats[0].doubleValue-bar)<1e-9 && k<=root.songOrder.count && fabs(root.songOrderBeats[k-1].doubleValue+root.songOrderLength[k-1].doubleValue-3*bar)<1e-9,@"Cycle: with ↻ Space plays from the cycle's start up to its end");
                [root queueSongPart:(NSInteger)root.songOrder.count]; KV_CHECK(root.songOrder.count>k && fabs(root.songOrderBeats[k].doubleValue-bar)<1e-9,@"Cycle: and comes round to its start");
                [root stopPlayback:nil]; root.loopButton.state=NSControlStateValueOff; [root loopChanged:root.loopButton];
                { NSPoint mid=NSMakePoint([arr xOfBeat:2*bar],cycleY); arr.snap=KvSnapBar;   // the cycle carried by its middle keeps its length; an edge stretches it
                  void (^drag)(NSPoint,NSPoint,NSEventModifierFlags)=^(NSPoint from,NSPoint to,NSEventModifierFlags flags) { [arr mouseDown:mouse(NSEventTypeLeftMouseDown,from,1,flags)]; [arr mouseDragged:mouse(NSEventTypeLeftMouseDragged,to,1,flags)]; [arr mouseUp:mouse(NSEventTypeLeftMouseUp,to,1,flags)]; };
                  drag(mid,NSMakePoint([arr xOfBeat:3*bar],cycleY),0); KV_CHECK(fabs(root.song->cycle_from-2*bar)<1e-9 && fabs(root.song->cycle_to-4*bar)<1e-9,@"Cycle: dragged by its middle it moves a bar whole");
                  drag(NSMakePoint([arr xOfBeat:4*bar],cycleY),NSMakePoint([arr xOfBeat:5*bar],cycleY),0); KV_CHECK(fabs(root.song->cycle_from-2*bar)<1e-9 && fabs(root.song->cycle_to-5*bar)<1e-9,@"Cycle: its right edge stretches it");
                  arr.snap=KvSnapSmart; }
                [arr clearCycle:nil]; KV_CHECK(root.song->cycle_to==0,@"Cycle: «Снять цикл» clears it");
                // Scissors: the tool or ⌘ with the pointer; ⌘T at the playhead.
                arr.tool=KvToolScissors; click(NSMakePoint([arr xOfBeat:bar+.4],melodyY),1,0);
                KV_CHECK(root.song->count==count+1 && fabs(kv_section_beats(root.song,0)-bar)<1e-9,@"Scissors: a click cuts the section on the bar");
                [root undoSong]; arr.tool=KvToolPointer; click(NSMakePoint([arr xOfBeat:2*bar+.4],melodyY),1,NSEventModifierFlagCommand);
                KV_CHECK(root.song->count==count+1 && fabs(kv_section_beats(root.song,0)-2*bar)<1e-9,@"Scissors: ⌘-click with the pointer cuts too");
                [root undoSong]; arr.cursorBeat=bar; [root arrangerSelect:0]; [root cutSection:nil];
                KV_CHECK(root.song->count==count+1 && fabs(kv_section_beats(root.song,0)-bar)<1e-9,@"Scissors: ⌘T cuts at the playhead");
                [root undoSong]; KV_CHECK(root.song->count==count,@"Scissors: ⌘Z joins it back");
                // Pencil: the circle's progression after the song's end, or at the nearest seam.
                arr.tool=KvToolPencil; NSArray *draft=root.editingSection>=0?root.draftState[@"progression"]:root.progression;
                click(NSMakePoint([arr xOfBeat:kv_song_beats(root.song)]+30,melodyY),1,0);
                BOOL same=root.song->count==count+1 && root.song->sections[count].count==draft.count; for(NSUInteger i=0;same && i<draft.count;i++) same=root.song->sections[count].codes[i]==[draft[i] intValue];
                KV_CHECK(same && root.editingSection==(NSInteger)count,@"Pencil: a click after the song puts the circle's progression there");
                [root undoSong]; click(NSMakePoint(NSMinX([arr rectOfSection:2])+6,melodyY),1,0);
                KV_CHECK(root.song->count==count+1 && root.song->sections[2].kind==KV_SECTION_VERSE && root.editingSection==2,@"Pencil: on a section's left half it goes in before it");
                [root undoSong]; arr.tool=KvToolPointer; arr.snap=KvSnapSmart; arr.cursorBeat=0;
                KV_CHECK(root.song->count==count,@"Pencil: ⌘Z takes it back");
                // Corners (spec 1.5 §4): top right — the repeats, bottom right — the length on the snap, bottom left — the start.
                arr.snap=KvSnapBar; [arr showWholeSong:nil];
                void (^drag)(NSPoint,NSPoint,NSEventModifierFlags)=^(NSPoint from,NSPoint to,NSEventModifierFlags flags) { [arr mouseDown:mouse(NSEventTypeLeftMouseDown,from,1,flags)]; [arr mouseDragged:mouse(NSEventTypeLeftMouseDragged,to,1,flags)]; [arr mouseUp:mouse(NSEventTypeLeftMouseUp,to,1,flags)]; };
                NSPoint (^bassMid)(NSInteger)=^NSPoint(NSInteger i) { NSRect r=[arr rectOfRegion:i track:KV_TRACK_BASS]; return NSMakePoint(NSMidX(r),NSMidY(r)+10); };
                NSPoint (^markerMid)(NSInteger)=^NSPoint(NSInteger i) { NSRect r=[arr rectOfSection:i]; return NSMakePoint(NSMidX(r),NSMidY(r)); };
                NSRect verse=[arr rectOfRegion:0 track:KV_TRACK_BASS]; double verseBeats=kv_section_beats(root.song,0),pass=kv_section_pass_beats(root.song,&root.song->sections[0]);
                drag(NSMakePoint(NSMaxX(verse)-2,NSMinY(verse)+4),NSMakePoint(NSMinX(verse)+(CGFloat)(2*pass*arr.scale),NSMinY(verse)+4),0);
                KV_CHECK(root.song->sections[0].repeats==2 && root.song->sections[0].length==0 && fabs(kv_section_beats(root.song,0)-2*pass)<1e-9,@"Corners: the top right one sets the repeats");
                [root undoSong]; drag(NSMakePoint(NSMaxX(verse)-2,NSMaxY(verse)-4),NSMakePoint(NSMinX(verse)+(CGFloat)((verseBeats-bar+.3)*arr.scale),NSMaxY(verse)-4),0);
                KV_CHECK(fabs(kv_section_beats(root.song,0)-(verseBeats-bar))<1e-9 && root.song->count==count,@"Corners: the bottom right one shortens the section on the bar");
                [root undoSong]; drag(NSMakePoint(NSMinX(verse)+2,NSMaxY(verse)-4),NSMakePoint(NSMinX(verse)+(CGFloat)((bar+.2)*arr.scale),NSMaxY(verse)-4),0);
                KV_CHECK(fabs(root.song->sections[0].start-bar)<1e-9 && fabs(kv_section_beats(root.song,0)-(verseBeats-bar))<1e-9,@"Corners: the bottom left one starts the section a bar later in its progression");
                [root undoSong]; KV_CHECK(fabs(kv_section_beats(root.song,0)-verseBeats)<1e-9 && root.song->sections[0].start==0,@"Corners: ⌘Z undoes each");
                { NSRect marker=[arr rectOfSection:0]; drag(NSMakePoint(NSMaxX(marker)-2,NSMidY(marker)),NSMakePoint(NSMinX(marker)+(CGFloat)((verseBeats-bar+.3)*arr.scale),NSMidY(marker)),0);
                  BOOL shorter=fabs(kv_section_beats(root.song,0)-(verseBeats-bar))<1e-9; [root undoSong]; NSRect middle=[arr rectOfRegion:0 track:KV_TRACK_BASS];
                  drag(NSMakePoint(NSMaxX(middle)-2,NSMidY(middle)),NSMakePoint(NSMinX(middle)+(CGFloat)((verseBeats-bar+.3)*arr.scale),NSMidY(middle)),0);
                  KV_CHECK(shorter && fabs(kv_section_beats(root.song,0)-(verseBeats-bar))<1e-9,@"Corners: the right edge shortens the section, on its marker and halfway down a region"); [root undoSong]; }
                // The buttons of the region under the pointer.
                NSRect chorus=[arr rectOfRegion:2 track:KV_TRACK_MELODY]; [arr hoverAtPoint:NSMakePoint(NSMidX(chorus),NSMidY(chorus))];
                NSArray<NSValue *> *buttons=[arr buttonRectsOf:2 track:KV_TRACK_MELODY]; NSPoint (^centre)(NSInteger)=^NSPoint(NSInteger k) { return NSMakePoint(NSMidX(buttons[k].rectValue),NSMidY(buttons[k].rectValue)); };
                KV_CHECK(arr.hoverRegion==2 && arr.hoverTrack==KV_TRACK_MELODY && buttons.count==4,@"Buttons: the region under the pointer shows ✎ ✂ ⧉ ✕");
                click(centre(2),1,0); KV_CHECK(root.song->count==count+1 && root.song->sections[3].kind==root.song->sections[2].kind && root.editingSection==3,@"Buttons: ⧉ duplicates the section after itself");
                [root undoSong]; click(centre(3),1,0); KV_CHECK(root.song->count==count-1,@"Buttons: ✕ removes it");
                [root undoSong]; click(centre(1),1,0); KV_CHECK(arr.tool==KvToolScissors && root.song->count==count,@"Buttons: ✂ takes the scissors, nothing is cut yet");
                click(NSMakePoint([arr xOfBeat:kv_section_start(root.song,2)+bar+.3],NSMidY([arr rectOfRegion:2 track:KV_TRACK_BASS])),1,0);
                KV_CHECK(root.song->count==count+1 && fabs(kv_section_beats(root.song,2)-bar)<1e-9 && arr.tool==KvToolPointer,@"Buttons: then a click cuts where it is, on the bar, and the pointer is back");
                [root undoSong]; arr.cursorBeat=0; click(centre(0),1,0); KV_CHECK(root.viewMode==2 && root.rollDocked && root.editingSection==2,@"Buttons: ✎ opens it in the roll under the tracks"); [root pianoRoll:root.roll openSection:-1]; [root.window makeFirstResponder:arr];
                // Selection: ⇧-click a range, ⌫ removes it, ⌘A all, ⌘D copies them, Esc one; a drag moves the range; a drop on a section swaps.
                uint32_t ids[4]; for(int k=0;k<4;k++) ids[k]=root.song->sections[k].id;
                click(bassMid(1),1,0); click(bassMid(3),1,NSEventModifierFlagShift);
                KV_CHECK(arr.selection.location==1 && arr.selection.length==3 && root.editingSection==3,@"Selection: ⇧-click selects the range");
                [arr keyDown:key(51,0)]; KV_CHECK(root.song->count==count-3 && root.song->sections[0].id==ids[0],@"Selection: ⌫ removes the whole range"); [root undoSong];
                [arr keyDown:key(0,NSEventModifierFlagCommand)]; KV_CHECK(arr.selection.location==0 && arr.selection.length==count,@"Selection: ⌘A selects every section");
                [root duplicateSection:nil]; BOOL copies=root.song->count==2*count; for(size_t k=0;copies && k<count;k++) copies=root.song->sections[count+k].kind==root.song->sections[k].kind;
                KV_CHECK(copies && arr.selection.location==count && arr.selection.length==count,@"Selection: ⌘D copies the whole range after it"); [root undoSong];
                [arr keyDown:key(0,NSEventModifierFlagCommand)]; [arr keyDown:key(53,0)]; KV_CHECK(arr.selection.length==1,@"Selection: Esc narrows it to one");
                click(bassMid(0),1,0); click(bassMid(1),1,NSEventModifierFlagShift); drag(markerMid(0),NSMakePoint(NSMaxX([arr rectOfSection:3])-4,markerMid(0).y),0);
                KV_CHECK(root.song->sections[0].id==ids[2] && root.song->sections[1].id==ids[3] && root.song->sections[2].id==ids[0] && root.song->sections[3].id==ids[1] && arr.selection.location==2 && arr.selection.length==2,@"Selection: a drag moves the whole range");
                [root undoSong]; click(bassMid(0),1,0); drag(markerMid(0),markerMid(3),0);
                KV_CHECK(root.song->sections[0].id==ids[3] && root.song->sections[3].id==ids[0] && root.song->sections[1].id==ids[1],@"Swap: a section dropped on the middle of another trades places with it");
                [root undoSong]; KV_CHECK(root.song->sections[0].id==ids[0] && root.song->sections[3].id==ids[3],@"Swap: ⌘Z puts them back");
                // A region dragged on its track moves the section, as its marker does; a shifted drums region's bar turns.
                { arr.snap=KvSnapBeat; drag(bassMid(0),markerMid(3),0);
                  KV_CHECK(root.song->sections[0].id==ids[3] && root.song->sections[3].id==ids[0] && root.song->sections[0].regions[KV_TRACK_BASS].shift==0,@"Drag: a bass region dragged onto another section trades places with it, nothing shifts");
                  [root undoSong]; KV_CHECK(root.song->sections[0].id==ids[0],@"Drag: ⌘Z puts it back");
                  [root arrangerSelect:0]; [root arrangerSet:KvSectionFieldBeat value:4+KV_BEAT_POP]; NSData *plain=[root arrangerHits:0];
                  [root arrangerShiftRegion:0 track:KV_TRACK_DRUMS shift:.5]; NSData *turned=[root arrangerHits:0];
                  double bar=kv_meter_bar(root.song->meter); NSMutableArray *expect=[NSMutableArray array],*got=[NSMutableArray array];
                  const KvHit *a=plain.bytes,*b=turned.bytes; for(size_t k=0;k<plain.length/sizeof(KvHit) && a[k].beat<bar-1e-9;k++) [expect addObject:@(round(fmod(a[k].beat+.5,bar)*1000))];
                  for(size_t k=0;k<turned.length/sizeof(KvHit) && b[k].beat<bar-1e-9;k++) [got addObject:@(round(b[k].beat*1000))];
                  [expect sortUsingSelector:@selector(compare:)];
                  KV_CHECK(turned.length==plain.length && expect.count>0 && [expect isEqualToArray:got],@"Shift: a shifted drums region turns the bar's pattern by the shift");
                  [root undoSong]; [root undoSong]; arr.snap=KvSnapSmart; }
                // A texture chosen with all the sections selected goes to them all (a transition keeps its own).
                { [arr keyDown:key(53,0)]; NSInteger mode=root.performanceMode==2?1:2; uint32_t seed1=root.song->sections[1].arrangement.seed; [root.performanceChoice selectItemWithTag:mode]; [root performanceChanged:root.performanceChoice];
                  BOOL all=YES; for(size_t i=0;i<root.song->count;i++) if(root.song->sections[i].kind!=KV_SECTION_TRANSITION && root.song->sections[i].arrangement.arpeggio!=(mode==2)) all=NO;
                  KV_CHECK(all && root.song->sections[1].arrangement.seed==seed1 && [root.status.stringValue containsString:@"всей песни"],@"Texture: chosen with one section selected it is the song's, every section takes it and keeps its own variation");
                  [root undoSong]; click(bassMid(0),1,0); click(bassMid(1),1,NSEventModifierFlagShift); [root.performanceChoice selectItemWithTag:mode]; [root performanceChanged:root.performanceChoice];
                  KV_CHECK(root.song->sections[0].arrangement.arpeggio==(mode==2) && root.song->sections[1].arrangement.arpeggio==(mode==2) && root.song->sections[3].arrangement.arpeggio!=(mode==2) && [root.status.stringValue containsString:@"выделенных"],@"Texture: with a range selected it goes to the range alone");
                  [root undoSong]; [arr keyDown:key(53,0)]; }
                // The right-click menu.
                NSMenu *menu=[arr menuForSection:2 track:KV_TRACK_BASS beat:kv_section_start(root.song,2)+bar]; NSMenuItem *mute=nil;
                for(NSMenuItem *item in menu.itemArray) if([item.title containsString:T(@"Бас")]) mute=item;
                KV_CHECK(menu.numberOfItems>=7 && [menu itemAtIndex:1].enabled && mute,@"Menu: right-click offers the roll, cut here, duplicate, delete and the region's M");
                [NSApp sendAction:mute.action to:mute.target from:mute]; KV_CHECK(root.song->sections[2].regions[KV_TRACK_BASS].mute && root.editingSection==2,@"Menu: it mutes the bass in that section"); [root undoSong];
                NSMenuItem *cutHere=[menu itemAtIndex:1]; [NSApp sendAction:cutHere.action to:cutHere.target from:cutHere];
                KV_CHECK(root.song->count==count+1 && fabs(kv_section_beats(root.song,2)-bar)<1e-9,@"Menu: «cut here» cuts where it was opened"); [root undoSong];
                NSMenu *drums=[arr menuForSection:2 track:KV_TRACK_DRUMS beat:0]; NSMenuItem *beats=nil; for(NSMenuItem *item in drums.itemArray) if(item.submenu) beats=item;
                KV_CHECK(beats.submenu.numberOfItems==arr.beatChoice.numberOfItems,@"Menu: on the drums, the beat list");
                arr.snap=KvSnapSmart; KV_CHECK(root.song->count==count,@"Selection: the song is back as it was");
                // Automation (spec 1.5 §6а): ⌁ opens the tempo lane under the ruler, «A» a volume lane under its track; a double click puts a
                // point on the snap, a drag moves it, ⌫ removes it; a volume point at 0 % fades its track out; the tempo follows the curve as
                // the song plays and goes into the MIDI file; a point goes with its section; the song keeps its curves.
                { arr.snap=KvSnapBar; CGFloat markerBefore=NSMinY([arr rectOfSection:0]);
                  arr.tempoButton.state=NSControlStateValueOn; [arr.tempoButton sendAction:arr.tempoButton.action to:arr.tempoButton.target]; [arr layout];
                  KV_CHECK(arr.showTempo && NSMinY([arr rectOfSection:0])>=markerBefore+36 && !NSIsEmptyRect([arr curveRect:-1]) && NSMinY([arr curveRect:-1])>=48,@"Automation: ⌁ opens the tempo lane under the ruler");
                  double second=kv_section_start(root.song,1); NSPoint at=[arr pointOfCurve:-1 value:140 beat:second]; click(at,2,0);
                  KV_CHECK(root.song->tempo.count==1 && fabs(root.song->tempo.points[0].beat-second)<1e-9 && fabs(root.song->tempo.points[0].value-140)<=2,@"Automation: a double click in the lane puts a tempo point on the bar");
                  NSPoint moved=[arr pointOfCurve:-1 value:180 beat:second+bar]; drag(at,moved,0);
                  KV_CHECK(root.song->tempo.count==1 && fabs(root.song->tempo.points[0].beat-(second+bar))<1e-9 && fabs(root.song->tempo.points[0].value-180)<=2,@"Automation: a drag moves the point in time and value");
                  click(moved,1,0); [arr keyDown:key(51,0)]; KV_CHECK(root.song->tempo.count==0 && root.song->count==count,@"Automation: ⌫ removes the point, not the section");
                  arr.volumeButtons[KV_TRACK_MELODY].state=NSControlStateValueOn; [arr.volumeButtons[KV_TRACK_MELODY] sendAction:arr.volumeButtons[KV_TRACK_MELODY].action to:arr.volumeButtons[KV_TRACK_MELODY].target]; [arr layout];
                  NSRect volume=[arr curveRect:KV_TRACK_MELODY];
                  KV_CHECK(!NSIsEmptyRect(volume) && NSMinY(volume)>=NSMaxY([arr rectOfRegion:0 track:KV_TRACK_MELODY]) && NSMaxY(volume)<=NSMinY([arr rectOfRegion:0 track:KV_TRACK_BASS]) && ![root arrangerLayoutProblem],@"Automation: «A» opens a volume lane under its track, the window still in order");
                  click([arr pointOfCurve:KV_TRACK_MELODY value:0 beat:0],2,0); NSData *faded=[root arrangerNotes:0]; const KvPianoEvent *e=faded.bytes; size_t right=0,left=0;
                  for(size_t k=0;k<faded.length/sizeof(*e);k++) { if(e[k].hand) right++; else left++; }
                  KV_CHECK(root.song->volume[KV_TRACK_MELODY].count==1 && root.song->volume[KV_TRACK_MELODY].points[0].value<.02f && !right && left,@"Automation: a volume point at 0 % fades the melody out, the bass plays on");
                  [root undoSong]; KV_CHECK(!root.song->volume[KV_TRACK_MELODY].count,@"Automation: ⌘Z takes the point back");
                  KvCurve ramp; memset(&ramp,0,sizeof(ramp)); kv_curve_set(&ramp,0,100); kv_curve_set(&ramp,8,200); [root arrangerSetCurve:-1 to:&ramp];
                  [root applyTempo:100]; [root playSongFromBeat:0]; NSDate *until=[NSDate dateWithTimeIntervalSinceNow:1.5];
                  while(until.timeIntervalSinceNow>0) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0/60]]; [root updateSongPlayback]; [root updateSongTempo]; }
                  double beat=[root arrangerPlayheadBeat],want=kv_curve_at(&root.song->tempo,beat,100);
                  KV_CHECK(root.songPlaying && beat>1 && root.appliedBpm>101 && fabs(root.appliedBpm-want)<8,([NSString stringWithFormat:@"Automation: the tempo follows the curve as the song plays (beat %.2f, %.1f BPM, curve %.1f)",beat,root.appliedBpm,want]));
                  [root stopPlayback:nil];
                  NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"tonora-tempo.mid"]; KV_CHECK([root exportSongToPath:path],@"Automation: the song with a tempo curve is written");
                  NSData *file=[NSData dataWithContentsOfFile:path]; const uint8_t *bytes=file.bytes; size_t changes=0;
                  for(NSUInteger i=0;i+3<file.length;i++) if(bytes[i]==0xff && bytes[i+1]==0x51 && bytes[i+2]==3) changes++;
                  KV_CHECK(changes==9,@"Automation: the tempo curve goes into the MIDI file, a change every beat of the ramp"); [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
                  uint32_t moving=root.song->sections[1].id; KvCurve mark; memset(&mark,0,sizeof(mark)); kv_curve_set(&mark,kv_section_start(root.song,1)+1,90); [root arrangerSetCurve:-1 to:&mark];
                  [root arrangerMove:1 to:3 copy:NO]; NSInteger where=[root indexOfSection:moving];
                  KV_CHECK(where==3 && root.song->tempo.count==1 && fabs(root.song->tempo.points[0].beat-(kv_section_start(root.song,3)+1))<1e-9,@"Automation: a point goes with its section when the section moves");
                  NSDictionary *plist=[root songPlist]; [root undoSong];
                  KV_CHECK([plist[@"tempoCurve"] count]==1 && [root loadSongPlist:plist] && root.song->tempo.count==1 && fabs(root.song->tempo.points[0].value-90)<1e-4,@"Automation: the song keeps its curves");
                  [root undoSong]; [root undoSong]; [root undoSong]; KvCurve none; memset(&none,0,sizeof(none)); root.song->tempo=none; [root reloadEditing:0];
                  arr.showTempo=NO; [arr setShowsVolume:NO track:KV_TRACK_MELODY]; arr.snap=KvSnapSmart; [arr layout]; }
              }
              { // Song forms (spec 1.5 §6): five built in; the song rebuilt around its verse, its chorus kept; a section edited by hand
                // stays (at the end when the form has no place for it); ⌘R another variant; a form saved from the song comes back and goes.
                NSArray<NSDictionary *> *forms=[root arrangerForms]; NSDictionary *pop=forms.firstObject; size_t before=root.song->count; uint32_t firstId=root.song->sections[0].id;
                KV_CHECK(forms.count>=5 && [pop[@"letters"] isEqualToString:@"И–К–Пр–К–Пр–Б–Пр–Пр"] && root.arranger.structureChoice.numberOfItems>=(NSInteger)forms.count+3,@"Forms: five built in in «Структура», Pop reads И–К–Пр–К–Пр–Б–Пр–Пр");
                size_t pit=0; for(size_t i=0;i<root.song->count;i++) if(root.song->sections[i].kind==KV_SECTION_PIT) pit=i;
                uint32_t pitId=root.song->sections[pit].id; root.song->sections[pit].edited=YES; root.sectionTracks[@(pitId)]=[root trackData];   // as if its notes were edited in the roll
                const KvSection *oldChorus=NULL; for(size_t i=0;i<root.song->count && !oldChorus;i++) if(root.song->sections[i].kind==KV_SECTION_CHORUS) oldChorus=&root.song->sections[i];
                int chorusCodes[8]; size_t chorusCount=oldChorus?oldChorus->count:0; for(size_t k=0;k<chorusCount;k++) chorusCodes[k]=oldChorus->codes[k];
                NSArray *(^kinds)(void)=^NSArray *{ NSMutableArray *list=[NSMutableArray array]; for(size_t i=0;i<root.song->count;i++) if(root.song->sections[i].kind!=KV_SECTION_TRANSITION) [list addObject:@(root.song->sections[i].kind)]; return list; };
                NSMutableArray *expected=[NSMutableArray array]; for(NSNumber *slot in pop[@"slots"]) if(slot.intValue<KV_FORM_TRANSITION) [expected addObject:slot]; [expected addObject:@(KV_SECTION_PIT)];
                [root arrangerSelect:0]; [root arrangerApplyForm:pop];
                const KvSection *last=&root.song->sections[root.song->count-1]; BOOL sameChorus=NO;
                for(size_t i=0;i<root.song->count && !sameChorus;i++) if(root.song->sections[i].kind==KV_SECTION_CHORUS && root.song->sections[i].count==chorusCount) { sameChorus=YES; for(size_t k=0;k<chorusCount;k++) if(root.song->sections[i].codes[k]!=chorusCodes[k]) sameChorus=NO; }
                KV_CHECK([kinds() isEqualToArray:expected] && root.song->sections[root.editingSection].kind==KV_SECTION_VERSE && sameChorus,@"Forms: Pop rebuilds the song in its order around the verse, keeping its chorus");
                KV_CHECK(last->id==pitId && last->edited && root.sectionTracks[@(pitId)] && kv_song_valid(root.song),@"Forms: a section edited by hand stays, at the end when the form has no place for it");
                BOOL other=NO; int pushes=1; uint32_t (^chorusVary)(void)=^uint32_t{ for(size_t i=0;i<root.song->count;i++) if(root.song->sections[i].kind==KV_SECTION_CHORUS) return root.song->sections[i].vary; return 0; }; uint32_t vary=chorusVary();
                for(int tries=0;tries<4 && !other;tries++) { [root regenerateArrangement:nil]; pushes++; if(chorusVary()%3!=vary%3) other=YES; }   // spec 1.6: the same material, another way of playing it
                KV_CHECK(other && [kinds() isEqualToArray:expected] && root.song->sections[root.song->count-1].id==pitId,@"Forms: ⌘R makes another variant of the form, the edited section still there");
                KV_CHECK([root saveFormNamed:@"Тестовая"],@"Forms: the song's form is saved");
                NSDictionary *mine=[root arrangerForms].lastObject; NSArray *saved=mine[@"slots"];
                NSString *entry=[NSString stringWithFormat:@"Тестовая · %@",mine[@"letters"]];
                KV_CHECK([mine[@"name"] isEqualToString:@"Тестовая"] && [mine[@"user"] boolValue] && saved.count==root.song->count && [root.arranger.structureChoice itemWithTitle:entry],@"Forms: it comes back in «Структура» with the song's kinds");
                NSArray *order=kinds(); [root arrangerApplyForm:mine]; pushes++;
                KV_CHECK([kinds() isEqualToArray:order] && root.song->sections[root.song->count-1].id==pitId,@"Forms: applied, a saved form gives the same sections (the edited one in its place)");
                [root arrangerDeleteForm:@"Тестовая"]; BOOL gone=YES; for(NSDictionary *form in [root arrangerForms]) if([form[@"name"] isEqualToString:@"Тестовая"]) gone=NO;
                KV_CHECK(gone,@"Forms: deleted, it leaves the menu");
                for(int k=0;k<pushes;k++) [root undoSong];
                KV_CHECK(root.song->count==before && root.song->sections[0].id==firstId,@"Forms: ⌘Z brings the song back");
                root.song->sections[pit].edited=NO; [root.sectionTracks removeObjectForKey:@(pitId)]; }
              { // Feedback on 1.5.0: the empty song shows its three tracks with «✦ Сгенерировать песню» on the melody track, which makes a
                // whole song where every track plays; the metronome switched off while the song plays goes quiet at once; the wheel zooms
                // the way the roll does; a double click on the ruler plays from there; the ruler's menu clears the cycle.
                KvArranger *arr=root.arranger; KvSong *kept=malloc(sizeof(KvSong)); memcpy(kept,root.song,sizeof(KvSong)); NSMutableDictionary *tracks=[root.sectionTracks mutableCopy];
                kv_song_reset(root.song); [root.sectionTracks removeAllObjects]; [root reloadEditing:0]; [arr reload]; [arr layout];
                KV_CHECK(!arr.generateButton.hidden && !arr.takeButton.hidden && NSMinY(arr.generateButton.frame)>80 && NSMaxX(arr.generateButton.frame)<NSWidth(arr.bounds) && arr.trackLevels[0].hidden,@"Empty song: three empty tracks and «Сгенерировать песню» on the melody one, no stray sliders");
                [arr.generateButton performClick:nil]; BOOL melody=NO,bass=NO,drums=NO;
                for(NSInteger i=0;i<(NSInteger)root.song->count;i++) { NSData *d=[root arrangerNotes:i]; const KvPianoEvent *e=d.bytes; for(size_t k=0;k<d.length/sizeof(*e);k++) { if(e[k].hand) melody=YES; else bass=YES; } if([root arrangerHits:i].length) drums=YES; }
                KV_CHECK(root.song->count>=8 && melody && bass && drums && arr.generateButton.hidden,@"Empty song: one click makes a whole song, every track plays");
                if(root.drumsOn) [root toggleDrums:nil]; if(!root.metronomeOn) [root toggleMetronome:nil];   // the click alone
                [root playSongFromBeat:0]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.3]];
                double clicking=kv_audio_rhythm_beat(root.audio); [root toggleMetronome:nil]; [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.2]];
                KV_CHECK(clicking>=0 && kv_audio_rhythm_beat(root.audio)<0 && root.songPlaying,@"Metronome: switched off while the song plays, the click stops at once");
                [root stopPlayback:nil];
                { NSWindow *window=arr.window; CGEventRef wheel=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitPixel,1,30); CGEventSetFlags(wheel,kCGEventFlagMaskCommand);
                  NSEvent *event=[NSEvent eventWithCGEvent:wheel]; CFRelease(wheel); (void)window;
                  root.roll.zoom=4; double before=root.roll.zoom; [root.roll scrollWheel:event]; double rollWay=root.roll.zoom-before;   // room both ways
                  [arr zoomBy:2 aroundX:400]; before=arr.zoom; [arr scrollWheel:event]; double songWay=arr.zoom-before;
                  KV_CHECK(rollWay!=0 && songWay!=0 && (rollWay>0)==(songWay>0),@"Zoom: the wheel with ⌘ zooms the song the way it zooms the roll"); }
                { NSEvent *(^at)(NSEventType,CGFloat,NSInteger)=^NSEvent *(NSEventType type,CGFloat x,NSInteger clicks) {
                      return [NSEvent mouseEventWithType:type location:[arr convertPoint:NSMakePoint(x,40) toView:nil] modifierFlags:0 timestamp:0 windowNumber:arr.window.windowNumber context:nil eventNumber:0 clickCount:clicks pressure:1]; };
                  double bar=kv_meter_bar(root.song->meter); [arr showWholeSong:nil]; root.song->cycle_from=0; root.song->cycle_to=8*bar; CGFloat x=[arr xOfBeat:2*bar];
                  [arr mouseDown:at(NSEventTypeLeftMouseDown,x,1)]; [arr mouseUp:at(NSEventTypeLeftMouseUp,x,1)]; [arr mouseDown:at(NSEventTypeLeftMouseDown,x,2)]; [arr mouseUp:at(NSEventTypeLeftMouseUp,x,2)];
                  KV_CHECK(root.songPlaying && fabs(root.songOrderBeats[0].doubleValue-2*bar)<1e-9 && root.song->cycle_to>0,@"Ruler: a double click inside the cycle plays from there and keeps the cycle");
                  [root stopPlayback:nil]; NSMenu *menu=[arr menuForEvent:at(NSEventTypeRightMouseDown,x,1)]; NSMenuItem *clear=[menu itemAtIndex:0];
                  [NSApp sendAction:clear.action to:clear.target from:clear]; KV_CHECK(root.song->cycle_to==0,@"Ruler: its menu clears the cycle"); }
                memcpy(root.song,kept,sizeof(KvSong)); free(kept); root.sectionTracks=tracks; root.songPlans=nil; [root reloadEditing:0]; }
              if(root.metronomeOn) [root toggleMetronome:nil]; if(!root.drumsOn) [root toggleDrums:nil]; root.songPlans=nil; if(hoverWindow) hoverWindow.contentView=nil;
              [root showView:0]; }
            // Spec 1.6: the song grows from what was made on the circle and in the roll; a new meter keeps the edits; a selected transition keeps its length.
            { [root stopPlayback:nil]; [root showView:0]; kv_song_reset(root.song); [root.sectionTracks removeAllObjects]; [root.songUndo removeAllObjects]; [root reloadEditing:0];
              [root.meterChoice selectItemAtIndex:KV_METER_4_4]; [root meterChanged:root.meterChoice];
              [root clearProgression:nil]; for(NSNumber *degree in @[@0,@5,@3,@4]) [root addChord:root.addButtons[degree.integerValue]];
              [root showView:1]; KV_CHECK([root.roll addNoteAtBeat:.5 midi:96 duration:.5] && root.trackEdited,@"Song 1.6: a note added in the roll");
              [root showView:2]; [root arrangerGenerateSong:nil];
              BOOL (^heard)(NSInteger)=^BOOL(NSInteger i) { NSData *d=[root arrangerNotes:i]; const KvPianoEvent *e=d.bytes; for(size_t k=0;k<d.length/sizeof(*e);k++) if(e[k].midi==96 || e[k].midi==108) return YES; return NO; };
              size_t own=0,grown=0,choruses=0,carried=0;
              for(size_t i=0;i<root.song->count;i++) { const KvSection *x=&root.song->sections[i];
                  if(x->source) grown++; else own++;
                  if(x->kind==KV_SECTION_CHORUS) { choruses++; if(heard((NSInteger)i)) carried++; } }
              KV_CHECK(root.song->count>=8 && own<=3 && grown>=root.song->count-3 && choruses>=2 && carried==choruses,([NSString stringWithFormat:@"Song 1.6: the sections grow from the verse (%zu of %zu), the note edited in the roll is in every chorus (%zu of %zu)",grown,root.song->count,carried,choruses]));
              size_t before=0; for(size_t i=0;i<root.song->count;i++) if(root.song->sections[i].edited && heard((NSInteger)i)) before++;
              [root.meterChoice selectItemAtIndex:KV_METER_6_8]; [root meterChanged:root.meterChoice];
              size_t after=0; for(size_t i=0;i<root.song->count;i++) if(root.song->sections[i].edited && heard((NSInteger)i)) after++;
              KV_CHECK(before>0 && after==before && kv_song_valid(root.song),@"Meter: the notes edited in the roll survive a new meter in every section");
              NSInteger transition=-1; for(size_t i=0;i<root.song->count && transition<0;i++) if(root.song->sections[i].kind==KV_SECTION_TRANSITION) transition=(NSInteger)i;
              if(transition>=0) { [root arrangerSelect:transition]; double beats=kv_song_beats(root.song); for(int k=0;k<200;k++) { [root songWithWorking]; kv_song_refresh_transitions(root.song); }
                  KV_CHECK(kv_song_valid(root.song) && fabs(kv_song_beats(root.song)-beats)<1e-6,@"A selected transition keeps its length (it once grew without end)"); }
              [root.meterChoice selectItemAtIndex:KV_METER_4_4]; [root meterChanged:root.meterChoice]; }
            // A strings texture stays with its section through a piano detour: the piano plays it as two hands, the strings get it back.
            if(root.stringsAvailable) { [root stopPlayback:nil]; [root showView:0]; kv_song_reset(root.song); [root.sectionTracks removeAllObjects]; [root.songUndo removeAllObjects];
              [root showSoundSettings:nil]; [root.instrumentChoice selectItemAtIndex:KV_INSTRUMENT_STRINGS]; [root instrumentChanged:root.instrumentChoice]; [root closeSound:nil];
              [root.performanceChoice selectItemWithTag:3+KV_STRINGS_PIZZICATO-KV_STRINGS_CHORALE]; [root performanceChanged:root.performanceChoice];
              [root clearProgression:nil]; for(NSNumber *degree in @[@0,@5,@3,@4]) [root addChord:root.addButtons[degree.integerValue]]; [root sendToArranger:nil];
              KV_CHECK(root.song->count==1 && root.song->sections[0].arrangement.strings==KV_STRINGS_PIZZICATO,@"Texture: the section takes the pizzicato");
              [root showSoundSettings:nil]; [root.instrumentChoice selectItemAtIndex:0]; [root instrumentChanged:root.instrumentChoice]; [root closeSound:nil];
              [root arrangerSelect:0]; [root storeWorking]; NSData *onPiano=[root arrangerNotes:0];
              KV_CHECK(root.performanceMode==1 && root.song->sections[0].arrangement.strings==KV_STRINGS_PIZZICATO && onPiano.length>0,@"Texture: on the piano it shows and plays as two hands, the section keeps the pizzicato");
              [root showSoundSettings:nil]; [root.instrumentChoice selectItemAtIndex:KV_INSTRUMENT_STRINGS]; [root instrumentChanged:root.instrumentChoice]; [root closeSound:nil]; [root arrangerSelect:0];
              KV_CHECK(root.performanceMode==3+KV_STRINGS_PIZZICATO-KV_STRINGS_CHORALE,@"Texture: back on the strings the section is pizzicato again");
              [root showSoundSettings:nil]; [root.instrumentChoice selectItemAtIndex:0]; [root instrumentChanged:root.instrumentChoice]; [root closeSound:nil]; [root showView:0]; }   // the section stays for the file check below
            // Silence rests the output queue; the next sound starts it again and is heard.
            { [root stopPlayback:nil]; if(root.metronomeOn) [root toggleMetronome:nil];
              [root playTonic:nil]; NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:15]; BOOL rested=NO;
              while(!rested && deadline.timeIntervalSinceNow>0) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.1]]; rested=kv_audio_suspend(root.audio) || (!kv_audio_is_playing(root.audio) && root.idleTicks>200); }
              KV_CHECK(rested,@"Silence: the output queue rests after a quiet while");
              [root playTonic:nil]; int sounding[KV_ACTIVE_NOTES]; unsigned heard=0; deadline=[NSDate dateWithTimeIntervalSinceNow:2];
              while(!heard && deadline.timeIntervalSinceNow>0) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]]; heard=kv_audio_active_notes(root.audio,sounding); }
              KV_CHECK(heard>0,@"Silence: the first sound after the rest starts the queue again and sounds"); [root stopPlayback:nil]; }
            // .tonora: the work, and only the work, goes into the file; opening it in a new window brings it back; other files are refused.
            { [root stopPlayback:nil]; [root showView:0];
              NSData *file=[root documentData]; NSDictionary *state=[KvRoot documentStateFromData:file];
              KV_CHECK(file.length>0 && state[@"song"] && state[@"progression"] && state[@"tempo"] && !state[@"language"] && !state[@"midiIn"] && !state[@"windowOrigin"],@"File: the work and only the work goes in");
              NSArray *progression=[root.progression copy]; double tempo=root.tempo; size_t sections=root.song->count;
              [root applyTempo:150]; [root clearProgression:nil]; [root saveState];   // changed since it was saved
              [KvRoot loadDocumentState:state]; KvRoot *opened=[[KvRoot alloc] initWithFrame:root.frame];
              KV_CHECK([opened.progression isEqualToArray:progression] && fabs(opened.tempo-tempo)<1e-9 && opened.song->count==sections && sections>0,@"File: opening brings back the progression, the tempo and the song");
              KV_CHECK([[opened documentStateFromDefaults] isEqualToDictionary:[root documentStateFromDefaults]],@"File: the opened window keeps the file's state as it was read");
              [opened stopPlayback:nil];
              KV_CHECK(![KvRoot documentStateFromData:[@"<plist version=\"1.0\"><dict/></plist>" dataUsingEncoding:NSUTF8StringEncoding]] && ![KvRoot documentStateFromData:[NSData data]] && ![KvRoot documentStateFromData:[@"tonora" dataUsingEncoding:NSUTF8StringEncoding]],@"File: anything but a .tonora file is refused");
              [root applyTempo:tempo]; for(NSNumber *code in progression) [root addChordCode:code.intValue]; [root saveState]; }
            // English: the same saved state in an English interface; no Cyrillic anywhere in it; the replaced view is freed.
            { [root.performanceChoice selectItemWithTag:1]; [root performanceChanged:root.performanceChoice]; [root applyTempo:97]; [root stopPlayback:nil]; [root saveState];
              NSArray *progression=[root.progression copy]; KvKey key=root.key;
              TNSetLanguage(@"en"); __weak KvRoot *weakEnglish=nil;
              @autoreleasepool {
                  KvRoot *english=[[KvRoot alloc] initWithFrame:NSMakeRect(0,0,1240,760)]; [english layout]; weakEnglish=english;
                  KV_CHECK([english.progression isEqualToArray:progression] && english.tempo==97 && english.key.circle_index==key.circle_index && english.key.minor==key.minor && english.performanceMode==1,@"English: the saved sequence, tempo, key and texture come back");
                  [english showSoundSettings:nil]; KV_CHECK(english.languageControl.selectedSegment==0 && english.languageControl.superview==english.soundPanel.contentView,@"English: FX holds the language switch, set to English");
                  for(NSInteger tab=0;tab<3;tab++) { english.inspectorTabs.selectedSegment=tab; [english inspectorTabChanged:english.inspectorTabs]; [english layout];
                      NSString *russian=KvCyrillicIn(english); KV_CHECK(!russian,([NSString stringWithFormat:@"English: Cyrillic left in the window (tab %ld): «%@»",(long)tab,russian])); }
                  NSString *russian=KvCyrillicIn(english.soundPanel.contentView); KV_CHECK(!russian,([@"English: Cyrillic left in FX: " stringByAppendingString:russian?:@""]));
                  KV_CHECK([english.heading.stringValue rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0x400,0x100)]].location==NSNotFound,@"English: the key title is English");
                  NSMutableArray<NSString *> *texts=[NSMutableArray arrayWithObjects:T(KvCircleHint),T(EmptyHint),T(EmptyLink),T(KvCardTabs[0]),T(KvCardTabs[1]),nil];
                  const KvShortcut *tables[]={KvGeneral,KvRollKeys,KvComputerKeys,KvSongKeys};
                  for(int t=0;t<4;t++) for(int i=0;tables[t][i].key;i++) { [texts addObject:T(@(tables[t][i].key))]; [texts addObject:T(@(tables[t][i].text))]; }
                  for(int i=0;i<3;i++) { [texts addObject:T(@(KvCircleHelp[i][0]))]; [texts addObject:T(@(KvCircleHelp[i][1]))]; }
                  for(NSArray<NSString *> *entry in KvSequenceMenu()) [texts addObject:entry[0]];
                  for(NSString *text in texts) KV_CHECK([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0x400,0x100)]].location==NSNotFound,([@"English: Cyrillic left in the help card or menus: " stringByAppendingString:text]));
                  for(NSNumber *height in @[@680,@760]) for(NSNumber *width in @[@1120,@1240,@1440]) {
                      english.frame=NSMakeRect(0,0,width.doubleValue,height.doubleValue); NSString *problem=[english layoutProblem];
                      KV_CHECK(!problem,([NSString stringWithFormat:@"English layout %@x%@: %@",width,height,problem])); }
                  [english closeSound:nil]; [english stopPlayback:nil];
              }
              KV_CHECK(!weakEnglish,@"English: a replaced root view is freed (no second audio engine or MIDI port)");
              TNSetLanguage(@"ru"); }
            [TNPreferences removePersistentDomainForName:suite];
            puts("Native integration: selection, transposition, saved state, piano playback, effects and generator controls passed.");
            return 0;
        }
        NSApplication *app=[NSApplication sharedApplication]; [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        KvDelegate *delegate=[KvDelegate new]; app.delegate=delegate; [app run];
    }
    return 0;
}
