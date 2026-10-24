#import "controls.h"
#include <math.h>
static BOOL Dark(void) { return [[NSAppearance.currentDrawingAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua,NSAppearanceNameAqua]] isEqualToString:NSAppearanceNameDarkAqua]; }
static NSColor *Color(CGFloat r,CGFloat g,CGFloat b) { return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1]; }
NSColor *TNCanvas(void) { return [NSColor colorWithName:@"TonoraCanvas" dynamicProvider:^NSColor *(NSAppearance *appearance) { return [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua,NSAppearanceNameAqua]] isEqualToString:NSAppearanceNameDarkAqua]?Color(.055,.075,.115):Color(.95,.96,.98); }]; }
NSColor *TNSurface(void) { return [NSColor colorWithName:@"TonoraSurface" dynamicProvider:^NSColor *(NSAppearance *appearance) { return [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameDarkAqua,NSAppearanceNameAqua]] isEqualToString:NSAppearanceNameDarkAqua]?Color(.082,.108,.16):NSColor.whiteColor; }]; }
NSColor *TNAccent(void) { return Color(.40,.48,.96); }
NSUserDefaults *TNPreferences;
NSUserDefaults *TNDefaults(void) { return TNPreferences ?: NSUserDefaults.standardUserDefaults; }
NSString *TNLanguage(void) {
    NSString *saved=[TNDefaults() stringForKey:@"language"]; if([saved isEqualToString:@"en"] || [saved isEqualToString:@"ru"]) return saved;
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"ru"]?@"ru":@"en";
}
void TNSetLanguage(NSString *language) { if(language) [TNDefaults() setObject:language forKey:@"language"]; else [TNDefaults() removeObjectForKey:@"language"]; }
BOOL TNEnglish(void) { return [TNLanguage() isEqualToString:@"en"]; }
NSString *T(NSString *russian) { if(!russian.length || !TNEnglish()) return russian; NSString *english=TNEnglishTable()[russian]; return english?:russian; }
NSColor *TNPassing(void) { return Color(.91,.33,.60); }
NSColor *TNAnticipation(void) { return Color(.60,.32,.90); }
static NSColor *Control(void) { return Dark()?Color(.14,.18,.25):Color(.89,.92,.96); }
static NSColor *Border(void) { return [NSColor.labelColor colorWithAlphaComponent:.12]; }
static void Rounded(NSRect rect,CGFloat radius,NSColor *fill,NSColor *stroke) {
    NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
    [fill setFill]; [path fill]; if(stroke) { [stroke setStroke]; path.lineWidth=1; [path stroke]; }
}
static void Title(NSString *title,NSRect rect,NSFont *font,NSColor *color,NSTextAlignment alignment) {
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.alignment=alignment; style.lineBreakMode=NSLineBreakByTruncatingTail;
    NSSize size=[title sizeWithAttributes:@{NSFontAttributeName:font}];
    rect.origin.y+=(rect.size.height-size.height)/2; rect.size.height=size.height+2;
    [title drawInRect:rect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:style}];
}
static NSImage *Tinted(NSImage *image,NSColor *color) {
    return [NSImage imageWithSize:image.size flipped:NO drawingHandler:^BOOL(NSRect destination) {
        // Source-in keeps the image's coverage and replaces its colour, so translucent colours (disabled) stay translucent.
        [image drawInRect:destination]; [color set]; NSRectFillUsingOperation(destination,NSCompositingOperationSourceIn); return YES;
    }];
}
static void DrawIcon(NSImage *image,NSRect rect,NSColor *color) {
    NSSize size=image.size; NSRect target=NSMakeRect(round(NSMidX(rect)-size.width/2),round(NSMidY(rect)-size.height/2),size.width,size.height);
    [Tinted(image,color) drawInRect:target fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}
/* Tonora's own glyphs, drawn in an 18-point box (scaled to the requested size) in the style of SF Symbols. */
static void GlyphCircle(void) {
    NSBezierPath *outer=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(1.5,1.5,15,15)]; outer.lineWidth=1.5; [outer stroke];
    NSBezierPath *inner=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(6,6,6,6)]; inner.lineWidth=1.3; [inner stroke];
    NSBezierPath *spokes=[NSBezierPath bezierPath]; spokes.lineWidth=1;
    for(int i=0;i<12;i++) { double a=i*M_PI/6; [spokes moveToPoint:NSMakePoint(9+3*cos(a),9+3*sin(a))]; [spokes lineToPoint:NSMakePoint(9+7.5*cos(a),9+7.5*sin(a))]; }
    [spokes stroke];
}
static void GlyphRoll(void) {
    for(int i=0;i<4;i++) NSRectFill(NSMakeRect(1,1.5+i*4,2.5,3));   // keys
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(5,13,6,3) xRadius:1.2 yRadius:1.2] fill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(9.5,7.5,5,3) xRadius:1.2 yRadius:1.2] fill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(12,2,5.5,3) xRadius:1.2 yRadius:1.2] fill];
}
static void GlyphScale(void) {
    // Ascending note heads, tilted like engraved ones.
    for(int i=0;i<4;i++) {
        NSAffineTransform *t=[NSAffineTransform transform]; [t translateXBy:3.2+i*3.9 yBy:3.4+i*3.7]; [t rotateByDegrees:20];
        NSBezierPath *head=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-2.4,-1.7,4.8,3.4)]; [head transformUsingAffineTransform:t]; [head fill];
    }
}
/* Textures (the «Фактура» menu) and strings strokes (the «Штрих» control), in the same 18-point box. */
static void Stroke(NSBezierPath *path,CGFloat width) { path.lineWidth=width; path.lineCapStyle=NSLineCapStyleRound; path.lineJoinStyle=NSLineJoinStyleRound; [path stroke]; }
static void Dot(CGFloat x,CGFloat y,CGFloat r) { [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x-r,y-r,2*r,2*r)] fill]; }
static void Baseline(void) { NSBezierPath *p=[NSBezierPath bezierPath]; [p moveToPoint:NSMakePoint(2,3)]; [p lineToPoint:NSMakePoint(16,3)]; Stroke(p,1.5); }
static void GlyphBlocks(void) { for(int i=0;i<3;i++) [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2,2.5+i*5.2,14,2.8) xRadius:.9 yRadius:.9] fill]; }
static void GlyphHands(void) {
    for(int h=0;h<2;h++) { CGFloat x=2+h*8.5;
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,2,5.5,6.5) xRadius:2 yRadius:2] fill];
        NSBezierPath *fingers=[NSBezierPath bezierPath];
        for(int f=0;f<3;f++) { [fingers moveToPoint:NSMakePoint(x+1+f*1.75,9)]; [fingers lineToPoint:NSMakePoint(x+1+f*1.75,f==1?15.5:13.5)]; }
        Stroke(fingers,1.3); }
}
static void GlyphArpeggio(void) { NSBezierPath *p=[NSBezierPath bezierPath]; [p moveToPoint:NSMakePoint(3,3)]; [p lineToPoint:NSMakePoint(15,15)]; Stroke(p,1.3); for(int i=0;i<4;i++) Dot(3+i*4,3+i*4,1.7); }
static void GlyphChorale(void) { NSBezierPath *p=[NSBezierPath bezierPath]; for(int i=0;i<4;i++) { [p moveToPoint:NSMakePoint(2,3+i*4)]; [p lineToPoint:NSMakePoint(16,3+i*4)]; } Stroke(p,1.5); }
static void GlyphCantilena(void) {
    Baseline(); NSBezierPath *wave=[NSBezierPath bezierPath]; [wave moveToPoint:NSMakePoint(2,10)];
    [wave curveToPoint:NSMakePoint(9,10) controlPoint1:NSMakePoint(4,15) controlPoint2:NSMakePoint(7,15)];
    [wave curveToPoint:NSMakePoint(16,10) controlPoint1:NSMakePoint(11,5) controlPoint2:NSMakePoint(14,5)]; Stroke(wave,1.5);
}
static void GlyphOstinato(void) { Baseline(); NSBezierPath *p=[NSBezierPath bezierPath]; for(int i=0;i<5;i++) { [p moveToPoint:NSMakePoint(3+i*3,6.5)]; [p lineToPoint:NSMakePoint(3+i*3,12)]; } Stroke(p,1.6); }
static void GlyphPizzicato(void) {
    Baseline(); NSBezierPath *p=[NSBezierPath bezierPath];
    for(int i=0;i<3;i++) { CGFloat x=4+i*5,y=i==1?10.5:8; Dot(x,y,1.8); [p moveToPoint:NSMakePoint(x,y+2.5)]; [p lineToPoint:NSMakePoint(x,y+5.5)]; }
    Stroke(p,1.3);
}
static void GlyphAuto(void) {
    NSBezierPath *star=[NSBezierPath bezierPath]; [star moveToPoint:NSMakePoint(9,1.5)];
    const CGFloat pts[][2]={{10.8,7.2},{16.5,9},{10.8,10.8},{9,16.5},{7.2,10.8},{1.5,9},{7.2,7.2}};
    for(int i=0;i<7;i++) [star lineToPoint:NSMakePoint(pts[i][0],pts[i][1])]; [star closePath]; [star fill];
}
static void GlyphLegato(void) {
    NSBezierPath *slur=[NSBezierPath bezierPath]; [slur moveToPoint:NSMakePoint(2.5,7)];
    [slur curveToPoint:NSMakePoint(15.5,7) controlPoint1:NSMakePoint(6,15) controlPoint2:NSMakePoint(12,15)]; Stroke(slur,1.5);
    Dot(3.5,3.5,1.8); Dot(14.5,3.5,1.8);
}
static void GlyphStaccato(void) { [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4.5,3,9,5.5)] fill]; Dot(9,13.5,1.5); }
static void GlyphPluck(void) {
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4.5,1.5,9,5.5)] fill];
    NSBezierPath *plus=[NSBezierPath bezierPath]; [plus moveToPoint:NSMakePoint(9,9.5)]; [plus lineToPoint:NSMakePoint(9,16.5)]; [plus moveToPoint:NSMakePoint(5.5,13)]; [plus lineToPoint:NSMakePoint(12.5,13)]; Stroke(plus,1.6);
}
NSImage *TNIcon(NSString *name,CGFloat pointSize) {
    if(![name hasPrefix:@"tonora."]) {
        NSImage *image=[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
        return image?[image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:NSFontWeightSemibold]]:nil;
    }
    static const struct { const char *name; void (*draw)(void); } glyphs[]={
        {"tonora.circle",GlyphCircle},{"tonora.roll",GlyphRoll},{"tonora.scale",GlyphScale},
        {"tonora.blocks",GlyphBlocks},{"tonora.hands",GlyphHands},{"tonora.arpeggio",GlyphArpeggio},{"tonora.chorale",GlyphChorale},
        {"tonora.cantilena",GlyphCantilena},{"tonora.ostinato",GlyphOstinato},{"tonora.pizzicato",GlyphPizzicato},
        {"tonora.auto",GlyphAuto},{"tonora.legato",GlyphLegato},{"tonora.staccato",GlyphStaccato},{"tonora.pluck",GlyphPluck}};
    void (*draw)(void)=NULL;
    for(size_t i=0;i<sizeof glyphs/sizeof *glyphs;i++) if([name isEqualToString:@(glyphs[i].name)]) draw=glyphs[i].draw;
    if(!draw) return nil;
    CGFloat side=round(pointSize*1.25);
    NSImage *image=[NSImage imageWithSize:NSMakeSize(side,side) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSAffineTransform *t=[NSAffineTransform transform]; [t scaleBy:rect.size.width/18]; [t concat];
        [NSColor.blackColor set]; draw(); return YES;
    }];
    image.template=YES; return image;
}
/* ---- hover label ---- */
@interface TNHintBubble : NSView
@property(nonatomic,copy) NSString *text;
@end
@implementation TNHintBubble
+ (NSDictionary *)attributes {
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.lineBreakMode=NSLineBreakByWordWrapping;
    return @{NSFontAttributeName:[NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.whiteColor,NSParagraphStyleAttributeName:style};
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; NSRect r=NSInsetRect(self.bounds,.5,.5);
    NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:r xRadius:6 yRadius:6];
    [[NSColor colorWithCalibratedRed:.10 green:.12 blue:.17 alpha:.96] setFill]; [path fill];
    [[NSColor colorWithWhite:1 alpha:.14] setStroke]; [path stroke];
    [self.text drawInRect:NSInsetRect(self.bounds,8,4) withAttributes:[TNHintBubble attributes]];
}
@end
BOOL TNViewCovered(NSView *view,NSPoint windowPoint) {
    NSView *content=view.window.contentView; if(!content) return NO;
    NSView *hit=[content hitTest:content.superview?[content.superview convertPoint:windowPoint fromView:nil]:windowPoint];
    return hit && hit!=view && ![hit isDescendantOf:view];
}
static NSPanel *HintPanel; static TNHintBubble *HintBubble; static __weak NSView *HintAnchor; static NSUInteger HintToken; static NSTimeInterval HintHiddenAt;
static void HintPresent(NSView *anchor,NSRect rect,NSString *text) {
    NSWindow *window=anchor.window; if(!window || !window.visible || anchor.hiddenOrHasHiddenAncestor) return;
    if(TNViewCovered(anchor,[anchor convertPoint:NSMakePoint(NSMidX(rect),NSMidY(rect)) toView:nil])) return;
    if(!HintPanel) {
        HintPanel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,10,10) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:YES];
        HintPanel.opaque=NO; HintPanel.backgroundColor=NSColor.clearColor; HintPanel.hasShadow=YES; HintPanel.ignoresMouseEvents=YES; HintPanel.releasedWhenClosed=NO;
        HintBubble=[[TNHintBubble alloc] initWithFrame:NSMakeRect(0,0,10,10)]; HintPanel.contentView=HintBubble;
        for(NSNotificationName name in @[NSWindowDidResignKeyNotification,NSWindowWillCloseNotification,NSWindowWillMoveNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { if(note.object!=HintPanel) TNHintHide(nil); }];
    }
    NSRect bound=[text boundingRectWithSize:NSMakeSize(300,400) options:NSStringDrawingUsesLineFragmentOrigin attributes:[TNHintBubble attributes]];
    NSSize size=NSMakeSize(ceil(bound.size.width)+17,ceil(bound.size.height)+9);
    NSRect screenRect=[window convertRectToScreen:[anchor convertRect:rect toView:nil]];
    NSRect visible=(window.screen?:NSScreen.mainScreen).visibleFrame;
    CGFloat x=MAX(NSMinX(visible)+4,MIN(NSMaxX(visible)-size.width-4,NSMidX(screenRect)-size.width/2));
    CGFloat y=NSMinY(screenRect)-6-size.height; if(y<NSMinY(visible)+4) y=NSMaxY(screenRect)+6;
    HintBubble.text=text; HintBubble.needsDisplay=YES;
    [HintPanel setFrame:NSMakeRect(x,y,size.width,size.height) display:YES];
    if(HintPanel.parentWindow!=window) { [HintPanel.parentWindow removeChildWindow:HintPanel]; [window addChildWindow:HintPanel ordered:NSWindowAbove]; }
    [HintPanel orderFront:nil];
}
void TNHintShow(NSView *anchor,NSRect rect,NSString *text,BOOL immediately) {
    if(!anchor || !text.length) return;
    NSUInteger token=++HintToken; HintAnchor=anchor;
    BOOL warm=HintPanel.visible || NSProcessInfo.processInfo.systemUptime-HintHiddenAt<.5;
    if(immediately || warm) { HintPresent(anchor,rect,text); return; }
    __weak NSView *weakAnchor=anchor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.35*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        NSView *view=weakAnchor; if(view && token==HintToken && HintAnchor==view) HintPresent(view,rect,text);
    });
}
void TNHintHide(NSView *anchor) {
    if(anchor && HintAnchor && anchor!=HintAnchor) return;
    HintToken++; HintAnchor=nil;
    if(HintPanel.visible) { [HintPanel.parentWindow removeChildWindow:HintPanel]; [HintPanel orderOut:nil]; HintHiddenAt=NSProcessInfo.processInfo.systemUptime; }
}
NSString *TNHintVisibleText(void) { return HintPanel.visible?HintBubble.text:nil; }
@interface TNButton ()
@property BOOL hovered;
@property NSTrackingArea *hoverTracking;
@end
@implementation TNButton
- (BOOL)isFlipped { return YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(self.hoverTracking) [self removeTrackingArea:self.hoverTracking];
    self.hoverTracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]; [self addTrackingArea:self.hoverTracking];
}
- (void)setHint:(NSString *)hint {
    _hint=[hint copy]; self.toolTip=nil; [self setAccessibilityLabel:hint];
    if(self.hovered && HintAnchor==self) TNHintShow(self,self.bounds,hint,YES);
}
- (void)mouseEntered:(NSEvent *)event { if(TNViewCovered(self,event.locationInWindow)) return; self.hovered=YES; self.needsDisplay=YES; if(self.hint) TNHintShow(self,self.bounds,self.hint,NO); }
- (void)mouseExited:(NSEvent *)event { (void)event; self.hovered=NO; self.needsDisplay=YES; TNHintHide(self); }
- (void)mouseDown:(NSEvent *)event { TNHintHide(self); [super mouseDown:event]; }
- (void)viewDidHide { [super viewDidHide]; self.hovered=NO; TNHintHide(self); }
- (void)viewWillMoveToWindow:(NSWindow *)window { if(!window) TNHintHide(self); [super viewWillMoveToWindow:window]; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; BOOL primary=self.bezelColor!=nil; BOOL active=self.state==NSControlStateValueOn;
    NSColor *fill=primary?TNAccent():active?[TNAccent() colorWithAlphaComponent:.20]:Control();
    if(self.cell.highlighted && self.enabled) fill=[fill blendedColorWithFraction:.18 ofColor:NSColor.blackColor];
    else if(self.hovered && self.enabled) fill=[fill blendedColorWithFraction:.12 ofColor:TNAccent()];
    CGFloat alpha=self.enabled?1:.36;
    Rounded(NSInsetRect(self.bounds,1,2),8,[fill colorWithAlphaComponent:fill.alphaComponent*alpha],active?TNAccent():Border());
    NSColor *ink=primary?NSColor.whiteColor:(self.contentTintColor?:NSColor.labelColor);
    [self drawLabelInRect:NSInsetRect(self.bounds,11,0) color:[ink colorWithAlphaComponent:alpha]];
    if(self.window.firstResponder==self) { [TNAccent() setStroke]; NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,2) xRadius:8 yRadius:8]; p.lineWidth=2; [p stroke]; }
}
- (void)drawLabelInRect:(NSRect)rect color:(NSColor *)color {
    NSImage *image=self.image;
    if(image && !self.title.length) { DrawIcon(image,self.bounds,color); return; }
    Title(self.title,rect,self.font?:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],color,self.alignment);
}
@end
@interface TNSegmentedCell : NSSegmentedCell
@end
@implementation TNSegmentedCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    Rounded(NSInsetRect(frame,0.5,0.5),8,Control(),Border());
    NSInteger count=self.segmentCount; if(count<1) return;
    CGFloat width=frame.size.width/count;
    for(NSInteger i=0;i<count;i++) {
        NSRect part=NSMakeRect(frame.origin.x+i*width+3,frame.origin.y+3,width-6,frame.size.height-6);
        BOOL selected=[self isSelectedForSegment:i];
        if(selected) Rounded(part,6,TNAccent(),nil);
        NSImage *image=[self imageForSegment:i];
        NSColor *ink=selected?NSColor.whiteColor:NSColor.secondaryLabelColor;
        if(image && ![self labelForSegment:i].length) { DrawIcon(image,part,ink); continue; }
        if(image) { DrawIcon(image,NSMakeRect(part.origin.x+2,part.origin.y,16,part.size.height),ink); part.origin.x+=17; part.size.width-=18; }
        Title([self labelForSegment:i],part,[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],selected?NSColor.whiteColor:NSColor.secondaryLabelColor,NSTextAlignmentCenter);
    }
    (void)view;
}
@end
@interface TNSegmented ()
@property(nonatomic) NSTrackingArea *hoverTracking;
@property(nonatomic) NSInteger hoverSegment;
@end
@implementation TNSegmented
+ (Class)cellClass { return TNSegmentedCell.class; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(self.hoverTracking) [self removeTrackingArea:self.hoverTracking];
    self.hoverTracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited|NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]; [self addTrackingArea:self.hoverTracking];
}
- (void)setHints:(NSArray<NSString *> *)hints { _hints=[hints copy]; self.toolTip=nil; for(NSInteger i=0;i<(NSInteger)hints.count && i<self.segmentCount;i++) [[self imageForSegment:i] setAccessibilityDescription:hints[i]]; }
- (void)hoverAt:(NSEvent *)event {
    if(!self.hints.count || self.segmentCount<1 || TNViewCovered(self,event.locationInWindow)) return;
    CGFloat width=NSWidth(self.bounds)/self.segmentCount; NSInteger i=(NSInteger)floor([self convertPoint:event.locationInWindow fromView:nil].x/width);
    if(i<0 || i>=self.segmentCount || i>=(NSInteger)self.hints.count || i==self.hoverSegment) return;
    self.hoverSegment=i; TNHintShow(self,NSMakeRect(i*width,0,width,NSHeight(self.bounds)),self.hints[i],NO);
}
- (void)mouseEntered:(NSEvent *)event { self.hoverSegment=-1; [self hoverAt:event]; }
- (void)mouseMoved:(NSEvent *)event { [self hoverAt:event]; }
- (void)mouseExited:(NSEvent *)event { (void)event; self.hoverSegment=-1; TNHintHide(self); }
- (void)mouseDown:(NSEvent *)event { TNHintHide(self); self.hoverSegment=-1; [super mouseDown:event]; }
/* The cell draws equal segments; make hit-testing match the drawing. */
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    if(self.segmentCount>0) for(NSInteger i=0;i<self.segmentCount;i++) [self setWidth:floor(size.width/self.segmentCount)-1 forSegment:i];
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if(self.window.firstResponder==self) { [TNAccent() setStroke]; NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:8 yRadius:8]; p.lineWidth=2; [p stroke]; }
}
@end
@interface TNPopupCell : NSPopUpButtonCell
@end
@implementation TNPopupCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    Rounded(NSInsetRect(frame,1,1),8,Control(),Border());
    NSRect text=NSInsetRect(frame,12,0); text.size.width-=20;
    NSImage *icon=self.selectedItem.image;
    if(icon) { DrawIcon(icon,NSMakeRect(text.origin.x-2,text.origin.y,20,text.size.height),NSColor.labelColor); text.origin.x+=22; text.size.width-=22; }
    /* A menu item may carry a short display title in representedObject; the menu shows the full one. */
    id shortTitle=self.selectedItem.representedObject;
    Title([shortTitle isKindOfClass:NSString.class]?shortTitle:self.title,text,[NSFont systemFontOfSize:13 weight:NSFontWeightMedium],NSColor.labelColor,NSTextAlignmentLeft);
    CGFloat x=NSMaxX(frame)-17,y=NSMidY(frame);
    NSBezierPath *chevron=[NSBezierPath bezierPath]; [chevron moveToPoint:NSMakePoint(x-4,y-2)]; [chevron lineToPoint:NSMakePoint(x,y+2)]; [chevron lineToPoint:NSMakePoint(x+4,y-2)]; chevron.lineWidth=1.6; [NSColor.secondaryLabelColor setStroke]; [chevron stroke]; (void)view;
}
@end
@implementation TNPopup
+ (Class)cellClass { return TNPopupCell.class; }
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if(self.window.firstResponder==self) { [TNAccent() setStroke]; NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds,1,1) xRadius:8 yRadius:8]; p.lineWidth=2; [p stroke]; }
}
@end
@interface TNSliderCell : NSSliderCell
@end
@implementation TNSliderCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    double range=self.maxValue-self.minValue,position=range>0?(self.doubleValue-self.minValue)/range:0;
    if(self.isVertical) {   // filled from the bottom
        NSRect track=NSMakeRect(NSMidX(rect)-3,rect.origin.y,6,rect.size.height); Rounded(track,3,Control(),nil);
        CGFloat h=track.size.height*fmax(0,fmin(1,position)); if(h>0) Rounded(NSMakeRect(track.origin.x,flipped?NSMaxY(track)-h:track.origin.y,6,h),3,TNAccent(),nil);
        return;
    }
    NSRect track=NSMakeRect(rect.origin.x,NSMidY(rect)-3,rect.size.width,6); Rounded(track,3,Control(),nil);
    TNSlider *slider=(TNSlider *)self.controlView;
    if([slider isKindOfClass:TNSlider.class] && range>0 && slider.recommendedMax>slider.recommendedMin) {
        double a=fmax(0,(slider.recommendedMin-self.minValue)/range),b=fmin(1,(slider.recommendedMax-self.minValue)/range);
        NSRect zone=NSMakeRect(track.origin.x+track.size.width*a,NSMidY(rect)+5,track.size.width*(b-a),2);
        Rounded(zone,1,[NSColor.systemGreenColor colorWithAlphaComponent:.75],nil);
    }
    track.size.width*=fmax(0,fmin(1,position)); if(track.size.width>0) Rounded(track,3,TNAccent(),nil); (void)flipped;
}
- (void)drawKnob:(NSRect)knobRect {
    NSRect knob=NSInsetRect(knobRect,1,1); Rounded(knob,knob.size.width/2,NSColor.whiteColor,[TNAccent() colorWithAlphaComponent:.6]);
    Rounded(NSInsetRect(knob,5,5),4,TNAccent(),nil);
}
@end
@implementation TNSlider
+ (Class)cellClass { return TNSliderCell.class; }
@end
