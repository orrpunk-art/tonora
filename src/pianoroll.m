#import "pianoroll.h"
#import "controls.h"
#include <math.h>
static const CGFloat KvToolbarH=36, KvRulerH=26, KvKeysW=60;
enum { DRAG_NONE, DRAG_MOVE, DRAG_RESIZE, DRAG_PENDING, DRAG_MARQUEE };
/* NSRectFill copies pixels, so a translucent colour punches holes instead of tinting; always blend. */
static void RollFill(NSRect rect) { NSRectFillUsingOperation(rect,NSCompositingOperationSourceOver); }
static void RollText(NSString *text,NSRect rect,CGFloat size,NSFontWeight weight,NSColor *color,NSTextAlignment align) {
    NSMutableParagraphStyle *style=[NSMutableParagraphStyle new]; style.alignment=align; style.lineBreakMode=NSLineBreakByClipping;
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:weight],NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:style}];
}
/* Icon-only toolbar button with a hover label; a text glyph where the system lacks the symbol. */
static TNButton *RollIcon(NSString *symbol,NSString *fallback,NSString *hint,id target,SEL action) {
    TNButton *button=[TNButton buttonWithTitle:@"" target:target action:action]; button.bezelStyle=NSBezelStyleRounded; button.bordered=NO;
    button.font=[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    NSImage *image=TNIcon(symbol,14); if(image) { image.accessibilityDescription=hint; button.image=image; } else button.title=fallback;
    button.hint=hint; return button;
}
static NSString *const KvFollowOnHint=@"Следовать за воспроизведением · ⌘F. Масштаб или прокрутка во время игры выключают";
static NSString *const KvFollowOffHint=@"Вид стоит на месте · нажмите, чтобы вернуться к курсору воспроизведения · ⌘F";
@interface KvPianoRoll () {
    BOOL _selected[KV_PERFORMANCE_CAPACITY];
    double _dragBeat[KV_PERFORMANCE_CAPACITY]; int _dragMidi[KV_PERFORMANCE_CAPACITY]; double _dragDuration[KV_PERFORMANCE_CAPACITY];
    /* The vertical axis is a row coordinate v: unfolded, v is the pitch (21…108); folded, the kept pitches are
       numbered upward from 21 without gaps. topPitch, zoom and scrolling all work in v. */
    int _vOf[128], _midiOfV[128], _vTop; BOOL _rowsBuilt, _rowsValid;
    unsigned char _roles[KV_PERFORMANCE_CAPACITY];   /* chord tone / passing / anticipation of each note */
}
@property(nonatomic) double topPitch;      /* pitch at the top edge of the note area, fractional for smooth scrolling */
@property(nonatomic) int dragMode;
@property(nonatomic) NSUInteger dragIndex;
@property(nonatomic) NSPoint dragStart;
@property(nonatomic) BOOL dragChanged;
@property(nonatomic) TNButton *resetButton,*quantizeButton,*deleteButton,*zoomOut,*zoomIn,*helpButton,*followButton,*scaleButton,*foldButton;
@property(nonatomic,readwrite) KvMidiDragHandle *dragHandle;
@property(nonatomic) NSPopUpButton *gridChoice,*speedChoice;
@property(nonatomic) NSTextField *stats;
@property(nonatomic) NSTrackingArea *tracking;
@property(nonatomic) NSInteger hoverIndex; @property(nonatomic) BOOL hoverEdge;
@property(nonatomic) BOOL fitted;          /* the row height and centre were computed for a real size */
@property(nonatomic) NSRect marquee;
@property(nonatomic) size_t loadedCount;   /* note count at the last reload: same count keeps the selection */
/* The note under the cursor when the drag began: its original start, pitch and length (indices change while sorting). */
@property(nonatomic) double anchorBeat,anchorDuration; @property(nonatomic) int anchorMidi;
@property(nonatomic) int lastAuditioned;
@property(nonatomic,readwrite) NSPopUpButton *sectionChoice;
@end
@implementation KvPianoRoll
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])) {
        _gridBeats=.25; _speed=1; _zoom=1; _rowHeight=14; _topPitch=85; _playheadBeat=-1; _splitNote=60; _hoverIndex=-1;
        _resetButton=RollIcon(@"arrow.counterclockwise",@"↺",T(@"Вернуть дорожку из рисунка · ручные правки сбросятся"),self,@selector(resetTrack:)); [self addSubview:_resetButton];
        _sectionChoice=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO]; _sectionChoice.target=self; _sectionChoice.action=@selector(sectionPicked:); _sectionChoice.hidden=YES;
        [_sectionChoice setAccessibilityLabel:T(@"Секция песни")]; [self addSubview:_sectionChoice];
        _gridChoice=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for(NSArray *item in @[@[T(@"Сетка 1/4"),@"1/4"],@[T(@"Сетка 1/8"),@"1/8"],@[T(@"Сетка 1/16"),@"1/16"],@[T(@"Сетка 1/8 · триоль"),@"1/8T"],@[T(@"Без сетки"),T(@"Своб.")]]) { [_gridChoice addItemWithTitle:item[0]]; _gridChoice.lastItem.representedObject=item[1]; }
        [_gridChoice selectItemAtIndex:2]; _gridChoice.target=self; _gridChoice.action=@selector(gridChanged:); _gridChoice.toolTip=T(@"Шаг привязки при добавлении, перемещении и растяжении нот"); [self addSubview:_gridChoice];
        _speedChoice=[[TNPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];
        for(NSArray *item in @[@[T(@"Скорость ×1"),@"×1"],@[T(@"Скорость ×¾"),@"×¾"],@[T(@"Скорость ×½"),@"×½"],@[T(@"Скорость ×¼"),@"×¼"]]) { [_speedChoice addItemWithTitle:item[0]]; _speedChoice.lastItem.representedObject=item[1]; }
        _speedChoice.target=self; _speedChoice.action=@selector(speedChanged:); _speedChoice.toolTip=T(@"Замедленное воспроизведение для разбора; темп не меняется"); [self addSubview:_speedChoice];
        _quantizeButton=RollIcon(@"align.horizontal.left",@"Q",T(@"Квантовать: начала выделенных нот к сетке"),self,@selector(quantize:)); [self addSubview:_quantizeButton];
        _deleteButton=RollIcon(@"trash",@"✕",T(@"Удалить выделенные ноты · ⌫"),self,@selector(deleteAction:)); [self addSubview:_deleteButton];
        _zoomOut=RollIcon(@"minus.magnifyingglass",@"−",T(@"Мельче по времени · ⌘− · ⌘+колесо; по высоте — ⌘⌥−"),self,@selector(zoomOutAction:)); [self addSubview:_zoomOut];
        _zoomIn=RollIcon(@"plus.magnifyingglass",@"+",T(@"Крупнее по времени · ⌘+ · ⌘+колесо; по высоте — ⌘⌥+"),self,@selector(zoomInAction:)); [self addSubview:_zoomIn];
        _scaleButton=RollIcon(@"pianokeys",T(@"Гамма"),T(@"Подсветить гамму"),self,@selector(toggleScale:)); [_scaleButton setButtonType:NSButtonTypePushOnPushOff]; [self addSubview:_scaleButton];
        id savedScale=[TNDefaults() objectForKey:@"pianoRollScale"]; _showScale=savedScale?[savedScale boolValue]:YES;
        _scaleButton.state=_showScale?NSControlStateValueOn:NSControlStateValueOff;
        _foldButton=RollIcon(@"rectangle.compress.vertical",@"Fold",T(@"Свернуть до нот гаммы · F"),self,@selector(toggleFold:)); [_foldButton setButtonType:NSButtonTypePushOnPushOff]; [self addSubview:_foldButton];
        _fold=[TNDefaults() boolForKey:@"pianoRollFold"]; _foldButton.state=_fold?NSControlStateValueOn:NSControlStateValueOff;
        _helpButton=RollIcon(@"questionmark.circle",@"?",T(@"Все сочетания клавиш · ⌘/"),self,@selector(toggleHelp:)); [self addSubview:_helpButton];
        _followButton=RollIcon(@"arrow.right.to.line",@"→|",T(KvFollowOnHint),self,@selector(toggleFollow:)); [_followButton setButtonType:NSButtonTypePushOnPushOff]; _followButton.state=NSControlStateValueOn; [self addSubview:_followButton]; _follow=YES;
        _dragHandle=[[KvMidiDragHandle alloc] initWithFrame:NSZeroRect]; _dragHandle.hint=T(@"Перетащите в DAW или Finder: клип выделенных нот, без выделения — вся дорожка · ⌘C — в буфер");
        __weak KvPianoRoll *weakRoll=self; _dragHandle.provider=^NSURL *{ KvPianoRoll *roll=weakRoll; return roll?[roll.owner pianoRollMidiClip:roll]:nil; }; [self addSubview:_dragHandle];
        _stats=[NSTextField labelWithString:@""]; _stats.font=[NSFont systemFontOfSize:11]; _stats.textColor=NSColor.secondaryLabelColor; _stats.alignment=NSTextAlignmentRight; _stats.lineBreakMode=NSLineBreakByTruncatingTail; [self addSubview:_stats];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (double)totalBeats { return self.track && self.track->total_beats>0?self.track->total_beats:4; }
- (NSRect)noteAreaRect { return NSMakeRect(KvKeysW,KvToolbarH+KvRulerH,NSWidth(self.bounds)-KvKeysW,NSHeight(self.bounds)-KvToolbarH-KvRulerH); }
/* At zoom 1 the view shows four bars (or the whole track when it is shorter); the rest scrolls. */
- (double)windowBeats { double bar=[self.owner pianoRollBeatsPerBar:self]; if(bar<=0) bar=4; return MIN([self totalBeats],4*bar); }
- (double)minZoom { return MIN(1,[self windowBeats]/[self totalBeats]); }
- (double)visibleBeats { return [self windowBeats]/self.zoom; }
- (double)pixelsPerBeat { return NSWidth([self noteAreaRect])/[self visibleBeats]; }
- (CGFloat)xForBeat:(double)beat { return NSMinX([self noteAreaRect])+(beat-self.scrollBeat)*[self pixelsPerBeat]; }
- (double)beatAtX:(CGFloat)x { return self.scrollBeat+(x-NSMinX([self noteAreaRect]))/[self pixelsPerBeat]; }
/* Row of pitch m spans [top−m−1, top−m) rows below the top edge, so pitch `top` would sit just above the area. */
/* Rebuild the rows when the fold, the scale or the notes changed; the pitch at the middle of the view stays put. */
- (void)ensureRows {
    if(_rowsBuilt && (_rowsValid || self.dragMode!=DRAG_NONE)) return;   // never reshuffle rows under a drag
    double middle=0; int anchor=-1;
    if(_rowsBuilt) { double rows=NSHeight([self noteAreaRect])/self.rowHeight; middle=self.topPitch-rows/2; int v=MAX(21,MIN(_vTop,(int)floor(middle))); anchor=_midiOfV[v]; middle-=v; }
    BOOL keep[128]={NO}; int kept=0;
    if(self.fold) {
        int tonic=0; unsigned scale=self.showScale?[self.owner pianoRollScale:self tonic:&tonic]:0;
        for(int m=21;m<=108;m++) if(scale>>(m%12)&1u) keep[m]=YES;
        if(self.track) for(size_t i=0;i<self.track->count;i++) { int m=self.track->events[i].midi; if(m>=21 && m<=108) keep[m]=YES; }
        for(int m=21;m<=108;m++) if(keep[m]) kept++;
    }
    BOOL folded=self.fold && kept>0;   // nothing to fold to: show every key
    int v=21,below=21;
    for(int m=21;m<=108;m++) {
        if(!folded || keep[m]) { _vOf[m]=v; _midiOfV[v]=m; below=v; v++; }
        else _vOf[m]=below;            // a pitch without a row sits on the row below it
    }
    for(int m=0;m<21;m++) _vOf[m]=m; for(int m=109;m<128;m++) _vOf[m]=v+(m-109);   // off the keyboard: outside every row
    _vTop=v-1; _rowsBuilt=YES; _rowsValid=YES;
    if(anchor>=0) { self.topPitch=_vOf[anchor]+middle+NSHeight([self noteAreaRect])/self.rowHeight/2; [self clampView]; }
}
- (NSUInteger)rowCount { [self ensureRows]; return (NSUInteger)(_vTop-20); }
- (int)vForMidi:(int)midi { [self ensureRows]; return _vOf[MAX(0,MIN(127,midi))]; }
- (int)vAtY:(CGFloat)y { return (int)ceil(self.topPitch-1-(y-NSMinY([self noteAreaRect]))/self.rowHeight-1e-9); }
/* Pitch of row v; outside the rows it returns a pitch outside 21…108, which callers reject. */
- (int)midiForV:(int)v { [self ensureRows]; return v<21?20:v>_vTop?109:_midiOfV[v]; }
- (CGFloat)yForV:(int)v { return NSMinY([self noteAreaRect])+(self.topPitch-v-1)*self.rowHeight; }
- (CGFloat)yForMidi:(int)midi { return [self yForV:[self vForMidi:midi]]; }
- (int)midiAtY:(CGFloat)y { return [self midiForV:[self vAtY:y]]; }
- (int)visibleRows { return (int)floor(NSHeight([self noteAreaRect])/self.rowHeight); }
- (void)clampView {
    double rows=NSHeight([self noteAreaRect])/self.rowHeight;
    int top=_rowsBuilt?_vTop+1:109;
    if(self.topPitch>top) self.topPitch=top; if(self.topPitch-rows<21) self.topPitch=MIN(top,21+rows);
    if(self.zoom<[self minZoom]) self.zoom=[self minZoom];
    double visible=[self visibleBeats]; if(self.scrollBeat>[self totalBeats]-visible) self.scrollBeat=[self totalBeats]-visible; if(self.scrollBeat<0) self.scrollBeat=0;
}
/* Fit the rows to the window and centre the view on the notes. */
- (void)fitView {
    CGFloat areaH=NSHeight([self noteAreaRect]); if(areaH<40) { self.fitted=NO; return; }
    self.rowHeight=MAX(10,MIN(18,floor(areaH/30)));
    int low=108,high=21; if(self.track) for(size_t i=0;i<self.track->count;i++) { int m=self.track->events[i].midi; if(m<low) low=m; if(m>high) high=m; }
    if(low>high) { low=48; high=84; }
    double rows=areaH/self.rowHeight; self.topPitch=round(([self vForMidi:low]+[self vForMidi:high])/2.0+rows/2+.5); [self clampView]; self.fitted=YES;
}
/* New notes from the owner. The view (zoom, scroll, row height) is the user's and stays as it is;
   the selection survives when the notes are the same ones (e.g. replaying the arrangement). */
- (void)reload {
    size_t count=self.track?self.track->count:0;
    if(count!=self.loadedCount) memset(_selected,0,sizeof(_selected));
    self.loadedCount=count; self.hoverIndex=-1; _rowsValid=NO;
    if(!self.fitted) [self fitView]; else [self clampView];
    [self updateToolbar]; self.needsDisplay=YES;
}
/* ⌘0: four bars from the start, rows fitted to the notes. */
- (void)resetView { [self userMovedTimeView]; self.zoom=1; self.scrollBeat=0; [self fitView]; self.needsDisplay=YES; }
- (void)setFrameSize:(NSSize)size {
    BOOL changed=fabs(size.height-NSHeight(self.frame))>.5 || fabs(size.width-NSWidth(self.frame))>.5;
    [super setFrameSize:size];
    if(changed || !self.fitted) { [self fitView]; self.needsDisplay=YES; }
}
- (void)layout {
    [super layout]; CGFloat x=8,y=4,h=28;
    // Groups: track · grid and speed · note edits · view · help · clip.
    self.resetButton.frame=NSMakeRect(x,y,34,h); x+=46; self.gridChoice.frame=NSMakeRect(x,y,88,h); x+=94; self.speedChoice.frame=NSMakeRect(x,y,78,h); x+=90;
    self.quantizeButton.frame=NSMakeRect(x,y,34,h); x+=38; self.deleteButton.frame=NSMakeRect(x,y,34,h); x+=46;
    self.zoomOut.frame=NSMakeRect(x,y,34,h); x+=38; self.zoomIn.frame=NSMakeRect(x,y,34,h); x+=38; self.followButton.frame=NSMakeRect(x,y,34,h); x+=46;
    self.scaleButton.frame=NSMakeRect(x,y,34,h); x+=38; self.foldButton.frame=NSMakeRect(x,y,34,h); x+=38; self.helpButton.frame=NSMakeRect(x,y,34,h); x+=46; self.dragHandle.frame=NSMakeRect(x,y,78,h); x+=86;
    self.stats.frame=NSMakeRect(x,y+6,MAX(40,NSWidth(self.bounds)-x-8),18);
    self.sectionChoice.frame=NSMakeRect(x,y,MAX(40,NSWidth(self.bounds)-x-8),h); self.stats.hidden=!self.sectionChoice.hidden;
    [self clampView];
}
- (void)updateToolbar {
    size_t count=self.track?self.track->count:0; NSUInteger selected=[self selectedCount];
    self.stats.stringValue=[NSString stringWithFormat:T(@"%zu нот%@%@"),count,selected?[NSString stringWithFormat:T(@" · выделено %lu"),(unsigned long)selected]:@"",self.edited?T(@" · изменено вручную"):T(@" · из рисунка")];
    _rowsValid=NO; self.foldButton.hint=self.fold?T(@"Развернуть: все клавиши · F"):self.showScale?T(@"Свернуть до нот гаммы и строк с нотами · F"):T(@"Свернуть до строк с нотами · F");
    NSString *scale=[self.owner pianoRollScaleName:self]?:@"";
    NSString *scaleHint=[NSString stringWithFormat:T(@"%@ гамму%@"),self.showScale?T(@"Подсветка: убрать"):T(@"Подсветить"),scale.length?[@" · " stringByAppendingString:scale]:@""];
    if(![self.scaleButton.hint isEqualToString:scaleHint]) self.scaleButton.hint=scaleHint;
    self.deleteButton.enabled=selected>0; self.quantizeButton.enabled=selected>0 && self.gridBeats>0;
    NSArray<NSString *> *sections=[self.owner respondsToSelector:@selector(pianoRollSections:)]?[self.owner pianoRollSections:self]:nil;
    if(sections.count) {   // the open section and the way back, in place of the note count (which becomes its hover text)
        [self.sectionChoice removeAllItems]; [self.sectionChoice addItemWithTitle:T(@"← Аранжировщик · ⇧⌘A")]; self.sectionChoice.lastItem.representedObject=T(@"← Аранжировщик");
        for(NSString *name in sections) { [self.sectionChoice addItemWithTitle:name]; self.sectionChoice.lastItem.representedObject=[name componentsSeparatedByString:@" · "].firstObject; }
        [self.sectionChoice selectItemAtIndex:[self.owner pianoRollSection:self]+1]; self.sectionChoice.toolTip=self.stats.stringValue;
    }
    if(self.sectionChoice.hidden!=!sections.count) { self.sectionChoice.hidden=!sections.count; self.needsLayout=YES; }
    [self.speedChoice selectItemAtIndex:self.speed>=1?0:self.speed>=.75?1:self.speed>=.5?2:3];
}
- (BOOL)isSelectedAt:(NSUInteger)index { return index<KV_PERFORMANCE_CAPACITY && _selected[index]; }
- (NSUInteger)selectedCount { NSUInteger n=0; if(self.track) for(size_t i=0;i<self.track->count;i++) if(_selected[i]) n++; return n; }
- (void)setSelected:(BOOL)selected at:(NSUInteger)index { if(index<KV_PERFORMANCE_CAPACITY) _selected[index]=selected; [self updateToolbar]; self.needsDisplay=YES; }
- (void)selectAll { if(self.track) for(size_t i=0;i<self.track->count;i++) _selected[i]=YES; [self updateToolbar]; self.needsDisplay=YES; }
- (void)deselectAll { memset(_selected,0,sizeof(_selected)); [self updateToolbar]; self.needsDisplay=YES; }
/* Keep the track sorted, each note inside the sequence and tagged with the chord it starts in; selection follows the notes. */
- (void)normalize {
    KvPerformance *t=self.track; if(!t) return;
    double total=t->total_beats,bpc=t->beats_per_chord;
    for(size_t i=0;i<t->count;i++) {
        KvPianoEvent *e=&t->events[i];
        if(e->beat<0) e->beat=0; if(e->beat>total-.05) e->beat=total-.05;
        if(e->duration<.05) e->duration=.05; if(e->beat+e->duration>total) e->duration=total-e->beat;
        if(e->midi<21) e->midi=21; if(e->midi>108) e->midi=108;
        if(e->velocity<.4f) e->velocity=.4f; if(e->velocity>1) e->velocity=1;
        e->chord=(unsigned)MIN((double)t->chord_count-1,floor(e->beat/bpc+1e-9));
    }
    for(size_t i=1;i<t->count;i++) {
        KvPianoEvent e=t->events[i]; BOOL sel=_selected[i]; double db=_dragBeat[i]; int dm=_dragMidi[i]; double dd=_dragDuration[i]; size_t j=i;
        while(j && t->events[j-1].beat>e.beat) { t->events[j]=t->events[j-1]; _selected[j]=_selected[j-1]; _dragBeat[j]=_dragBeat[j-1]; _dragMidi[j]=_dragMidi[j-1]; _dragDuration[j]=_dragDuration[j-1]; j--; }
        t->events[j]=e; _selected[j]=sel; _dragBeat[j]=db; _dragMidi[j]=dm; _dragDuration[j]=dd;
    }
}
/* Same-pitch notes never overlap (one piano key): an earlier note ends where the next one of its pitch starts;
   a note starting at the same moment replaces the unselected one. Applied on drop, so a drag can pass over notes. */
- (void)resolveOverlaps {
    KvPerformance *t=self.track; if(!t) return;
    BOOL removed[KV_PERFORMANCE_CAPACITY]; memset(removed,0,sizeof(removed));
    for(size_t i=0;i<t->count;i++) {
        if(removed[i]) continue;
        for(size_t j=i+1;j<t->count;j++) {
            if(removed[j] || t->events[j].midi!=t->events[i].midi) continue;
            KvPianoEvent *a=&t->events[i],*b=&t->events[j];
            if(b->beat>=a->beat+a->duration-1e-9) break;
            if(b->beat-a->beat<.05) { size_t drop=_selected[i] && !_selected[j]?j:i; removed[drop]=YES; if(drop==i) break; continue; }
            a->duration=b->beat-a->beat; break;
        }
    }
    size_t kept=0;
    for(size_t i=0;i<t->count;i++) if(!removed[i]) { t->events[kept]=t->events[i]; _selected[kept]=_selected[i]; _dragBeat[kept]=_dragBeat[i]; _dragMidi[kept]=_dragMidi[i]; _dragDuration[kept]=_dragDuration[i]; kept++; }
    for(size_t i=kept;i<t->count;i++) _selected[i]=NO;
    t->count=kept;
}
- (void)commit { [self normalize]; [self resolveOverlaps]; self.edited=YES; [self updateToolbar]; self.needsDisplay=YES; [self.owner pianoRollDidEdit:self]; }
- (double)snap:(double)beat { if(self.gridBeats<=0) return beat; return round(beat/self.gridBeats)*self.gridBeats; }
- (double)snapDown:(double)beat { if(self.gridBeats<=0) return beat; return floor(beat/self.gridBeats+1e-9)*self.gridBeats; }
- (BOOL)addNoteAtBeat:(double)beat midi:(int)midi duration:(double)duration {
    KvPerformance *t=self.track; if(!t || t->count>=KV_PERFORMANCE_CAPACITY || midi<21 || midi>108) return NO;
    if(beat<0 || beat>=t->total_beats) return NO;
    [self.owner pianoRollWillEdit:self];
    t->events[t->count]=(KvPianoEvent){midi,beat,fmax(.05,duration),.72f,0,midi<self.splitNote?0u:1u,0};
    memset(_selected,0,sizeof(_selected)); _selected[t->count]=YES; t->count++;
    [self commit]; return YES;
}
- (BOOL)resizeNoteAt:(NSUInteger)index toDuration:(double)duration {
    KvPerformance *t=self.track; if(!t || index>=t->count) return NO;
    [self.owner pianoRollWillEdit:self]; t->events[index].duration=fmax(.05,duration); [self commit]; return YES;
}
- (BOOL)moveNoteAt:(NSUInteger)index toBeat:(double)beat midi:(int)midi {
    KvPerformance *t=self.track; if(!t || index>=t->count) return NO;
    [self.owner pianoRollWillEdit:self]; t->events[index].beat=beat; t->events[index].midi=midi; [self commit]; return YES;
}
- (BOOL)setHand:(unsigned)hand forSelected:(BOOL)onlySelected {
    KvPerformance *t=self.track; if(!t) return NO; BOOL any=NO;
    for(size_t i=0;i<t->count;i++) if(!onlySelected || _selected[i]) any=YES;
    if(!any) return NO; [self.owner pianoRollWillEdit:self];
    for(size_t i=0;i<t->count;i++) if(!onlySelected || _selected[i]) t->events[i].hand=hand;
    [self commit]; return YES;
}
- (void)changeVelocityOfSelectedBy:(float)delta {
    KvPerformance *t=self.track; if(!t || ![self selectedCount]) return; [self.owner pianoRollWillEdit:self];
    for(size_t i=0;i<t->count;i++) if(_selected[i]) t->events[i].velocity+=delta;
    [self commit];
}
- (void)deleteSelected {
    KvPerformance *t=self.track; if(!t || ![self selectedCount]) return; [self.owner pianoRollWillEdit:self];
    size_t kept=0; for(size_t i=0;i<t->count;i++) if(!_selected[i]) t->events[kept++]=t->events[i];
    t->count=kept; memset(_selected,0,sizeof(_selected)); [self commit];
}
/* Copies the selected notes `offset` beats later and selects the copies; copies past the end are dropped. */
- (NSUInteger)appendCopiesOfSelectedOffset:(double)offset {
    KvPerformance *t=self.track; if(!t) return 0; size_t original=t->count; NSUInteger added=0;
    BOOL copy[KV_PERFORMANCE_CAPACITY]; memcpy(copy,_selected,sizeof(copy)); memset(_selected,0,sizeof(_selected));
    for(size_t i=0;i<original && t->count<KV_PERFORMANCE_CAPACITY;i++) if(copy[i]) {
        KvPianoEvent e=t->events[i]; e.beat+=offset; e.fill=0; if(e.beat>=t->total_beats-1e-9) continue;
        size_t at=t->count++; t->events[at]=e; _selected[at]=YES; _dragBeat[at]=e.beat; _dragMidi[at]=e.midi; _dragDuration[at]=e.duration; added++;
    }
    return added;
}
- (void)duplicateSelected {
    KvPerformance *t=self.track; if(!t || ![self selectedCount]) return;
    double start=INFINITY,end=0; for(size_t i=0;i<t->count;i++) if(_selected[i]) { start=fmin(start,t->events[i].beat); end=fmax(end,t->events[i].beat+t->events[i].duration); }
    double span=end-start; if(self.gridBeats>0) span=ceil(span/self.gridBeats-1e-9)*self.gridBeats;
    [self.owner pianoRollWillEdit:self];
    if(![self appendCopiesOfSelectedOffset:span]) { [self.owner pianoRollDidEdit:self]; return; }
    [self commit];
    // Keep the copies in view.
    double visible=[self visibleBeats]; if(start+span>=self.scrollBeat+visible) { self.scrollBeat=floor((start+span)/visible)*visible; [self clampView]; }
}
- (void)quantizeSelected {
    KvPerformance *t=self.track; if(!t || ![self selectedCount] || self.gridBeats<=0) return; [self.owner pianoRollWillEdit:self];
    for(size_t i=0;i<t->count;i++) if(_selected[i]) t->events[i].beat=fmin(t->total_beats-.05,[self snap:t->events[i].beat]);
    [self commit];
}
/* ↑↓: the next row up or down — a semitone unfolded, the next kept pitch (a scale step) folded. */
- (void)moveSelectedByRows:(int)rows {
    KvPerformance *t=self.track; if(!t || ![self selectedCount]) return; [self ensureRows]; [self.owner pianoRollWillEdit:self];
    for(size_t i=0;i<t->count;i++) if(_selected[i]) t->events[i].midi=[self midiForV:MAX(21,MIN(_vTop,[self vForMidi:t->events[i].midi]+rows))];
    [self commit];
}
- (void)moveSelectedBy:(double)beats semitones:(int)semitones {
    KvPerformance *t=self.track; if(!t || ![self selectedCount]) return; [self.owner pianoRollWillEdit:self];
    for(size_t i=0;i<t->count;i++) if(_selected[i]) { t->events[i].beat+=beats; t->events[i].midi+=semitones; }
    [self commit];
}
// ---- toolbar actions ----
- (void)sectionPicked:(NSPopUpButton *)sender { [self.owner pianoRoll:self openSection:sender.indexOfSelectedItem-1]; }
- (void)resetTrack:(id)sender { (void)sender; [self.owner pianoRollResetRequested:self]; }
- (void)gridChanged:(NSPopUpButton *)sender { static const double grids[]={1,.5,.25,1.0/3,0}; self.gridBeats=grids[MIN(4,MAX(0,sender.indexOfSelectedItem))]; [self updateToolbar]; self.needsDisplay=YES; }
- (void)speedChanged:(NSPopUpButton *)sender { static const double speeds[]={1,.75,.5,.25}; self.speed=speeds[MIN(3,MAX(0,sender.indexOfSelectedItem))]; [self.owner pianoRoll:self speedChanged:self.speed]; }
- (void)quantize:(id)sender { (void)sender; [self quantizeSelected]; }
- (void)deleteAction:(id)sender { (void)sender; [self deleteSelected]; }
/* Zoom the time axis keeping the beat under `anchorX` where it is (Ableton style). */
- (void)zoomBy:(double)factor aroundX:(CGFloat)anchorX {
    [self userMovedTimeView]; double beat=[self beatAtX:anchorX]; self.zoom=MAX([self minZoom],MIN(16,self.zoom*factor));
    self.scrollBeat=beat-(anchorX-NSMinX([self noteAreaRect]))/[self pixelsPerBeat]; [self clampView]; self.needsDisplay=YES;
}
/* Vertical zoom: change the row height keeping the pitch under `anchorY` in place. */
- (void)zoomRowsBy:(double)factor aroundY:(CGFloat)anchorY {
    NSRect area=[self noteAreaRect]; double pitch=self.topPitch-(anchorY-NSMinY(area))/self.rowHeight; // continuous pitch under the cursor
    self.rowHeight=MAX(6,MIN(30,self.rowHeight*factor));
    self.topPitch=pitch+(anchorY-NSMinY(area))/self.rowHeight; [self clampView]; self.needsDisplay=YES;
}
- (void)zoomInAction:(id)sender { (void)sender; [self zoomBy:1.5 aroundX:NSMidX([self noteAreaRect])]; }
- (void)zoomOutAction:(id)sender { (void)sender; [self zoomBy:1/1.5 aroundX:NSMidX([self noteAreaRect])]; }
/* Follow the playhead: when it leaves the visible window, page to the window that contains it.
   Off while a note is being dragged, and after the user moves or zooms the time axis during playback. */
- (void)setPlayheadBeat:(double)playheadBeat {
    _playheadBeat=playheadBeat;
    if(playheadBeat<0 || !self.follow || self.dragMode!=DRAG_NONE) return;
    [self pageToPlayhead];
}
- (void)pageToPlayhead {
    double visible=[self visibleBeats],beat=self.playheadBeat; if(beat<0) return;
    if(beat<self.scrollBeat-1e-6 || beat>=self.scrollBeat+visible-1e-6) { self.scrollBeat=floor(beat/visible+1e-9)*visible; [self clampView]; self.needsDisplay=YES; }
}
- (void)setFollow:(BOOL)follow {
    _follow=follow; self.followButton.state=follow?NSControlStateValueOn:NSControlStateValueOff; self.followButton.hint=T(follow?KvFollowOnHint:KvFollowOffHint);
    if(follow) [self pageToPlayhead];
}
- (void)toggleFollow:(id)sender { (void)sender; self.follow=!self.follow; }
- (void)toggleScale:(id)sender { (void)sender; self.showScale=!self.showScale; }
- (void)toggleFold:(id)sender { (void)sender; self.fold=!self.fold; }
- (void)setFold:(BOOL)fold {
    _fold=fold; self.foldButton.state=fold?NSControlStateValueOn:NSControlStateValueOff;
    [TNDefaults() setBool:fold forKey:@"pianoRollFold"]; [self updateToolbar]; [self ensureRows]; [self clampView]; self.needsDisplay=YES;
}
- (void)setShowScale:(BOOL)showScale {
    _showScale=showScale; self.scaleButton.state=showScale?NSControlStateValueOn:NSControlStateValueOff;
    [TNDefaults() setBool:showScale forKey:@"pianoRollScale"]; [self updateToolbar]; self.needsDisplay=YES;
}
/* A manual move of the time axis while playing means "let me look here": stop following until the button is pressed. */
- (void)userMovedTimeView { if(self.playheadBeat>=0 && self.follow) self.follow=NO; }
// ---- hit testing & mouse ----
- (NSRect)rectForNote:(NSUInteger)index {
    KvPianoEvent e=self.track->events[index];
    CGFloat x=round([self xForBeat:e.beat]),x1=round([self xForBeat:e.beat+e.duration]),y=round([self yForMidi:e.midi])+1;
    return NSMakeRect(x,y,MAX(4,x1-x-1),self.rowHeight-2);
}
- (NSUInteger)noteIndexAtPoint:(NSPoint)point edge:(BOOL *)edge {
    if(!self.track) return NSNotFound;
    for(size_t i=self.track->count;i-->0;) {
        NSRect r=[self rectForNote:i];
        if(NSPointInRect(point,NSInsetRect(r,-1,0))) { if(edge) *edge=point.x>=NSMaxX(r)-MIN(7,NSWidth(r)/2); return i; }
    }
    return NSNotFound;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas]; if(self.tracking) [self removeTrackingArea:self.tracking];
    self.tracking=[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved|NSTrackingMouseEnteredAndExited|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]; [self addTrackingArea:self.tracking];
}
/* Recompute what each note is to the harmony under it. */
- (void)updateRoles {
    KvPerformance *t=self.track; if(!t) return;
    NSArray<NSNumber *> *list=[self.owner pianoRollChordMasks:self]; unsigned masks[64]={0}; size_t n=MIN(list.count,(NSUInteger)64);
    for(size_t i=0;i<n;i++) masks[i]=list[i].unsignedIntValue;
    kv_note_roles(t,masks,n,_roles);
}
- (unsigned char)roleOfNote:(NSUInteger)index { [self updateRoles]; return self.track && index<self.track->count?_roles[index]:KV_ROLE_CHORD; }
/* Hover label for a note outside its chord: what it is and to which chord it belongs. */
- (void)hintForNote:(NSInteger)index {
    KvPerformance *t=self.track; if(index<0 || !t || (size_t)index>=t->count || !_roles[index]) { TNHintHide(self); return; }
    KvPianoEvent e=t->events[index]; NSArray<NSString *> *names=[self.owner pianoRollChordNames:self];
    size_t c=t->beats_per_chord>0?(size_t)floor(e.beat/t->beats_per_chord+1e-9):0;
    NSString *(^chord)(size_t)=^NSString *(size_t i) { if(!names.count) return @""; NSString *name=names[i%names.count]; NSRange dot=[name rangeOfString:@" · "]; return dot.location==NSNotFound?name:[name substringFromIndex:NSMaxRange(dot)]; };
    NSString *note=[NSString stringWithFormat:@"%@%d",[self.owner pianoRoll:self nameForMidi:e.midi],e.midi/12-1];
    NSString *text=_roles[index]==KV_ROLE_ANTICIPATION?[NSString stringWithFormat:T(@"Предвосхищение: %@ из следующего аккорда %@, звучит чуть раньше смены"),note,chord(c+1)]
                                                      :[NSString stringWithFormat:T(@"Проходящая нота: %@ не входит в %@, ведёт мелодию к звуку аккорда"),note,chord(c)];
    TNHintShow(self,[self rectForNote:(NSUInteger)index],text,NO);
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; BOOL edge=NO; NSUInteger index=[self noteIndexAtPoint:p edge:&edge];
    NSInteger hover=index==NSNotFound || TNViewCovered(self,event.locationInWindow)?-1:(NSInteger)index;
    if(hover!=self.hoverIndex) [self hintForNote:hover];
    if(hover!=self.hoverIndex || edge!=self.hoverEdge) { self.hoverIndex=hover; self.hoverEdge=edge; self.needsDisplay=YES; }
    if(hover>=0) [edge?NSCursor.resizeLeftRightCursor:NSCursor.openHandCursor set]; else [NSCursor.arrowCursor set];
}
- (void)mouseExited:(NSEvent *)event { (void)event; self.hoverIndex=-1; self.needsDisplay=YES; [NSCursor.arrowCursor set]; TNHintHide(self); }
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    if(p.y<KvToolbarH) return;
    if(p.x<KvKeysW && p.y>=KvToolbarH+KvRulerH) { int midi=[self midiAtY:p.y]; if(midi>=21 && midi<=108) [self.owner pianoRoll:self audition:midi]; return; }
    if(!NSPointInRect(p,[self noteAreaRect]) || !self.track) return;
    BOOL edge=NO; NSUInteger index=[self noteIndexAtPoint:p edge:&edge];
    if(event.clickCount==2) {
        if(index==NSNotFound) { double beat=[self snapDown:[self beatAtX:p.x]]; int midi=[self midiAtY:p.y]; [self addNoteAtBeat:beat midi:midi duration:self.gridBeats>0?self.gridBeats:.5]; [self.owner pianoRoll:self audition:midi]; }
        else { memset(_selected,0,sizeof(_selected)); _selected[index]=YES; [self deleteSelected]; self.hoverIndex=-1; } // double-click on a note removes it
        self.dragMode=DRAG_NONE; return;
    }
    if(index==NSNotFound) {
        if(!(event.modifierFlags&NSEventModifierFlagShift)) [self deselectAll];
        self.dragMode=DRAG_MARQUEE; self.dragStart=p; self.marquee=NSZeroRect; return;
    }
    if(event.modifierFlags&NSEventModifierFlagShift) _selected[index]=!_selected[index];
    else if(!_selected[index]) { memset(_selected,0,sizeof(_selected)); _selected[index]=YES; }
    [self.owner pianoRoll:self audition:self.track->events[index].midi];
    for(size_t i=0;i<self.track->count;i++) { _dragBeat[i]=self.track->events[i].beat; _dragMidi[i]=self.track->events[i].midi; _dragDuration[i]=self.track->events[i].duration; }
    self.dragMode=DRAG_PENDING; self.dragIndex=index; self.dragStart=p; self.dragChanged=NO; self.hoverEdge=edge; self.lastAuditioned=self.track->events[index].midi;
    self.anchorBeat=self.track->events[index].beat; self.anchorMidi=self.track->events[index].midi; self.anchorDuration=self.track->events[index].duration;
    [self updateToolbar]; self.needsDisplay=YES;
}
- (void)mouseDragged:(NSEvent *)event {
    if(self.dragMode==DRAG_NONE || !self.track) return;
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    if(self.dragMode==DRAG_MARQUEE) {
        self.marquee=NSMakeRect(MIN(p.x,self.dragStart.x),MIN(p.y,self.dragStart.y),fabs(p.x-self.dragStart.x),fabs(p.y-self.dragStart.y));
        for(size_t i=0;i<self.track->count;i++) _selected[i]=NSIntersectsRect(self.marquee,[self rectForNote:i]);
        [self updateToolbar]; self.needsDisplay=YES; return;
    }
    if(self.dragMode==DRAG_PENDING) {
        if(fabs(p.x-self.dragStart.x)<3 && fabs(p.y-self.dragStart.y)<3) return;
        self.dragMode=self.hoverEdge?DRAG_RESIZE:DRAG_MOVE; [self.owner pianoRollWillEdit:self];
        // ⌥-drag leaves the originals in place and drags copies.
        if(self.dragMode==DRAG_MOVE && (event.modifierFlags&NSEventModifierFlagOption)) [self appendCopiesOfSelectedOffset:0];
    }
    KvPerformance *t=self.track;
    if(self.dragMode==DRAG_RESIZE) {
        // The end of the dragged note lands on the grid; the others keep the same change of length.
        double end=[self snap:[self beatAtX:p.x]],lead=fmax(self.gridBeats>0?self.gridBeats:.05,end-self.anchorBeat),delta=lead-self.anchorDuration;
        for(size_t i=0;i<t->count;i++) if(_selected[i]) t->events[i].duration=fmax(self.gridBeats>0?self.gridBeats:.05,_dragDuration[i]+delta);
    } else {
        // The dragged note's start snaps to the grid absolutely; the selection moves with it.
        double target=[self snapDown:[self beatAtX:p.x]-([self beatAtX:self.dragStart.x]-self.anchorBeat)+(self.gridBeats>0?self.gridBeats/2:0)];
        if(self.gridBeats<=0) target=self.anchorBeat+[self beatAtX:p.x]-[self beatAtX:self.dragStart.x];
        // Vertically the selection moves by rows: semitones unfolded, scale steps folded.
        double dBeat=target-self.anchorBeat; int dRows=[self vAtY:p.y]-[self vAtY:self.dragStart.y];
        for(size_t i=0;i<t->count;i++) if(_selected[i]) { t->events[i].beat=_dragBeat[i]+dBeat; t->events[i].midi=[self midiForV:MAX(21,MIN(_vTop,[self vForMidi:_dragMidi[i]]+dRows))]; t->events[i].duration=_dragDuration[i]; }
        int moved=[self midiForV:MAX(21,MIN(_vTop,[self vForMidi:self.anchorMidi]+dRows))]; if(moved>=21 && moved<=108 && moved!=self.lastAuditioned) { self.lastAuditioned=moved; [self.owner pianoRoll:self audition:moved]; }
    }
    self.dragChanged=YES; [self normalize]; self.needsDisplay=YES;
}
- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if(self.dragMode==DRAG_MOVE || self.dragMode==DRAG_RESIZE) { if(self.dragChanged) [self commit]; }
    if(self.dragMode==DRAG_MARQUEE) { self.marquee=NSZeroRect; self.needsDisplay=YES; }
    self.dragMode=DRAG_NONE;
}
- (void)rightMouseDown:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; BOOL edge; NSUInteger index=[self noteIndexAtPoint:p edge:&edge];
    if(index!=NSNotFound && !_selected[index]) { memset(_selected,0,sizeof(_selected)); _selected[index]=YES; [self updateToolbar]; self.needsDisplay=YES; }
    if(![self selectedCount]) return;
    NSMenu *menu=[[NSMenu alloc] initWithTitle:T(@"Ноты")];
    [menu addItemWithTitle:T(@"Удалить") action:@selector(deleteAction:) keyEquivalent:@""].target=self;
    [menu addItemWithTitle:T(@"Дублировать  ⌘D") action:@selector(duplicateAction:) keyEquivalent:@""].target=self;
    [menu addItemWithTitle:T(@"В левую руку") action:@selector(toLeftHand:) keyEquivalent:@""].target=self;
    [menu addItemWithTitle:T(@"В правую руку") action:@selector(toRightHand:) keyEquivalent:@""].target=self;
    [menu addItemWithTitle:T(@"Громче") action:@selector(louder:) keyEquivalent:@""].target=self;
    [menu addItemWithTitle:T(@"Тише") action:@selector(softer:) keyEquivalent:@""].target=self;
    [menu addItemWithTitle:T(@"Квантовать") action:@selector(quantize:) keyEquivalent:@""].target=self;
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}
/* The shortcuts card belongs to the window (⌘/ works everywhere); the roll only opens and closes it. */
- (void)toggleHelp:(id)sender { (void)sender; [self.owner pianoRollToggleShortcuts:self]; }
- (BOOL)showHelp { return [self.owner pianoRollShortcutsVisible:self]; }
- (void)setShowHelp:(BOOL)showHelp { if(showHelp!=self.showHelp) [self.owner pianoRollToggleShortcuts:self]; }
- (void)duplicateAction:(id)sender { (void)sender; [self duplicateSelected]; }
- (void)toLeftHand:(id)sender { (void)sender; [self setHand:0 forSelected:YES]; }
- (void)toRightHand:(id)sender { (void)sender; [self setHand:1 forSelected:YES]; }
- (void)louder:(id)sender { (void)sender; [self changeVelocityOfSelectedBy:.1f]; }
- (void)softer:(id)sender { (void)sender; [self changeVelocityOfSelectedBy:-.1f]; }
- (void)scrollWheel:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    if(event.modifierFlags&NSEventModifierFlagCommand) {
        // macOS turns a vertical wheel into a horizontal one while ⇧ is held, so take whichever axis moved.
        double raw=fabs(event.scrollingDeltaY)>=fabs(event.scrollingDeltaX)?event.scrollingDeltaY:event.scrollingDeltaX;
        double delta=event.hasPreciseScrollingDeltas?raw/60.0:raw/6.0;
        if(event.modifierFlags&NSEventModifierFlagOption) [self zoomRowsBy:pow(1.5,-delta) aroundY:p.y]; else [self zoomBy:pow(1.5,-delta) aroundX:p.x];
        return;
    }
    if((event.modifierFlags&NSEventModifierFlagShift) || fabs(event.scrollingDeltaX)>fabs(event.scrollingDeltaY)) { double dx=(event.modifierFlags&NSEventModifierFlagShift) && fabs(event.scrollingDeltaX)<fabs(event.scrollingDeltaY)?event.scrollingDeltaY:event.scrollingDeltaX; if(fabs(dx)>.5) [self userMovedTimeView]; self.scrollBeat-=dx*(event.hasPreciseScrollingDeltas?1:12)/[self pixelsPerBeat]; }
    else self.topPitch+=event.hasPreciseScrollingDeltas?event.scrollingDeltaY/self.rowHeight:event.scrollingDeltaY*2; // trackpads move by pixels, wheels by notches
    [self clampView]; self.needsDisplay=YES;
}
- (void)magnifyWithEvent:(NSEvent *)event {
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    if(event.modifierFlags&NSEventModifierFlagOption) [self zoomRowsBy:1+event.magnification aroundY:p.y]; else [self zoomBy:1+event.magnification aroundX:p.x];
}
- (void)keyDown:(NSEvent *)event {
    if([self.owner pianoRollPlayKey:event]) return;   // computer keyboard mode takes the note keys (and M)
    NSEventModifierFlags flags=event.modifierFlags; unsigned short code=event.keyCode;
    if(flags&NSEventModifierFlagCommand) {
        if(code==44) { [self.owner pianoRollToggleShortcuts:self]; return; } // ⌘/
        if(code==3) { self.follow=!self.follow; return; }               // ⌘F
        if(code==0) { [self selectAll]; return; }                        // ⌘A
        if(code==2) { [self duplicateSelected]; return; }                 // ⌘D
        if(code==8) { [self.owner pianoRollCopyMidi:self]; return; }      // ⌘C — MIDI clip to the pasteboard
        BOOL vertical=(flags&NSEventModifierFlagOption)!=0; CGFloat midY=NSMidY([self noteAreaRect]);
        if(code==24 || code==69) { if(vertical) [self zoomRowsBy:1.25 aroundY:midY]; else [self zoomInAction:nil]; return; }     // ⌘= / ⌘+, with ⌥ — rows
        if(code==27 || code==78) { if(vertical) [self zoomRowsBy:1/1.25 aroundY:midY]; else [self zoomOutAction:nil]; return; }  // ⌘−
        if(code==29) { [self resetView]; return; } // ⌘0 — four bars from the start, rows refitted
        if(code==6) { if(flags&NSEventModifierFlagShift) [self.owner pianoRollRedo:self]; else [self.owner pianoRollUndo:self]; return; } // ⌘Z
        [self.owner pianoRollForwardKey:event]; return;
    }
    if(code==53 && self.showHelp) { self.showHelp=NO; return; }        // Esc closes the shortcuts card
    if(code==3 && !(flags&(NSEventModifierFlagOption|NSEventModifierFlagControl|NSEventModifierFlagShift))) { self.fold=!self.fold; return; } // F
    if(code==51 || code==117) { [self deleteSelected]; return; }
    if(code==123 || code==124 || code==125 || code==126) {
        double step=self.gridBeats>0?self.gridBeats:.25;
        if(![self selectedCount]) {
            // Nothing selected: the arrows scroll the view (they never change the key from inside the editor).
            if(code==125) self.topPitch-=3; else if(code==126) self.topPitch+=3; else self.scrollBeat+=(code==124?1:-1)*step*4;
            [self clampView]; self.needsDisplay=YES; return;
        }
        if(code==123) [self moveSelectedBy:-step semitones:0];
        else if(code==124) [self moveSelectedBy:step semitones:0];
        else if(flags&NSEventModifierFlagOption) [self changeVelocityOfSelectedBy:code==126?.1f:-.1f];
        else if(flags&NSEventModifierFlagShift) [self moveSelectedBy:0 semitones:code==126?12:-12];
        else [self moveSelectedByRows:code==126?1:-1];
        return;
    }
    [self.owner pianoRollForwardKey:event];
}
// ---- drawing ----
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; NSRect area=[self noteAreaRect]; KvPerformance *t=self.track;
    [TNSurface() setFill]; RollFill(self.bounds);
    double total=[self totalBeats],bar=[self.owner pianoRollBeatsPerBar:self]; if(bar<=0) bar=4;
    NSColor *black=[NSColor.labelColor colorWithAlphaComponent:.06],*line=[NSColor.labelColor colorWithAlphaComponent:.10],*strong=[NSColor.labelColor colorWithAlphaComponent:.28];
    [self ensureRows]; int highest=(int)floor(self.topPitch),lowest=(int)floor(self.topPitch-area.size.height/self.rowHeight)-1;
    [NSGraphicsContext saveGraphicsState]; NSRectClip(NSMakeRect(0,area.origin.y,NSWidth(self.bounds),area.size.height));
    // Rows. Without the scale: black-key rows shaded. With it (as Ableton's Scale): rows of the selected scale tinted,
    // the tonic stronger, rows outside the scale dimmed. Octave lines at every C either way.
    int tonic=0; unsigned scale=self.showScale?[self.owner pianoRollScale:self tonic:&tonic]:0;
    BOOL dark=[[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
    NSColor *inScale=[TNAccent() colorWithAlphaComponent:dark?.24:.15],*tonicRow=[TNAccent() colorWithAlphaComponent:dark?.46:.34];
    NSColor *outScale=dark?[NSColor.blackColor colorWithAlphaComponent:.48]:[NSColor.labelColor colorWithAlphaComponent:.16];
    for(int v=highest;v>=lowest;v--) {
        if(v<21 || v>_vTop) continue; int midi=_midiOfV[v],pc=midi%12; BOOL isBlack=pc==1||pc==3||pc==6||pc==8||pc==10;
        BOOL member=scale && (scale>>pc&1u),isTonic=scale && pc==tonic;
        NSRect row=NSMakeRect(area.origin.x,[self yForV:v],area.size.width,self.rowHeight);
        if(scale) { [(isTonic?tonicRow:member?inScale:outScale) setFill]; RollFill(row); }
        else if(isBlack) { [black setFill]; RollFill(row); }
        if(pc==0) { [strong setFill]; RollFill(NSMakeRect(row.origin.x,NSMaxY(row)-1,row.size.width,1)); }
        // Key strip: a piano key; scale notes carry an accent mark at the edge and their name.
        NSRect key=NSMakeRect(2,row.origin.y,KvKeysW-6,self.rowHeight);
        [(isBlack?[NSColor colorWithWhite:.2 alpha:1]:[NSColor colorWithWhite:.97 alpha:1]) setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(key,0,.5) xRadius:2 yRadius:2] fill];
        if(member) { [[TNAccent() colorWithAlphaComponent:isTonic?1:.7] setFill]; RollFill(NSMakeRect(NSMaxX(key)-7,row.origin.y+1,7,self.rowHeight-2)); }
        NSString *name=[self.owner pianoRoll:self nameForMidi:midi];
        if(scale && member && self.rowHeight>=9) {
            NSString *text=isTonic || pc==0?[NSString stringWithFormat:@"%@%d",name,midi/12-1]:name;
            RollText(text,NSMakeRect(4,row.origin.y,KvKeysW-19,self.rowHeight),MIN(10,self.rowHeight-3),isTonic?NSFontWeightBold:NSFontWeightMedium,isTonic?TNAccent():isBlack?[NSColor colorWithWhite:.85 alpha:1]:[NSColor colorWithWhite:.35 alpha:1],NSTextAlignmentRight);
        } else if(!scale && (pc==0 || pc==5 || (self.fold && self.rowHeight>=9))) RollText([NSString stringWithFormat:@"%@%d",name,midi/12-1],NSMakeRect(6,row.origin.y,KvKeysW-12,self.rowHeight),MIN(10,self.rowHeight-3),NSFontWeightMedium,[NSColor colorWithWhite:.35 alpha:1],NSTextAlignmentRight);
    }
    [NSGraphicsContext restoreGraphicsState];
    // Grid: subdivisions, beats, bars; ruler with bar numbers and chord names.
    [NSGraphicsContext saveGraphicsState]; NSRectClip(NSMakeRect(area.origin.x,KvToolbarH,area.size.width,NSHeight(self.bounds)-KvToolbarH));
    double grid=self.gridBeats>0?self.gridBeats:.25,ppb=[self pixelsPerBeat];
    if(grid*ppb>=6) for(double b=0;b<total+1e-9;b+=grid) { CGFloat x=round([self xForBeat:b])+.5; if(x<area.origin.x-1 || x>NSMaxX(area)) continue; [[NSColor.labelColor colorWithAlphaComponent:.05] setFill]; RollFill(NSMakeRect(x,area.origin.y,1,area.size.height)); }
    for(double b=0;b<=total+1e-9;b+=1) { CGFloat x=round([self xForBeat:b])+.5; if(x<area.origin.x-1 || x>NSMaxX(area)+1) continue; BOOL barline=fabs(fmod(b+1e-9,bar))<1e-6; [(barline?strong:line) setFill]; RollFill(NSMakeRect(x,KvToolbarH+(barline?0:KvRulerH-6),1,NSHeight(self.bounds)-KvToolbarH-(barline?0:KvRulerH-6))); }
    double first=[self.owner respondsToSelector:@selector(pianoRollFirstBar:)]?[self.owner pianoRollFirstBar:self]:1;   // a song's section counts the song's bars
    for(double b=0,n=first;b<total-1e-9;b+=bar,n++) RollText([NSString stringWithFormat:@"%.0f",n],NSMakeRect([self xForBeat:b]+4,KvToolbarH+2,40,12),10,NSFontWeightSemibold,NSColor.secondaryLabelColor,NSTextAlignmentLeft);
    if(t) { NSArray<NSString *> *names=[self.owner pianoRollChordNames:self]; double bpc=t->beats_per_chord;
        for(size_t c=0;c<t->chord_count && c<names.count;c++) { CGFloat x0=[self xForBeat:c*bpc],x1=[self xForBeat:(c+1)*bpc]; [[TNAccent() colorWithAlphaComponent:c%2?.07:.12] setFill]; RollFill(NSMakeRect(x0,KvToolbarH+KvRulerH-12,x1-x0,12)); RollText(names[c],NSMakeRect(x0+4,KvToolbarH+KvRulerH-13,x1-x0-8,12),10,NSFontWeightSemibold,TNAccent(),NSTextAlignmentLeft); } }
    // Notes, clipped to the note area so a partly scrolled top row never covers the ruler.
    // Melody notes outside their chord are coloured by what they are: passing (pink) or anticipation (violet).
    [self updateRoles]; BOOL anyRole=NO;
    [NSGraphicsContext saveGraphicsState]; NSRectClip(area);
    if(t) for(size_t i=0;i<t->count;i++) {
        KvPianoEvent e=t->events[i]; int v=[self vForMidi:e.midi]; if(v>highest || v<lowest) continue;   // cull by row, not pitch (folded rows)
        NSRect r=[self rectForNote:i]; if(NSMaxX(r)<area.origin.x || r.origin.x>NSMaxX(area)) continue;
        unsigned char role=_roles[i]; anyRole|=role!=KV_ROLE_CHORD;
        NSColor *base=role==KV_ROLE_PASSING?TNPassing():role==KV_ROLE_ANTICIPATION?TNAnticipation():e.hand?TNAccent():[NSColor colorWithCalibratedRed:0 green:.55 blue:.42 alpha:1];
        NSBezierPath *path=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r,.5,.5) xRadius:1.5 yRadius:1.5];
        [[base colorWithAlphaComponent:.45+.55*e.velocity] setFill]; [path fill];
        [[base blendedColorWithFraction:.35 ofColor:NSColor.blackColor] setStroke]; path.lineWidth=1; [path stroke];
        if(_selected[i]) { NSBezierPath *ring=[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r,-1,-1) xRadius:2.5 yRadius:2.5]; [NSColor.labelColor setStroke]; ring.lineWidth=1.5; [ring stroke]; }
        else if((NSInteger)i==self.hoverIndex) { [[NSColor.labelColor colorWithAlphaComponent:.6] setStroke]; [path stroke]; }
        NSString *label=[self.owner pianoRoll:self nameForMidi:e.midi];
        if(role && r.size.width>=64) label=[label stringByAppendingString:role==KV_ROLE_PASSING?T(@" · прох."):T(@" · предв.")];
        if(r.size.width>=26 && self.rowHeight>=12) RollText(label,NSMakeRect(r.origin.x+3,r.origin.y,r.size.width-6,r.size.height),MIN(10,self.rowHeight-4),NSFontWeightSemibold,NSColor.whiteColor,NSTextAlignmentLeft);
        if(e.fill) { [NSColor.whiteColor setFill]; RollFill(NSMakeRect(r.origin.x+2,NSMaxY(r)-3,3,2)); }
    }
    [NSGraphicsContext restoreGraphicsState];
    if(anyRole) { // legend in the lower right corner of the note area
        NSDictionary *font=@{NSFontAttributeName:[NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium]};
        CGFloat w1=[T(@"проходящая") sizeWithAttributes:font].width,w2=[T(@"предвосхищение") sizeWithAttributes:font].width,w=w1+w2+58;
        NSRect box=NSMakeRect(NSMaxX(area)-w-8,NSMaxY(area)-26,w,20);
        NSBezierPath *frame=[NSBezierPath bezierPathWithRoundedRect:box xRadius:6 yRadius:6]; [[TNSurface() colorWithAlphaComponent:.92] setFill]; [frame fill];
        [[NSColor.labelColor colorWithAlphaComponent:.15] setStroke]; [frame stroke];
        CGFloat x=box.origin.x+8;
        [TNPassing() setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,box.origin.y+6,12,8) xRadius:2 yRadius:2] fill];
        RollText(T(@"проходящая"),NSMakeRect(x+16,box.origin.y+3,w1+4,14),10.5,NSFontWeightMedium,NSColor.secondaryLabelColor,NSTextAlignmentLeft); x+=w1+26;
        [TNAnticipation() setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,box.origin.y+6,12,8) xRadius:2 yRadius:2] fill];
        RollText(T(@"предвосхищение"),NSMakeRect(x+16,box.origin.y+3,w2+4,14),10.5,NSFontWeightMedium,NSColor.secondaryLabelColor,NSTextAlignmentLeft);
    }
    if(self.dragMode==DRAG_MARQUEE && !NSIsEmptyRect(self.marquee)) { [[TNAccent() colorWithAlphaComponent:.12] setFill]; NSRectFillUsingOperation(self.marquee,NSCompositingOperationSourceOver); [[TNAccent() colorWithAlphaComponent:.7] setStroke]; [NSBezierPath strokeRect:NSInsetRect(self.marquee,.5,.5)]; }
    // Playhead.
    if(self.playheadBeat>=0) { CGFloat x=round([self xForBeat:self.playheadBeat]); [NSColor.systemOrangeColor setFill]; RollFill(NSMakeRect(x,KvToolbarH,2,NSHeight(self.bounds)-KvToolbarH)); }
    [NSGraphicsContext restoreGraphicsState];
    if(!t || !t->count) RollText(T(@"Пусто · двойной щелчок — нота · кнопка ↺ — заполнить дорожку текущим рисунком"),NSMakeRect(area.origin.x,NSMidY(area)-9,area.size.width,18),12,NSFontWeightRegular,NSColor.secondaryLabelColor,NSTextAlignmentCenter);
    [[NSColor.labelColor colorWithAlphaComponent:.15] setFill]; RollFill(NSMakeRect(0,KvToolbarH-1,NSWidth(self.bounds),1)); RollFill(NSMakeRect(KvKeysW-1,KvToolbarH,1,NSHeight(self.bounds)-KvToolbarH));
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityLabel { return T(@"Пиано-ролл. Двойной щелчок по пустому месту добавляет ноту, по ноте — удаляет. Перетаскивание двигает, с Option копирует, правый край меняет длину, Command-D дублирует, Delete удаляет."); }
- (NSString *)accessibilityValue { return self.stats.stringValue; }
@end
