#import <Cocoa/Cocoa.h>
NSColor *TNCanvas(void);
NSColor *TNSurface(void);
NSColor *TNAccent(void);
/* Melody notes outside the chord under them: passing / neighbour notes and anticipations of the next chord. */
/* The app's settings; the self-test points TNPreferences at a throwaway suite so it never touches the user's. */
extern NSUserDefaults *TNPreferences;
NSUserDefaults *TNDefaults(void);
NSColor *TNPassing(void);
NSColor *TNAnticipation(void);
/* A template icon: an SF Symbol, or one of Tonora's own glyphs ("tonora.circle", "tonora.roll", "tonora.scale"). nil when the system has no such symbol (callers fall back to text). */
NSImage *TNIcon(NSString *name,CGFloat pointSize);
/* Hover label: a small bubble next to `rect` of `anchor`, shown quickly on hover (instantly when one was just visible). */
void TNHintShow(NSView *anchor,NSRect rect,NSString *text,BOOL immediately);
BOOL TNViewCovered(NSView *view,NSPoint windowPoint);   /* another view (the help card) lies over this point: no hover there */
void TNHintHide(NSView *anchor);   /* nil hides whatever is shown */
NSString *TNHintVisibleText(void);
/* Interface language. Russian strings in the code are the keys; English comes from TNEnglishTable (strings_en.m).
   The choice is saved in TNDefaults as "language"; without one, a Russian system gets Russian and any other English. */
NSString *TNLanguage(void);
void TNSetLanguage(NSString *language);   /* @"en", @"ru" or nil (follow the system) */
BOOL TNEnglish(void);
NSString *T(NSString *russian);
NSDictionary<NSString *,NSString *> *TNEnglishTable(void); /* for self-tests: the text on screen, or nil */
@interface TNButton : NSButton
/* Label shown in a bubble on hover and read by VoiceOver; replaces the slow system tooltip. */
@property(nonatomic,copy) NSString *hint;
/* Subclasses override to draw custom content over the shared background. */
- (void)drawLabelInRect:(NSRect)rect color:(NSColor *)color;
@end
@interface TNSegmented : NSSegmentedControl
@property(nonatomic,copy) NSArray<NSString *> *hints;  /* per-segment hover labels (icon segments) */
@end
@interface TNPopup : NSPopUpButton
@end
@interface TNSlider : NSSlider
/* Optional highlighted span of the track (e.g. recommended tempo range). */
@property(nonatomic) double recommendedMin;
@property(nonatomic) double recommendedMax;
@end
