#import "arranger.h"
#import "controls.h"

/* Rows from the top (flipped): a line for the summary, the ruler, the arrangement track, three tracks, the overview. */
static const CGFloat KvRulerTop=30,KvRulerHeight=18,KvMarkerTop=52,KvMarkerHeight=22,KvTracksTop=80,KvTrackGap=6,KvOverviewHeight=14,KvHeaderWidth=118,KvInset=8,KvGhostHeight=34;
static const CGFloat KvLaneX=KvHeaderWidth+12;
static NSString *Translated(const char *text) { return T([NSString stringWithUTF8String:text]); }
/* The colour of a section's kind: verses the accent, choruses orange, breakdowns teal, transitions purple, bridges lilac, intro and outro grey. */
static NSColor *KindColor(KvSectionKind kind) {
    switch(kind) {
        case KV_SECTION_VERSE: return TNAccent();
        case KV_SECTION_CHORUS: return NSColor.systemOrangeColor;
        case KV_SECTION_PIT: return NSColor.systemTealColor;
        case KV_SECTION_TRANSITION: return NSColor.systemPurpleColor;
        case KV_SECTION_BRIDGE: return [NSColor colorWithCalibratedRed:.80 green:.56 blue:.90 alpha:1];
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
static TNButton *Toggle(NSString *title,NSString *tip,id target,SEL action,NSInteger tag) {
    TNButton *button=[TNButton buttonWithTitle:title target:target action:action]; button.bezelStyle=NSBezelStyleRounded; button.bordered=NO;
    [button setButtonType:NSButtonTypePushOnPushOff]; button.font=[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]; button.hint=tip; button.tag=tag; return button;
}
static TNSlider *Level(id target,SEL action,NSInteger tag,double low,double high,NSString *tip) {
    TNSlider *slider=[TNSlider sliderWithValue:100 minValue:low maxValue:high target:target action:action]; slider.continuous=NO; slider.tag=tag;
    slider.controlSize=NSControlSizeSmall; slider.toolTip=tip; [slider setAccessibilityLabel:tip]; return slider;
}
static NSTextField *Caption(NSString *text,CGFloat size,NSFontWeight weight,NSColor *color) {
    NSTextField *label=[NSTextField labelWithString:text]; label.font=[NSFont systemFontOfSize:size weight:weight]; label.textColor=color; label.lineBreakMode=NSLineBreakByTruncatingTail; return label;
}
static void Text(NSString *text,NSRect rect,CGFloat size,NSFontWeight weight,NSColor *color,BOOL mono) {
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.lineBreakMode=NSLineBreakByTruncatingTail;
    NSFont *font=mono?[NSFont monospacedSystemFontOfSize:size weight:weight]:[NSFont systemFontOfSize:size weight:weight];
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:style}];
}

/* The playhead: a thin view that moves each frame, so the tracks under it are not repainted. */
@interface KvPlayheadView : NSView
@end
@implementation KvPlayheadView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { self.layer.backgroundColor=NSColor.systemOrangeColor.CGColor; }
@end
@interface KvPanelView : NSView
@end
@implementation KvPanelView
- (BOOL)isFlipped { return YES; }
@end

@interface KvArranger ()
@property(nonatomic) NSTrackingArea *tracking;
@property(nonatomic) NSInteger pressed;            /* section under the mouse at mouseDown, −1 none */
@property(nonatomic) BOOL stretching,dragging,copying,scrolling;
@property(nonatomic) NSPoint downPoint;
@property(nonatomic) NSInteger dropIndex;          /* insertion point while dragging */
@property(nonatomic) int stretchRepeats;           /* while stretching: the repeats the edge points at */
@property(nonatomic) double cutBeat;               /* scissors (⌘ held over a section): the cut in song beats, −1 none */
@property(nonatomic) NSInteger cutSection;
@property(nonatomic,readwrite) NSInteger hoverSection,hoverGhost,hoverSeam;   /* the section whose ghosts show, the ghost and the seam under the mouse */
@property(nonatomic) NSArray<NSDictionary *> *ghosts; @property(nonatomic) NSInteger ghostsFor;
@property(nonatomic) BOOL auditioning;
@property(nonatomic) KvPlayheadView *playhead;
@property(nonatomic) NSMutableDictionary<NSNumber *,NSData *> *notesCache,*hitsCache;   /* by section id, until the next reload */
@property(nonatomic) NSArray<NSTextField *> *trackNames,*trackKinds;
@property(nonatomic) NSTextField *panelTitle,*panelInfo,*panelEdits,*regionHeading;
@property(nonatomic) NSArray<NSTextField *> *panelLabels,*regionNames,*regionValues;
@property(nonatomic,readwrite) NSView *sectionPanel;
@property(nonatomic,readwrite) NSPopUpButton *kindChoice,*repeatsChoice,*levelChoice,*beatChoice,*liftChoice,*transitionChoice;
@property(nonatomic,readwrite) NSButton *openButton,*revertButton,*removeButton,*takeButton,*exportButton;
@property(nonatomic,readwrite) NSArray<NSButton *> *trackMutes,*trackSolos,*regionMutes;
@property(nonatomic,readwrite) NSArray<NSSlider *> *trackLevels,*regionLevels;
@end

@implementation KvArranger
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        _selected=-1; _pressed=-1; _cutBeat=-1; _cutSection=-1; _dropIndex=-1; _hoverSection=_hoverGhost=_hoverSeam=_ghostsFor=-1;
        _notesCache=[NSMutableDictionary dictionary]; _hitsCache=[NSMutableDictionary dictionary];
        [self setAccessibilityRole:NSAccessibilityGroupRole]; [self setAccessibilityLabel:T(@"Аранжировщик")];
        // Track headers.
        NSArray *names=@[T(@"Мелодия"),T(@"Бас"),T(@"Ударные")],*kinds=@[T(@"правая рука"),T(@"левая рука"),T(@"бит секций")];
        NSMutableArray *labels=[NSMutableArray array],*subs=[NSMutableArray array],*mutes=[NSMutableArray array],*solos=[NSMutableArray array],*levels=[NSMutableArray array];
        for(int t=0;t<KV_TRACKS;t++) {
            NSTextField *name=Caption(names[t],13,NSFontWeightSemibold,NSColor.labelColor),*kind=Caption(kinds[t],10,NSFontWeightRegular,NSColor.secondaryLabelColor);
            TNButton *mute=Toggle(@"M",[NSString stringWithFormat:T(@"Выключить дорожку «%@» во всей песне"),names[t]],self,@selector(trackChanged:),t);
            TNButton *solo=Toggle(@"S",[NSString stringWithFormat:T(@"Только дорожка «%@»"),names[t]],self,@selector(trackChanged:),t);
            TNSlider *level=Level(self,@selector(trackChanged:),t,0,120,[NSString stringWithFormat:T(@"Громкость дорожки «%@»"),names[t]]);
            for(NSView *view in @[name,kind,mute,solo,level]) [self addSubview:view];
            [labels addObject:name]; [subs addObject:kind]; [mutes addObject:mute]; [solos addObject:solo]; [levels addObject:level];
        }
        _trackNames=labels; _trackKinds=subs; _trackMutes=mutes; _trackSolos=solos; _trackLevels=levels;
        _takeButton=[TNButton buttonWithTitle:T(@"Взять текущую последовательность") target:self action:@selector(take:)]; _takeButton.bezelStyle=NSBezelStyleRounded; _takeButton.bordered=NO;
        _takeButton.font=[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]; ((TNButton *)_takeButton).hint=T(@"Последовательность с круга становится первой секцией · ⇧⌘A");
        _exportButton=Icon(@"square.and.arrow.down",@"↓",T(@"Экспорт MIDI песни… · ⇧⌘E · все секции, бит на 10-м канале, маркеры секций"),nil,NSSelectorFromString(@"exportSong:"));
        [self addSubview:_takeButton]; [self addSubview:_exportButton];
        _playhead=[[KvPlayheadView alloc] initWithFrame:NSZeroRect]; _playhead.wantsLayer=YES; _playhead.hidden=YES; [self addSubview:_playhead];
        [self buildPanel];
    }
    return self;
}
/* The «Секция» panel: what the selected section is and how each track plays in it. */
- (void)buildPanel {
    KvPanelView *panel=[[KvPanelView alloc] initWithFrame:NSZeroRect]; self.sectionPanel=panel;
    NSMutableArray *kinds=[NSMutableArray array]; for(int k=0;k<KV_SECTION_KINDS;k++) [kinds addObject:@[Translated(kv_section_kind_name((KvSectionKind)k))]];
    self.kindChoice=Popup(kinds,self,@selector(fieldChanged:),T(@"Тип секции"));
    NSMutableArray *repeats=[NSMutableArray array]; for(int r=1;r<=KV_SECTION_REPEATS;r++) [repeats addObject:@[[NSString stringWithFormat:T(@"Повтор ×%d"),r],[NSString stringWithFormat:@"×%d",r]]];
    self.repeatsChoice=Popup(repeats,self,@selector(fieldChanged:),T(@"Сколько раз прогрессия звучит подряд · или потяните правый край секции"));
    NSMutableArray *levels=[NSMutableArray array]; for(int l=50;l<=120;l+=10) [levels addObject:@[[NSString stringWithFormat:T(@"Громкость %d %%"),l],[NSString stringWithFormat:@"%d %%",l]]];
    self.levelChoice=Popup(levels,self,@selector(fieldChanged:),T(@"Громкость секции: сила удара всех нот"));
    NSMutableArray *beats=[@[@[T(@"Бит как у песни"),T(@"Как у песни")],@[T(@"Без бита"),T(@"Без бита")],@[T(@"Тихий бит: хай-хэт и шейкер"),T(@"Тихий")],@[T(@"Бит по стилю рисунка"),T(@"По стилю")]] mutableCopy];
    for(int b=0;b<KV_BEAT_COUNT;b++) [beats addObject:@[[NSString stringWithFormat:T(@"Бит «%@»"),Translated(kv_beat_name((KvBeat)b))],Translated(kv_beat_name((KvBeat)b))]];
    self.beatChoice=Popup(beats,self,@selector(fieldChanged:),T(@"Бит секции на дорожке «Ударные»"));
    self.liftChoice=Popup(@[@[T(@"Регистр как на круге"),T(@"Как на круге")],@[T(@"Правая рука на октаву выше"),T(@"Правая выше")],@[T(@"Обе руки на октаву ниже"),T(@"Обе ниже")]],self,@selector(fieldChanged:),T(@"Регистр секции"));
    NSMutableArray *ways=[NSMutableArray array]; for(int t=0;t<KV_TRANSITION_KINDS;t++) [ways addObject:@[Translated(kv_transition_name((KvTransitionKind)t))]];
    self.transitionChoice=Popup(ways,self,@selector(fieldChanged:),T(@"Как переход ведёт в следующую секцию"));
    self.openButton=[TNButton buttonWithTitle:T(@"Открыть в ролле") target:self action:@selector(openSelected:)]; self.openButton.bezelStyle=NSBezelStyleRounded; self.openButton.bordered=NO;
    ((TNButton *)self.openButton).hint=T(@"Открыть секцию в пиано-ролле · двойной щелчок · Enter");
    self.revertButton=Icon(@"arrow.counterclockwise",@"↺",T(@"Вернуть рисунок: убрать ручные правки нот секции"),self,@selector(revert:));
    self.removeButton=Icon(@"trash",@"⌫",T(@"Удалить секцию · ⌫"),self,@selector(removeSelected:));
    self.panelTitle=Caption(@"",20,NSFontWeightBold,NSColor.labelColor); self.panelInfo=Caption(@"",11,NSFontWeightRegular,NSColor.secondaryLabelColor);
    self.panelEdits=Caption(@"",11,NSFontWeightMedium,NSColor.secondaryLabelColor); self.regionHeading=Caption(T(@"Регионы секции"),13,NSFontWeightSemibold,NSColor.labelColor);
    NSMutableArray *rowLabels=[NSMutableArray array]; for(NSString *text in @[T(@"Тип"),T(@"Повтор"),T(@"Громкость"),T(@"Регистр")]) [rowLabels addObject:Caption(text,12,NSFontWeightRegular,NSColor.secondaryLabelColor)];
    self.panelLabels=rowLabels;
    NSMutableArray *regionNames=[NSMutableArray array],*regionMutes=[NSMutableArray array],*regionLevels=[NSMutableArray array],*regionValues=[NSMutableArray array];
    NSArray *names=@[T(@"Мелодия"),T(@"Бас"),T(@"Ударные")];
    for(int t=0;t<KV_TRACKS;t++) {
        [regionNames addObject:Caption(names[t],12,NSFontWeightRegular,NSColor.secondaryLabelColor)];
        [regionMutes addObject:Toggle(@"M",[NSString stringWithFormat:T(@"Выключить «%@» в этой секции"),names[t]],self,@selector(regionChanged:),t)];
        if(t<KV_TRACK_DRUMS) { [regionLevels addObject:Level(self,@selector(regionChanged:),t,50,120,[NSString stringWithFormat:T(@"Громкость «%@» в этой секции"),names[t]])]; [regionValues addObject:Caption(@"",11,NSFontWeightMedium,NSColor.labelColor)]; }
    }
    self.regionNames=regionNames; self.regionMutes=regionMutes; self.regionLevels=regionLevels; self.regionValues=regionValues;
    for(NSView *view in @[self.panelTitle,self.panelInfo,self.kindChoice,self.repeatsChoice,self.levelChoice,self.liftChoice,self.transitionChoice,self.regionHeading,self.beatChoice,self.panelEdits,self.openButton,self.revertButton,self.removeButton]) [panel addSubview:view];
    for(NSArray *group in @[rowLabels,regionNames,regionMutes,regionLevels,regionValues]) for(NSView *view in group) [panel addSubview:view];
}
- (void)layoutPanel {
    CGFloat w=NSWidth(self.sectionPanel.bounds),y=0,label=78,x=label,cw=w-label;
    self.panelTitle.frame=NSMakeRect(0,y,w,26); y+=28; self.panelInfo.frame=NSMakeRect(0,y,w,16); y+=24;
    const KvSong *s=[self song]; BOOL transition=s && self.selected>=0 && self.selected<(NSInteger)s->count && s->sections[self.selected].kind==KV_SECTION_TRANSITION;
    NSArray *controls=@[self.kindChoice,self.repeatsChoice,self.levelChoice,transition?self.transitionChoice:self.liftChoice];
    for(NSUInteger i=0;i<controls.count;i++) { self.panelLabels[i].frame=NSMakeRect(0,y+6,label-6,16); ((NSView *)controls[i]).frame=NSMakeRect(x,y,cw,28); y+=32; }
    self.panelLabels[3].stringValue=transition?T(@"Переход"):T(@"Регистр"); self.liftChoice.hidden=transition; self.transitionChoice.hidden=!transition;
    y+=8; self.regionHeading.frame=NSMakeRect(0,y,w,18); y+=24;
    for(int t=0;t<KV_TRACKS;t++) {
        self.regionNames[t].frame=NSMakeRect(0,y+6,label-6,16); self.regionMutes[t].frame=NSMakeRect(x,y,30,28);
        if(t<KV_TRACK_DRUMS) { self.regionLevels[t].frame=NSMakeRect(x+36,y+4,cw-36-48,20); self.regionValues[t].frame=NSMakeRect(w-44,y+6,44,16); }
        else self.beatChoice.frame=NSMakeRect(x+36,y,cw-36,28);
        y+=32;
    }
    y+=4; self.panelEdits.frame=NSMakeRect(0,y,w,16); y+=24;
    self.openButton.frame=NSMakeRect(0,y,w-80,30); self.revertButton.frame=NSMakeRect(w-74,y-1,34,32); self.removeButton.frame=NSMakeRect(w-36,y-1,34,32);
}
- (const KvSong *)song { return [self.owner arrangerSong]; }
- (double)songBeats { const KvSong *s=[self song]; return s?kv_song_beats(s):0; }
- (double)beatsPerBar { const KvSong *s=[self song]; return s?kv_meter_bar(s->meter):4; }
- (CGFloat)laneWidth { return NSWidth(self.bounds)-KvLaneX-KvInset; }
/* Points per beat: the whole song across the tracks, at least sixteen bars' worth, never less than 18 points a bar. */
- (CGFloat)scale {
    double bar=[self beatsPerBar],shown=MAX([self songBeats],16*bar);
    return (CGFloat)MAX(18/bar,[self laneWidth]/shown);
}
- (CGFloat)xOfBeat:(double)beat { return KvLaneX+(CGFloat)((beat-self.scrollBeat)*[self scale]); }
- (double)beatAtX:(CGFloat)x { return self.scrollBeat+(x-KvLaneX)/[self scale]; }
- (CGFloat)overviewTop { return NSHeight(self.bounds)-KvOverviewHeight-4; }
- (CGFloat)trackHeight { return MAX(40,floor(([self overviewTop]-8-KvTracksTop-2*KvTrackGap)/KV_TRACKS)); }
- (NSRect)laneRect:(int)track { CGFloat h=[self trackHeight]; return NSMakeRect(KvLaneX,KvTracksTop+track*(h+KvTrackGap),[self laneWidth],h); }
- (CGFloat)tracksBottom { return NSMaxY([self laneRect:KV_TRACKS-1]); }
- (NSRect)spanOf:(NSInteger)index {   /* x and width of a section */
    const KvSong *s=[self song]; if(!s || index<0 || index>=(NSInteger)s->count) return NSZeroRect;
    double start=kv_section_start(s,(size_t)index),length=kv_section_beats(s,(size_t)index);
    return NSMakeRect([self xOfBeat:start],0,MAX(6,length*[self scale]-2),0);
}
- (NSRect)rectOfSection:(NSInteger)index { NSRect r=[self spanOf:index]; r.origin.y=KvMarkerTop; r.size.height=KvMarkerHeight; return r; }
- (NSRect)rectOfRegion:(NSInteger)index track:(int)track { NSRect r=[self spanOf:index],lane=[self laneRect:track]; r.origin.y=NSMinY(lane)+2; r.size.height=NSHeight(lane)-4; return r; }
- (NSRect)columnOf:(NSInteger)index { NSRect r=[self spanOf:index]; r.origin.y=KvMarkerTop; r.size.height=[self tracksBottom]-KvMarkerTop; return r; }
- (NSInteger)sectionAtPoint:(NSPoint)p {
    const KvSong *s=[self song]; if(!s || p.x<KvLaneX) return -1;
    for(NSInteger i=0;i<(NSInteger)s->count;i++) if(NSPointInRect(p,NSInsetRect([self columnOf:i],-1,0))) return i;
    return -1;
}
- (void)clampScroll {
    double visible=[self laneWidth]/[self scale],max=MAX(0,[self songBeats]-visible+[self beatsPerBar]);
    self.scrollBeat=MAX(0,MIN(max,self.scrollBeat));
}
- (void)layout {
    [super layout]; [self clampScroll];
    for(int t=0;t<KV_TRACKS;t++) {
        NSRect lane=[self laneRect:t]; CGFloat y=NSMinY(lane);
        self.trackNames[t].frame=NSMakeRect(KvInset,y+4,KvHeaderWidth-KvInset,17); self.trackKinds[t].frame=NSMakeRect(KvInset,y+21,KvHeaderWidth-KvInset,14);
        BOOL roomy=NSHeight(lane)>=72; CGFloat row=roomy?y+38:y+4,left=roomy?KvInset:KvHeaderWidth-56;
        self.trackMutes[t].frame=NSMakeRect(left,row,28,24); self.trackSolos[t].frame=NSMakeRect(left+30,row,28,24);
        self.trackLevels[t].frame=NSMakeRect(KvInset,y+NSHeight(lane)-22,KvHeaderWidth-KvInset,18); self.trackLevels[t].hidden=NSHeight(lane)<64;
        if(!roomy) self.trackKinds[t].hidden=YES;
    }
    self.takeButton.frame=NSMakeRect(round(KvLaneX+[self laneWidth]/2-150),round(NSMidY(self.bounds)+4),300,32);
    self.exportButton.frame=NSMakeRect(NSWidth(self.bounds)-KvInset-34,0,34,26);
    [self layoutPanel];
}
- (void)updatePlayhead {
    double beat=[self.owner arrangerPlayheadBeat]; CGFloat x=beat>=0?round([self xOfBeat:beat]):-1;
    BOOL shown=beat>=0 && x>=KvLaneX-1 && x<=NSWidth(self.bounds)-KvInset+1;
    if(self.playhead.hidden!=!shown) self.playhead.hidden=!shown;
    NSRect frame=NSMakeRect(x-1,KvRulerTop,2,[self tracksBottom]-KvRulerTop); if(shown && !NSEqualRects(frame,self.playhead.frame)) self.playhead.frame=frame;
}
- (void)reload {
    self.ghosts=nil; self.ghostsFor=-1; [self.notesCache removeAllObjects]; [self.hitsCache removeAllObjects];
    const KvSong *s=[self song]; BOOL empty=!s || !s->count;
    if(empty || self.hoverSection>=(NSInteger)s->count) { self.hoverSection=self.hoverGhost=self.hoverSeam=-1; }
    if(!empty && (self.selected<0 || self.selected>=(NSInteger)s->count)) self.selected=0;
    BOOL has=!empty && self.selected>=0;
    self.takeButton.hidden=!empty; self.exportButton.hidden=empty;
    for(NSArray *group in @[self.trackNames,self.trackKinds,self.trackMutes,self.trackSolos,self.trackLevels]) for(NSView *view in group) view.hidden=empty;
    for(NSView *view in self.sectionPanel.subviews) view.hidden=!has;
    if(s) for(int t=0;t<KV_TRACKS;t++) {
        self.trackMutes[t].state=s->track_mute[t]?NSControlStateValueOn:NSControlStateValueOff; self.trackSolos[t].state=s->track_solo[t]?NSControlStateValueOn:NSControlStateValueOff;
        self.trackLevels[t].doubleValue=s->track_level[t]*100;
    }
    if(has) {
        const KvSection *x=&s->sections[self.selected];
        [self.kindChoice selectItemAtIndex:x->kind]; [self.repeatsChoice selectItemAtIndex:x->repeats-1];
        [self.levelChoice selectItemAtIndex:MAX(0,MIN(7,(int)lroundf(x->level*10)-5))];
        [self.beatChoice selectItemAtIndex:x->beat==KV_SECTION_BEAT_FIXED?4+x->beat_fixed:MIN(3,(int)x->beat)];
        [self.liftChoice selectItemAtIndex:x->lift>0?1:x->lift<0?2:0]; [self.transitionChoice selectItemAtIndex:x->transition];
        BOOL edited=[self.owner arrangerEdited:self.selected]; self.revertButton.enabled=edited;
        for(int t=0;t<KV_TRACKS;t++) {
            self.regionMutes[t].state=x->regions[t].mute?NSControlStateValueOn:NSControlStateValueOff;
            if(t<KV_TRACK_DRUMS) { self.regionLevels[t].doubleValue=x->regions[t].level*100; self.regionValues[t].stringValue=[NSString stringWithFormat:@"%d %%",(int)lroundf(x->regions[t].level*100)]; }
        }
        double bar=[self beatsPerBar],start=kv_section_start(s,(size_t)self.selected),length=kv_section_beats(s,(size_t)self.selected);
        int first=(int)floor(start/bar+1e-9)+1,last=(int)ceil((start+length)/bar-1e-9);
        NSString *bars=first==last?[NSString stringWithFormat:T(@"такт %d"),first]:[NSString stringWithFormat:T(@"такты %d–%d"),first,last];
        self.panelTitle.stringValue=[self.owner arrangerName:self.selected];
        self.panelInfo.stringValue=[NSString stringWithFormat:@"%@ · %@ · %@",bars,[self.owner arrangerChords:self.selected],[self.owner arrangerDetails:self.selected]];
        self.panelInfo.toolTip=self.panelInfo.stringValue;
        self.panelEdits.stringValue=edited?T(@"Правки нот: есть · ↺ — вернуть рисунок"):T(@"Правки нот: нет · ноты из рисунка");
    }
    self.needsLayout=YES; self.needsDisplay=YES;
}
// ---- notes and hits of a section, for the regions ----
- (NSData *)notesOf:(NSInteger)index {
    uint32_t key=[self song]->sections[index].id; NSData *d=self.notesCache[@(key)];
    if(!d) { d=[self.owner arrangerNotes:index]?:[NSData data]; self.notesCache[@(key)]=d; }
    return d;
}
- (NSData *)hitsOf:(NSInteger)index {
    uint32_t key=[self song]->sections[index].id; NSData *d=self.hitsCache[@(key)];
    if(!d) { d=[self.owner arrangerHits:index]?:[NSData data]; self.hitsCache[@(key)]=d; }
    return d;
}

// ---- ghosts: what may come next, under the hovered marker ----
- (NSArray<NSDictionary *> *)ghostsAfter:(NSInteger)index {
    if(index<0) return @[];
    if(self.ghostsFor!=index || !self.ghosts) { self.ghosts=[self.owner arrangerSuggestions:index]?:@[]; self.ghostsFor=index; }
    return self.ghosts;
}
static const CGFloat KvLeadWidth=24;
- (CGFloat)ghostTop { return KvTracksTop+2; }
- (NSArray<NSValue *> *)ghostRectsAfter:(NSInteger)index {
    NSArray<NSDictionary *> *ghosts=[self ghostsAfter:index]; if(!ghosts.count) return @[];
    NSMutableArray<NSValue *> *rects=[NSMutableArray array]; CGFloat x=MAX(KvLaneX,NSMinX([self rectOfSection:index])),start=x;
    // As long as what they insert, at least 112 points; a row wider than the tracks shrinks to fit them.
    CGFloat leads=0,sum=0,widths[8]; NSUInteger count=MIN(ghosts.count,(NSUInteger)8);
    for(NSUInteger i=0;i<count;i++) { leads+=([ghosts[i][@"leadBeats"] doubleValue]>0?KvLeadWidth+4:0)+6; widths[i]=MAX(112,[ghosts[i][@"beats"] doubleValue]*[self scale]-3); sum+=widths[i]; }
    CGFloat room=[self laneWidth]-leads; if(sum>room && room>0) for(NSUInteger i=0;i<count;i++) widths[i]=MAX(96,widths[i]*room/sum);
    for(NSUInteger i=0;i<count;i++) {
        CGFloat lead=[ghosts[i][@"leadBeats"] doubleValue]>0?KvLeadWidth+4:0;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x+lead,[self ghostTop],widths[i],KvGhostHeight)]]; x+=lead+widths[i]+6;
    }
    CGFloat over=x-6-(NSWidth(self.bounds)-KvInset),shift=MAX(0,MIN(over,start-KvLaneX));   // keep the row inside the tracks
    if(shift>0) for(NSUInteger i=0;i<rects.count;i++) rects[i]=[NSValue valueWithRect:NSOffsetRect(rects[i].rectValue,-shift,0)];
    return rects;
}
- (NSRect)leadRectOf:(NSRect)ghost { return NSMakeRect(NSMinX(ghost)-KvLeadWidth-4,NSMinY(ghost),KvLeadWidth,NSHeight(ghost)); }
/* The seam after section i on the arrangement track: the gap to the next one, when neither side is a transition. */
- (NSInteger)seamAtPoint:(NSPoint)p {
    const KvSong *s=[self song]; if(!s || p.y<KvMarkerTop || p.y>KvMarkerTop+KvMarkerHeight) return -1;
    for(NSInteger i=0;i+1<(NSInteger)s->count;i++) {
        CGFloat edge=NSMinX([self rectOfSection:i+1])-1;
        if(fabs(p.x-edge)<=5 && s->sections[i].kind!=KV_SECTION_TRANSITION && s->sections[i+1].kind!=KV_SECTION_TRANSITION) return i;
    }
    return -1;
}
- (NSInteger)markerAtPoint:(NSPoint)p {
    const KvSong *s=[self song]; if(!s) return -1;
    for(NSInteger i=0;i<(NSInteger)s->count;i++) if(NSPointInRect(p,NSInsetRect([self rectOfSection:i],-1,0))) return i;
    return -1;
}
- (void)hoverAtPoint:(NSPoint)p {
    NSInteger section=self.hoverSection,ghost=-1,seam=[self seamAtPoint:p],under=[self markerAtPoint:p];
    if(seam>=0) section=-1;
    else if(under>=0 && !self.dragging && !self.stretching) section=under;
    else if(section>=0 && p.y>=KvMarkerTop+KvMarkerHeight && p.y<=[self ghostTop]+KvGhostHeight+4) {   // moving down onto the ghosts keeps them
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
    if(seam>=0 && changed) TNHintShow(self,NSMakeRect(NSMinX([self rectOfSection:seam+1])-10,KvMarkerTop,16,KvMarkerHeight),T(@"Вставить переход · ⌥-щелчок — выбрать вид"),NO);
    else if(seam<0 && ghost<0 && changed) TNHintHide(self);
    if(changed) self.needsDisplay=YES;
}
- (void)drawGhosts {
    const KvSong *s=[self song];
    if(self.hoverSeam>=0 && s) {
        CGFloat x=NSMinX([self rectOfSection:self.hoverSeam+1])-10;
        NSBezierPath *pill=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,KvMarkerTop-3,17,KvMarkerHeight+6) xRadius:5 yRadius:5];
        CGFloat dash[]={4,3}; [pill setLineDash:dash count:2 phase:0]; pill.lineWidth=1.5; [[NSColor.systemPurpleColor colorWithAlphaComponent:.12] setFill]; [pill fill]; [NSColor.systemPurpleColor setStroke]; [pill stroke];
        Text(@"+",NSMakeRect(x+3,KvMarkerTop+2,12,18),14,NSFontWeightSemibold,NSColor.systemPurpleColor,NO);
    }
    if(self.hoverSection<0 || self.dragging || self.stretching) return;
    NSArray<NSDictionary *> *ghosts=[self ghostsAfter:self.hoverSection]; NSArray<NSValue *> *rects=[self ghostRectsAfter:self.hoverSection];
    for(NSUInteger i=0;i<ghosts.count && i<rects.count;i++) {
        NSRect r=rects[i].rectValue; NSColor *color=KindColor((KvSectionKind)[ghosts[i][@"kind"] intValue]); BOOL hot=(NSInteger)i==self.hoverGhost;
        CGFloat dash[]={5,4};
        if([ghosts[i][@"leadBeats"] doubleValue]>0) {
            NSRect lr=[self leadRectOf:r]; [TNCanvas() setFill]; NSRectFill(lr);
            NSBezierPath *lead=[NSBezierPath bezierPathWithRoundedRect:lr xRadius:6 yRadius:6]; [lead setLineDash:dash count:2 phase:0]; lead.lineWidth=1.5;
            if(hot) { [[NSColor.systemPurpleColor colorWithAlphaComponent:.15] setFill]; [lead fill]; } [NSColor.systemPurpleColor setStroke]; [lead stroke];
            NSArray *glyphs=@[@"⤴",@"V7",@"∿",@"‖"]; NSInteger way=MIN(3,MAX(0,[ghosts[i][@"leadKind"] integerValue]));
            Text(glyphs[way],NSMakeRect(NSMinX(r)-KvLeadWidth-1,NSMinY(r)+9,KvLeadWidth,16),way==1?9:12,NSFontWeightSemibold,NSColor.systemPurpleColor,NO);
        }
        NSBezierPath *box=[NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8]; [TNCanvas() setFill]; [box fill];
        [box setLineDash:dash count:2 phase:0]; box.lineWidth=1.5;
        if(hot) { [[color colorWithAlphaComponent:.15] setFill]; [box fill]; } [color setStroke]; [box stroke];
        NSString *title=self.auditioning && hot?[@"▶ " stringByAppendingString:ghosts[i][@"title"]]:ghosts[i][@"title"];
        Text(title,NSMakeRect(NSMinX(r)+8,NSMinY(r)+9,NSWidth(r)-14,16),11,NSFontWeightSemibold,color,NO);
    }
}
// ---- drawing ----
/* A region's notes in small: the melody as strokes over the upper part, the bass thicker in the lower third, the beat as dots
   by drum (kick low, snare in the middle, cymbals and shakers high). */
- (void)drawThumbnails:(NSInteger)index track:(int)track inRect:(NSRect)r color:(NSColor *)color {
    if(NSWidth(r)<40) return;
    CGFloat top=NSMinY(r)+16,height=NSHeight(r)-20,scale=[self scale]; if(height<8) return;
    [[color blendedColorWithFraction:.6 ofColor:NSColor.labelColor] setFill];   // light notes on dark, dark on light
    if(track==KV_TRACK_DRUMS) {
        NSData *d=[self hitsOf:index]; const KvHit *h=d.bytes; size_t n=d.length/sizeof(KvHit);
        for(size_t i=0;i<n;i++) {
            int drum=h[i].drum; CGFloat level=drum==KV_DRUM_KICK?.88f:drum<=KV_DRUM_CLAP?.55f:drum>=KV_DRUM_CONGA_HIGH && drum<=KV_DRUM_CONGA_LOW?.7f:.2f;
            CGFloat x=NSMinX(r)+(CGFloat)(h[i].beat*scale),size=2+2*h[i].velocity; if(x>NSMaxX(r)-2) continue;
            NSRectFill(NSMakeRect(x,top+level*height-size/2,size,size));
        }
        return;
    }
    NSData *d=[self notesOf:index]; const KvPianoEvent *e=d.bytes; size_t n=d.length/sizeof(KvPianoEvent); unsigned hand=track==KV_TRACK_MELODY?1:0;
    int low=127,high=0; for(size_t i=0;i<n;i++) if(e[i].hand==hand) { low=MIN(low,e[i].midi); high=MAX(high,e[i].midi); }
    if(low>high) return;
    if(high-low<12) { int mid=(low+high)/2; low=mid-6; high=mid+6; }
    CGFloat band=track==KV_TRACK_MELODY?height*.85f:height*.6f,offset=track==KV_TRACK_MELODY?0:height*.35f,thick=track==KV_TRACK_MELODY?2:3;
    for(size_t i=0;i<n;i++) if(e[i].hand==hand) {
        CGFloat x=NSMinX(r)+(CGFloat)(e[i].beat*scale),w=MAX(2,(CGFloat)(e[i].duration*scale)-1),y=top+offset+band*(1-(CGFloat)(e[i].midi-low)/(high-low));
        if(x>NSMaxX(r)-2) continue; NSRectFill(NSMakeRect(x,y,MIN(w,NSMaxX(r)-x-1),thick));
    }
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; const KvSong *s=[self song]; CGFloat w=NSWidth(self.bounds);
    if(!s || !s->count) {
        Text(T(@"Соберите последовательность на круге и отправьте её сюда · ⇧⌘A"),NSMakeRect(KvLaneX,NSMidY(self.bounds)-28,[self laneWidth],20),14,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
        return;
    }
    double bar=[self beatsPerBar],total=kv_song_beats(s),bpm=s->bpm; int bars=(int)ceil(total/bar-1e-9),seconds=(int)lround(total*60/bpm);
    NSString *header=[NSString stringWithFormat:T(@"Песня · %@ · %@ · %.0f BPM · %@ · %d:%02d"),Translated(kv_key_title(s->key)),Translated(kv_meter_name(s->meter)),bpm,TNBarCount(bars),seconds/60,seconds%60];
    Text(header,NSMakeRect(KvLaneX,4,w-KvLaneX-KvInset-44,18),13,NSFontWeightSemibold,NSColor.labelColor,NO);
    Text(T(@"Аранжировка"),NSMakeRect(KvInset,KvMarkerTop+4,KvHeaderWidth-KvInset,14),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
    // Track lanes and their headers' backgrounds.
    BOOL solo=s->track_solo[0] || s->track_solo[1] || s->track_solo[2];
    for(int t=0;t<KV_TRACKS;t++) {
        NSRect lane=[self laneRect:t]; [[TNSurface() colorWithAlphaComponent:.55] setFill]; NSRectFill(lane);
        NSRect head=NSMakeRect(0,NSMinY(lane),KvHeaderWidth,NSHeight(lane)); NSBezierPath *card=[NSBezierPath bezierPathWithRoundedRect:head xRadius:8 yRadius:8]; [TNSurface() setFill]; [card fill];
    }
    [NSGraphicsContext saveGraphicsState]; NSRectClip(NSMakeRect(KvLaneX-2,KvRulerTop,w-KvLaneX-KvInset+4,NSHeight(self.bounds)-KvRulerTop));
    // Ruler: a number at each section start and every four bars; a tick on every bar.
    [[NSColor.separatorColor colorWithAlphaComponent:.8] setFill]; NSRectFill(NSMakeRect(KvLaneX,KvRulerTop+KvRulerHeight,w-KvLaneX-KvInset,1));
    NSMutableIndexSet *labelled=[NSMutableIndexSet indexSet]; for(size_t i=0;i<s->count;i++) [labelled addIndex:(NSUInteger)floor(kv_section_start(s,i)/bar+1e-9)];
    for(int b=0;b<=bars;b++) { if(b%4==0) [labelled addIndex:(NSUInteger)b]; }
    CGFloat lastLabel=-100;
    for(int b=0;b<=bars;b++) {
        CGFloat x=[self xOfBeat:b*bar]; [NSColor.separatorColor setFill]; NSRectFill(NSMakeRect(x,KvRulerTop+KvRulerHeight-4,1,4));
        [[NSColor.separatorColor colorWithAlphaComponent:.18] setFill]; NSRectFill(NSMakeRect(x,KvTracksTop,1,[self tracksBottom]-KvTracksTop));
        if([labelled containsIndex:(NSUInteger)b] && x-lastLabel>22) { Text([NSString stringWithFormat:@"%d",b+1],NSMakeRect(x+2,KvRulerTop+1,40,14),10,NSFontWeightMedium,NSColor.secondaryLabelColor,NO); lastLabel=x; }
    }
    // Sections: a marker on the arrangement track, a region on each track.
    for(NSInteger i=0;i<(NSInteger)s->count;i++) {
        const KvSection *x=&s->sections[i]; NSRect marker=[self rectOfSection:i]; if(NSMaxX(marker)<KvLaneX || NSMinX(marker)>w) continue;
        NSColor *color=KindColor(x->kind); if(i==self.pressed && self.dragging) color=[color colorWithAlphaComponent:.55];
        NSBezierPath *plate=[NSBezierPath bezierPathWithRoundedRect:marker xRadius:5 yRadius:5]; [color setFill]; [plate fill];
        BOOL edited=[self.owner arrangerEdited:i]; NSString *name=[self.owner arrangerName:i];
        if(NSWidth(marker)<40) name=[name substringToIndex:MIN((NSUInteger)1,name.length)];
        Text(name,NSMakeRect(NSMinX(marker)+6,KvMarkerTop+3,NSWidth(marker)-(edited?20:8),16),11,NSFontWeightSemibold,x->kind==KV_SECTION_BRIDGE?NSColor.blackColor:NSColor.whiteColor,NO);
        if(edited && NSWidth(marker)>=40) Text(@"✎",NSMakeRect(NSMaxX(marker)-15,KvMarkerTop+3,12,16),11,NSFontWeightRegular,NSColor.whiteColor,NO);
        double pass=kv_section_pass_beats(s,x),length=kv_section_beats(s,(size_t)i);
        for(int t=0;t<KV_TRACKS;t++) {
            NSRect r=[self rectOfRegion:i track:t]; BOOL muted=x->regions[t].mute || s->track_mute[t] || (solo && !s->track_solo[t]);
            NSBezierPath *box=[NSBezierPath bezierPathWithRoundedRect:r xRadius:6 yRadius:6];
            if(muted) { CGFloat dash[]={4,3}; [box setLineDash:dash count:2 phase:0]; box.lineWidth=1; [[color colorWithAlphaComponent:.8] setStroke]; [box stroke];
                if(NSWidth(r)>=30) Text(x->regions[t].mute?@"M":@"·",NSMakeRect(NSMinX(r)+6,NSMinY(r)+3,20,14),10,NSFontWeightSemibold,color,NO); continue; }
            [[color colorWithAlphaComponent:.38] setFill]; [box fill]; box.lineWidth=1; [color setStroke]; [box stroke];
            for(double at=pass-fmod(x->start,pass);t==KV_TRACK_MELODY && at<length-1e-9;at+=pass) {   // a notch where the pass begins again
                CGFloat px=NSMinX(r)+(CGFloat)(at*[self scale]); [[NSColor.labelColor colorWithAlphaComponent:.3] setFill]; NSRectFill(NSMakeRect(px,NSMinY(r)+4,1,NSHeight(r)-8)); }
            if(t==KV_TRACK_MELODY && NSWidth(r)>=60) Text([self.owner arrangerChords:i],NSMakeRect(NSMinX(r)+6,NSMinY(r)+2,NSWidth(r)-10,14),10,NSFontWeightMedium,NSColor.labelColor,YES);
            [self drawThumbnails:i track:t inRect:r color:color];
        }
        if(i==self.selected) {
            NSBezierPath *ring=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(marker,-1.5,-1.5) xRadius:6 yRadius:6]; ring.lineWidth=2; [NSColor.labelColor setStroke]; [ring stroke];
            for(int t=0;t<KV_TRACKS;t++) { NSBezierPath *edge=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect([self rectOfRegion:i track:t],-1,-1) xRadius:7 yRadius:7]; edge.lineWidth=1.5; [[NSColor.labelColor colorWithAlphaComponent:.8] setStroke]; [edge stroke]; }
        }
    }
    CGFloat bottom=[self tracksBottom];
    // Stretching: the length the edge points at.
    if(self.stretching && self.pressed>=0 && self.pressed<(NSInteger)s->count) {
        NSRect r=[self columnOf:self.pressed]; double pass=kv_section_pass_beats(s,&s->sections[self.pressed]);
        CGFloat to=NSMinX(r)+(CGFloat)(pass*self.stretchRepeats*[self scale])-2;
        NSBezierPath *ghost=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(r),NSMinY(r),MAX(6,to-NSMinX(r)),NSHeight(r)) xRadius:6 yRadius:6];
        CGFloat dash[]={5,4}; [ghost setLineDash:dash count:2 phase:0]; ghost.lineWidth=1.5; [NSColor.labelColor setStroke]; [ghost stroke];
        Text([NSString stringWithFormat:@"×%d",self.stretchRepeats],NSMakeRect(to-34,KvMarkerTop-16,40,14),11,NSFontWeightSemibold,NSColor.labelColor,NO);
    }
    // Dragging: where the section lands.
    if(self.dragging && self.dropIndex>=0) {
        CGFloat x=self.dropIndex<(NSInteger)s->count?NSMinX([self rectOfSection:self.dropIndex])-2:NSMaxX([self rectOfSection:(NSInteger)s->count-1])+1;
        [TNAccent() setFill]; NSRectFill(NSMakeRect(x-1,KvMarkerTop-4,3,bottom-KvMarkerTop+8));
        if(self.copying) Text(T(@"копия"),NSMakeRect(x+4,KvRulerTop,60,14),10,NSFontWeightSemibold,TNAccent(),NO);
    }
    // Scissors: the cut a ⌘-click makes, through every track.
    if(self.cutBeat>=0) {
        CGFloat x=[self xOfBeat:self.cutBeat]; NSBezierPath *line=[NSBezierPath bezierPath]; [line moveToPoint:NSMakePoint(x,KvMarkerTop-2)]; [line lineToPoint:NSMakePoint(x,bottom+2)];
        CGFloat dash[]={3,3}; [line setLineDash:dash count:2 phase:0]; line.lineWidth=1.5; [NSColor.labelColor setStroke]; [line stroke];
        Text([NSString stringWithFormat:T(@"✂ такт %d"),(int)floor(self.cutBeat/bar+1e-9)+1],NSMakeRect(x+4,KvRulerTop,80,14),11,NSFontWeightSemibold,NSColor.labelColor,NO);
    }
    [self drawGhosts];
    [NSGraphicsContext restoreGraphicsState];
    // Overview: the whole song in small, the visible part framed.
    CGFloat oy=[self overviewTop],ow=[self laneWidth]; [[TNSurface() colorWithAlphaComponent:.6] setFill]; NSRectFill(NSMakeRect(KvLaneX,oy,ow,KvOverviewHeight));
    Text(T(@"Обзор"),NSMakeRect(KvInset,oy,KvHeaderWidth-KvInset,14),10,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
    double whole=MAX(total,[self laneWidth]/[self scale]);
    for(size_t i=0;i<s->count;i++) { CGFloat x0=KvLaneX+(CGFloat)(kv_section_start(s,i)/whole*ow),x1=KvLaneX+(CGFloat)((kv_section_start(s,i)+kv_section_beats(s,i))/whole*ow);
        [KindColor(s->sections[i].kind) setFill]; NSRectFill(NSMakeRect(x0,oy+2,MAX(1,x1-x0-1),KvOverviewHeight-4)); }
    CGFloat vx=KvLaneX+(CGFloat)(self.scrollBeat/whole*ow),vw=(CGFloat)([self laneWidth]/[self scale]/whole*ow);
    NSBezierPath *view=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(vx,oy,MIN(vw,KvLaneX+ow-vx),KvOverviewHeight) xRadius:3 yRadius:3]; view.lineWidth=1.5; [[NSColor.labelColor colorWithAlphaComponent:.7] setStroke]; [view stroke];
}

// ---- mouse ----
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (BOOL)nearRightEdge:(NSPoint)p of:(NSInteger)index { NSRect r=[self columnOf:index]; return index>=0 && fabs(p.x-NSMaxX(r))<=6 && p.y>=NSMinY(r) && p.y<=NSMaxY(r); }
/* With ⌘ held over a section: the allowed cut nearest the mouse. */
- (void)updateScissorsAt:(NSPoint)p flags:(NSEventModifierFlags)flags {
    double before=self.cutBeat; self.cutBeat=-1; self.cutSection=-1;
    const KvSong *s=[self song]; NSInteger i=[self sectionAtPoint:p];
    if(s && i>=0 && (flags&NSEventModifierFlagCommand)) {
        double start=kv_section_start(s,(size_t)i),cut=kv_song_snap_cut(s,(size_t)i,[self beatAtX:p.x]-start,kv_meter_bar(s->meter));
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
- (void)scrollOverviewTo:(CGFloat)x {
    double whole=MAX([self songBeats],[self laneWidth]/[self scale]),visible=[self laneWidth]/[self scale];
    self.scrollBeat=(x-KvLaneX)/[self laneWidth]*whole-visible/2; [self clampScroll]; self.needsDisplay=YES; [self updatePlayhead];
}
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; self.downPoint=p; self.dragging=self.stretching=self.scrolling=NO;
    if(p.y>=[self overviewTop] && p.x>=KvLaneX) { self.scrolling=YES; [self scrollOverviewTo:p.x]; return; }
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
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    if(self.scrolling) { [self scrollOverviewTo:p.x]; return; }
    const KvSong *s=[self song]; if(!s || self.pressed<0 || self.pressed>=(NSInteger)s->count) return;
    if(self.stretching) {
        NSRect r=[self columnOf:self.pressed]; double pass=kv_section_pass_beats(s,&s->sections[self.pressed])*[self scale];
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
    if(self.scrolling) { self.scrolling=NO; return; }
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
    self.scrollBeat-=delta/[self scale]; [self clampScroll]; self.needsDisplay=YES; [self updatePlayhead];
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
// ---- the panel and the track headers ----
- (void)fieldChanged:(NSPopUpButton *)sender {
    NSInteger v=sender.indexOfSelectedItem;
    if(sender==self.kindChoice) [self.owner arrangerSet:KvSectionFieldKind value:v];
    else if(sender==self.repeatsChoice) [self.owner arrangerSet:KvSectionFieldRepeats value:v+1];
    else if(sender==self.levelChoice) [self.owner arrangerSet:KvSectionFieldLevel value:50+10*v];
    else if(sender==self.beatChoice) [self.owner arrangerSet:KvSectionFieldBeat value:v];
    else if(sender==self.liftChoice) [self.owner arrangerSet:KvSectionFieldLift value:v==1?12:v==2?-12:0];
    else if(sender==self.transitionChoice) [self.owner arrangerSet:KvSectionFieldTransition value:v];
}
- (void)trackChanged:(NSControl *)sender {
    int t=(int)sender.tag;
    if(sender==self.trackMutes[t]) [self.owner arrangerSetTrack:t mute:((NSButton *)sender).state==NSControlStateValueOn solo:-1 level:-1];
    else if(sender==self.trackSolos[t]) [self.owner arrangerSetTrack:t mute:-1 solo:((NSButton *)sender).state==NSControlStateValueOn level:-1];
    else [self.owner arrangerSetTrack:t mute:-1 solo:-1 level:sender.doubleValue/100];
}
- (void)regionChanged:(NSControl *)sender {
    int t=(int)sender.tag;
    if(sender==self.regionMutes[t]) [self.owner arrangerSetRegion:t mute:((NSButton *)sender).state==NSControlStateValueOn level:-1];
    else [self.owner arrangerSetRegion:t mute:-1 level:sender.doubleValue/100];
}
- (void)openSelected:(id)sender { (void)sender; if(self.selected>=0) [self.owner arrangerOpenInRoll:self.selected]; }
- (void)revert:(id)sender { [self.owner arrangerRevert:sender]; }
- (void)removeSelected:(id)sender { (void)sender; if(self.selected>=0) [self.owner arrangerRemove:self.selected]; }
- (void)take:(id)sender { [self.owner arrangerTakeDraft:sender]; }
@end
