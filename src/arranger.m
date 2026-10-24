#import "arranger.h"
#import "controls.h"

static const CGFloat KvLaneTop=58,KvLaneHeight=64,KvGhostTop=130,KvGhostHeight=34,KvDynamicsTop=186,KvInset=8;
static NSString *Translated(const char *text) { return T([NSString stringWithUTF8String:text]); }
/* The colour of a section's kind: verses the accent, choruses orange, breakdowns teal, transitions purple, intro and outro grey. */
static NSColor *KindColor(KvSectionKind kind) {
    switch(kind) {
        case KV_SECTION_VERSE: return TNAccent();
        case KV_SECTION_CHORUS: return NSColor.systemOrangeColor;
        case KV_SECTION_PIT: return NSColor.systemTealColor;
        case KV_SECTION_TRANSITION: return NSColor.systemPurpleColor;
        default: return NSColor.systemGrayColor;
    }
}
static TNPopup *Popup(NSArray<NSArray<NSString *> *> *items,id target,SEL action,NSString *tip) {
    TNPopup *popup=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for(NSArray<NSString *> *item in items) { [popup addItemWithTitle:item[0]]; popup.lastItem.representedObject=item.count>1?item[1]:nil; }
    popup.target=target; popup.action=action; popup.toolTip=tip; [popup setAccessibilityLabel:tip]; return popup;
}
static TNButton *Icon(NSString *symbol,NSString *fallback,NSString *tip,id target,SEL action) {
    TNButton *button=[TNButton buttonWithTitle:@"" target:target action:action]; button.bezelStyle=NSBezelStyleRounded; button.bordered=NO;
    NSImage *image=TNIcon(symbol,14); if(image) button.image=image; else button.title=fallback;
    button.hint=tip; return button;
}

/* The playhead: a thin view that moves each frame, so the lane under it is not repainted. */
@interface KvPlayheadView : NSView
@end
@implementation KvPlayheadView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { self.layer.backgroundColor=NSColor.systemOrangeColor.CGColor; }
@end
@interface KvArranger ()
@property(nonatomic) NSTrackingArea *tracking;
@property(nonatomic) NSInteger pressed;            /* section under the mouse at mouseDown, −1 none */
@property(nonatomic) BOOL stretching,dragging,copying;
@property(nonatomic) NSPoint downPoint;
@property(nonatomic) NSInteger dropIndex;          /* insertion point while dragging */
@property(nonatomic) int stretchRepeats;           /* while stretching: the repeats the edge points at */
@property(nonatomic) double cutBeat;               /* scissors (⌘ held over a section): the cut in song beats, −1 none */
@property(nonatomic) NSInteger cutSection;
@property(nonatomic) NSTextField *info;
@property(nonatomic,readwrite) NSInteger hoverSection,hoverGhost,hoverSeam;   /* the section whose ghosts show, the ghost and the seam under the mouse */
@property(nonatomic) NSArray<NSDictionary *> *ghosts; @property(nonatomic) NSInteger ghostsFor;
@property(nonatomic) BOOL auditioning;
@property(nonatomic) KvPlayheadView *playhead;
@property(nonatomic,readwrite) NSPopUpButton *kindChoice,*repeatsChoice,*levelChoice,*beatChoice,*liftChoice,*transitionChoice;
@property(nonatomic,readwrite) NSButton *openButton,*revertButton,*removeButton,*takeButton,*exportButton;
@end

@implementation KvArranger
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        _selected=-1; _pressed=-1; _cutBeat=-1; _cutSection=-1; _dropIndex=-1; _hoverSection=_hoverGhost=_hoverSeam=_ghostsFor=-1;
        [self setAccessibilityRole:NSAccessibilityGroupRole]; [self setAccessibilityLabel:T(@"Аранжировщик")];
        NSMutableArray *kinds=[NSMutableArray array]; for(int k=0;k<KV_SECTION_KINDS;k++) [kinds addObject:@[Translated(kv_section_kind_name((KvSectionKind)k))]];
        _kindChoice=Popup(kinds,self,@selector(fieldChanged:),T(@"Тип секции"));
        NSMutableArray *repeats=[NSMutableArray array]; for(int r=1;r<=KV_SECTION_REPEATS;r++) [repeats addObject:@[[NSString stringWithFormat:T(@"Повтор ×%d"),r],[NSString stringWithFormat:@"×%d",r]]];
        _repeatsChoice=Popup(repeats,self,@selector(fieldChanged:),T(@"Сколько раз прогрессия звучит подряд · или потяните правый край секции"));
        NSMutableArray *levels=[NSMutableArray array]; for(int l=50;l<=120;l+=10) [levels addObject:@[[NSString stringWithFormat:T(@"Громкость %d %%"),l],[NSString stringWithFormat:@"%d %%",l]]];
        _levelChoice=Popup(levels,self,@selector(fieldChanged:),T(@"Громкость секции: сила удара всех нот"));
        NSMutableArray *beats=[@[@[T(@"Бит как у песни"),T(@"Бит: как у песни")],@[T(@"Без бита"),T(@"Без бита")],@[T(@"Тихий бит: хай-хэт и шейкер"),T(@"Бит: тихий")],@[T(@"Бит по стилю рисунка"),T(@"Бит: по стилю")]] mutableCopy];
        for(int b=0;b<KV_BEAT_COUNT;b++) [beats addObject:@[[NSString stringWithFormat:T(@"Бит «%@»"),Translated(kv_beat_name((KvBeat)b))],[NSString stringWithFormat:T(@"Бит: %@"),[Translated(kv_beat_name((KvBeat)b)) lowercaseString]]]];
        _beatChoice=Popup(beats,self,@selector(fieldChanged:),T(@"Ритм под секцией: «как у песни» — метроном и бит из транспорта"));
        _liftChoice=Popup(@[@[T(@"Регистр как на круге"),T(@"Регистр: как на круге")],@[T(@"Правая рука на октаву выше"),T(@"Правая на октаву выше")],@[T(@"Обе руки на октаву ниже"),T(@"Обе на октаву ниже")]],self,@selector(fieldChanged:),T(@"Регистр секции"));
        NSMutableArray *ways=[NSMutableArray array]; for(int t=0;t<KV_TRANSITION_KINDS;t++) [ways addObject:@[[NSString stringWithFormat:T(@"Переход: %@"),[Translated(kv_transition_name((KvTransitionKind)t)) lowercaseString]]]];
        _transitionChoice=Popup(ways,self,@selector(fieldChanged:),T(@"Как переход ведёт в следующую секцию"));
        _openButton=Icon(@"tonora.roll",@"✎",T(@"Открыть секцию в пиано-ролле · двойной щелчок · Enter"),self,@selector(openSelected:));
        _revertButton=Icon(@"arrow.counterclockwise",@"↺",T(@"Вернуть рисунок: убрать ручные правки нот секции"),self,@selector(revert:));
        _removeButton=Icon(@"trash",@"⌫",T(@"Удалить секцию · ⌫"),self,@selector(removeSelected:));
        _takeButton=[TNButton buttonWithTitle:T(@"Взять текущую последовательность") target:self action:@selector(take:)]; _takeButton.bezelStyle=NSBezelStyleRounded; _takeButton.bordered=NO;
        _takeButton.font=[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]; ((TNButton *)_takeButton).hint=T(@"Последовательность с круга становится первой секцией · ⇧⌘A");
        _exportButton=Icon(@"square.and.arrow.down",@"↓",T(@"Экспорт MIDI песни… · ⇧⌘E · все секции, бит на 10-м канале, маркеры секций"),nil,NSSelectorFromString(@"exportSong:"));
        _info=[NSTextField labelWithString:@""]; _info.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; _info.textColor=NSColor.secondaryLabelColor; _info.lineBreakMode=NSLineBreakByTruncatingTail;
        for(NSView *view in @[_kindChoice,_repeatsChoice,_levelChoice,_beatChoice,_liftChoice,_transitionChoice,_openButton,_revertButton,_removeButton,_takeButton,_exportButton,_info]) [self addSubview:view];
        _playhead=[[KvPlayheadView alloc] initWithFrame:NSZeroRect]; _playhead.wantsLayer=YES; _playhead.hidden=YES; [self addSubview:_playhead];
    }
    return self;
}
- (const KvSong *)song { return [self.owner arrangerSong]; }
- (double)songBeats { const KvSong *s=[self song]; return s?kv_song_beats(s):0; }
- (double)beatsPerBar { const KvSong *s=[self song]; return s?kv_meter_bar(s->meter):4; }
/* Points per beat: the whole song across the width, at least sixteen bars' worth, never less than 18 points a bar. */
- (CGFloat)scale {
    CGFloat width=NSWidth(self.bounds)-2*KvInset; double bar=[self beatsPerBar];
    double shown=MAX([self songBeats],16*bar);
    return (CGFloat)MAX(18/bar,width/shown);
}
- (CGFloat)xOfBeat:(double)beat { return KvInset+(CGFloat)((beat-self.scrollBeat)*[self scale]); }
- (double)beatAtX:(CGFloat)x { return self.scrollBeat+(x-KvInset)/[self scale]; }
- (NSRect)rectOfSection:(NSInteger)index {
    const KvSong *s=[self song]; if(!s || index<0 || index>=(NSInteger)s->count) return NSZeroRect;
    double start=kv_section_start(s,(size_t)index),length=kv_section_beats(s,(size_t)index);
    CGFloat x=[self xOfBeat:start]; return NSMakeRect(x,KvLaneTop,MAX(6,length*[self scale]-3),KvLaneHeight);
}
- (NSInteger)sectionAtPoint:(NSPoint)p {
    const KvSong *s=[self song]; if(!s) return -1;
    for(NSInteger i=0;i<(NSInteger)s->count;i++) if(NSPointInRect(p,NSInsetRect([self rectOfSection:i],-1,0))) return i;
    return -1;
}
- (void)clampScroll {
    double visible=(NSWidth(self.bounds)-2*KvInset)/[self scale],max=MAX(0,[self songBeats]-visible+[self beatsPerBar]);
    self.scrollBeat=MAX(0,MIN(max,self.scrollBeat));
}
- (void)layout {
    [super layout]; [self clampScroll];
    CGFloat h=NSHeight(self.bounds),y=h-34,x=KvInset;
    self.info.frame=NSMakeRect(KvInset,y-26,NSWidth(self.bounds)-2*KvInset,18);
    const KvSong *s=[self song]; BOOL transition=s && self.selected>=0 && self.selected<(NSInteger)s->count && s->sections[self.selected].kind==KV_SECTION_TRANSITION;
    NSArray *row=@[self.kindChoice,self.repeatsChoice,self.levelChoice,self.beatChoice,transition?self.transitionChoice:self.liftChoice];
    const CGFloat widths[5]={112,64,90,150,204};
    for(NSUInteger i=0;i<row.count;i++) { ((NSView *)row[i]).frame=NSMakeRect(x,y,widths[i],28); x+=widths[i]+6; }
    self.liftChoice.hidden=transition; self.transitionChoice.hidden=!transition;
    CGFloat right=NSWidth(self.bounds)-KvInset;
    self.removeButton.frame=NSMakeRect(right-34,y-2,34,32); self.revertButton.frame=NSMakeRect(right-74,y-2,34,32); self.openButton.frame=NSMakeRect(right-114,y-2,34,32);
    self.takeButton.frame=NSMakeRect(round(NSMidX(self.bounds)-150),round(NSMidY(self.bounds)+4),300,32);
    self.exportButton.frame=NSMakeRect(right-34,0,34,28);
}
- (void)updatePlayhead {
    double beat=[self.owner arrangerPlayheadBeat]; CGFloat x=beat>=0?round([self xOfBeat:beat]):-1;
    BOOL shown=beat>=0 && x>=KvInset-1 && x<=NSWidth(self.bounds)-KvInset+1;
    if(self.playhead.hidden!=!shown) self.playhead.hidden=!shown;
    NSRect frame=NSMakeRect(x-1,48,2,KvDynamicsTop+30-48); if(shown && !NSEqualRects(frame,self.playhead.frame)) self.playhead.frame=frame;
}
- (void)reload {
    self.ghosts=nil; self.ghostsFor=-1;
    const KvSong *s=[self song]; BOOL empty=!s || !s->count;
    if(empty || self.hoverSection>=(NSInteger)s->count) { self.hoverSection=self.hoverGhost=self.hoverSeam=-1; }
    if(!empty && (self.selected<0 || self.selected>=(NSInteger)s->count)) self.selected=0;
    BOOL has=!empty && self.selected>=0;
    for(NSView *view in @[self.kindChoice,self.repeatsChoice,self.levelChoice,self.beatChoice,self.liftChoice,self.transitionChoice,self.openButton,self.revertButton,self.removeButton,self.info]) view.hidden=!has;
    self.takeButton.hidden=!empty; self.exportButton.hidden=empty;
    if(has) {
        const KvSection *x=&s->sections[self.selected];
        [self.kindChoice selectItemAtIndex:x->kind]; [self.repeatsChoice selectItemAtIndex:x->repeats-1];
        [self.levelChoice selectItemAtIndex:MAX(0,MIN(7,(int)lroundf(x->level*10)-5))];
        [self.beatChoice selectItemAtIndex:x->beat==KV_SECTION_BEAT_FIXED?4+x->beat_fixed:MIN(3,(int)x->beat)];
        [self.liftChoice selectItemAtIndex:x->lift>0?1:x->lift<0?2:0]; [self.transitionChoice selectItemAtIndex:x->transition];
        self.revertButton.enabled=[self.owner arrangerEdited:self.selected];
        double bar=[self beatsPerBar],start=kv_section_start(s,(size_t)self.selected),length=kv_section_beats(s,(size_t)self.selected);
        int first=(int)floor(start/bar+1e-9)+1,last=(int)ceil((start+length)/bar-1e-9);
        NSString *bars=first==last?[NSString stringWithFormat:T(@"такт %d"),first]:[NSString stringWithFormat:T(@"такты %d–%d"),first,last];
        self.info.stringValue=[NSString stringWithFormat:@"%@ · %@ · %@%@",[self.owner arrangerName:self.selected],bars,[self.owner arrangerDetails:self.selected],[self.owner arrangerEdited:self.selected]?T(@" · ✎ ноты правлены в ролле"):@""];
    }
    self.needsLayout=YES; self.needsDisplay=YES;
}

// ---- ghosts: what may come next, under the hovered section ----
- (NSArray<NSDictionary *> *)ghostsAfter:(NSInteger)index {
    if(index<0) return @[];
    if(self.ghostsFor!=index || !self.ghosts) { self.ghosts=[self.owner arrangerSuggestions:index]?:@[]; self.ghostsFor=index; }
    return self.ghosts;
}
static const CGFloat KvLeadWidth=24;
- (NSArray<NSValue *> *)ghostRectsAfter:(NSInteger)index {
    NSArray<NSDictionary *> *ghosts=[self ghostsAfter:index]; if(!ghosts.count) return @[];
    NSMutableArray<NSValue *> *rects=[NSMutableArray array]; CGFloat x=NSMinX([self rectOfSection:index]),start=x;
    // As long as what they insert, at least 112 points; a row wider than the view shrinks to fit it.
    CGFloat leads=0,sum=0,widths[8]; NSUInteger count=MIN(ghosts.count,(NSUInteger)8);
    for(NSUInteger i=0;i<count;i++) { leads+=([ghosts[i][@"leadBeats"] doubleValue]>0?KvLeadWidth+4:0)+6; widths[i]=MAX(112,[ghosts[i][@"beats"] doubleValue]*[self scale]-3); sum+=widths[i]; }
    CGFloat room=NSWidth(self.bounds)-2*KvInset-leads; if(sum>room && room>0) for(NSUInteger i=0;i<count;i++) widths[i]=MAX(96,widths[i]*room/sum);
    for(NSUInteger i=0;i<count;i++) {
        CGFloat lead=[ghosts[i][@"leadBeats"] doubleValue]>0?KvLeadWidth+4:0;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x+lead,KvGhostTop,widths[i],KvGhostHeight)]]; x+=lead+widths[i]+6;
    }
    CGFloat over=x-6-(NSWidth(self.bounds)-KvInset),shift=MAX(0,MIN(over,start-KvInset));   // keep the row inside the view
    if(shift>0) for(NSUInteger i=0;i<rects.count;i++) rects[i]=[NSValue valueWithRect:NSOffsetRect(rects[i].rectValue,-shift,0)];
    return rects;
}
- (NSRect)leadRectOf:(NSRect)ghost { return NSMakeRect(NSMinX(ghost)-KvLeadWidth-4,NSMinY(ghost),KvLeadWidth,NSHeight(ghost)); }
/* The seam after section i: the gap to the next one, when neither side is a transition. */
- (NSInteger)seamAtPoint:(NSPoint)p {
    const KvSong *s=[self song]; if(!s || p.y<KvLaneTop || p.y>KvLaneTop+KvLaneHeight) return -1;
    for(NSInteger i=0;i+1<(NSInteger)s->count;i++) {
        CGFloat edge=NSMinX([self rectOfSection:i+1])-1.5;
        if(fabs(p.x-edge)<=5 && s->sections[i].kind!=KV_SECTION_TRANSITION && s->sections[i+1].kind!=KV_SECTION_TRANSITION) return i;
    }
    return -1;
}
- (void)hoverAtPoint:(NSPoint)p {
    NSInteger section=self.hoverSection,ghost=-1,seam=[self seamAtPoint:p],under=[self sectionAtPoint:p];
    if(seam>=0) section=-1;
    else if(under>=0 && !self.dragging && !self.stretching) section=under;
    else if(section>=0 && p.y>=KvGhostTop-8 && p.y<=KvGhostTop+KvGhostHeight+4) {   // moving down onto the ghosts keeps them
        NSArray<NSValue *> *rects=[self ghostRectsAfter:section]; CGFloat left=CGFLOAT_MAX,right=-CGFLOAT_MAX;
        for(NSUInteger i=0;i<rects.count;i++) { NSRect r=rects[i].rectValue; left=MIN(left,NSMinX(r)-KvLeadWidth-4); right=MAX(right,NSMaxX(r));
            if(NSPointInRect(p,NSUnionRect(r,[self leadRectOf:r]))) ghost=(NSInteger)i; }
        if(p.x<left-8 || p.x>right+8) section=-1;
    } else section=-1;
    if(ghost!=self.hoverGhost && self.auditioning) { self.auditioning=NO; [self.owner arrangerAudition:-1 after:self.hoverSection]; }
    BOOL changed=section!=self.hoverSection || ghost!=self.hoverGhost || seam!=self.hoverSeam;
    self.hoverSection=section; self.hoverSeam=seam;
    if(ghost!=self.hoverGhost) {
        self.hoverGhost=ghost;
        if(ghost>=0) { NSArray *ghosts=[self ghostsAfter:section]; NSRect r=[[self ghostRectsAfter:section][ghost] rectValue]; TNHintShow(self,r,ghosts[ghost][@"tip"],NO); }
        else TNHintHide(self);
    }
    if(seam>=0 && changed) TNHintShow(self,NSMakeRect(NSMinX([self rectOfSection:seam+1])-10,KvLaneTop,16,KvLaneHeight),T(@"Вставить переход · ⌥-щелчок — выбрать вид"),NO);
    else if(seam<0 && ghost<0 && changed) TNHintHide(self);
    if(changed) self.needsDisplay=YES;
}
- (void)drawGhosts {
    const KvSong *s=[self song];
    if(self.hoverSeam>=0 && s) {
        CGFloat x=NSMinX([self rectOfSection:self.hoverSeam+1])-10;
        NSBezierPath *pill=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,KvLaneTop-4,17,KvLaneHeight+8) xRadius:5 yRadius:5];
        CGFloat dash[]={4,3}; [pill setLineDash:dash count:2 phase:0]; pill.lineWidth=1.5; [[NSColor.systemPurpleColor colorWithAlphaComponent:.12] setFill]; [pill fill]; [NSColor.systemPurpleColor setStroke]; [pill stroke];
        Text(@"+",NSMakeRect(x+3,KvLaneTop+KvLaneHeight/2-10,12,18),15,NSFontWeightSemibold,NSColor.systemPurpleColor,NO);
    }
    if(self.hoverSection<0 || self.dragging || self.stretching) return;
    NSArray<NSDictionary *> *ghosts=[self ghostsAfter:self.hoverSection]; NSArray<NSValue *> *rects=[self ghostRectsAfter:self.hoverSection];
    for(NSUInteger i=0;i<ghosts.count && i<rects.count;i++) {
        NSRect r=rects[i].rectValue; NSColor *color=KindColor((KvSectionKind)[ghosts[i][@"kind"] intValue]); BOOL hot=(NSInteger)i==self.hoverGhost;
        CGFloat dash[]={5,4};
        if([ghosts[i][@"leadBeats"] doubleValue]>0) {
            NSBezierPath *lead=[NSBezierPath bezierPathWithRoundedRect:[self leadRectOf:r] xRadius:6 yRadius:6]; [lead setLineDash:dash count:2 phase:0]; lead.lineWidth=1.5;
            if(hot) { [[NSColor.systemPurpleColor colorWithAlphaComponent:.15] setFill]; [lead fill]; } [NSColor.systemPurpleColor setStroke]; [lead stroke];
            NSArray *glyphs=@[@"⤴",@"V7",@"∿",@"‖"]; NSInteger way=MIN(3,MAX(0,[ghosts[i][@"leadKind"] integerValue]));
            Text(glyphs[way],NSMakeRect(NSMinX(r)-KvLeadWidth-1,NSMinY(r)+9,KvLeadWidth,16),way==1?9:12,NSFontWeightSemibold,NSColor.systemPurpleColor,NO);
        }
        NSBezierPath *box=[NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8]; [box setLineDash:dash count:2 phase:0]; box.lineWidth=1.5;
        if(hot) { [[color colorWithAlphaComponent:.15] setFill]; [box fill]; } [color setStroke]; [box stroke];
        NSString *title=self.auditioning && hot?[@"▶ " stringByAppendingString:ghosts[i][@"title"]]:ghosts[i][@"title"];
        Text(title,NSMakeRect(NSMinX(r)+8,NSMinY(r)+9,NSWidth(r)-14,16),11,NSFontWeightSemibold,color,NO);
    }
}
// ---- drawing ----
static void Text(NSString *text,NSRect rect,CGFloat size,NSFontWeight weight,NSColor *color,BOOL mono) {
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.lineBreakMode=NSLineBreakByTruncatingTail;
    NSFont *font=mono?[NSFont monospacedSystemFontOfSize:size weight:weight]:[NSFont systemFontOfSize:size weight:weight];
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:style}];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; const KvSong *s=[self song]; CGFloat w=NSWidth(self.bounds);
    if(!s || !s->count) {
        Text(T(@"Соберите последовательность на круге и отправьте её сюда · ⇧⌘A"),NSMakeRect(KvInset,NSMidY(self.bounds)-28,w-2*KvInset,20),14,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
        return;
    }
    double bar=[self beatsPerBar],total=kv_song_beats(s),bpm=s->bpm; int bars=(int)ceil(total/bar-1e-9),seconds=(int)lround(total*60/bpm);
    NSString *header=[NSString stringWithFormat:T(@"Песня · %@ · %@ · %.0f BPM · %@ · %d:%02d"),Translated(kv_key_title(s->key)),Translated(kv_meter_name(s->meter)),bpm,TNBarCount(bars),seconds/60,seconds%60];
    Text(header,NSMakeRect(KvInset,4,w-2*KvInset-44,20),14,NSFontWeightSemibold,NSColor.labelColor,NO);
    [NSGraphicsContext saveGraphicsState]; NSRectClip(NSMakeRect(KvInset-2,28,w-2*KvInset+4,NSHeight(self.bounds)-28));
    // Ruler: a number at each section start and every four bars; a tick on every bar.
    [[NSColor.separatorColor colorWithAlphaComponent:.8] setFill]; NSRectFill(NSMakeRect(KvInset,52,w-2*KvInset,1));
    NSMutableIndexSet *labelled=[NSMutableIndexSet indexSet]; for(size_t i=0;i<s->count;i++) [labelled addIndex:(NSUInteger)floor(kv_section_start(s,i)/bar+1e-9)];
    for(int b=0;b<=bars;b++) { if(b%4==0) [labelled addIndex:(NSUInteger)b]; }
    CGFloat lastLabel=-100;
    for(int b=0;b<=bars;b++) {
        CGFloat x=[self xOfBeat:b*bar]; [NSColor.separatorColor setFill]; NSRectFill(NSMakeRect(x,48,1,4));
        if([labelled containsIndex:(NSUInteger)b] && x-lastLabel>22) { Text([NSString stringWithFormat:@"%d",b+1],NSMakeRect(x+2,34,40,14),10,NSFontWeightMedium,NSColor.secondaryLabelColor,NO); lastLabel=x; }
    }
    // The lane.
    for(NSInteger i=0;i<(NSInteger)s->count;i++) {
        const KvSection *x=&s->sections[i]; NSRect r=[self rectOfSection:i]; if(NSMaxX(r)<0 || NSMinX(r)>w) continue;
        NSColor *color=KindColor(x->kind); if(i==self.pressed && self.dragging) color=[color colorWithAlphaComponent:.55];
        NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8]; [color setFill]; [path fill];
        double pass=kv_section_pass_beats(s,x);
        for(int k=1;k<x->repeats;k++) { CGFloat px=NSMinX(r)+(CGFloat)(k*pass*[self scale]); [[NSColor.whiteColor colorWithAlphaComponent:.35] setFill]; NSRectFill(NSMakeRect(px,NSMinY(r)+6,1,NSHeight(r)-12)); }
        if(i==self.selected) { NSBezierPath *ring=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r,-2,-2) xRadius:10 yRadius:10]; ring.lineWidth=2; [NSColor.labelColor setStroke]; [ring stroke]; }
        NSRect text=NSInsetRect(r,8,0); BOOL edited=[self.owner arrangerEdited:i];
        if(NSWidth(text)>14) {
            Text([self.owner arrangerName:i],NSMakeRect(NSMinX(text),NSMinY(r)+6,NSWidth(text)-(edited?14:0),17),13,NSFontWeightSemibold,NSColor.whiteColor,NO);
            Text([self.owner arrangerChords:i],NSMakeRect(NSMinX(text),NSMinY(r)+24,NSWidth(text),16),11,NSFontWeightMedium,NSColor.whiteColor,YES);
            Text([self.owner arrangerDetails:i],NSMakeRect(NSMinX(text),NSMinY(r)+42,NSWidth(text),15),10,NSFontWeightRegular,[NSColor.whiteColor colorWithAlphaComponent:.85],NO);
            if(edited) Text(@"✎",NSMakeRect(NSMaxX(r)-18,NSMinY(r)+5,14,16),12,NSFontWeightRegular,NSColor.whiteColor,NO);
        }
    }
    // Stretching: the length the edge points at.
    if(self.stretching && self.pressed>=0 && self.pressed<(NSInteger)s->count) {
        NSRect r=[self rectOfSection:self.pressed]; double pass=kv_section_pass_beats(s,&s->sections[self.pressed]);
        CGFloat to=NSMinX(r)+(CGFloat)(pass*self.stretchRepeats*[self scale])-3;
        NSBezierPath *ghost=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(r),NSMinY(r),MAX(6,to-NSMinX(r)),NSHeight(r)) xRadius:8 yRadius:8];
        CGFloat dash[]={5,4}; [ghost setLineDash:dash count:2 phase:0]; ghost.lineWidth=1.5; [NSColor.labelColor setStroke]; [ghost stroke];
        Text([NSString stringWithFormat:@"×%d",self.stretchRepeats],NSMakeRect(to-34,NSMaxY(r)+4,40,14),11,NSFontWeightSemibold,NSColor.labelColor,NO);
    }
    // Dragging: where the section lands.
    if(self.dragging && self.dropIndex>=0) {
        CGFloat x=self.dropIndex<(NSInteger)s->count?NSMinX([self rectOfSection:self.dropIndex])-3:NSMaxX([self rectOfSection:(NSInteger)s->count-1])+1;
        [TNAccent() setFill]; NSRectFill(NSMakeRect(x-1,KvLaneTop-6,3,KvLaneHeight+12));
        if(self.copying) Text(T(@"копия"),NSMakeRect(x+4,KvLaneTop-18,60,14),10,NSFontWeightSemibold,TNAccent(),NO);
    }
    // Scissors: the cut ⌘-click makes.
    if(self.cutBeat>=0) {
        CGFloat x=[self xOfBeat:self.cutBeat]; NSBezierPath *line=[NSBezierPath bezierPath]; [line moveToPoint:NSMakePoint(x,KvLaneTop-4)]; [line lineToPoint:NSMakePoint(x,KvLaneTop+KvLaneHeight+4)];
        CGFloat dash[]={3,3}; [line setLineDash:dash count:2 phase:0]; line.lineWidth=1.5; [NSColor.labelColor setStroke]; [line stroke];
        Text([NSString stringWithFormat:T(@"✂ такт %d"),(int)floor(self.cutBeat/bar+1e-9)+1],NSMakeRect(x-30,KvLaneTop+KvLaneHeight+6,80,14),11,NSFontWeightSemibold,NSColor.labelColor,NO);
    }
    // Dynamics: each section's level, a line from 50 % (low) to 120 % (high).
    Text(T(@"Громкость"),NSMakeRect(KvInset,KvDynamicsTop-16,120,14),10,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
    NSBezierPath *levels=[NSBezierPath bezierPath]; levels.lineWidth=2;
    for(NSInteger i=0;i<(NSInteger)s->count;i++) {
        NSRect r=[self rectOfSection:i]; CGFloat y=KvDynamicsTop+(CGFloat)((1.2-s->sections[i].level)/.7*24);
        if(!i) [levels moveToPoint:NSMakePoint(NSMinX(r),y)]; else [levels lineToPoint:NSMakePoint(NSMinX(r),y)];
        [levels lineToPoint:NSMakePoint(NSMaxX(r),y)];
    }
    [TNAccent() setStroke]; [levels stroke];
    [self drawGhosts];
    [NSGraphicsContext restoreGraphicsState];
    Text(T(@"Наведите на секцию — что дальше · двойной щелчок — в ролл · перетаскивание — переставить, с ⌥ — копия · ⌘-щелчок — разрезать · правый край — повторы"),NSMakeRect(KvInset,KvDynamicsTop+36,w-2*KvInset,14),10,NSFontWeightRegular,NSColor.tertiaryLabelColor,NO);
}

// ---- mouse ----
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (BOOL)nearRightEdge:(NSPoint)p of:(NSInteger)index { NSRect r=[self rectOfSection:index]; return index>=0 && fabs(p.x-NSMaxX(r))<=6 && p.y>=NSMinY(r) && p.y<=NSMaxY(r); }
/* With ⌘ held over a section: the allowed cut nearest the mouse. */
- (void)updateScissorsAt:(NSPoint)p flags:(NSEventModifierFlags)flags {
    double before=self.cutBeat; self.cutBeat=-1; self.cutSection=-1;
    const KvSong *s=[self song]; NSInteger i=[self sectionAtPoint:p];
    if(s && i>=0 && (flags&NSEventModifierFlagCommand)) {
        double start=kv_section_start(s,(size_t)i),cut=kv_song_snap_cut(s,(size_t)i,[self beatAtX:p.x]-start);
        if(cut>0) { self.cutBeat=start+cut; self.cutSection=i; }
    }
    if(before!=self.cutBeat) self.needsDisplay=YES;
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; [self updateScissorsAt:p flags:event.modifierFlags]; [self hoverAtPoint:p];
    NSInteger i=[self sectionAtPoint:p];
    if(self.cutBeat>=0) [NSCursor.crosshairCursor set]; else if([self nearRightEdge:p of:i] || [self nearRightEdge:p of:[self sectionAtPoint:NSMakePoint(p.x-4,p.y)]]) [NSCursor.resizeLeftRightCursor set]; else [NSCursor.arrowCursor set];
}
- (void)flagsChanged:(NSEvent *)event { [self updateScissorsAt:[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil] flags:event.modifierFlags]; [super flagsChanged:event]; }
- (void)mouseExited:(NSEvent *)event { (void)event; if(self.cutBeat>=0) { self.cutBeat=-1; self.needsDisplay=YES; } [self hoverAtPoint:NSMakePoint(-100,-100)]; [NSCursor.arrowCursor set]; }
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; self.downPoint=p; self.dragging=self.stretching=NO;
    BOOL option=(event.modifierFlags&NSEventModifierFlagOption)!=0; [self hoverAtPoint:p];
    if(self.hoverGhost>=0 && self.hoverSection>=0) {   // a ghost: insert it, or (⌥ on a new chorus) choose among other choruses
        NSInteger after=self.hoverSection,ghost=self.hoverGhost; NSDictionary *g=[self ghostsAfter:after][ghost];
        if(self.auditioning) { self.auditioning=NO; [self.owner arrangerAudition:-1 after:after]; }
        if(option && [g[@"chorus"] boolValue]) {
            NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Другой припев")]; NSArray<NSString *> *variants=[self.owner arrangerChorusVariants:after];
            for(NSUInteger k=0;k<variants.count;k++) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:variants[k] action:@selector(chooseVariant:) keyEquivalent:@""]; item.target=self; item.tag=(NSInteger)k; item.representedObject=@(after); [menu addItem:item]; }
            [menu popUpMenuPositioningItem:nil atLocation:p inView:self]; return;
        }
        self.hoverSection=self.hoverGhost=-1; TNHintHide(self); [self.owner arrangerAccept:ghost after:after]; return;
    }
    if(self.hoverSeam>=0) {
        NSInteger after=self.hoverSeam; self.hoverSeam=-1; TNHintHide(self);
        if(option) {
            NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Переход")];
            for(int k=0;k<KV_TRANSITION_KINDS;k++) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:T(@"Переход: %@"),[Translated(kv_transition_name((KvTransitionKind)k)) lowercaseString]] action:@selector(chooseTransition:) keyEquivalent:@""]; item.target=self; item.tag=k; item.representedObject=@(after); [menu addItem:item]; }
            [menu popUpMenuPositioningItem:nil atLocation:p inView:self]; return;
        }
        [self.owner arrangerTransitionAfter:after kind:-1]; return;
    }
    NSInteger i=[self sectionAtPoint:p];
    if(i<0) { NSInteger left=[self sectionAtPoint:NSMakePoint(p.x-4,p.y)]; if([self nearRightEdge:p of:left]) i=left; }
    self.pressed=i; if(i<0) return;
    if(event.modifierFlags&NSEventModifierFlagCommand) {   // scissors
        [self updateScissorsAt:p flags:event.modifierFlags];
        if(self.cutBeat>=0) { const KvSong *s=[self song]; double at=self.cutBeat-kv_section_start(s,(size_t)self.cutSection); NSInteger section=self.cutSection; self.cutBeat=-1; self.pressed=-1; [self.owner arrangerCut:section atBeat:at]; }
        return;
    }
    if(event.clickCount==2) { self.pressed=-1; [self.owner arrangerOpenInRoll:i]; return; }
    if([self nearRightEdge:p of:i]) { self.stretching=YES; self.stretchRepeats=[self song]->sections[i].repeats; }
    if(i!=self.selected) [self.owner arrangerSelect:i];
}
- (void)mouseDragged:(NSEvent *)event {
    const KvSong *s=[self song]; if(!s || self.pressed<0 || self.pressed>=(NSInteger)s->count) return;
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    if(self.stretching) {
        NSRect r=[self rectOfSection:self.pressed]; double pass=kv_section_pass_beats(s,&s->sections[self.pressed])*[self scale];
        int repeats=(int)lround((p.x-NSMinX(r))/MAX(1,pass)); repeats=MAX(1,MIN(KV_SECTION_REPEATS,repeats));
        if(repeats!=self.stretchRepeats) { self.stretchRepeats=repeats; self.needsDisplay=YES; }
        return;
    }
    if(!self.dragging && fabs(p.x-self.downPoint.x)<4) return;
    self.dragging=YES; self.copying=(event.modifierFlags&NSEventModifierFlagOption)!=0;
    NSInteger drop=(NSInteger)s->count; for(NSInteger i=0;i<(NSInteger)s->count;i++) if(p.x<NSMidX([self rectOfSection:i])) { drop=i; break; }
    self.dropIndex=drop; self.needsDisplay=YES;
}
- (void)mouseUp:(NSEvent *)event {
    (void)event; const KvSong *s=[self song]; NSInteger from=self.pressed; self.pressed=-1;
    if(self.stretching) { self.stretching=NO; if(s && from>=0 && from<(NSInteger)s->count && self.stretchRepeats!=s->sections[from].repeats) [self.owner arrangerSet:KvSectionFieldRepeats value:self.stretchRepeats]; self.needsDisplay=YES; return; }
    if(self.dragging) {
        self.dragging=NO; NSInteger drop=self.dropIndex; self.dropIndex=-1; self.needsDisplay=YES;
        if(!s || from<0 || drop<0) return;
        if(self.copying) { [self.owner arrangerMove:from to:drop copy:YES]; return; }
        NSInteger to=drop>from?drop-1:drop;   // the index it takes once taken out of its place
        if(to!=from) [self.owner arrangerMove:from to:to copy:NO];
    }
}
- (void)chooseVariant:(NSMenuItem *)item { self.hoverSection=self.hoverGhost=-1; [self.owner arrangerAcceptVariant:item.tag after:[item.representedObject integerValue]]; }
- (void)chooseTransition:(NSMenuItem *)item { [self.owner arrangerTransitionAfter:[item.representedObject integerValue] kind:item.tag]; }
- (void)scrollWheel:(NSEvent *)event {
    CGFloat delta=fabs(event.scrollingDeltaX)>fabs(event.scrollingDeltaY)?event.scrollingDeltaX:event.scrollingDeltaY;
    if(!event.hasPreciseScrollingDeltas) delta*=8;
    self.scrollBeat-=delta/[self scale]; [self clampScroll]; self.needsDisplay=YES;
}
// ---- keys ----
- (void)keyDown:(NSEvent *)event {
    if(event.keyCode==49 && self.hoverGhost>=0 && self.hoverSection>=0) {   // Space over a ghost: hear it (again: stop)
        self.auditioning=!self.auditioning; [self.owner arrangerAudition:self.auditioning?self.hoverGhost:-1 after:self.hoverSection]; self.needsDisplay=YES; return;
    }
    const KvSong *s=[self song]; NSInteger count=s?(NSInteger)s->count:0; NSEventModifierFlags flags=event.modifierFlags;
    if(count && self.selected>=0 && (event.keyCode==123 || event.keyCode==124)) {
        NSInteger to=self.selected+(event.keyCode==123?-1:1); if(to<0 || to>=count) return;
        if(flags&NSEventModifierFlagCommand) [self.owner arrangerMove:self.selected to:to copy:NO]; else [self.owner arrangerSelect:to];
        return;
    }
    if(count && self.selected>=0 && !(flags&NSEventModifierFlagCommand)) {
        if(event.keyCode==51 || event.keyCode==117) { [self.owner arrangerRemove:self.selected]; return; }
        if(event.keyCode==36 || event.keyCode==76) { [self.owner arrangerOpenInRoll:self.selected]; return; }
    }
    [self.owner arrangerForwardKey:event];
}
// ---- the bar under the lane ----
- (void)fieldChanged:(NSPopUpButton *)sender {
    NSInteger v=sender.indexOfSelectedItem;
    if(sender==self.kindChoice) [self.owner arrangerSet:KvSectionFieldKind value:v];
    else if(sender==self.repeatsChoice) [self.owner arrangerSet:KvSectionFieldRepeats value:v+1];
    else if(sender==self.levelChoice) [self.owner arrangerSet:KvSectionFieldLevel value:50+10*v];
    else if(sender==self.beatChoice) [self.owner arrangerSet:KvSectionFieldBeat value:v];
    else if(sender==self.liftChoice) [self.owner arrangerSet:KvSectionFieldLift value:v==1?12:v==2?-12:0];
    else if(sender==self.transitionChoice) [self.owner arrangerSet:KvSectionFieldTransition value:v];
}
- (void)openSelected:(id)sender { (void)sender; if(self.selected>=0) [self.owner arrangerOpenInRoll:self.selected]; }
- (void)revert:(id)sender { [self.owner arrangerRevert:sender]; }
- (void)removeSelected:(id)sender { (void)sender; if(self.selected>=0) [self.owner arrangerRemove:self.selected]; }
- (void)take:(id)sender { [self.owner arrangerTakeDraft:sender]; }
@end
