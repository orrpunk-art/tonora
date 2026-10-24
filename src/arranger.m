#import "arranger.h"
#import "controls.h"

/* Rows from the top (flipped): a line for the summary, the ruler, the arrangement track, three tracks, the overview. */
static const CGFloat KvRulerTop=30,KvRulerHeight=27,KvCycleHeight=10,KvMarkerTop=61,KvMarkerHeight=22,KvTracksTop=89,KvTrackGap=6,KvOverviewHeight=14,KvHeaderWidth=118,KvInset=8,KvGhostHeight=34,KvTransitionWidth=28,KvTempoHeight=36,KvCurveHeight=40;
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
/* A track's switch as in Logic: a small pill with its symbol, lit in its colour when on (mute blue, solo yellow, automation green). */
@interface KvTrackToggle : TNButton
@property(nonatomic) NSColor *lit;
@property(nonatomic,copy) NSString *symbol,*letter;
@property(nonatomic) BOOL marked;   /* a dot: there is something behind it (a curve with its lane closed) */
@end
@implementation KvTrackToggle
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; BOOL on=self.state==NSControlStateValueOn; NSRect r=NSInsetRect(self.bounds,1,1);
    NSColor *fill=on?self.lit:[NSColor.labelColor colorWithAlphaComponent:[[self valueForKey:@"hovered"] boolValue]?.16:.08];
    NSBezierPath *pill=[NSBezierPath bezierPathWithRoundedRect:r xRadius:5 yRadius:5]; [fill setFill]; [pill fill];
    if(!on) { [[NSColor.labelColor colorWithAlphaComponent:.18] setStroke]; pill.lineWidth=1; [pill stroke]; }
    NSColor *ink=on?(self.lit==NSColor.systemYellowColor?NSColor.blackColor:NSColor.whiteColor):NSColor.secondaryLabelColor;
    NSImage *image=self.symbol?TNIcon(self.symbol,11):nil;
    if(image) image=[image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:ink]];
    if(image) { NSSize size=image.size; [image drawInRect:NSMakeRect(round(NSMidX(r)-size.width/2),round(NSMidY(r)-size.height/2),size.width,size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        if(self.marked) { [self.lit setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMaxX(r)-6,NSMinY(r)+1,5,5)] fill]; } return; }
    if(self.marked) { [self.lit setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMaxX(r)-6,NSMinY(r)+1,5,5)] fill]; }
    NSDictionary *a=@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightBold],NSForegroundColorAttributeName:ink}; NSSize size=[self.letter sizeWithAttributes:a];
    [self.letter drawAtPoint:NSMakePoint(round(NSMidX(r)-size.width/2),round(NSMidY(r)-size.height/2)) withAttributes:a];
}
@end
static TNButton *Toggle(NSString *title,NSString *tip,id target,SEL action,NSInteger tag) {
    KvTrackToggle *button=[KvTrackToggle buttonWithTitle:@"" target:target action:action]; button.bezelStyle=NSBezelStyleRounded; button.bordered=NO;
    [button setButtonType:NSButtonTypePushOnPushOff]; button.hint=tip; button.tag=tag; button.letter=title;
    if([title isEqualToString:@"M"]) { button.symbol=@"speaker.slash.fill"; button.lit=NSColor.systemBlueColor; }
    else if([title isEqualToString:@"S"]) { button.symbol=@"headphones"; button.lit=NSColor.systemYellowColor; }
    else if([title isEqualToString:@"A"]) { button.symbol=@"point.topleft.down.curvedto.point.bottomright.up"; button.lit=NSColor.systemGreenColor; }
    else { button.symbol=@"waveform.path"; button.lit=NSColor.systemOrangeColor; }
    return button;
}
static TNSlider *Level(id target,SEL action,NSInteger tag,double low,double high,NSString *tip) {
    TNSlider *slider=[TNSlider sliderWithValue:100 minValue:low maxValue:high target:target action:action]; slider.continuous=NO; slider.tag=tag;
    slider.controlSize=NSControlSizeSmall; slider.toolTip=tip; [slider setAccessibilityLabel:tip]; return slider;
}
static NSTextField *Caption(NSString *text,CGFloat size,NSFontWeight weight,NSColor *color) {
    NSTextField *label=[NSTextField labelWithString:text]; label.font=[NSFont systemFontOfSize:size weight:weight]; label.textColor=color; label.lineBreakMode=NSLineBreakByTruncatingTail; return label;
}
/* NSRectFill copies the colour's alpha into the view (a hole); this blends it over what is drawn. */
static void Fill(NSRect rect) { NSRectFillUsingOperation(rect,NSCompositingOperationSourceOver); }
static void Text(NSString *text,NSRect rect,CGFloat size,NSFontWeight weight,NSColor *color,BOOL mono) {
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.lineBreakMode=NSLineBreakByTruncatingTail;
    NSFont *font=mono?[NSFont monospacedSystemFontOfSize:size weight:weight]:[NSFont systemFontOfSize:size weight:weight];
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:style}];
}

/* A tool's cursor: its symbol in black with a white rim, so it reads on both themes; the crosshair when the system lacks it. */
static NSCursor *ToolCursor(NSString *symbol,BOOL tipAtBottomLeft) {
    NSImage *glyph=TNIcon(symbol,15); if(!glyph) return NSCursor.crosshairCursor;
    NSImage *(^tinted)(NSColor *)=^NSImage *(NSColor *color) {
        return [NSImage imageWithSize:glyph.size flipped:NO drawingHandler:^BOOL(NSRect r) { [glyph drawInRect:r]; [color set]; NSRectFillUsingOperation(r,NSCompositingOperationSourceAtop); return YES; }]; };
    NSImage *white=tinted(NSColor.whiteColor),*black=tinted(NSColor.blackColor); NSSize size=NSMakeSize(glyph.size.width+4,glyph.size.height+4);
    NSImage *image=[NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect r) { (void)r;
        for(int dx=-1;dx<=1;dx++) for(int dy=-1;dy<=1;dy++) [white drawInRect:NSMakeRect(2+dx,2+dy,glyph.size.width,glyph.size.height)];
        [black drawInRect:NSMakeRect(2,2,glyph.size.width,glyph.size.height)]; return YES; }];
    return [[NSCursor alloc] initWithImage:image hotSpot:tipAtBottomLeft?NSMakePoint(2,size.height-2):NSMakePoint(size.width/2,size.height/2)];
}
static NSCursor *ScissorsCursor(void) { static NSCursor *cursor; if(!cursor) cursor=ToolCursor(@"scissors",NO); return cursor; }
static NSCursor *PencilCursor(void) { static NSCursor *cursor; if(!cursor) cursor=ToolCursor(@"pencil",YES); return cursor; }

/* The playhead: a thin view that moves each frame, so the tracks under it are not repainted. */
@interface KvPlayheadView : NSView
@end
@implementation KvPlayheadView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { self.layer.backgroundColor=NSColor.systemOrangeColor.CGColor; }   // at rest the view is half transparent
@end
@interface KvPanelView : NSView
@end
@implementation KvPanelView
- (BOOL)isFlipped { return YES; }
@end

@interface KvArranger ()
@property(nonatomic) NSTrackingArea *tracking;
@property(nonatomic) NSInteger pressed;            /* section under the mouse at mouseDown, −1 none */
@property(nonatomic) BOOL dragging,copying,scrolling,onRuler,cycling,collapse,shiftedRuler,oneCut;
@property(nonatomic) NSInteger rulerClicks;
@property(nonatomic) int corner;                   /* the corner being dragged: 1 loop (repeats), 2 length, 3 start; 0 none */
@property(nonatomic) double cornerValue;           /* what it points at: repeats, beats of length, beats trimmed from the start */
@property(nonatomic) NSInteger swapTarget,anchor;  /* the section a drag would swap with; where a ⇧-click range starts */
@property(nonatomic) BOOL movingCycle;             /* the cycle grabbed by its middle: it moves whole */
@property(nonatomic) NSCursor *cursor;             /* what the pointer shows here; a cursor rect keeps it when the playhead's frame changes every frame */
@property(nonatomic) double cycleGrab,cycleSpan;   /* beats from its start to the grab, its length */
@property(nonatomic,readwrite) NSInteger hoverRegion,hoverButton;
@property(nonatomic,readwrite) int hoverTrack;
@property(nonatomic) double rulerBeat,cycleFrom,cycleTo;   /* the ruler: where the press snapped, the cycle being drawn */
@property(nonatomic) NSPoint downPoint;
@property(nonatomic) NSInteger dropIndex;          /* insertion point while dragging */
@property(nonatomic) double cutBeat;               /* scissors (⌘ held over a section): the cut in song beats, −1 none */
@property(nonatomic) NSInteger cutSection;
@property(nonatomic,readwrite) NSInteger hoverSection,hoverGhost,hoverSeam;   /* the section whose ghosts show, the ghost and the seam under the mouse */
@property(nonatomic) NSArray<NSDictionary *> *ghosts; @property(nonatomic) NSInteger ghostsFor;
@property(nonatomic) BOOL auditioning;
@property(nonatomic) KvPlayheadView *playhead;
@property(nonatomic) NSMutableDictionary<NSNumber *,NSData *> *notesCache,*hitsCache;   /* by section id, until the next reload */
@property(nonatomic) NSArray<NSTextField *> *trackNames,*trackKinds;
@property(nonatomic) NSTextField *panelTitle,*panelInfo,*panelEdits,*regionHeading,*emptyPanel;
@property(nonatomic,readwrite) NSButton *generateButton;
@property(nonatomic) NSArray<NSTextField *> *panelLabels,*regionNames,*regionValues;
@property(nonatomic,readwrite) NSView *sectionPanel;
@property(nonatomic,readwrite) NSSegmentedControl *toolChoice;
@property(nonatomic,readwrite) NSPopUpButton *snapChoice;
@property(nonatomic,readwrite) NSButton *zoomOutButton,*zoomInButton,*wholeSongButton;
@property(nonatomic,readwrite) NSPopUpButton *structureChoice;
@property(nonatomic) NSTextField *snapLabel;
@property(nonatomic,readwrite) NSButton *tempoButton;
@property(nonatomic,readwrite) NSArray<NSButton *> *volumeButtons;
@property(nonatomic) NSUInteger volumeLanes;       /* a bit per track whose volume lane shows */
@property(nonatomic) BOOL curvesSeen;              /* lanes opened once for the curves a song came with */
@property(nonatomic) int editCurve;                /* the curve being edited: −2 none, −1 tempo, 0…2 volume */
@property(nonatomic,readwrite) NSInteger selectedPoint;
@property(nonatomic) BOOL draggingPoint,onCurve;
@property(nonatomic,readwrite) NSPopUpButton *kindChoice,*repeatsChoice,*levelChoice,*beatChoice,*liftChoice,*transitionChoice;
@property(nonatomic,readwrite) NSButton *openButton,*revertButton,*removeButton,*takeButton,*exportButton;
@property(nonatomic,readwrite) NSArray<NSButton *> *trackMutes,*trackSolos,*regionMutes;
@property(nonatomic,readwrite) NSArray<NSSlider *> *trackLevels,*regionLevels;
@end

@implementation KvArranger { KvCurve _draft; }   /* _draft: the curve as a drag leaves it, shown until the owner takes it */
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        _selected=-1; _pressed=-1; _cutBeat=-1; _cutSection=-1; _dropIndex=-1; _hoverSection=_hoverGhost=_hoverSeam=_ghostsFor=-1; _swapTarget=_anchor=_hoverRegion=_hoverButton=-1; _hoverTrack=-1; _selectedTrack=-1;
        _notesCache=[NSMutableDictionary dictionary]; _hitsCache=[NSMutableDictionary dictionary]; _editCurve=-2; _selectedPoint=-1;
        [self setAccessibilityRole:NSAccessibilityGroupRole]; [self setAccessibilityLabel:T(@"Аранжировщик")];
        // Track headers.
        NSArray *names=@[T(@"Мелодия"),T(@"Бас"),T(@"Ударные")],*kinds=@[T(@"правая рука"),T(@"левая рука"),T(@"бит секций")];
        NSMutableArray *labels=[NSMutableArray array],*subs=[NSMutableArray array],*mutes=[NSMutableArray array],*solos=[NSMutableArray array],*levels=[NSMutableArray array],*curves=[NSMutableArray array];
        for(int t=0;t<KV_TRACKS;t++) {
            NSTextField *name=Caption(names[t],13,NSFontWeightSemibold,NSColor.labelColor),*kind=Caption(kinds[t],10,NSFontWeightRegular,NSColor.secondaryLabelColor);
            TNButton *mute=Toggle(@"M",[NSString stringWithFormat:T(@"Выключить дорожку «%@» во всей песне"),names[t]],self,@selector(trackChanged:),t);
            TNButton *solo=Toggle(@"S",[NSString stringWithFormat:T(@"Только дорожка «%@»"),names[t]],self,@selector(trackChanged:),t);
            TNSlider *level=Level(self,@selector(trackChanged:),t,0,120,[NSString stringWithFormat:T(@"Громкость дорожки «%@»"),names[t]]);
            TNButton *curve=Toggle(@"A",[NSString stringWithFormat:T(@"Кривая громкости «%@» · двойной щелчок — точка, ⌫ — удалить"),names[t]],self,@selector(volumeLaneToggled:),t);
            for(NSView *view in @[name,kind,mute,solo,level,curve]) [self addSubview:view]; [curves addObject:curve];
            [labels addObject:name]; [subs addObject:kind]; [mutes addObject:mute]; [solos addObject:solo]; [levels addObject:level];
        }
        _trackNames=labels; _trackKinds=subs; _trackMutes=mutes; _trackSolos=solos; _trackLevels=levels; _volumeButtons=curves;
        _tempoButton=Toggle(@"⌁",T(@"Дорожка темпа: кривая темпа песни · двойной щелчок — точка"),self,@selector(tempoLaneToggled:),0); [self addSubview:_tempoButton];
        _takeButton=[TNButton buttonWithTitle:T(@"Только аккорды круга") target:self action:@selector(take:)]; _takeButton.bezelStyle=NSBezelStyleRounded; _takeButton.bordered=NO;
        _takeButton.font=[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]; ((TNButton *)_takeButton).hint=T(@"Последовательность с круга становится первой секцией · ⇧⌘A");
        _generateButton=[TNButton buttonWithTitle:T(@"✦ Сгенерировать песню") target:self action:@selector(generate:)]; _generateButton.bezelStyle=NSBezelStyleRounded; _generateButton.bordered=NO;
        _generateButton.bezelColor=TNAccent(); _generateButton.font=[NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        ((TNButton *)_generateButton).hint=T(@"Целая песня из аккордов круга (нет аккордов — создаст): интро, куплеты, припевы, бридж, переходы · мелодия, бас и ударные"); [self addSubview:_generateButton];
        _emptyPanel=Caption(T(@"В песне пока нет секций. Сгенерируйте песню на дорожке слева или отправьте туда аккорды круга · ⇧⌘A."),12,NSFontWeightRegular,NSColor.secondaryLabelColor);
        _exportButton=Icon(@"square.and.arrow.down",@"↓",T(@"Экспорт MIDI ▾ · вся песня (⇧⌘E) или одна дорожка: мелодия, бас, ударные"),self,@selector(exportMenu:));
        [self addSubview:_takeButton]; [self addSubview:_exportButton];
        _playhead=[[KvPlayheadView alloc] initWithFrame:NSZeroRect]; _playhead.wantsLayer=YES; _playhead.hidden=YES; [self addSubview:_playhead];
        // Toolbar: tools, snap, zoom.
        _zoom=1;
        TNSegmented *tools=[TNSegmented segmentedControlWithLabels:@[@"",@"",@""] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(toolChanged:)];
        NSArray *icons=@[@[@"cursorarrow",@"▸"],@[@"scissors",@"✂"],@[@"pencil",@"✎"]];
        for(NSInteger i=0;i<3;i++) { NSImage *image=TNIcon(icons[i][0],14); if(image) [tools setImage:image forSegment:i]; else [tools setLabel:icons[i][1] forSegment:i]; }
        tools.hints=@[T(@"Указатель · T: выбрать, переставить, растянуть"),T(@"Ножницы · I: щелчок режет секцию · или держите ⌘"),T(@"Карандаш · P: щелчок ставит последовательность с круга новой секцией")];
        tools.selectedSegment=0; [tools setAccessibilityLabel:T(@"Инструмент")]; _toolChoice=tools;
        _snapLabel=Caption(T(@"Привязка"),12,NSFontWeightRegular,NSColor.secondaryLabelColor);
        _snapChoice=Popup(@[@[T(@"Привязка умная: по масштабу"),T(@"Умная")],@[T(@"Привязка к такту"),T(@"Такт")],@[T(@"Привязка к доле"),T(@"Доля")],@[T(@"Привязка к восьмой"),@"1/8"],@[T(@"Без привязки"),T(@"Без")]],self,@selector(snapChanged:),T(@"Привязка ножниц, углов, линейки и цикла · ⌃ во время жеста — без привязки"));
        { NSImage *magnet=TNIcon(@"magnet",12); if(magnet) { for(NSMenuItem *item in _snapChoice.itemArray) item.image=magnet; _snapLabel.hidden=YES; } }   // the icon says «snap»; the word only without it
        _structureChoice=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:YES]; _structureChoice.autoenablesItems=NO; _structureChoice.target=self; _structureChoice.action=@selector(structureChosen:);
        _structureChoice.toolTip=T(@"Собрать песню по форме вокруг выбранного куплета · правленные вручную секции остаются"); [_structureChoice setAccessibilityLabel:T(@"Структура")];
        _zoomOutButton=Icon(@"minus.magnifyingglass",@"−",T(@"Мельче · ⌘− · ⌘+колесо или щипок"),self,@selector(zoomOut:));
        _zoomInButton=Icon(@"plus.magnifyingglass",@"+",T(@"Крупнее · ⌘+ · ⌘+колесо или щипок"),self,@selector(zoomIn:));
        _wholeSongButton=Icon(@"arrow.left.and.right.square",T(@"Вся песня"),T(@"Вся песня в окне · Z"),self,@selector(showWholeSong:));   // the text only without the icon
        for(NSView *view in @[_toolChoice,_snapLabel,_snapChoice,_zoomOutButton,_zoomInButton,_wholeSongButton,_structureChoice]) [self addSubview:view];
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
    NSMutableArray *beats=[@[@[T(@"Ударные как у песни · по стилю секции или бит песни"),T(@"Как у песни")],@[T(@"Без бита"),T(@"Без бита")],@[T(@"Тихий бит: хай-хэт и шейкер"),T(@"Тихий")],@[T(@"Бит по стилю рисунка"),T(@"По стилю")]] mutableCopy];
    for(int b=0;b<KV_BEAT_COUNT;b++) [beats addObject:@[[NSString stringWithFormat:T(@"Бит «%@»"),Translated(kv_beat_name((KvBeat)b))],Translated(kv_beat_name((KvBeat)b))]];
    self.beatChoice=Popup(beats,self,@selector(fieldChanged:),T(@"Ударные секции · звучат, когда ударные включены (⇧⌘K)"));
    self.liftChoice=Popup(@[@[T(@"Регистр как на круге"),T(@"Как на круге")],@[T(@"Правая рука на октаву выше"),T(@"Правая выше")],@[T(@"Обе руки на октаву ниже"),T(@"Обе ниже")]],self,@selector(fieldChanged:),T(@"Регистр секции"));
    NSMutableArray *ways=[NSMutableArray array]; for(int t=0;t<KV_TRANSITION_KINDS;t++) [ways addObject:@[Translated(kv_transition_name((KvTransitionKind)t))]];
    self.transitionChoice=Popup(ways,self,@selector(fieldChanged:),T(@"Как переход ведёт в следующую секцию"));
    self.openButton=[TNButton buttonWithTitle:T(@"Открыть в ролле") target:self action:@selector(openSelected:)]; self.openButton.bezelStyle=NSBezelStyleRounded; self.openButton.bordered=NO;
    ((TNButton *)self.openButton).hint=T(@"Открыть секцию в пиано-ролле · двойной щелчок · Enter");
    self.revertButton=Icon(@"arrow.counterclockwise",@"↺",T(@"Вернуть рисунок: убрать ручные правки нот секции"),self,@selector(revert:));
    self.removeButton=Icon(@"trash",@"⌫",T(@"Удалить секцию · ⌫"),self,@selector(removeSelected:));
    self.emptyPanel.lineBreakMode=NSLineBreakByWordWrapping; self.emptyPanel.maximumNumberOfLines=6; [panel addSubview:self.emptyPanel];
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
    self.panelLabels[3].stringValue=transition?T(@"Переход"):T(@"Регистр");
    BOOL has=s && s->count && self.selected>=0; self.liftChoice.hidden=!has || transition; self.transitionChoice.hidden=!has || !transition;
    self.emptyPanel.frame=NSMakeRect(0,4,w,80); self.emptyPanel.hidden=has;
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
/* Points per beat. At zoom 1 the whole song fits (at least sixteen bars' worth, never under 18 points a bar); zoom brings it
   closer, up to 160 points a beat. */
- (CGFloat)fitScale {
    const KvSong *s=[self song]; double bar=[self beatsPerBar],shown=MAX([self songBeats],16*bar); CGFloat lane=[self laneWidth],k=lane/shown;
    for(int pass=0;pass<2 && s;pass++) {   // short transitions take more than their beats (see widthOf:), the rest shares what is left
        CGFloat extra=0; for(size_t i=0;i<s->count;i++) if(s->sections[i].kind==KV_SECTION_TRANSITION) extra+=MAX(0,KvTransitionWidth-kv_section_beats(s,i)*k);
        k=MAX(1,lane-extra)/shown;
    }
    return (CGFloat)MAX(18/bar,k);
}
- (double)maxZoom { return MAX(1,160/[self fitScale]); }
- (CGFloat)scale { return [self fitScale]*(CGFloat)MAX(1,MIN([self maxZoom],self.zoom)); }
/* A section's width: its beats at the scale; a transition never narrower than 28 points, so a one-bar one stays readable. */
- (CGFloat)widthOf:(size_t)i scale:(CGFloat)k {
    const KvSong *s=[self song]; CGFloat w=(CGFloat)(kv_section_beats(s,i)*k);
    return s->sections[i].kind==KV_SECTION_TRANSITION?MAX(KvTransitionWidth,w):w;
}
/* Song beats to points from the song's start and back: linear inside each section, past the end at the scale. */
- (CGFloat)rawX:(double)beat {
    const KvSong *s=[self song]; CGFloat k=[self scale],x=0; double at=0;
    for(size_t i=0;s && i<s->count;i++) { double length=kv_section_beats(s,i); CGFloat w=[self widthOf:i scale:k];
        if(beat<at+length) return x+(CGFloat)((beat-at)/length)*w;
        x+=w; at+=length; }
    return x+(CGFloat)(beat-at)*k;
}
- (double)rawBeat:(CGFloat)x {
    const KvSong *s=[self song]; CGFloat k=[self scale],left=0; double at=0;
    for(size_t i=0;s && i<s->count;i++) { double length=kv_section_beats(s,i); CGFloat w=[self widthOf:i scale:k];
        if(x<left+w) return at+(x-left)/w*length;
        left+=w; at+=length; }
    return at+(x-left)/k;
}
- (CGFloat)xOfBeat:(double)beat { return KvLaneX+[self rawX:beat]-[self rawX:self.scrollBeat]; }
- (double)beatAtX:(CGFloat)x { return [self rawBeat:x-KvLaneX+[self rawX:self.scrollBeat]]; }
- (double)lastVisibleBeat { return [self beatAtX:KvLaneX+[self laneWidth]]; }
- (double)snapGrid:(NSEventModifierFlags)flags {
    if(flags&NSEventModifierFlagControl) return 0;
    double bar=[self beatsPerBar]; CGFloat k=[self scale];
    switch(self.snap) {
        case KvSnapBar: return bar; case KvSnapBeat: return 1; case KvSnapEighth: return .5; case KvSnapOff: return 0;
        default: return k>=40?.5:k>=14?1:bar;
    }
}
- (double)snapped:(double)beat flags:(NSEventModifierFlags)flags { double grid=[self snapGrid:flags]; return grid>0?round(beat/grid)*grid:beat; }
- (CGFloat)overviewTop { return NSHeight(self.bounds)-KvOverviewHeight-4; }
- (CGFloat)markerTop { return KvMarkerTop+(self.showTempo?KvTempoHeight+4:0); }
- (CGFloat)tracksTop { return KvTracksTop+(self.showTempo?KvTempoHeight+4:0); }
- (BOOL)showsVolume:(int)track { return track>=0 && track<KV_TRACKS && (self.volumeLanes&(1u<<track)); }
- (void)setShowsVolume:(BOOL)shown track:(int)track {
    if(track<0 || track>=KV_TRACKS) return; self.volumeLanes=shown?self.volumeLanes|(1u<<track):self.volumeLanes&~(1u<<track);
    self.volumeButtons[track].state=shown?NSControlStateValueOn:NSControlStateValueOff; const KvSong *s=[self song]; ((KvTrackToggle *)self.volumeButtons[track]).marked=s && s->volume[track].count && !shown; self.needsLayout=YES; self.needsDisplay=YES;
}
- (void)setShowTempo:(BOOL)showTempo { _showTempo=showTempo; self.tempoButton.state=showTempo?NSControlStateValueOn:NSControlStateValueOff; const KvSong *s=[self song]; ((KvTrackToggle *)self.tempoButton).marked=s && s->tempo.count && !showTempo; self.needsLayout=YES; self.needsDisplay=YES; }
- (CGFloat)curvesHeight { CGFloat h=0; for(int t=0;t<KV_TRACKS;t++) if([self showsVolume:t]) h+=KvCurveHeight+4; return h; }
- (CGFloat)trackHeight { return MAX(40,floor(([self overviewTop]-8-[self tracksTop]-2*KvTrackGap-[self curvesHeight])/KV_TRACKS)); }
- (NSRect)laneRect:(int)track {
    CGFloat h=[self trackHeight],y=[self tracksTop];
    for(int t=0;t<track;t++) y+=h+KvTrackGap+([self showsVolume:t]?KvCurveHeight+4:0);
    return NSMakeRect(KvLaneX,y,[self laneWidth],h);
}
- (NSRect)curveRect:(int)curve {
    if(curve<0) return self.showTempo?NSMakeRect(KvLaneX,KvMarkerTop,[self laneWidth],KvTempoHeight):NSZeroRect;
    if(![self showsVolume:curve]) return NSZeroRect;
    NSRect lane=[self laneRect:curve]; return NSMakeRect(KvLaneX,NSMaxY(lane)+3,[self laneWidth],KvCurveHeight);
}
/* A curve's range on screen: the tempo 40…240 BPM, a volume 0…120 %. */
- (double)curveLow:(int)curve { return curve<0?40:0; }
- (double)curveHigh:(int)curve { return curve<0?240:1.2; }
- (NSPoint)pointOfCurve:(int)curve value:(double)value beat:(double)beat {
    NSRect r=[self curveRect:curve]; double low=[self curveLow:curve],high=[self curveHigh:curve],f=MAX(0,MIN(1,(value-low)/(high-low)));
    return NSMakePoint([self xOfBeat:beat],NSMaxY(r)-4-(CGFloat)f*(NSHeight(r)-8));
}
- (double)valueOfCurve:(int)curve atY:(CGFloat)y {
    NSRect r=[self curveRect:curve]; double low=[self curveLow:curve],high=[self curveHigh:curve],f=(NSMaxY(r)-4-y)/(NSHeight(r)-8),v=low+MAX(0,MIN(1,f))*(high-low);
    return curve<0?round(v):round(v*100)/100;   // whole BPM, whole percent
}
- (const KvCurve *)curve:(int)curve { const KvSong *s=[self song]; if(!s) return NULL; if(curve==self.editCurve && self.draggingPoint) return &_draft; return curve<0?&s->tempo:&s->volume[curve]; }
- (int)curveAtPoint:(NSPoint)p { for(int c=-1;c<KV_TRACKS;c++) if(NSPointInRect(p,NSInsetRect([self curveRect:c],0,-2))) return c; return -2; }
- (CGFloat)tracksBottom { return NSMaxY([self laneRect:KV_TRACKS-1]); }
- (NSRect)spanOf:(NSInteger)index {   /* x and width of a section */
    const KvSong *s=[self song]; if(!s || index<0 || index>=(NSInteger)s->count) return NSZeroRect;
    double start=kv_section_start(s,(size_t)index); CGFloat x=[self xOfBeat:start];
    return NSMakeRect(x,0,MAX(6,[self xOfBeat:start+kv_section_beats(s,(size_t)index)]-x-2),0);
}
- (NSRect)rectOfSection:(NSInteger)index { NSRect r=[self spanOf:index]; r.origin.y=[self markerTop]; r.size.height=KvMarkerHeight; return r; }
- (NSRect)rectOfRegion:(NSInteger)index track:(int)track { NSRect r=[self spanOf:index],lane=[self laneRect:track]; r.origin.y=NSMinY(lane)+2; r.size.height=NSHeight(lane)-4; return r; }
- (NSRect)columnOf:(NSInteger)index { NSRect r=[self spanOf:index]; r.origin.y=[self markerTop]; r.size.height=[self tracksBottom]-[self markerTop]; return r; }
- (NSInteger)sectionAtPoint:(NSPoint)p {
    const KvSong *s=[self song]; if(!s || p.x<KvLaneX) return -1;
    for(NSInteger i=0;i<(NSInteger)s->count;i++) if(NSPointInRect(p,NSInsetRect([self columnOf:i],-1,0))) return i;
    return -1;
}
- (void)clampScroll {
    self.zoom=MAX(1,MIN([self maxZoom],self.zoom));
    CGFloat end=[self rawX:[self songBeats]]+(CGFloat)([self beatsPerBar]*[self scale]);   // a bar of room after the song
    double max=end>[self laneWidth]?[self rawBeat:end-[self laneWidth]]:0;
    self.scrollBeat=MAX(0,MIN(max,self.scrollBeat));
}
/* Zoom keeping the beat under x where it is. */
- (void)zoomBy:(double)factor aroundX:(CGFloat)x {
    x=MAX(KvLaneX,MIN(KvLaneX+[self laneWidth],x)); double beat=[self beatAtX:x];
    self.zoom=MAX(1,MIN([self maxZoom],self.zoom*factor));
    self.scrollBeat=[self rawBeat:[self rawX:beat]-(x-KvLaneX)]; [self clampScroll];
    self.needsDisplay=YES; [self updatePlayhead];
}
- (void)showWholeSong:(id)sender { (void)sender; self.zoom=1; self.scrollBeat=0; [self clampScroll]; self.needsDisplay=YES; [self updatePlayhead]; }
- (void)zoomOut:(id)sender { (void)sender; [self zoomBy:1/1.5 aroundX:KvLaneX+[self laneWidth]/2]; }
- (void)zoomIn:(id)sender { (void)sender; [self zoomBy:1.5 aroundX:KvLaneX+[self laneWidth]/2]; }
- (void)setTool:(KvArrangerTool)tool { _tool=tool; self.toolChoice.selectedSegment=tool; [self updateScissorsAt:[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil] flags:NSEvent.modifierFlags]; }
- (void)toolChanged:(NSSegmentedControl *)sender { self.tool=(KvArrangerTool)MAX(0,sender.selectedSegment); }
- (void)setSnap:(KvArrangerSnap)snap { _snap=snap; [self.snapChoice selectItemAtIndex:snap]; }
- (void)snapChanged:(NSPopUpButton *)sender { self.snap=(KvArrangerSnap)MAX(0,sender.indexOfSelectedItem); }
- (void)layout {
    [super layout]; [self clampScroll];
    for(int t=0;t<KV_TRACKS;t++) {
        NSRect lane=[self laneRect:t]; CGFloat y=NSMinY(lane);
        self.trackNames[t].frame=NSMakeRect(KvInset,y+4,KvHeaderWidth-KvInset,17); self.trackKinds[t].frame=NSMakeRect(KvInset,y+21,KvHeaderWidth-KvInset,14);
        BOOL roomy=NSHeight(lane)>=72; CGFloat row=roomy?y+38:y+22,left=KvInset,high=roomy?24:18;   // short lanes: the buttons right under the name
        self.trackMutes[t].frame=NSMakeRect(left,row,28,high); self.trackSolos[t].frame=NSMakeRect(left+30,row,28,high); self.volumeButtons[t].frame=NSMakeRect(left+60,row,28,high);
        self.trackLevels[t].frame=NSMakeRect(KvInset,y+NSHeight(lane)-22,KvHeaderWidth-KvInset,18); self.trackLevels[t].hidden=NSHeight(lane)<64 || self.trackMutes[t].hidden;
        self.trackKinds[t].hidden=!roomy || self.trackNames[t].hidden;
    }
    { NSRect melody=[self laneRect:KV_TRACK_MELODY]; CGFloat mid=NSMidX(melody);   // the empty song: generate it right on the melody track
      self.generateButton.frame=NSMakeRect(round(mid-130),round(NSMidY(melody)-6),260,36); self.takeButton.frame=NSMakeRect(round(mid-110),round(NSMidY(melody)+36),220,30); }
    self.exportButton.frame=NSMakeRect(NSWidth(self.bounds)-KvInset-34,0,34,26);
    // Toolbar: tools over the headers; snap and zoom over the tracks; the song's summary after them (drawn).
    self.toolChoice.frame=NSMakeRect(0,0,88,26); self.tempoButton.frame=NSMakeRect(92,1,26,24);
    CGFloat x=KvLaneX,label=self.snapLabel.hidden?0:ceil([self.snapLabel.stringValue sizeWithAttributes:@{NSFontAttributeName:self.snapLabel.font}].width)+4;
    if(label) { self.snapLabel.frame=NSMakeRect(x,5,label,16); x+=label+2; }
    CGFloat snap=self.snapChoice.itemArray.firstObject.image?106:92; self.snapChoice.frame=NSMakeRect(x,0,snap,26); x+=snap+8;
    self.zoomOutButton.frame=NSMakeRect(x,0,28,26); self.zoomInButton.frame=NSMakeRect(x+30,0,28,26); x+=62;
    CGFloat whole=self.wholeSongButton.image?28:ceil([self.wholeSongButton.title sizeWithAttributes:@{NSFontAttributeName:self.wholeSongButton.font?:[NSFont systemFontOfSize:13]}].width)+24;
    self.wholeSongButton.frame=NSMakeRect(x,0,whole,26); x+=whole+8;
    CGFloat structure=ceil([T(@"Структура") sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13 weight:NSFontWeightMedium]}].width)+52;
    self.structureChoice.frame=NSMakeRect(x,0,structure,26);
    [self layoutPanel];
}
- (void)updatePlayhead {
    double beat=[self.owner arrangerPlayheadBeat]; BOOL playing=beat>=0; const KvSong *s=[self song];
    if(!playing && s && s->count) beat=MIN(self.cursorBeat,kv_song_beats(s));   // at rest: where the next play starts
    CGFloat x=beat>=0?round([self xOfBeat:beat]):-1; CGFloat alpha=playing?1:.55; if(self.playhead.alphaValue!=alpha) self.playhead.alphaValue=alpha;
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
    if(!has) _selection=NSMakeRange(0,0);
    else if(!NSLocationInRange((NSUInteger)self.selected,_selection) || NSMaxRange(_selection)>s->count) { _selection=NSMakeRange((NSUInteger)self.selected,1); _anchor=self.selected; }
    self.takeButton.hidden=!empty; self.exportButton.hidden=empty;
    for(NSArray *group in @[self.trackNames,self.trackKinds,self.trackMutes,self.trackSolos,self.trackLevels,@[self.toolChoice,self.snapChoice,self.zoomOutButton,self.zoomInButton,self.wholeSongButton,self.structureChoice,self.tempoButton],self.volumeButtons]) for(NSView *view in group) view.hidden=empty;
    for(NSArray *group in @[self.trackNames,self.trackKinds]) for(NSView *view in group) view.hidden=NO;   // an empty song still shows its three tracks
    if(!empty) {   // lanes open only on request; a closed lane with a curve shows a dot on its button
        ((KvTrackToggle *)self.tempoButton).marked=s->tempo.count && !self.showTempo; self.tempoButton.needsDisplay=YES;
        for(int t=0;t<KV_TRACKS;t++) { ((KvTrackToggle *)self.volumeButtons[t]).marked=s->volume[t].count && ![self showsVolume:t]; self.volumeButtons[t].needsDisplay=YES; }
    }
    if(self.editCurve>=-1 && !self.draggingPoint) { const KvCurve *c=[self curve:self.editCurve]; if(!c || self.selectedPoint>=(NSInteger)c->count) self.selectedPoint=-1; }
    self.snapLabel.hidden=empty || self.snapChoice.itemArray.firstObject.image!=nil;
    [self rebuildStructureMenu];
    for(NSView *view in self.sectionPanel.subviews) view.hidden=!has;
    self.emptyPanel.hidden=has; self.generateButton.hidden=!empty;
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
- (CGFloat)ghostTop { return [self tracksTop]+2; }
- (NSArray<NSValue *> *)ghostRectsAfter:(NSInteger)index {
    NSArray<NSDictionary *> *ghosts=[self ghostsAfter:index]; if(!ghosts.count) return @[];
    const KvSong *song=[self song]; NSMutableArray<NSValue *> *rects=[NSMutableArray array];
    CGFloat x=song && index==(NSInteger)song->count-1?NSMinX([self endSlotRect]):MAX(KvLaneX,NSMinX([self rectOfSection:index])),start=x;
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
    const KvSong *s=[self song]; if(!s || p.y<[self markerTop] || p.y>[self markerTop]+KvMarkerHeight) return -1;
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
    const KvSong *song=[self song]; NSInteger section=self.hoverSection,ghost=-1,seam=-1,under=song && song->count && NSPointInRect(p,[self endSlotRect])?(NSInteger)song->count-1:-1;
    if(under>=0 && !self.dragging && !self.corner) section=under;   // the «+» after the song: what may come next
    else if(section>=0 && p.y>=[self markerTop]+KvMarkerHeight && p.y<=[self ghostTop]+KvGhostHeight+4) {   // moving down onto the ghosts keeps them
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
    if(seam>=0 && changed) TNHintShow(self,NSMakeRect(NSMinX([self rectOfSection:seam+1])-10,[self markerTop],16,KvMarkerHeight),T(@"Вставить переход · ⌥-щелчок — выбрать вид"),NO);
    else if(seam<0 && ghost<0 && changed) TNHintHide(self);
    // The region under the pointer shows its buttons (not while the ghosts are up or a gesture runs).
    NSInteger region=-1,button=-1; int track=-1; const KvSong *s=[self song];
    if(s && section<0 && seam<0 && self.tool==KvToolPointer && !self.dragging && !self.corner)
        for(NSInteger i=0;i<(NSInteger)s->count && region<0;i++) for(int t=0;t<KV_TRACKS;t++) if(NSPointInRect(p,[self rectOfRegion:i track:t])) { region=i; track=t; break; }
    if(region>=0) { NSArray<NSValue *> *rects=[self buttonRectsOf:region track:track]; for(NSUInteger k=0;k<rects.count;k++) if(NSPointInRect(p,rects[k].rectValue)) button=(NSInteger)k; }
    if(region!=self.hoverRegion || track!=self.hoverTrack || button!=self.hoverButton) {
        if(button!=self.hoverButton) {
            NSArray *tips=@[T(@"Открыть в ролле · двойной щелчок"),T(@"Разрезать: по плейхеду, если он в секции, иначе посередине · или ⌘-щелчок где нужно"),T(@"Дублировать · ⌘D"),T(@"Удалить · ⌫")];
            if(button>=0) TNHintShow(self,[[self buttonRectsOf:region track:track][button] rectValue],track==KV_TRACK_DRUMS && button==0?T(@"Бит секции"):tips[button],NO); else if(ghost<0 && seam<0) TNHintHide(self);
        }
        self.hoverRegion=region; self.hoverTrack=track; self.hoverButton=button; changed=YES;
    }
    if(changed) self.needsDisplay=YES;
}
/* ✎ ✂ ⧉ ✕ in the region's top right corner, inside the tracks. */
- (NSArray<NSValue *> *)buttonRectsOf:(NSInteger)index track:(int)track {
    const KvSong *s=[self song]; if(!s || index<0 || index>=(NSInteger)s->count || track<0 || track>=KV_TRACKS) return @[];
    NSRect r=NSIntersectionRect([self rectOfRegion:index track:track],[self laneRect:track]); if(NSWidth(r)<100 || NSHeight(r)<30) return @[];
    NSMutableArray *rects=[NSMutableArray array]; CGFloat size=20,x=NSMaxX(r)-6-4*size;
    for(int k=0;k<4;k++) [rects addObject:[NSValue valueWithRect:NSMakeRect(x+k*size,NSMinY(r)+3,size,18)]];
    return rects;
}
- (void)drawButtonsOf:(NSInteger)index track:(int)track {
    NSArray<NSValue *> *rects=[self buttonRectsOf:index track:track]; if(!rects.count) return;
    NSRect all=NSUnionRect(rects.firstObject.rectValue,rects.lastObject.rectValue);
    NSBezierPath *pill=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(all,-3,-1) xRadius:6 yRadius:6]; [[TNCanvas() colorWithAlphaComponent:.88] setFill]; [pill fill];
    NSArray *symbols=@[track==KV_TRACK_DRUMS?@"metronome":@"pencil",@"scissors",@"plus.square.on.square",@"xmark"],*glyphs=@[track==KV_TRACK_DRUMS?@"♩":@"✎",@"✂",@"⧉",@"✕"];
    for(NSUInteger k=0;k<rects.count;k++) {
        NSRect r=rects[k].rectValue; NSColor *color=(NSInteger)k==self.hoverButton?TNAccent():NSColor.labelColor; NSImage *image=TNIcon(symbols[k],11);
        if(image) image=[image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
        if(image) { NSSize size=image.size; [image drawInRect:NSMakeRect(round(NSMidX(r)-size.width/2),round(NSMidY(r)-size.height/2),size.width,size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil]; }
        else Text(glyphs[k],NSMakeRect(NSMinX(r)+4,NSMinY(r)+1,16,16),12,NSFontWeightMedium,color,NO);
    }
}
/* «+» right after the song's last marker: hovering it shows what may come next. */
- (NSRect)endSlotRect {
    const KvSong *s=[self song]; if(!s || !s->count) return NSZeroRect;
    return NSMakeRect([self xOfBeat:kv_song_beats(s)]+2,[self markerTop],30,KvMarkerHeight);
}
- (void)drawGhosts {
    const KvSong *s=[self song];
    if(s && s->count) {
        NSRect slot=[self endSlotRect]; BOOL hot=self.hoverSection>=0; NSBezierPath *pill=[NSBezierPath bezierPathWithRoundedRect:slot xRadius:5 yRadius:5];
        CGFloat dash[]={4,3}; [pill setLineDash:dash count:2 phase:0]; pill.lineWidth=1.5; [[TNAccent() colorWithAlphaComponent:hot?.22:.08] setFill]; [pill fill]; [TNAccent() setStroke]; [pill stroke];
        Text(@"+",NSMakeRect(NSMinX(slot)+9,NSMinY(slot)+1,14,18),15,NSFontWeightSemibold,TNAccent(),NO);
    }
    if(self.hoverSection<0 || self.dragging || self.corner) return;
    NSArray<NSDictionary *> *ghosts=[self ghostsAfter:self.hoverSection]; NSArray<NSValue *> *rects=[self ghostRectsAfter:self.hoverSection];
    for(NSUInteger i=0;i<ghosts.count && i<rects.count;i++) {
        NSRect r=rects[i].rectValue; NSColor *color=KindColor((KvSectionKind)[ghosts[i][@"kind"] intValue]); BOOL hot=(NSInteger)i==self.hoverGhost;
        CGFloat dash[]={5,4};
        if([ghosts[i][@"leadBeats"] doubleValue]>0) {
            NSRect lr=[self leadRectOf:r]; [TNCanvas() setFill]; Fill(lr);
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
    CGFloat top=NSMinY(r)+16,height=NSHeight(r)-20,scale=(NSWidth(r)+2)/(CGFloat)MAX(1e-6,kv_section_beats([self song],(size_t)index)); if(height<8) return;
    [[color blendedColorWithFraction:.6 ofColor:NSColor.labelColor] setFill];   // light notes on dark, dark on light
    if(track==KV_TRACK_DRUMS) {
        NSData *d=[self hitsOf:index]; const KvHit *h=d.bytes; size_t n=d.length/sizeof(KvHit);
        for(size_t i=0;i<n;i++) {
            int drum=h[i].drum; CGFloat level=drum==KV_DRUM_KICK?.88f:drum<=KV_DRUM_CLAP?.55f:drum>=KV_DRUM_CONGA_HIGH && drum<=KV_DRUM_CONGA_LOW?.7f:.2f;
            CGFloat x=NSMinX(r)+(CGFloat)(h[i].beat*scale),size=2+2*h[i].velocity; if(x>NSMaxX(r)-2) continue;
            Fill(NSMakeRect(x,top+level*height-size/2,size,size));
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
        if(x>NSMaxX(r)-2) continue; Fill(NSMakeRect(x,y,MIN(w,NSMaxX(r)-x-1),thick));
    }
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; const KvSong *s=[self song]; CGFloat w=NSWidth(self.bounds);
    if(!s || !s->count) {   // empty tracks waiting, the way into a song on the melody track
        Text(T(@"Аранжировка"),NSMakeRect(KvInset,[self markerTop]+4,KvHeaderWidth-KvInset,14),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
        Fill(NSMakeRect(KvLaneX,KvRulerTop+KvRulerHeight,[self laneWidth],1));
        for(int t=0;t<KV_TRACKS;t++) {
            NSRect lane=[self laneRect:t]; [[NSColor.labelColor colorWithAlphaComponent:.04] setFill]; Fill(lane);
            NSBezierPath *border=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(lane,.5,.5) xRadius:6 yRadius:6]; CGFloat dash[]={4,4}; [border setLineDash:dash count:2 phase:0]; [[NSColor.labelColor colorWithAlphaComponent:.15] setStroke]; [border stroke];
            NSRect head=NSMakeRect(0,NSMinY(lane),KvHeaderWidth,NSHeight(lane)); NSBezierPath *card=[NSBezierPath bezierPathWithRoundedRect:head xRadius:8 yRadius:8]; [TNSurface() setFill]; [card fill];
        }
        NSRect melody=[self laneRect:KV_TRACK_MELODY];
        Text(T(@"Песня целиком из аккордов круга: интро, куплеты, припевы, бридж и переходы — мелодия, бас и ударные"),NSMakeRect(NSMinX(melody)+16,NSMidY(melody)-34,NSWidth(melody)-32,18),12,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
        NSRect bass=[self laneRect:KV_TRACK_BASS],drums=[self laneRect:KV_TRACK_DRUMS];
        Text(T(@"левая рука появится здесь"),NSMakeRect(NSMinX(bass)+16,NSMidY(bass)-8,300,16),11,NSFontWeightRegular,NSColor.tertiaryLabelColor,NO);
        Text(T(@"бит секций появится здесь"),NSMakeRect(NSMinX(drums)+16,NSMidY(drums)-8,300,16),11,NSFontWeightRegular,NSColor.tertiaryLabelColor,NO);
        return;
    }
    double bar=[self beatsPerBar],total=kv_song_beats(s),bpm=s->bpm,k=[self scale]; int bars=(int)ceil(total/bar-1e-9),seconds=(int)lround(total*60/bpm);
    NSString *header=[NSString stringWithFormat:@"%@ · %d:%02d · %.0f BPM · %@ · %@",TNBarCount(bars),seconds/60,seconds%60,bpm,Translated(kv_meter_name(s->meter)),Translated(kv_key_title(s->key))];   // the key gives way first
    CGFloat headerX=NSMaxX(self.structureChoice.frame)+12; Text(header,NSMakeRect(headerX,6,NSMinX(self.exportButton.frame)-headerX-6,18),11,NSFontWeightSemibold,NSColor.labelColor,NO);
    Text(T(@"Аранжировка"),NSMakeRect(KvInset,[self markerTop]+4,KvHeaderWidth-KvInset,14),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
    // Track lanes and their headers' backgrounds.
    BOOL solo=s->track_solo[0] || s->track_solo[1] || s->track_solo[2];
    for(int t=0;t<KV_TRACKS;t++) {
        NSRect lane=[self laneRect:t]; [[TNSurface() colorWithAlphaComponent:.55] setFill]; Fill(lane);
        NSRect head=NSMakeRect(0,NSMinY(lane),KvHeaderWidth,NSHeight(lane)); NSBezierPath *card=[NSBezierPath bezierPathWithRoundedRect:head xRadius:8 yRadius:8]; [TNSurface() setFill]; [card fill];
    }
    [NSGraphicsContext saveGraphicsState]; NSRectClip(NSMakeRect(KvLaneX-2,KvRulerTop,w-KvLaneX-KvInset+4,NSHeight(self.bounds)-KvRulerTop));
    // The cycle: an orange band on the ruler (grey while ↻ is off), or the one being drawn.
    double cycleFrom=self.cycling?self.cycleFrom:s->cycle_from,cycleTo=self.cycling?self.cycleTo:s->cycle_to;
    // The cycle strip over the bar numbers (as Logic's upper ruler): drag there to draw the cycle, click it to switch ↻.
    [[NSColor.labelColor colorWithAlphaComponent:.05] setFill]; Fill(NSMakeRect(KvLaneX,KvRulerTop,w-KvLaneX-KvInset,KvCycleHeight));
    if(cycleTo>cycleFrom+1e-9) {
        NSRect band=NSMakeRect([self xOfBeat:cycleFrom],KvRulerTop,[self xOfBeat:cycleTo]-[self xOfBeat:cycleFrom],KvCycleHeight);
        NSColor *tint=[self.owner arrangerCycles] || self.cycling?NSColor.systemOrangeColor:NSColor.systemGrayColor;
        [[tint colorWithAlphaComponent:.8] setFill]; [[NSBezierPath bezierPathWithRoundedRect:band xRadius:3 yRadius:3] fill];
        [[tint colorWithAlphaComponent:.10] setFill]; Fill(NSMakeRect(NSMinX(band),KvRulerTop+KvCycleHeight,NSWidth(band),KvRulerHeight-KvCycleHeight));
    } else Text(T(@"↻ цикл: протяните здесь"),NSMakeRect([self xOfBeat:self.scrollBeat]+4,KvRulerTop-1,200,11),8,NSFontWeightMedium,NSColor.tertiaryLabelColor,NO);
    if(self.selection.length && NSMaxRange(self.selection)<=s->count) {   // the selected sections' span on the ruler, with its bar count, as a DAW marks a selected region
        double from=kv_section_start(s,self.selection.location),to=kv_section_start(s,NSMaxRange(self.selection)-1)+kv_section_beats(s,NSMaxRange(self.selection)-1);
        CGFloat x0=[self xOfBeat:from],x1=[self xOfBeat:to]; NSRect band=NSMakeRect(x0,KvRulerTop+KvCycleHeight,x1-x0-1,KvRulerHeight-KvCycleHeight);
        [[TNAccent() colorWithAlphaComponent:.16] setFill]; Fill(band); [TNAccent() setFill]; Fill(NSMakeRect(x0,NSMaxY(band)-2,x1-x0-1,2));
    }
    // Ruler: bars, then beats and eighths as the zoom allows; a number at each section start and every 1, 2, 4… bars as they fit.
    [[NSColor.separatorColor colorWithAlphaComponent:.8] setFill]; Fill(NSMakeRect(KvLaneX,KvRulerTop+KvRulerHeight,w-KvLaneX-KvInset,1));
    int every=1; while(every*bar*k<30 && every<64) every*=2;
    NSMutableIndexSet *labelled=[NSMutableIndexSet indexSet]; for(size_t i=0;i<s->count;i++) [labelled addIndex:(NSUInteger)floor(kv_section_start(s,i)/bar+1e-9)];
    int firstBar=MAX(0,(int)floor(self.scrollBeat/bar)),lastBar=(int)ceil([self lastVisibleBeat]/bar)+1; double minor=k*.5>=10?.5:k>=10?1:0;
    CGFloat lastLabel=-100;
    for(int b=firstBar;b<=lastBar;b++) {
        CGFloat x=[self xOfBeat:b*bar]; [NSColor.separatorColor setFill]; Fill(NSMakeRect(x,KvRulerTop+KvRulerHeight-5,1,5));
        [[NSColor.separatorColor colorWithAlphaComponent:.18] setFill]; Fill(NSMakeRect(x,[self tracksTop],1,[self tracksBottom]-[self tracksTop]));
        for(double m=minor;minor>0 && m<bar-1e-9;m+=minor) {
            CGFloat mx=[self xOfBeat:b*bar+m]; BOOL beat=fabs(m-round(m))<1e-9;
            [[NSColor.separatorColor colorWithAlphaComponent:beat?.8:.5] setFill]; Fill(NSMakeRect(mx,KvRulerTop+KvRulerHeight-(beat?3:2),1,beat?3:2));
            if(beat && k>=14) { [[NSColor.separatorColor colorWithAlphaComponent:.08] setFill]; Fill(NSMakeRect(mx,[self tracksTop],1,[self tracksBottom]-[self tracksTop])); }
        }
        if(([labelled containsIndex:(NSUInteger)b] || b%every==0) && x-lastLabel>22) { Text([NSString stringWithFormat:@"%d",b+1],NSMakeRect(x+2,KvRulerTop+KvCycleHeight+1,40,14),10,NSFontWeightMedium,NSColor.secondaryLabelColor,NO); lastLabel=x; }
    }
    if(self.selection.length && NSMaxRange(self.selection)<=s->count) {   // the selection's bar count, over the numbers at its right end
        double from=kv_section_start(s,self.selection.location),to=kv_section_start(s,NSMaxRange(self.selection)-1)+kv_section_beats(s,NSMaxRange(self.selection)-1);
        CGFloat x0=[self xOfBeat:from],x1=[self xOfBeat:to]; NSString *count=TNBarCount(round((to-from)/bar*100)/100);
        CGFloat width=ceil([count sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]}].width)+8;
        if(x1-x0>width+50) { [TNCanvas() setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x1-width-3,KvRulerTop+KvCycleHeight+1,width,14) xRadius:4 yRadius:4] fill];
            Text(count,NSMakeRect(x1-width+1,KvRulerTop+KvCycleHeight+1,width,14),10,NSFontWeightSemibold,TNAccent(),NO); }
    }
    // Sections: a marker on the arrangement track, a region on each track.
    for(NSInteger i=0;i<(NSInteger)s->count;i++) {
        const KvSection *x=&s->sections[i]; NSRect marker=[self rectOfSection:i]; if(NSMaxX(marker)<KvLaneX || NSMinX(marker)>w) continue;
        NSColor *color=KindColor(x->kind); if(i==self.pressed && self.dragging) color=[color colorWithAlphaComponent:.55];
        NSBezierPath *plate=[NSBezierPath bezierPathWithRoundedRect:marker xRadius:5 yRadius:5]; [color setFill]; [plate fill];
        BOOL edited=[self.owner arrangerEdited:i]; NSString *name=[self.owner arrangerName:i];
        CGFloat left=MAX(NSMinX(marker),KvLaneX),shown=NSMaxX(marker)-left;   // a marker scrolled half out keeps its name in view
        if(shown<40) name=[name substringToIndex:MIN((NSUInteger)1,name.length)];
        Text(name,NSMakeRect(left+6,[self markerTop]+3,shown-(edited?20:8),16),11,NSFontWeightSemibold,x->kind==KV_SECTION_BRIDGE?NSColor.blackColor:NSColor.whiteColor,NO);
        if(edited && NSWidth(marker)>=40) Text(@"✎",NSMakeRect(NSMaxX(marker)-15,[self markerTop]+3,12,16),11,NSFontWeightRegular,NSColor.whiteColor,NO);
        double pass=kv_section_pass_beats(s,x),length=kv_section_beats(s,(size_t)i);
        for(int t=0;t<KV_TRACKS;t++) {
            NSRect r=[self rectOfRegion:i track:t]; BOOL muted=x->regions[t].mute || s->track_mute[t] || (solo && !s->track_solo[t]);
            NSBezierPath *box=[NSBezierPath bezierPathWithRoundedRect:r xRadius:6 yRadius:6];
            if(muted) { CGFloat dash[]={4,3}; [box setLineDash:dash count:2 phase:0]; box.lineWidth=1; [[color colorWithAlphaComponent:.8] setStroke]; [box stroke];
                if(NSWidth(r)>=30) Text(x->regions[t].mute?@"M":@"·",NSMakeRect(NSMinX(r)+6,NSMinY(r)+3,20,14),10,NSFontWeightSemibold,color,NO); continue; }
            [[color colorWithAlphaComponent:.38] setFill]; [box fill]; box.lineWidth=1; [color setStroke]; [box stroke];
            for(double at=pass-fmod(x->start,pass);t==KV_TRACK_MELODY && at<length-1e-9;at+=pass) {   // a notch where the pass begins again
                CGFloat px=NSMinX(r)+(CGFloat)(at*[self scale]); [[NSColor.labelColor colorWithAlphaComponent:.3] setFill]; Fill(NSMakeRect(px,NSMinY(r)+4,1,NSHeight(r)-8)); }
            if(t==KV_TRACK_MELODY && NSWidth(r)>=60) Text([self.owner arrangerChords:i],NSMakeRect(NSMinX(r)+6,NSMinY(r)+2,NSWidth(r)-10,14),10,NSFontWeightMedium,NSColor.labelColor,YES);
            [self drawThumbnails:i track:t inRect:r color:color];
            double shift=x->regions[t].shift;
            if(t==KV_TRACK_DRUMS && i==0 && [self.owner arrangerDrumsHint]) { NSRect lane=[self laneRect:KV_TRACK_DRUMS];   // where the drums come from
                Text([self.owner arrangerDrumsHint],NSMakeRect(KvLaneX+12,NSMidY(lane)-8,NSWidth(lane)-24,16),11,NSFontWeightMedium,NSColor.secondaryLabelColor,NO); }
            if(fabs(shift)>1e-9 && NSWidth(r)>=60) Text([NSString stringWithFormat:@"↦ %@",[self shiftText:shift]],NSMakeRect(NSMinX(r)+6,NSMaxY(r)-16,NSWidth(r)-10,14),10,NSFontWeightSemibold,NSColor.labelColor,NO);
        }
        if(NSLocationInRange((NSUInteger)i,self.selection) || i==self.selected) {   // the one in the inspector a little bolder
            BOOL anchor=i==self.selected; NSBezierPath *ring=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(marker,-1.5,-1.5) xRadius:6 yRadius:6]; ring.lineWidth=anchor?2:1.5; [NSColor.labelColor setStroke]; [ring stroke];
            for(int t=0;t<KV_TRACKS;t++) { if(anchor && self.selectedTrack>=0 && t!=self.selectedTrack) continue;   // one region chosen: only it
                NSBezierPath *edge=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect([self rectOfRegion:i track:t],-1,-1) xRadius:7 yRadius:7]; edge.lineWidth=anchor?1.5:1; [[NSColor.labelColor colorWithAlphaComponent:anchor?.8:.55] setStroke]; [edge stroke]; }
        }
        if(i==self.swapTarget) { NSBezierPath *swap=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect([self columnOf:i],-2,-2) xRadius:8 yRadius:8]; swap.lineWidth=2.5; [TNAccent() setStroke]; [swap stroke];
            Text(T(@"⇄ поменять местами"),NSMakeRect(NSMinX(marker)+4,KvRulerTop,160,14),10,NSFontWeightSemibold,TNAccent(),NO); }
    }
    if(self.hoverRegion>=0 && self.hoverRegion<(NSInteger)s->count && self.hoverTrack>=0) [self drawButtonsOf:self.hoverRegion track:self.hoverTrack];
    CGFloat bottom=[self tracksBottom];
    for(int c=-1;c<KV_TRACKS;c++) [self drawCurve:c];
    // A corner being dragged: the section it would make, dashed, and what it says.
    if(self.corner && self.pressed>=0 && self.pressed<(NSInteger)s->count) {
        NSRect r=[self columnOf:self.pressed]; double pass=kv_section_pass_beats(s,&s->sections[self.pressed]); CGFloat from=NSMinX(r),to=NSMaxX(r); NSString *label;
        if(self.corner==1) { to=from+(CGFloat)(pass*self.cornerValue*k)-2; label=[NSString stringWithFormat:@"↻ ×%d",(int)self.cornerValue]; }
        else if(self.corner==2) { to=from+(CGFloat)(self.cornerValue*k)-2; label=[NSString stringWithFormat:@"⟷ %@",[self lengthText:self.cornerValue]]; }
        else { from+=(CGFloat)(self.cornerValue*k); label=[NSString stringWithFormat:T(@"начало %@%@"),self.cornerValue>=0?@"+":@"−",[self lengthText:fabs(self.cornerValue)]]; }
        NSBezierPath *ghost=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(MIN(from,to-6),NSMinY(r),MAX(6,to-from),NSHeight(r)) xRadius:6 yRadius:6];
        CGFloat dash[]={5,4}; [ghost setLineDash:dash count:2 phase:0]; ghost.lineWidth=1.5; [NSColor.labelColor setStroke]; [ghost stroke];
        CGFloat width=ceil([label sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]}].width)+10,lx=self.corner==3?from:to-width;
        NSBezierPath *pill=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(lx,KvRulerTop,width,15) xRadius:4 yRadius:4]; [TNCanvas() setFill]; [pill fill];
        Text(label,NSMakeRect(lx+5,KvRulerTop,width,14),11,NSFontWeightSemibold,NSColor.labelColor,NO);
    }
    // Dragging: where the sections land.
    if(self.dragging && self.dropIndex>=0 && self.swapTarget<0) {
        CGFloat x=self.dropIndex<(NSInteger)s->count?NSMinX([self rectOfSection:self.dropIndex])-2:NSMaxX([self rectOfSection:(NSInteger)s->count-1])+1;
        [TNAccent() setFill]; Fill(NSMakeRect(x-1,[self markerTop]-4,3,bottom-[self markerTop]+8));
        if(self.copying) Text(T(@"копия"),NSMakeRect(x+4,KvRulerTop,60,14),10,NSFontWeightSemibold,TNAccent(),NO);
    }
    // Scissors: the cut a ⌘-click makes, through every track.
    if(self.cutBeat>=0) {
        CGFloat x=[self xOfBeat:self.cutBeat]; NSBezierPath *line=[NSBezierPath bezierPath]; [line moveToPoint:NSMakePoint(x,[self markerTop]-2)]; [line lineToPoint:NSMakePoint(x,bottom+2)];
        CGFloat dash[]={3,3}; [line setLineDash:dash count:2 phase:0]; line.lineWidth=1.5; [NSColor.labelColor setStroke]; [line stroke];
        double inBar=fmod(self.cutBeat,bar); NSString *where=inBar<1e-6 || inBar>bar-1e-6?[NSString stringWithFormat:T(@"✂ такт %d"),(int)lround(self.cutBeat/bar)+1]
            :[NSString stringWithFormat:T(@"✂ такт %d · доля %@"),(int)floor(self.cutBeat/bar)+1,[NSString stringWithFormat:@"%g",floor(inBar*1000+.5)/1000+1]];
        CGFloat width=ceil([where sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]}].width)+10;
        NSBezierPath *pill=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x+3,KvRulerTop,width,15) xRadius:4 yRadius:4]; [TNCanvas() setFill]; [pill fill];   // over the ruler's numbers
        Text(where,NSMakeRect(x+8,KvRulerTop,width,14),11,NSFontWeightSemibold,NSColor.labelColor,NO);
    }
    [self drawGhosts];
    [NSGraphicsContext restoreGraphicsState];
    for(int c=-1;c<KV_TRACKS;c++) [self drawCurveHeader:c];
    // Overview: the whole song in small, the visible part framed.
    CGFloat oy=[self overviewTop],ow=[self laneWidth]; [[TNSurface() colorWithAlphaComponent:.6] setFill]; Fill(NSMakeRect(KvLaneX,oy,ow,KvOverviewHeight));
    Text(T(@"Обзор"),NSMakeRect(KvInset,oy,KvHeaderWidth-KvInset,14),10,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
    double whole=MAX(total,[self lastVisibleBeat]-self.scrollBeat);
    for(size_t i=0;i<s->count;i++) { CGFloat x0=KvLaneX+(CGFloat)(kv_section_start(s,i)/whole*ow),x1=KvLaneX+(CGFloat)((kv_section_start(s,i)+kv_section_beats(s,i))/whole*ow);
        [KindColor(s->sections[i].kind) setFill]; Fill(NSMakeRect(x0,oy+2,MAX(1,x1-x0-1),KvOverviewHeight-4)); }
    CGFloat vx=KvLaneX+(CGFloat)(self.scrollBeat/whole*ow),vw=(CGFloat)(([self lastVisibleBeat]-self.scrollBeat)/whole*ow);
    NSBezierPath *view=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(vx,oy,MIN(vw,KvLaneX+ow-vx),KvOverviewHeight) xRadius:3 yRadius:3]; view.lineWidth=1.5; [[NSColor.labelColor colorWithAlphaComponent:.7] setStroke]; [view stroke];
}

// ---- automation lanes ----
- (NSString *)curveValueText:(int)c value:(double)v { return c<0?[NSString stringWithFormat:@"%.0f BPM",v]:[NSString stringWithFormat:@"%.0f %%",v*100]; }
- (void)drawCurve:(int)c {
    NSRect r=[self curveRect:c]; const KvSong *s=[self song]; if(NSIsEmptyRect(r) || !s) return;
    [[NSColor.labelColor colorWithAlphaComponent:.06] setFill]; Fill(r);
    NSColor *color=c<0?NSColor.systemOrangeColor:TNAccent(); const KvCurve *curve=[self curve:c]; double base=c<0?s->bpm:1;
    if(!curve->count) {
        NSPoint a=[self pointOfCurve:c value:base beat:self.scrollBeat]; NSBezierPath *line=[NSBezierPath bezierPath]; [line moveToPoint:NSMakePoint(KvLaneX,a.y)]; [line lineToPoint:NSMakePoint(NSMaxX(r),a.y)];
        CGFloat dash[]={4,4}; [line setLineDash:dash count:2 phase:0]; line.lineWidth=1; [[color colorWithAlphaComponent:.6] setStroke]; [line stroke];
        Text([NSString stringWithFormat:T(@"%@ · двойной щелчок — точка"),[self curveValueText:c value:base]],NSMakeRect(KvLaneX+6,NSMinY(r)+2,260,14),10,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
        return;
    }
    NSBezierPath *path=[NSBezierPath bezierPath]; NSPoint first=[self pointOfCurve:c value:curve->points[0].value beat:curve->points[0].beat];
    [path moveToPoint:NSMakePoint(KvLaneX-2,first.y)];
    for(size_t i=0;i<curve->count;i++) [path lineToPoint:[self pointOfCurve:c value:curve->points[i].value beat:curve->points[i].beat]];
    [path lineToPoint:NSMakePoint(NSMaxX(r)+2,[self pointOfCurve:c value:curve->points[curve->count-1].value beat:0].y)];
    path.lineWidth=1.5; [color setStroke]; [path stroke];
    for(size_t i=0;i<curve->count;i++) {
        NSPoint q=[self pointOfCurve:c value:curve->points[i].value beat:curve->points[i].beat]; BOOL on=c==self.editCurve && (NSInteger)i==self.selectedPoint;
        NSBezierPath *dot=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(q.x-4,q.y-4,8,8)]; [(on?color:TNCanvas()) setFill]; [dot fill]; dot.lineWidth=1.5; [color setStroke]; [dot stroke];
        if(on) Text([self curveValueText:c value:curve->points[i].value],NSMakeRect(q.x+7,MAX(NSMinY(r),q.y-14),80,14),10,NSFontWeightSemibold,color,NO);
    }
}
- (void)drawCurveHeader:(int)c {
    NSRect r=[self curveRect:c]; if(NSIsEmptyRect(r)) return; NSArray *names=@[T(@"Мелодия"),T(@"Бас"),T(@"Ударные")];
    Text(c<0?T(@"Темп"):[NSString stringWithFormat:T(@"Громкость · %@"),names[c]],NSMakeRect(KvInset,NSMinY(r)+3,KvHeaderWidth-KvInset,14),10,NSFontWeightMedium,NSColor.secondaryLabelColor,NO);
}
- (void)tempoLaneToggled:(NSButton *)sender { self.showTempo=sender.state==NSControlStateValueOn; }
- (void)volumeLaneToggled:(NSButton *)sender { [self setShowsVolume:sender.state==NSControlStateValueOn track:(int)sender.tag]; }
- (NSInteger)pointAt:(NSPoint)p curve:(int)c {
    const KvCurve *curve=[self curve:c]; NSInteger hit=-1;
    for(size_t i=0;curve && i<curve->count;i++) { NSPoint q=[self pointOfCurve:c value:curve->points[i].value beat:curve->points[i].beat]; if(hypot(p.x-q.x,p.y-q.y)<=6) hit=(NSInteger)i; }
    return hit;
}
- (void)resetCurve:(NSMenuItem *)item { KvCurve none; memset(&none,0,sizeof(none)); self.selectedPoint=-1; [self.owner arrangerSetCurve:(int)item.tag to:&none]; }
- (void)removePointItem:(NSMenuItem *)item { self.editCurve=(int)item.tag; self.selectedPoint=[item.representedObject integerValue]; [self removeSelectedPoint]; }
- (BOOL)removeSelectedPoint {
    if(self.editCurve<-1 || self.selectedPoint<0) return NO;
    KvCurve copy=*[self curve:self.editCurve]; if(!kv_curve_remove(&copy,(size_t)self.selectedPoint)) return NO;
    self.selectedPoint=-1; [self.owner arrangerSetCurve:self.editCurve to:&copy]; return YES;
}
// ---- mouse ----
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil];
    [self addTrackingArea:self.tracking];
}
- (BOOL)onRulerPoint:(NSPoint)p { return p.x>=KvLaneX && p.y>=KvRulerTop-2 && p.y<KvRulerTop+KvRulerHeight+3; }
- (BOOL)onCycleStrip:(NSPoint)p { return [self onRulerPoint:p] && p.y<KvRulerTop+KvCycleHeight; }
- (NSString *)lengthText:(double)beats { return TNBarCount(beats/[self beatsPerBar]); }
/* A shift: whole bars as bars, else beats («+1,5 доли»). */
- (NSString *)shiftText:(double)beats {
    double bar=[self beatsPerBar],bars=fabs(beats)/bar; NSString *sign=beats<0?@"−":@"+";
    NSString *amount=fabs(bars-round(bars))<1e-9?TNBarCount(round(bars)):[NSString stringWithFormat:T(@"%@ дол."),[[NSString stringWithFormat:@"%g",floor(fabs(beats)*1000+.5)/1000] stringByReplacingOccurrencesOfString:@"." withString:TNEnglish()?@".":@","]];
    return [sign stringByAppendingString:amount];
}
/* A region's corners (spec 1.5 §4): top right — repeats (the loop), bottom right — length, bottom left — the start. */
- (int)cornerAt:(NSPoint)p section:(NSInteger *)index {
    const KvSong *s=[self song]; if(!s || self.tool!=KvToolPointer) return 0;
    for(NSInteger i=0;i<(NSInteger)s->count;i++) for(int t=-1;t<KV_TRACKS;t++) {
        NSRect r=t<0?[self rectOfSection:i]:[self rectOfRegion:i track:t]; if(p.y<NSMinY(r)-1 || p.y>NSMaxY(r)+1) continue;
        if(p.x>=NSMaxX(r)-6 && p.x<=NSMaxX(r)+1) { *index=i; return t>=0 && p.y<NSMinY(r)+MIN(14,NSHeight(r)*.3)?1:2; }   // the edge: length; a region's top corner: repeats
        if(p.x>=NSMinX(r)-1 && p.x<=NSMinX(r)+5 && NSWidth(r)>=20) { *index=i; return 3; }
    }
    return 0;
}
/* The scissors (the tool, or ⌘ held) over a section: the allowed cut nearest the mouse, on the snap grid. */
- (void)updateScissorsAt:(NSPoint)p flags:(NSEventModifierFlags)flags {
    double before=self.cutBeat; self.cutBeat=-1; self.cutSection=-1;
    const KvSong *s=[self song]; NSInteger i=[self sectionAtPoint:p];
    if(s && i>=0 && ((flags&NSEventModifierFlagCommand) || self.tool==KvToolScissors)) {
        double start=kv_section_start(s,(size_t)i),beat=[self beatAtX:p.x]-start,grid=[self snapGrid:flags],cut=kv_song_snap_cut(s,(size_t)i,beat,grid);
        for(double finer=1;cut<0 && grid>0 && finer>=.5;finer/=2) if(finer<grid) cut=kv_song_snap_cut(s,(size_t)i,beat,finer);   // a section shorter than the grid: a finer one
        if(cut>0) { self.cutBeat=start+cut; self.cutSection=i; }
    }
    if(before!=self.cutBeat) self.needsDisplay=YES;
}
static NSCursor *LoopCursor(void) { static NSCursor *cursor; if(!cursor) cursor=ToolCursor(@"repeat",NO); return cursor; }
- (void)updateCursorAt:(NSPoint)p flags:(NSEventModifierFlags)flags {
    NSInteger i=[self sectionAtPoint:p],corner=-1; BOOL inTracks=p.x>=KvLaneX && p.y>=[self markerTop] && p.y<=[self tracksBottom]; int kind=[self cornerAt:p section:&corner]; const KvSong *s=[self song];
    NSCursor *cursor=NSCursor.arrowCursor;
    if(self.cutBeat>=0 || ((flags&NSEventModifierFlagCommand || self.tool==KvToolScissors) && i>=0)) cursor=ScissorsCursor();
    else if(self.tool==KvToolPencil && inTracks) cursor=PencilCursor();
    else if([self onCycleStrip:p] && s && s->cycle_to>s->cycle_from && p.x>=[self xOfBeat:s->cycle_from]-5 && p.x<=[self xOfBeat:s->cycle_to]+5) {
        BOOL edge=fabs(p.x-[self xOfBeat:s->cycle_from])<=5 || fabs(p.x-[self xOfBeat:s->cycle_to])<=5; cursor=edge?NSCursor.resizeLeftRightCursor:NSCursor.openHandCursor; }
    else if(kind==1) cursor=LoopCursor();
    else if(kind) cursor=NSCursor.resizeLeftRightCursor;
    if(cursor!=self.cursor) { self.cursor=cursor; [self.window invalidateCursorRectsForView:self]; }
    [cursor set];
}
/* The playhead view moves every frame, which makes AppKit reset the cursor; the rect gives it back the same one, so it never shakes. */
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:self.cursor?:NSCursor.arrowCursor]; }
- (void)mouseMoved:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; [self updateScissorsAt:p flags:event.modifierFlags];
    if(self.tool==KvToolPointer) [self hoverAtPoint:p]; else [self hoverAtPoint:NSMakePoint(-100,-100)];
    [self updateCursorAt:p flags:event.modifierFlags];
}
- (void)flagsChanged:(NSEvent *)event {
    NSPoint p=[self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    [self updateScissorsAt:p flags:event.modifierFlags]; [self updateCursorAt:p flags:event.modifierFlags]; [super flagsChanged:event];
}
- (void)mouseExited:(NSEvent *)event { (void)event; if(self.cutBeat>=0) { self.cutBeat=-1; self.needsDisplay=YES; } [self hoverAtPoint:NSMakePoint(-100,-100)]; self.cursor=NSCursor.arrowCursor; [self.window invalidateCursorRectsForView:self]; [NSCursor.arrowCursor set]; }
- (void)scrollOverviewTo:(CGFloat)x {
    double visible=[self lastVisibleBeat]-self.scrollBeat,whole=MAX([self songBeats],visible);
    self.scrollBeat=(x-KvLaneX)/[self laneWidth]*whole-visible/2; [self clampScroll]; self.needsDisplay=YES; [self updatePlayhead];
}
/* The ruler's beat under x, snapped, inside the song. */
- (double)rulerBeatAt:(CGFloat)x flags:(NSEventModifierFlags)flags { return MAX(0,MIN([self songBeats],[self snapped:[self beatAtX:x] flags:flags])); }
/* What a drag or a key acts on: the selection when it holds the section, else the section alone. */
- (NSRange)rangeWith:(NSInteger)index { return NSLocationInRange((NSUInteger)index,self.selection) && self.selection.length>1?self.selection:NSMakeRange((NSUInteger)index,1); }
- (void)selectAfterOwner:(NSUInteger)length { if(self.selected>=0) { self.anchor=self.selected; self.selection=NSMakeRange((NSUInteger)self.selected,MIN(length,[self song]->count-(NSUInteger)self.selected)); } self.needsDisplay=YES; }
// The region buttons and the right-click menu do the same things.
- (void)openSection:(NSInteger)i { [self.owner arrangerOpenInRoll:i track:self.selectedTrack]; }
- (void)cutSectionNearPlayhead:(NSInteger)i {
    const KvSong *s=[self song]; double start=kv_section_start(s,(size_t)i),length=kv_section_beats(s,(size_t)i),at=self.cursorBeat-start;
    if(at<=1e-9 || at>=length-1e-9) { at=kv_song_snap_cut(s,(size_t)i,length/2,[self snapGrid:0]); if(at<0) at=length/2; }
    if(i!=self.selected) [self.owner arrangerSelect:i];
    [self.owner arrangerCut:i atBeat:at];
}
- (void)duplicateSection:(NSInteger)i { NSRange range=[self rangeWith:i]; [self.owner arrangerMoveRange:range to:(NSInteger)NSMaxRange(range) copy:YES]; [self selectAfterOwner:range.length]; }
- (void)removeSection:(NSInteger)i { NSRange range=[self rangeWith:i]; [self.owner arrangerRemoveRange:range]; [self selectAfterOwner:1]; }
- (NSMenu *)beatMenuFor:(NSInteger)i {
    NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Бит")]; const KvSong *s=[self song]; NSInteger current=s->sections[i].beat==KV_SECTION_BEAT_FIXED?4+s->sections[i].beat_fixed:MIN(3,(int)s->sections[i].beat);
    for(NSInteger k=0;k<self.beatChoice.numberOfItems;k++) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:[self.beatChoice itemTitleAtIndex:k] action:@selector(menuBeat:) keyEquivalent:@""];
        item.target=self; item.tag=k; item.representedObject=@(i); item.state=k==current?NSControlStateValueOn:NSControlStateValueOff; [menu addItem:item]; }
    return menu;
}
- (NSMenu *)menuForSection:(NSInteger)i track:(int)track beat:(double)beat {
    const KvSong *s=[self song]; if(!s || i<0 || i>=(NSInteger)s->count) return nil;
    NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Секция")]; NSDictionary *at=@{@"section":@(i),@"track":@(track),@"beat":@(beat)};
    NSMenuItem *(^add)(NSString *,SEL)=^NSMenuItem *(NSString *title,SEL action) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""]; item.target=self; item.representedObject=at; [menu addItem:item]; return item; };
    add(T(@"Открыть в ролле"),@selector(menuOpen:));
    double start=kv_section_start(s,(size_t)i),cut=kv_song_snap_cut(s,(size_t)i,beat-start,[self snapGrid:0]);
    add(T(@"Разрезать здесь"),@selector(menuCut:)).enabled=cut>0;
    NSRange range=[self rangeWith:i];
    add(range.length>1?[NSString stringWithFormat:T(@"Дублировать секции: %lu"),(unsigned long)range.length]:T(@"Дублировать"),@selector(menuDuplicate:));
    add(range.length>1?[NSString stringWithFormat:T(@"Удалить секции: %lu"),(unsigned long)range.length]:T(@"Удалить"),@selector(menuRemove:));
    [menu addItem:NSMenuItem.separatorItem];
    { NSArray<NSDictionary *> *ghosts=[self ghostsAfter:i]; NSMenu *next=[[NSMenu alloc] initWithTitle:T(@"Добавить после")];   // what may come next, as the «+» offers it
      for(NSUInteger k=0;k<ghosts.count;k++) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:ghosts[k][@"title"] action:@selector(menuSuggest:) keyEquivalent:@""]; item.target=self; item.tag=(NSInteger)k; item.representedObject=@(i); [next addItem:item]; }
      NSMenuItem *holder=add(T(@"Добавить после"),nil); holder.submenu=next; holder.enabled=ghosts.count>0; }
    if(i+1<(NSInteger)s->count && s->sections[i].kind!=KV_SECTION_TRANSITION && s->sections[i+1].kind!=KV_SECTION_TRANSITION) {
        NSMenu *ways=[[NSMenu alloc] initWithTitle:T(@"Вставить переход после")];
        for(int k=0;k<KV_TRANSITION_KINDS;k++) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:Translated(kv_transition_name((KvTransitionKind)k)) action:@selector(chooseTransition:) keyEquivalent:@""]; item.target=self; item.tag=k; item.representedObject=@(i); [ways addItem:item]; }
        NSMenuItem *holder=add(T(@"Вставить переход после"),nil); holder.submenu=ways;
    }
    add(range.length>1?T(@"Цикл по этим секциям"):T(@"Цикл по секции"),@selector(menuCycle:));
    if(track>=0) {
        [menu addItem:NSMenuItem.separatorItem]; NSArray *names=@[T(@"Мелодия"),T(@"Бас"),T(@"Ударные")];
        add([NSString stringWithFormat:s->sections[i].regions[track].mute?T(@"Включить «%@» в этой секции"):T(@"Выключить «%@» в этой секции"),names[track]],@selector(menuMute:));
        if(fabs(s->sections[i].regions[track].shift)>1e-9) add([NSString stringWithFormat:T(@"Убрать сдвиг «%@»"),names[track]],@selector(menuUnshift:));
        if(track==KV_TRACK_DRUMS) { NSMenuItem *beats=add(T(@"Бит"),nil); beats.submenu=[self beatMenuFor:i]; }
    }
    [menu addItem:NSMenuItem.separatorItem]; add(T(@"Выделить все секции · ⌘A"),@selector(menuSelectAll:));
    return menu;
}
- (NSInteger)menuSection:(NSMenuItem *)item { return [item.representedObject[@"section"] integerValue]; }
- (void)menuOpen:(NSMenuItem *)item { [self.owner arrangerOpenInRoll:[self menuSection:item] track:[item.representedObject[@"track"] intValue]]; }
- (void)menuCut:(NSMenuItem *)item {
    NSInteger i=[self menuSection:item]; const KvSong *s=[self song]; double start=kv_section_start(s,(size_t)i),cut=kv_song_snap_cut(s,(size_t)i,[item.representedObject[@"beat"] doubleValue]-start,[self snapGrid:0]);
    if(cut>0) { if(i!=self.selected) [self.owner arrangerSelect:i]; [self.owner arrangerCut:i atBeat:cut]; }
}
- (void)menuDuplicate:(NSMenuItem *)item { [self duplicateSection:[self menuSection:item]]; }
- (void)menuRemove:(NSMenuItem *)item { [self removeSection:[self menuSection:item]]; }
- (void)menuMute:(NSMenuItem *)item {
    NSInteger i=[self menuSection:item]; int track=[item.representedObject[@"track"] intValue]; if(i!=self.selected) [self.owner arrangerSelect:i];
    [self.owner arrangerSetRegion:track mute:![self song]->sections[i].regions[track].mute level:-1];
}
- (void)menuUnshift:(NSMenuItem *)item { [self.owner arrangerShiftRegion:[self menuSection:item] track:[item.representedObject[@"track"] intValue] shift:0]; }
- (void)menuBeat:(NSMenuItem *)item { NSInteger i=[item.representedObject integerValue]; if(i!=self.selected) [self.owner arrangerSelect:i]; [self.owner arrangerSet:KvSectionFieldBeat value:item.tag]; }
- (void)menuSuggest:(NSMenuItem *)item { [self.owner arrangerAccept:item.tag after:[item.representedObject integerValue]]; }
- (void)menuCycle:(NSMenuItem *)item {
    NSRange range=[self rangeWith:[self menuSection:item]]; const KvSong *s=[self song];
    double from=kv_section_start(s,range.location),to=kv_section_start(s,NSMaxRange(range)-1)+kv_section_beats(s,NSMaxRange(range)-1);
    [self.owner arrangerSetCycleFrom:from to:to]; self.needsDisplay=YES;
}
- (void)menuSelectAll:(id)sender { (void)sender; const KvSong *s=[self song]; if(s && s->count) { self.selection=NSMakeRange(0,s->count); self.needsDisplay=YES; } }
- (void)clearCycle:(id)sender { (void)sender; [self.owner arrangerSetCycleFrom:0 to:0]; self.needsDisplay=YES; }
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; int c=[self curveAtPoint:p];
    if([self onRulerPoint:p]) {   // the ruler: the cycle
        const KvSong *s=[self song]; NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Линейка")];
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:T(@"Снять цикл") action:@selector(clearCycle:) keyEquivalent:@""]; item.target=self; item.enabled=s && s->cycle_to>s->cycle_from; [menu addItem:item];
        return menu;
    }
    if(c>=-1) {   // a lane: remove the point under the mouse, or reset the whole curve
        NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Кривая")]; NSInteger hit=[self pointAt:p curve:c];
        if(hit>=0) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:T(@"Удалить точку · ⌫") action:@selector(removePointItem:) keyEquivalent:@""]; item.target=self; item.tag=c; item.representedObject=@(hit); [menu addItem:item]; }
        NSMenuItem *reset=[[NSMenuItem alloc] initWithTitle:T(@"Сбросить кривую") action:@selector(resetCurve:) keyEquivalent:@""]; reset.target=self; reset.tag=c; reset.enabled=[self curve:c]->count>0; [menu addItem:reset];
        return menu;
    }
    NSInteger i=[self sectionAtPoint:p]; if(i<0) return nil;
    int track=-1; for(int t=0;t<KV_TRACKS;t++) if(NSPointInRect(p,[self rectOfRegion:i track:t])) track=t;
    if(!NSLocationInRange((NSUInteger)i,self.selection)) { [self.owner arrangerSelect:i]; [self selectAfterOwner:1]; }
    return [self menuForSection:i track:track beat:[self beatAtX:p.x]];
}
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; NSEventModifierFlags flags=event.modifierFlags;
    self.downPoint=p; self.dragging=self.scrolling=self.onRuler=self.cycling=self.collapse=self.movingCycle=NO; self.corner=0; self.swapTarget=-1;
    const KvSong *s=[self song]; if(!s || !s->count) return;
    if(flags&NSEventModifierFlagControl && !(flags&NSEventModifierFlagCommand)) { NSMenu *menu=[self menuForEvent:event]; if(menu) [NSMenu popUpContextMenu:menu withEvent:event forView:self]; return; }
    if(p.y>=[self overviewTop] && p.x>=KvLaneX) { self.scrolling=YES; [self scrollOverviewTo:p.x]; return; }
    int c=[self curveAtPoint:p];
    if(c>=-1) {   // an automation lane: a double click adds a point, a point is picked and dragged
        self.editCurve=c; self.onCurve=YES; NSInteger hit=[self pointAt:p curve:c]; const KvCurve *curve=[self curve:c];
        if(hit<0 && event.clickCount==2) {
            KvCurve copy=*curve; size_t i=kv_curve_set(&copy,MAX(0,[self snapped:[self beatAtX:p.x] flags:flags]),(float)[self valueOfCurve:c atY:p.y]);
            if(i<KV_CURVE_POINTS) { self.selectedPoint=(NSInteger)i; [self.owner arrangerSetCurve:c to:&copy]; }
            self.onCurve=NO; return;
        }
        self.selectedPoint=hit; _draft=*curve; self.needsDisplay=YES; return;
    }
    if(self.editCurve>=-1) { self.editCurve=-2; self.selectedPoint=-1; self.needsDisplay=YES; }
    if([self onRulerPoint:p]) {   // the cycle strip draws the cycle; below it a click puts the playhead, a double click plays from there
        self.onRuler=YES; self.rulerBeat=[self rulerBeatAt:p.x flags:flags]; self.cycling=NO; self.rulerClicks=event.clickCount;
        self.shiftedRuler=[self onCycleStrip:p] || (flags&NSEventModifierFlagShift)!=0;
        if(self.shiftedRuler && s->cycle_to>s->cycle_from+1e-9) {   // on the cycle itself: an edge stretches it, the middle carries it whole
            CGFloat from=[self xOfBeat:s->cycle_from],to=[self xOfBeat:s->cycle_to];
            if(fabs(p.x-from)<=5) self.rulerBeat=s->cycle_to; else if(fabs(p.x-to)<=5) self.rulerBeat=s->cycle_from;
            else if(p.x>from && p.x<to) { self.movingCycle=YES; self.cycleGrab=[self beatAtX:p.x]-s->cycle_from; self.cycleSpan=s->cycle_to-s->cycle_from; }
        }
        if(!self.shiftedRuler) { self.cursorBeat=self.rulerBeat; [self updatePlayhead]; }
        return;
    }
    BOOL option=(flags&NSEventModifierFlagOption)!=0; if(self.tool==KvToolPointer) [self hoverAtPoint:p];
    if(self.tool==KvToolPointer && self.hoverGhost>=0 && self.hoverSection>=0) {   // a ghost: insert it, or (⌥ on a new chorus) choose among other choruses
        NSInteger after=self.hoverSection,ghost=self.hoverGhost; NSDictionary *g=[self ghostsAfter:after][ghost];
        if(self.auditioning) { self.auditioning=NO; [self.owner arrangerAudition:-1 after:after]; }
        if(option && [g[@"chorus"] boolValue]) {
            NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Другой припев")]; NSArray<NSString *> *variants=[self.owner arrangerChorusVariants:after];
            for(NSUInteger k=0;k<variants.count;k++) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:variants[k] action:@selector(chooseVariant:) keyEquivalent:@""]; item.target=self; item.tag=(NSInteger)k; item.representedObject=@(after); [menu addItem:item]; }
            [menu popUpMenuPositioningItem:nil atLocation:p inView:self]; return;
        }
        self.hoverSection=self.hoverGhost=-1; TNHintHide(self); [self.owner arrangerAccept:ghost after:after]; return;
    }
    if(NO) {   // seams no longer take a transition by hover (the edges resize); the context menu inserts one
        NSInteger after=self.hoverSeam; self.hoverSeam=-1; TNHintHide(self);
        if(option) {
            NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Переход")];
            for(int k=0;k<KV_TRANSITION_KINDS;k++) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:T(@"Переход: %@"),[Translated(kv_transition_name((KvTransitionKind)k)) lowercaseString]] action:@selector(chooseTransition:) keyEquivalent:@""]; item.target=self; item.tag=k; item.representedObject=@(after); [menu addItem:item]; }
            [menu popUpMenuPositioningItem:nil atLocation:p inView:self]; return;
        }
        [self.owner arrangerTransitionAfter:after kind:-1]; return;
    }
    if(self.tool==KvToolPointer && self.hoverRegion>=0 && self.hoverButton>=0) {   // ✎ ✂ ⧉ ✕ (♩ on the drums: its beat)
        NSInteger i=self.hoverRegion,button=self.hoverButton; int track=self.hoverTrack; self.hoverRegion=self.hoverButton=-1; TNHintHide(self);
        if(button==0 && track==KV_TRACK_DRUMS) { if(i!=self.selected) [self.owner arrangerSelect:i]; [[self beatMenuFor:i] popUpMenuPositioningItem:nil atLocation:p inView:self]; }
        else if(button==0) { self.selectedTrack=track; [self openSection:i]; }
        else if(button==1) { self.tool=KvToolScissors; self.oneCut=YES; [self updateScissorsAt:p flags:flags]; [self updateCursorAt:p flags:flags]; }   // ✂: click where to cut
        else if(button==2) [self duplicateSection:i]; else [self removeSection:i];
        return;
    }
    NSInteger i=[self sectionAtPoint:p];
    if(self.tool==KvToolPencil && !(flags&NSEventModifierFlagCommand)) {   // pencil: the circle's progression at the nearest seam, or at the end
        if(p.x<KvLaneX || p.y<[self markerTop] || p.y>[self tracksBottom]) return;
        NSInteger at=(NSInteger)s->count; if(i>=0) { NSRect r=[self columnOf:i]; at=p.x<NSMidX(r)?i:i+1; }
        [self.owner arrangerDrawAt:at]; [self selectAfterOwner:1]; return;
    }
    NSInteger cornered=-1; int corner=(flags&NSEventModifierFlagCommand)?0:[self cornerAt:p section:&cornered];
    if(corner) {   // a corner: select the section and drag its repeats, length or start
        self.pressed=cornered; self.corner=corner; if(cornered!=self.selected) [self.owner arrangerSelect:cornered]; [self selectAfterOwner:1];
        const KvSection *x=&s->sections[cornered]; self.cornerValue=corner==1?x->repeats:corner==2?kv_section_beats(s,(size_t)cornered):0; self.needsDisplay=YES; return;
    }
    self.pressed=i; if(i<0) return;
    if((flags&NSEventModifierFlagCommand) || self.tool==KvToolScissors) {   // scissors
        [self updateScissorsAt:p flags:flags|NSEventModifierFlagCommand]; NSInteger section=self.cutSection; double cut=self.cutBeat;
        self.cutBeat=-1; self.cutSection=-1; self.pressed=-1; self.needsDisplay=YES;
        if(section>=0) [self.owner arrangerCut:section atBeat:cut-kv_section_start(s,(size_t)section)];
        else [self.owner arrangerCut:i atBeat:[self beatAtX:p.x]-kv_section_start(s,(size_t)i)];   // too near an edge: the owner says why it refuses
        if(self.oneCut) { self.oneCut=NO; self.tool=KvToolPointer; }   // the ✂ button's scissors make one cut
        return;
    }
    if(event.clickCount==2) {   // the roll on the region's track; on the drums, the section's beat
        self.pressed=-1; BOOL drums=NSPointInRect(p,[self rectOfRegion:i track:KV_TRACK_DRUMS]); for(int t=0;t<KV_TRACK_DRUMS;t++) if(NSPointInRect(p,[self rectOfRegion:i track:t])) self.selectedTrack=t;
        if(drums) [[self beatMenuFor:i] popUpMenuPositioningItem:nil atLocation:p inView:self]; else [self openSection:i];
        return;
    }
    if(flags&NSEventModifierFlagShift && self.anchor>=0 && self.anchor<(NSInteger)s->count) {   // ⇧: the range from the last plain click
        NSInteger a=MIN(self.anchor,i),b=MAX(self.anchor,i); NSInteger keep=self.anchor;
        if(i!=self.selected) [self.owner arrangerSelect:i];
        self.anchor=keep; self.selection=NSMakeRange((NSUInteger)a,(NSUInteger)(b-a+1)); self.needsDisplay=YES; return;
    }
    { int track=-1; for(int t=0;t<KV_TRACKS;t++) if(NSPointInRect(p,[self rectOfRegion:i track:t])) track=t; if(track!=self.selectedTrack) { self.selectedTrack=track; self.needsDisplay=YES; } }   // a region: its track; the marker: the whole section
    if(NSLocationInRange((NSUInteger)i,self.selection) && self.selection.length>1) self.collapse=YES;   // keep the range for a drag; a plain click narrows it
    else { if(i!=self.selected) [self.owner arrangerSelect:i]; self.anchor=i; self.selection=NSMakeRange((NSUInteger)i,1); self.needsDisplay=YES; }
}
- (void)mouseDragged:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; NSEventModifierFlags flags=event.modifierFlags;
    if(self.scrolling) { [self scrollOverviewTo:p.x]; return; }
    if(self.onCurve) {   // a point: its time on the snap, between its neighbours, and its value
        int c=self.editCurve; NSInteger i=self.selectedPoint; const KvCurve *curve=c>=-1?[self curve:c]:NULL; if(!curve || i<0 || i>=(NSInteger)curve->count) return;
        double low=i>0?_draft.points[i-1].beat+1e-3:0,high=i+1<(NSInteger)_draft.count?_draft.points[i+1].beat-1e-3:1e6;
        _draft.points[i]=(KvPoint){MAX(low,MIN(high,[self snapped:[self beatAtX:p.x] flags:flags])),(float)[self valueOfCurve:c atY:p.y]};
        self.draggingPoint=YES; self.needsDisplay=YES; return;
    }
    if(self.onRuler) {
        double beat=[self rulerBeatAt:p.x flags:flags];
        if(!self.shiftedRuler) { self.cursorBeat=beat; [self updatePlayhead]; return; }   // the playhead follows the mouse
        if(!self.cycling && fabs(p.x-self.downPoint.x)<4) return;
        self.cycling=YES;
        if(self.movingCycle) { double from=MAX(0,MIN([self songBeats]-self.cycleSpan,[self snapped:[self beatAtX:p.x]-self.cycleGrab flags:flags])); self.cycleFrom=from; self.cycleTo=from+self.cycleSpan; }
        else { self.cycleFrom=MIN(self.rulerBeat,beat); self.cycleTo=MAX(self.rulerBeat,beat); }
        self.needsDisplay=YES; return;
    }
    const KvSong *s=[self song]; if(!s || self.pressed<0 || self.pressed>=(NSInteger)s->count) return;
    if(self.corner) {
        NSInteger i=self.pressed; NSRect r=[self columnOf:i]; double start=kv_section_start(s,(size_t)i),length=kv_section_beats(s,(size_t)i),pass=kv_section_pass_beats(s,&s->sections[i]);
        double beats=(p.x-NSMinX(r))/[self scale],value;   // the section's own beats from its left edge (a transition stretched to 28 pt aside)
        if(self.corner==1) value=MAX(1,MIN(KV_SECTION_REPEATS,lround(beats/pass)));
        else if(self.corner==2) { double end=[self snapped:start+beats flags:flags]-start; value=MAX(fmax([self snapGrid:flags],.125),MIN(512,end)); }
        else { double cut=[self snapped:start+beats flags:flags]-start; value=MIN(length-fmax([self snapGrid:flags],.125),cut); value=MAX(value,length-512); }
        if(value!=self.cornerValue) { self.cornerValue=value; self.needsDisplay=YES; }
        return;
    }
    if(!self.dragging && fabs(p.x-self.downPoint.x)<4) return;
    self.dragging=YES; self.collapse=NO; self.copying=(flags&NSEventModifierFlagOption)!=0;
    NSRange range=[self rangeWith:self.pressed]; NSInteger swap=-1;
    if(range.length==1 && !self.copying) for(NSInteger i=0;i<(NSInteger)s->count;i++) {   // over the middle of another section: swap with it
        NSRect r=[self columnOf:i]; if(i!=self.pressed && p.x>NSMinX(r)+NSWidth(r)*.25 && p.x<NSMaxX(r)-NSWidth(r)*.25) swap=i;
    }
    NSInteger drop=(NSInteger)s->count; for(NSInteger i=0;i<(NSInteger)s->count;i++) if(p.x<NSMidX([self rectOfSection:i])) { drop=i; break; }
    self.swapTarget=swap; self.dropIndex=drop; self.needsDisplay=YES;
}
- (void)mouseUp:(NSEvent *)event {
    (void)event; const KvSong *s=[self song]; NSInteger from=self.pressed; self.pressed=-1;
    if(self.scrolling) { self.scrolling=NO; return; }
    if(self.onCurve) { self.onCurve=NO; if(self.draggingPoint) { KvCurve moved=_draft; [self.owner arrangerSetCurve:self.editCurve to:&moved]; self.draggingPoint=NO; } self.needsDisplay=YES; return; }
    if(self.onRuler) {
        self.onRuler=NO;
        if(self.shiftedRuler) {
            if(self.cycling && self.cycleTo>self.cycleFrom+1e-9) [self.owner arrangerSetCycleFrom:self.cycleFrom to:self.cycleTo];   // it switches ↻ on
            else if(!self.cycling && s && s->cycle_to>s->cycle_from && self.rulerBeat>=s->cycle_from-1e-9 && self.rulerBeat<=s->cycle_to+1e-9) [self.owner arrangerToggleLoop];   // a click on it: ↻
            self.cycling=NO; self.needsDisplay=YES; return;
        }
        // A double click plays from there; while the song plays, a click (or a drag let go) goes on from there; else the playhead waits.
        if(self.rulerClicks>=2 || [self.owner arrangerPlayheadBeat]>=0) [self.owner arrangerPlayFrom:self.cursorBeat];
        return;
    }
    if(self.corner) {
        int corner=self.corner; double value=self.cornerValue; self.corner=0; self.needsDisplay=YES;
        if(!s || from<0 || from>=(NSInteger)s->count) return;
        if(corner==1 && (int)value!=s->sections[from].repeats) [self.owner arrangerSet:KvSectionFieldRepeats value:(NSInteger)value];
        else if(corner==2 && fabs(value-kv_section_beats(s,(size_t)from))>1e-9) [self.owner arrangerSetLength:from beats:value];
        else if(corner==3 && fabs(value)>1e-9) [self.owner arrangerTrimStart:from beats:value];
        return;
    }
    if(self.dragging) {
        self.dragging=NO; NSInteger drop=self.dropIndex,swap=self.swapTarget; self.dropIndex=self.swapTarget=-1; self.needsDisplay=YES;
        if(!s || from<0 || from>=(NSInteger)s->count) return;
        if(swap>=0) { [self.owner arrangerSwap:from with:swap]; [self selectAfterOwner:1]; return; }
        NSRange range=[self rangeWith:from]; if(drop<0) return;
        if(!self.copying && drop>=(NSInteger)range.location && drop<=(NSInteger)NSMaxRange(range)) return;   // onto itself
        [self.owner arrangerMoveRange:range to:drop copy:self.copying]; [self selectAfterOwner:range.length]; return;
    }
    if(self.collapse && from>=0) { self.collapse=NO; if(from!=self.selected) [self.owner arrangerSelect:from]; self.anchor=from; self.selection=NSMakeRange((NSUInteger)from,1); self.needsDisplay=YES; }
}
- (void)chooseVariant:(NSMenuItem *)item { self.hoverSection=self.hoverGhost=-1; [self.owner arrangerAcceptVariant:item.tag after:[item.representedObject integerValue]]; }
- (void)chooseTransition:(NSMenuItem *)item { [self.owner arrangerTransitionAfter:[item.representedObject integerValue] kind:item.tag]; }
/* The wheel scrolls; with ⌘ (or a pinch) it zooms toward the mouse. */
- (void)scrollWheel:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    if(event.modifierFlags&NSEventModifierFlagCommand) {
        double raw=fabs(event.scrollingDeltaY)>=fabs(event.scrollingDeltaX)?event.scrollingDeltaY:event.scrollingDeltaX;
        [self zoomBy:pow(1.5,-(event.hasPreciseScrollingDeltas?raw/60.0:raw/6.0)) aroundX:p.x]; return;   // the same way round as the piano roll
    }
    CGFloat delta=fabs(event.scrollingDeltaX)>fabs(event.scrollingDeltaY)?event.scrollingDeltaX:event.scrollingDeltaY;
    if(!event.hasPreciseScrollingDeltas) delta*=8;
    self.scrollBeat=[self rawBeat:[self rawX:self.scrollBeat]-delta]; [self clampScroll]; self.needsDisplay=YES; [self updatePlayhead];
}
- (void)magnifyWithEvent:(NSEvent *)event { [self zoomBy:1+event.magnification aroundX:[self convertPoint:event.locationInWindow fromView:nil].x]; }
// ---- keys ----
- (void)keyDown:(NSEvent *)event {
    if(event.keyCode==49 && self.hoverGhost>=0 && self.hoverSection>=0) {   // Space over a ghost: hear it (again: stop)
        self.auditioning=!self.auditioning; [self.owner arrangerAudition:self.auditioning?self.hoverGhost:-1 after:self.hoverSection]; self.needsDisplay=YES; return;
    }
    const KvSong *s=[self song]; NSInteger count=s?(NSInteger)s->count:0; NSEventModifierFlags flags=event.modifierFlags; unsigned short code=event.keyCode;
    BOOL command=(flags&NSEventModifierFlagCommand)!=0,option=(flags&NSEventModifierFlagOption)!=0,plain=!(flags&(NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl));
    if(count && plain) {   // tools and the whole song; the keyboard's T and Z do nothing here (there is no keyboard)
        if(code==17) { self.tool=KvToolPointer; return; }
        if(code==34) { self.tool=KvToolScissors; return; }
        if(code==35) { self.tool=KvToolPencil; return; }
        if(code==6) { [self showWholeSong:nil]; return; }
        if(code==115) { self.cursorBeat=0; [self updatePlayhead]; if([self.owner arrangerPlayheadBeat]>=0) [self.owner arrangerPlayFrom:0]; return; }   // Home: to the start
        if(code==53 && self.tool!=KvToolPointer) { self.tool=KvToolPointer; return; }   // Esc: back to the pointer first
        if(code==53 && self.selection.length>1) { self.selection=NSMakeRange((NSUInteger)self.selected,1); self.needsDisplay=YES; return; }   // then a single section
    }
    if(count && command && !option && code==0) { [self menuSelectAll:nil]; return; }   // ⌘A
    if(count && command && (code==24 || code==69 || code==27 || code==78)) { [self zoomBy:code==24 || code==69?1.5:1/1.5 aroundX:KvLaneX+[self laneWidth]/2]; return; }   // ⌘+ ⌘−, as in the roll
    if(count && command && !option && (code==123 || code==124)) { [self zoomBy:code==123?1/1.5:1.5 aroundX:KvLaneX+[self laneWidth]/2]; return; }   // ⌘← ⌘→
    if(count && self.selected>=0 && (code==123 || code==124)) {
        NSInteger to=self.selected+(code==123?-1:1); if(to<0 || to>=count) return;
        if(command) [self.owner arrangerMove:self.selected to:to copy:NO]; else [self.owner arrangerSelect:to];   // ⌥⌘← ⌥⌘→ move the section
        [self selectAfterOwner:1]; return;
    }
    if((code==51 || code==117) && !command && [self removeSelectedPoint]) return;   // ⌫ on a point of a curve
    if(count && self.selected>=0 && !command) {
        if(code==51 || code==117) { [self removeSection:self.selected]; return; }
        if(code==36 || code==76) { [self openSection:self.selected]; return; }
    }
    [self.owner arrangerForwardKey:event];
}
// ---- «Структура ▾» ----
- (void)rebuildStructureMenu {
    NSPopUpButton *popup=self.structureChoice; [popup removeAllItems]; [popup addItemWithTitle:T(@"Структура")];
    NSArray<NSDictionary *> *forms=[self.owner arrangerForms]; BOOL mine=NO; NSMenu *remove=[[NSMenu alloc] initWithTitle:T(@"Удалить свою форму")];
    for(NSUInteger i=0;i<forms.count;i++) {
        BOOL user=[forms[i][@"user"] boolValue]; if(user && !mine) { [popup.menu addItem:NSMenuItem.separatorItem]; mine=YES; }
        [popup addItemWithTitle:[NSString stringWithFormat:@"%@ · %@",forms[i][@"name"],forms[i][@"letters"]]]; popup.lastItem.tag=1000+(NSInteger)i; popup.lastItem.representedObject=forms[i];
        if(user) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:forms[i][@"name"] action:@selector(deleteForm:) keyEquivalent:@""]; item.target=self; item.representedObject=forms[i][@"name"]; [remove addItem:item]; }
    }
    [popup.menu addItem:NSMenuItem.separatorItem];
    [popup addItemWithTitle:T(@"Сохранить форму этой песни…")]; popup.lastItem.tag=2000;
    if(remove.numberOfItems) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:T(@"Удалить свою форму") action:NULL keyEquivalent:@""]; item.submenu=remove; [popup.menu addItem:item]; }
    [popup addItemWithTitle:T(@"Другой вариант той же формы · ⌘R")]; popup.lastItem.tag=2001;
}
- (void)structureChosen:(NSPopUpButton *)sender {
    NSMenuItem *item=sender.selectedItem;
    if(item.tag>=1000 && item.tag<2000) [self.owner arrangerApplyForm:item.representedObject];
    else if(item.tag==2000) [self.owner arrangerSaveForm:sender];
    else if(item.tag==2001) [self.owner arrangerAnotherForm:sender];
}
- (void)deleteForm:(NSMenuItem *)item { [self.owner arrangerDeleteForm:item.representedObject]; }
// ---- MIDI export: the song or one track ----
- (NSMenu *)exportMenu {
    NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Экспорт MIDI")]; NSArray *titles=@[T(@"Вся песня… · ⇧⌘E"),T(@"Только мелодия…"),T(@"Только бас…"),T(@"Только ударные…")];
    for(NSUInteger k=0;k<titles.count;k++) { NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:titles[k] action:@selector(exportChosen:) keyEquivalent:@""]; item.target=self; item.tag=(NSInteger)k; [menu addItem:item]; }
    return menu;
}
- (void)exportMenu:(NSButton *)sender { [[self exportMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(sender.frame),NSMaxY(sender.frame)+2) inView:self]; }
- (void)exportChosen:(NSMenuItem *)item { [self.owner arrangerExport:item.tag]; }
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
- (void)openSelected:(id)sender { (void)sender; if(self.selected>=0) [self openSection:self.selected]; }
- (void)revert:(id)sender { [self.owner arrangerRevert:sender]; }
- (void)removeSelected:(id)sender { (void)sender; if(self.selected>=0) [self.owner arrangerRemove:self.selected]; }
- (void)take:(id)sender { [self.owner arrangerTakeDraft:sender]; }
- (void)generate:(id)sender { [self.owner arrangerGenerateSong:sender]; }
@end
