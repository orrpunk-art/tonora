#import "mididrag.h"
#import "controls.h"
@interface KvMidiDragHandle ()
@property(nonatomic) BOOL hovered;
@property(nonatomic) NSTrackingArea *tracking;
@property(nonatomic) NSPoint downAt;
@end
@implementation KvMidiDragHandle
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]; [self addTrackingArea:self.tracking];
}
- (void)mouseEntered:(NSEvent *)event { if(TNViewCovered(self,event.locationInWindow)) return; self.hovered=YES; self.needsDisplay=YES; if(self.hint) TNHintShow(self,self.bounds,self.hint,NO); }
- (void)mouseExited:(NSEvent *)event { (void)event; self.hovered=NO; self.needsDisplay=YES; TNHintHide(self); }
- (void)viewDidHide { [super viewDidHide]; self.hovered=NO; TNHintHide(self); }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor]; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; NSRect r=NSInsetRect(self.bounds,1,2);
    NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8];
    [[TNAccent() colorWithAlphaComponent:self.hovered?.28:.16] setFill]; [path fill];
    CGFloat dash[]={3,2}; [path setLineDash:dash count:2 phase:0]; [[TNAccent() colorWithAlphaComponent:.8] setStroke]; [path stroke];
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.alignment=NSTextAlignmentCenter; style.lineBreakMode=NSLineBreakByClipping;
    NSDictionary *attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],NSForegroundColorAttributeName:TNAccent(),NSParagraphStyleAttributeName:style};
    NSString *text=self.title?:@"⠿ MIDI"; NSSize size=[text sizeWithAttributes:attributes];
    [text drawInRect:NSMakeRect(r.origin.x,NSMidY(r)-size.height/2,r.size.width,size.height+2) withAttributes:attributes];
}
- (void)mouseDown:(NSEvent *)event { TNHintHide(self); self.downAt=[self convertPoint:event.locationInWindow fromView:nil]; }
- (void)mouseDragged:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    if(hypot(p.x-self.downAt.x,p.y-self.downAt.y)<4) return;
    NSURL *url=self.provider?self.provider():nil; if(!url) { NSBeep(); return; }
    NSDraggingItem *item=[[NSDraggingItem alloc] initWithPasteboardWriter:url];
    NSImage *icon=[NSWorkspace.sharedWorkspace iconForFile:url.path]; icon.size=NSMakeSize(48,48);
    [item setDraggingFrame:NSMakeRect(p.x-24,p.y-24,48,48) contents:icon];
    [self beginDraggingSessionWithItems:@[item] event:event source:self];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context { (void)session; (void)context; return NSDragOperationCopy; }
- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session { (void)session; return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityLabel { return self.hint?:T(@"Перетащите MIDI-клип в DAW или Finder"); }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
@end
