#import <Cocoa/Cocoa.h>
#include "song.h"
@class KvArranger;
/* The section properties set from the arranger's bar under the lane. */
typedef enum { KvSectionFieldKind, KvSectionFieldRepeats, KvSectionFieldLevel, KvSectionFieldBeat, KvSectionFieldLift, KvSectionFieldTransition } KvSectionField;
/* The owner keeps the song, its tracks and undo; the arranger draws the lane and reports gestures. */
@protocol KvArrangerOwner <NSObject>
- (const KvSong *)arrangerSong;
- (NSString *)arrangerName:(NSInteger)index;       /* «Куплет 1», or the user's name */
- (NSString *)arrangerChords:(NSInteger)index;     /* «C Am F G» */
- (NSString *)arrangerDetails:(NSInteger)index;    /* «8 тактов · ×2 · баллада» */
- (BOOL)arrangerEdited:(NSInteger)index;           /* the section plays the user's notes */
- (double)arrangerPlayheadBeat;                    /* in the song, −1 when it does not play */
- (void)arrangerSelect:(NSInteger)index;
- (void)arrangerOpenInRoll:(NSInteger)index;
- (void)arrangerMove:(NSInteger)from to:(NSInteger)to copy:(BOOL)copy;
- (void)arrangerCut:(NSInteger)index atBeat:(double)beat;   /* beat inside the section, already an allowed cut */
- (void)arrangerRemove:(NSInteger)index;
- (void)arrangerSet:(KvSectionField)field value:(NSInteger)value;   /* of the selected section */
- (void)arrangerRevert:(id)sender;                 /* the selected section's notes back to its texture */
- (void)arrangerTakeDraft:(id)sender;              /* the circle's progression becomes a section */
- (void)arrangerForwardKey:(NSEvent *)event;
@end
@interface KvArranger : NSView
@property(nonatomic,weak) id<KvArrangerOwner> owner;
@property(nonatomic) NSInteger selected;           /* the owner sets it; −1 none */
@property(nonatomic) double scrollBeat;            /* first beat shown */
- (void)reload;                                    /* the song or the selection changed */
- (NSRect)rectOfSection:(NSInteger)index;          /* in view coordinates (self-test, hit testing) */
- (double)beatAtX:(CGFloat)x;
- (CGFloat)xOfBeat:(double)beat;
@property(nonatomic,readonly) NSPopUpButton *kindChoice,*repeatsChoice,*levelChoice,*beatChoice,*liftChoice,*transitionChoice;
@property(nonatomic,readonly) NSButton *openButton,*revertButton,*removeButton,*takeButton;
@end
