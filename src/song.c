#include "song.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *kv_section_kind_name(KvSectionKind kind) {
    static const char *names[KV_SECTION_KINDS]={"Интро","Куплет","Припев","Яма","Переход","Концовка","Бридж"};
    return kind>=0 && kind<KV_SECTION_KINDS?names[kind]:"";
}
const char *kv_transition_name(KvTransitionKind kind) {
    static const char *names[KV_TRANSITION_KINDS]={"Подъём","Доминанта","Проигрыш","Пауза"};
    return kind>=0 && kind<KV_TRANSITION_KINDS?names[kind]:"";
}
bool kv_section_valid(const KvSection *s) {
    if(!s || !s->id || s->kind<0 || s->kind>=KV_SECTION_KINDS || !s->count || s->count>8 || s->repeats<1 || s->repeats>KV_SECTION_REPEATS) return false;
    for(size_t i=0;i<s->count;i++) if(!kv_code_valid(s->codes[i])) return false;
    if(!memchr(s->name,0,sizeof(s->name))) return false;
    if(!isfinite(s->level) || s->level<.5f-1e-6f || s->level>1.2f+1e-6f) return false;
    if(s->beat<0 || s->beat>=KV_SECTION_BEAT_KINDS || s->beat_fixed<0 || s->beat_fixed>=KV_BEAT_COUNT) return false;
    if(s->lift!=0 && s->lift!=12 && s->lift!=-12) return false;
    if(s->transition<0 || s->transition>=KV_TRANSITION_KINDS) return false;
    if(!isfinite(s->length) || (s->length!=0 && (s->length<.125-1e-9 || s->length>512)) || !isfinite(s->start) || s->start<0 || s->start>=64) return false;
    for(int t=0;t<KV_TRACKS;t++) { const KvRegion *r=&s->regions[t];
        if(!isfinite(r->level) || r->level<.5f-1e-6f || r->level>1.2f+1e-6f || !isfinite(r->shift) || fabs(r->shift)>32) return false; }
    const KvArrangement *a=&s->arrangement;
    return a->style>=0 && a->style<KV_PATTERN_COUNT && a->length>=0 && a->length<KV_LENGTH_COUNT && a->fills>=0 && a->fills<KV_FILL_COUNT
        && a->arpeggio_pattern>=0 && a->arpeggio_pattern<KV_ARP_COUNT && a->division>=0 && a->division<KV_DIV_COUNT && a->strings>=0 && a->strings<KV_STRINGS_COUNT;
}
bool kv_song_valid(const KvSong *song) {
    if(!song || song->meter<0 || song->meter>=KV_METER_COUNT || !isfinite(song->bpm) || song->bpm<20 || song->bpm>300) return false;
    if(song->keyboard_base<36 || song->keyboard_base>84 || song->keyboard_base%12 || song->extension<0 || song->extension>4 || song->count>KV_SONG_SECTIONS) return false;
    for(int t=0;t<KV_TRACKS;t++) if(!isfinite(song->track_level[t]) || song->track_level[t]<0 || song->track_level[t]>1.2f+1e-6f) return false;
    if(!isfinite(song->cycle_from) || !isfinite(song->cycle_to) || song->cycle_from<0) return false;
    for(size_t i=0;i<song->count;i++) {
        if(!kv_section_valid(&song->sections[i]) || song->sections[i].start>=kv_section_pass_beats(song,&song->sections[i])) return false;
        for(size_t j=0;j<i;j++) if(song->sections[j].id==song->sections[i].id) return false;
    }
    return true;
}
void kv_song_reset(KvSong *song) {
    if(!song) return; KvSong keep=*song; memset(song,0,sizeof(*song));
    song->key=keep.key; song->meter=keep.meter; song->bpm=keep.bpm; song->keyboard_base=keep.keyboard_base; song->extension=keep.extension;
    for(int t=0;t<KV_TRACKS;t++) song->track_level[t]=1;
}
double kv_section_chord_beats(const KvSong *song,const KvSection *s) { return kv_chord_beats(song->meter,s->arrangement.length); }
double kv_section_pass_beats(const KvSong *song,const KvSection *s) { return s->count*kv_section_chord_beats(song,s); }
double kv_section_beats(const KvSong *song,size_t index) {
    if(!song || index>=song->count) return 0;
    const KvSection *s=&song->sections[index]; return s->length>0?s->length:kv_section_pass_beats(song,s)*s->repeats;
}
double kv_section_start(const KvSong *song,size_t index) {
    double t=0; for(size_t i=0;song && i<index && i<song->count;i++) t+=kv_section_beats(song,i); return t;
}
double kv_song_beats(const KvSong *song) { return song?kv_section_start(song,song->count):0; }
size_t kv_song_section_at(const KvSong *song,double beat,double *offset) {
    double t=0; size_t i=0;
    for(;song && i<song->count;i++) { double length=kv_section_beats(song,i); if(beat<t+length-1e-9) break; t+=length; }
    if(offset) *offset=beat-t;
    return i;
}

/* The break: the chord struck once for a beat, silence, then two scale notes leading up into the next section's root. */
static bool break_notes(const KvSong *song,size_t index,const KvChord *chord,KvPerformance *out) {
    double bar=kv_meter_bar(song->meter),length=kv_chord_beats(song->meter,song->sections[index].arrangement.length);
    out->chord_count=1; out->beats_per_chord=length; out->beats_per_bar=bar; out->total_beats=length;
    int voiced[8]; size_t n=kv_chord_voiced(chord,voiced);
    for(size_t v=0;v<n && out->count<KV_PERFORMANCE_CAPACITY;v++) { int m=voiced[v]; while(m>108) m-=12;
        out->events[out->count++]=(KvPianoEvent){.midi=m,.beat=0,.duration=fmin(1,length),.velocity=.85f,.chord=0,.hand=v?1u:0u}; }
    int target=-1; KvChord next;
    if(index+1<song->count && kv_code_chord(song->key,song->sections[index+1].codes[0],song->extension,&next)) target=next.midi[0]%12;
    else target=kv_tonic(song->key);
    int root=song->keyboard_base+12+((target-song->keyboard_base%12)+12)%12, steps[2]={root,root};
    for(int k=0;k<2;k++) { int m=(k?steps[0]:root)-1; while(m>21 && !kv_in_scale(song->key,m)) m--; steps[k]=m; }
    out->events[out->count++]=(KvPianoEvent){.midi=steps[1],.beat=length-.5,.duration=.25,.velocity=.7f,.chord=0,.hand=1};
    out->events[out->count++]=(KvPianoEvent){.midi=steps[0],.beat=length-.25,.duration=.25,.velocity=.75f,.chord=0,.hand=1};
    return kv_performance_valid(out);
}
bool kv_section_notes(const KvSong *song,size_t index,KvPerformance *out) {
    if(!out) return false; memset(out,0,sizeof(*out));
    if(!kv_song_valid(song) || index>=song->count) return false;
    const KvSection *s=&song->sections[index]; KvChord chords[8];
    for(size_t c=0;c<s->count;c++) {
        if(!kv_code_chord(song->key,s->codes[c],song->extension,&chords[c])) return false;
        for(size_t v=0;v<chords[c].count;v++) chords[c].midi[v]+=song->keyboard_base-60;
    }
    KvArrangement a=s->arrangement; a.meter=song->meter; a.preview=false; a.seconds_per_beat=60.0/song->bpm;
    if(s->kind==KV_SECTION_TRANSITION && s->transition==KV_TRANSITION_BREAK) return break_notes(song,index,chords,out);
    if(!kv_arrange_with(chords,s->count,song->keyboard_base,song->key,a,out)) return false;
    if(s->kind==KV_SECTION_TRANSITION && s->transition==KV_TRANSITION_RISE)   // a crescendo up to the next section
        for(size_t i=0;i<out->count;i++) out->events[i].velocity=(float)fmin(1,fmax(.4,.5+.5*out->events[i].beat/out->total_beats));
    if(s->lift) for(size_t i=0;i<out->count;i++) {
        KvPianoEvent *e=&out->events[i];
        if(s->lift>0 && !e->hand) continue;             // up: the right hand only; down: both
        if(e->midi+s->lift>=21 && e->midi+s->lift<=108) e->midi+=s->lift;
    }
    return kv_performance_valid(out);
}
bool kv_section_plan(const KvSong *song,size_t index,const KvPerformance *edited,KvPerformance *out) {
    if(!out || !song || index>=song->count) return false;
    const KvSection *s=&song->sections[index];
    if(s->edited && edited) {
        if(!kv_performance_valid(edited) || edited->chord_count!=s->count) return false;
        *out=*edited;
    } else if(!kv_section_notes(song,index,out)) return false;
    for(size_t i=0;i<out->count;i++) out->events[i].velocity=fminf(1,fmaxf(.4f,out->events[i].velocity*s->level));
    return true;
}

bool kv_region_audible(const KvSong *song,size_t index,int track) {
    if(!song || index>=song->count || track<0 || track>=KV_TRACKS) return false;
    bool solo=false; for(int t=0;t<KV_TRACKS;t++) solo|=song->track_solo[t];
    return !song->sections[index].regions[track].mute && !song->track_mute[track] && (!solo || song->track_solo[track]);
}
static int by_beat(const void *x,const void *y) {
    const KvPianoEvent *a=x,*b=y;
    if(a->beat!=b->beat) return a->beat<b->beat?-1:1;
    return a->midi<b->midi?-1:a->midi>b->midi;
}
bool kv_section_part(const KvSong *song,size_t index,const KvPerformance *edited,double from,double length,KvPerformance *out) {
    if(!out || !song || index>=song->count || !isfinite(from) || !isfinite(length) || length<=0) return false;
    const KvSection *s=&song->sections[index]; KvPerformance *pass=malloc(sizeof(KvPerformance)); if(!pass) return false;
    bool ok=s->edited && edited?kv_performance_valid(edited) && edited->chord_count==s->count:kv_section_notes(song,index,pass);
    if(ok && s->edited && edited) *pass=*edited;
    double total=kv_section_beats(song,index),cycle=pass->total_beats,end=fmin(from+length,total);
    if(!ok || cycle<=0 || from<0 || from>=total-1e-9 || end<=from) { free(pass); return false; }
    memset(out,0,sizeof(*out)); out->chord_count=pass->chord_count; out->beats_per_chord=pass->beats_per_chord;
    out->beats_per_bar=kv_meter_bar(song->meter); out->total_beats=end-from;
    double begin=fmod(s->start,cycle); if(begin<0) begin+=cycle;
    for(int track=KV_TRACK_MELODY;track<=KV_TRACK_BASS;track++) {
        if(!kv_region_audible(song,index,track)) continue;
        unsigned hand=track==KV_TRACK_MELODY?1:0; double shift=s->regions[track].shift;
        float gain=s->level*s->regions[track].level*song->track_level[track];
        // Pass k begins k cycles after the section's start, less the trim. A moved region moves what lies inside the section
        // (as a region in Logic): nothing comes in from the passes around it, and what leaves the section is cut at its edges.
        for(int k=0;k*cycle-begin<total;k++) for(size_t i=0;i<pass->count;i++) {
            KvPianoEvent e=pass->events[i]; if(e.hand!=hand) continue;
            double inside=k*cycle-begin+e.beat,at=inside+shift;
            if(inside<-1e-9 || inside>=total-1e-9 || at<-1e-9 || at>=total-1e-9 || at<from-1e-9 || at>=end-1e-9) continue;
            if(out->count>=KV_PERFORMANCE_CAPACITY) { free(pass); return false; }
            e.duration=fmin(fmin(e.duration,total-inside),total-at); e.beat=fmax(0,at-from); e.velocity=fminf(1,fmaxf(.4f,e.velocity*gain));
            out->events[out->count++]=e;
        }
    }
    free(pass);
    qsort(out->events,out->count,sizeof(KvPianoEvent),by_beat); kv_performance_resolve_overlaps(out);
    return true;
}

uint32_t kv_song_insert(KvSong *song,size_t index,const KvSection *section) {
    if(!song || !section || song->count>=KV_SONG_SECTIONS || index>song->count) return 0;
    KvSection s=*section; s.id=++song->next_id; if(!s.id) s.id=++song->next_id;
    if(!kv_section_valid(&s)) return 0;
    memmove(&song->sections[index+1],&song->sections[index],(song->count-index)*sizeof(KvSection));
    song->sections[index]=s; song->count++; kv_song_refresh_transitions(song); return s.id;
}
bool kv_song_remove(KvSong *song,size_t index) {
    if(!song || index>=song->count) return false;
    memmove(&song->sections[index],&song->sections[index+1],(song->count-index-1)*sizeof(KvSection)); song->count--; kv_song_refresh_transitions(song); return true;
}
bool kv_song_move(KvSong *song,size_t from,size_t to) {
    if(!song || from>=song->count || to>=song->count) return false;
    KvSection s=song->sections[from];
    if(from<to) memmove(&song->sections[from],&song->sections[from+1],(to-from)*sizeof(KvSection));
    else memmove(&song->sections[to+1],&song->sections[to],(from-to)*sizeof(KvSection));
    song->sections[to]=s; kv_song_refresh_transitions(song); return true;
}
uint32_t kv_song_duplicate(KvSong *song,size_t index) {
    if(!song || index>=song->count) return 0;
    KvSection copy=song->sections[index]; copy.name[0]=0;
    return kv_song_insert(song,index+1,&copy);
}
bool kv_song_set_repeats(KvSong *song,size_t index,int repeats) {
    if(!song || index>=song->count || repeats<1 || repeats>KV_SECTION_REPEATS) return false;
    song->sections[index].repeats=repeats; song->sections[index].length=0; return true;
}
bool kv_song_set_length(KvSong *song,size_t index,double beats) {
    if(!song || index>=song->count || !isfinite(beats) || beats<.125-1e-9 || beats>512) return false;
    KvSection *s=&song->sections[index]; double whole=kv_section_pass_beats(song,s);
    // Whole passes from the pass's start read as repeats again (the loop corner and the resize corner agree).
    double passes=beats/whole;
    if(s->start==0 && fabs(passes-round(passes))<1e-9 && round(passes)>=1 && round(passes)<=KV_SECTION_REPEATS) { s->repeats=(int)round(passes); s->length=0; }
    else s->length=beats;
    return true;
}
bool kv_song_trim_start(KvSong *song,size_t index,double beats) {
    if(!song || index>=song->count || !isfinite(beats)) return false;
    KvSection *s=&song->sections[index]; double total=kv_section_beats(song,index),cycle=kv_section_pass_beats(song,s);
    if(total-beats<.125-1e-9 || total-beats>512) return false;
    double start=fmod(s->start+beats,cycle); if(start<0) start+=cycle; if(cycle-start<1e-9) start=0;
    s->start=start; s->length=total-beats; return true;
}
double kv_song_snap_cut(const KvSong *song,size_t index,double beat,double grid) {
    if(!song || index>=song->count || !isfinite(beat) || !isfinite(grid) || grid<0) return -1;
    double begin=kv_section_start(song,index),total=kv_section_beats(song,index),at=beat;
    if(grid>0) at=round((begin+beat)/grid)*grid-begin;   // the song's grid, not the section's
    return at>=.125-1e-9 && at<=total-.125+1e-9?at:-1;
}
void kv_track_transpose(KvPerformance *track,int semitones) {
    if(!track || !semitones) return;
    for(size_t i=0;i<track->count;i++) {
        int m=track->events[i].midi+semitones; while(m>108) m-=12; while(m<21) m+=12; track->events[i].midi=m;
    }
    kv_performance_resolve_overlaps(track);   // folding an octave back can land on a note already there
}
uint32_t kv_song_cut(KvSong *song,size_t index,double beat) {
    if(!song || index>=song->count || song->count>=KV_SONG_SECTIONS) return 0;
    double total=kv_section_beats(song,index); if(!isfinite(beat) || beat<.125-1e-9 || beat>total-.125+1e-9) return 0;
    const KvSection original=song->sections[index]; KvSection right=original; right.name[0]=0;
    double cycle=kv_section_pass_beats(song,&original),start=fmod(original.start+beat,cycle); if(cycle-start<1e-9) start=0;
    song->sections[index].length=beat;
    right.start=start; right.length=total-beat;
    uint32_t made=kv_song_insert(song,index+1,&right);
    if(!made) { song->sections[index]=original; return 0; }
    kv_song_set_length(song,index,beat); kv_song_set_length(song,index+1,total-beat);   // whole passes read as repeats again
    return made;
}
KvSection kv_section_from_draft(KvSectionKind kind,const int *codes,size_t count,KvArrangement arrangement) {
    KvSection s; memset(&s,0,sizeof(s));
    s.kind=kind; s.count=count>8?8:count; if(codes) memcpy(s.codes,codes,s.count*sizeof(int));
    s.repeats=1; s.arrangement=arrangement; s.arrangement.preview=false; s.level=1; s.beat=KV_SECTION_BEAT_SONG; s.beat_fixed=KV_BEAT_POP;
    for(int t=0;t<KV_TRACKS;t++) s.regions[t].level=1;
    return s;
}

// ---- generators (spec 1.4 §4) ----
static bool minor_kind(KvKey key) { KvChord c; return kv_chord(key,0,&c) && c.midi[1]-c.midi[0]==3; }
static KvSection derived(KvSectionKind kind,const int *codes,size_t count,KvArrangement a,float level,KvSectionBeat beat,int lift) {
    KvSection s=kv_section_from_draft(kind,codes,count,a); s.level=level; s.beat=beat; s.lift=lift; return s;
}
static KvFillRate denser(KvPianoPattern style,KvFillRate fills) {
    switch(kv_fill_rate(style,fills)) { case KV_FILL_NONE: return KV_FILL_EVERY_4; case KV_FILL_EVERY_4: return KV_FILL_EVERY_2; default: return KV_FILL_EVERY_BAR; }
}
static bool hands(const KvArrangement *a) { return !a->blocks && !a->arpeggio && !a->strings; }
KvSection kv_section_chorus(const KvSong *song,const KvSection *verse,uint32_t seed) {
    static const int major[6][4]={{0,4,5,3},{5,3,0,4},{3,0,4,5},{0,3,5,4},{3,4,0,0},{0,5,3,4}};
    static const int minor[5][4]={{0,5,2,6},{0,6,5,KV_CODE_SECONDARY},{5,6,0,0},{0,3,6,2},{0,2,6,5}};
    bool m=minor_kind(song->key); const int (*turns)[4]=m?minor:major; size_t count=m?5:6,fit[6],n=0;
    int last=kv_code_base(verse->codes[verse->count-1]);
    for(size_t t=0;t<count;t++) {
        bool same=verse->count>=4; for(int k=0;same && k<4;k++) if(kv_code_base(verse->codes[k])!=turns[t][k]) same=false;
        bool opens=m?(turns[t][0]==0 || turns[t][0]==5):(turns[t][0]==0 || turns[t][0]==3 || turns[t][0]==5);
        if(!same && opens && turns[t][0]!=last) fit[n++]=t;
    }
    if(!n) for(size_t t=0;t<count;t++) { bool same=verse->count>=4; for(int k=0;same && k<4;k++) if(kv_code_base(verse->codes[k])!=turns[t][k]) same=false; if(!same) fit[n++]=t; }
    const int *turn=turns[fit[seed%n]]; int codes[8];
    for(int k=0;k<4;k++) codes[k]=codes[4+k]=turn[k];
    if(turn[3]!=0) codes[7]=0;                                         // the second time closes on the tonic
    else if(turn[2]==0) { codes[6]=m?KV_CODE_SECONDARY:4; }           // …through the dominant when it already ends there
    KvArrangement a=verse->arrangement;
    if(hands(&a)) { if(a.style==KV_AMBIENT) a.style=KV_BALLAD; a.fills=denser(a.style,a.fills); }
    if(a.arpeggio && a.division==KV_DIV_EIGHTH && song->bpm<=110) a.division=KV_DIV_SIXTEENTH;
    a.generated=true; a.seed=seed?seed:1;
    KvSection s=derived(KV_SECTION_CHORUS,codes,8,a,1.15f,verse->beat==KV_SECTION_BEAT_FIXED?KV_SECTION_BEAT_FIXED:KV_SECTION_BEAT_STYLE,song->keyboard_base<=60?12:0);
    s.beat_fixed=verse->beat_fixed; s.repeats=a.length==KV_LENGTH_BEAT?2:1; return s;
}
KvSection kv_section_pit(const KvSong *song,const KvSection *verse) {
    int codes[2]={5,3};                                                  // vi and IV (VI and iv in minor): away from the tonic
    if(kv_code_base(verse->codes[0])!=0) { codes[0]=verse->codes[0]; codes[1]=verse->count>1?verse->codes[1]:3; }
    KvArrangement a=verse->arrangement; a.length=KV_LENGTH_TWO_BARS; a.fills=KV_FILL_NONE; a.blocks=false;
    bool still=true;
    if(a.strings) a.strings=KV_STRINGS_CHORALE;
    else if(song->bpm<110) { a.arpeggio=false; a.style=KV_AMBIENT; }
    else { a.arpeggio=true; a.arpeggio_pattern=KV_ARP_UP; a.division=KV_DIV_EIGHTH; still=false; }
    return derived(KV_SECTION_PIT,codes,2,a,.7f,still?KV_SECTION_BEAT_OFF:KV_SECTION_BEAT_QUIET,0);
}
KvSection kv_section_intro(const KvSong *song,const KvSection *verse) {
    (void)song; int codes[2]={verse->codes[0],verse->count>1?verse->codes[1]:3};
    if(kv_code_base(verse->codes[0])==0) for(size_t i=1;i<verse->count;i++) if(kv_code_base(verse->codes[i])!=0) { codes[1]=verse->codes[i]; break; }
    KvArrangement a=verse->arrangement; a.length=KV_LENGTH_TWO_BARS; a.fills=KV_FILL_NONE; a.blocks=a.arpeggio=false;
    if(a.strings) a.strings=KV_STRINGS_CHORALE; else a.style=KV_AMBIENT;
    return derived(KV_SECTION_INTRO,codes,2,a,.8f,KV_SECTION_BEAT_OFF,0);
}
KvSection kv_section_outro(const KvSong *song,const KvSection *before) {
    int codes[3]={before?before->codes[before->count-1]:3,KV_CODE_SECONDARY,0};
    KvArrangement a=before?before->arrangement:(KvArrangement){0}; a.blocks=true; a.arpeggio=false; a.strings=KV_STRINGS_NONE; a.length=KV_LENGTH_BAR; a.fills=KV_FILL_NONE;
    return derived(KV_SECTION_OUTRO,codes,3,a,.9f,KV_SECTION_BEAT_OFF,song->keyboard_base<=60?12:0);
}
static int dominant_of(const KvSection *s) { int b=s?kv_code_base(s->codes[0]):0; return KV_CODE_SECONDARY+(b<=6?b:0); }
KvSection kv_section_transition(const KvSong *song,const KvSection *left,const KvSection *right,KvTransitionKind kind) {
    int code=kind==KV_TRANSITION_RISE || kind==KV_TRANSITION_DOMINANT?dominant_of(right):left?left->codes[left->count-1]:KV_CODE_SECONDARY;
    KvArrangement a=left?left->arrangement:(KvArrangement){0}; a.length=KV_LENGTH_BAR;
    switch(kind) {
        case KV_TRANSITION_RISE: a.blocks=false; a.strings=KV_STRINGS_NONE; a.arpeggio=true; a.arpeggio_pattern=KV_ARP_UP; a.division=song->bpm>130?KV_DIV_EIGHTH:KV_DIV_SIXTEENTH; break;
        case KV_TRANSITION_DOMINANT: if(hands(&a)) a.fills=KV_FILL_EVERY_BAR; break;
        case KV_TRANSITION_FILL: if(!a.strings) { a.blocks=a.arpeggio=false; a.style=KV_INTERLUDE; a.fills=KV_FILL_EVERY_BAR; } break;
        default: a.blocks=true; a.arpeggio=false; a.strings=KV_STRINGS_NONE; break;
    }
    KvSection s=derived(KV_SECTION_TRANSITION,&code,1,a,1,KV_SECTION_BEAT_SONG,0); s.transition=kind; return s;
}
KvTransitionKind kv_transition_for(const KvSection *left,const KvSection *right) {
    KvSectionKind l=left?left->kind:KV_SECTION_INTRO,r=right?right->kind:KV_SECTION_OUTRO;
    if(r==KV_SECTION_CHORUS && (l==KV_SECTION_VERSE || l==KV_SECTION_PIT)) return KV_TRANSITION_RISE;
    if(l==KV_SECTION_CHORUS && r==KV_SECTION_PIT) return KV_TRANSITION_BREAK;
    if(r==KV_SECTION_OUTRO || (l==KV_SECTION_CHORUS && r==KV_SECTION_VERSE)) return KV_TRANSITION_DOMINANT;
    return KV_TRANSITION_FILL;
}
void kv_song_refresh_transitions(KvSong *song) {
    for(size_t i=0;song && i<song->count;i++) {
        KvSection *s=&song->sections[i]; if(s->kind!=KV_SECTION_TRANSITION || s->edited) continue;
        KvSection fresh=kv_section_transition(song,i?&song->sections[i-1]:NULL,i+1<song->count?&song->sections[i+1]:NULL,s->transition);
        memcpy(s->codes,fresh.codes,sizeof(s->codes)); s->count=fresh.count; s->arrangement=fresh.arrangement;   // its length stays (a build is two bars)
    }
}
size_t kv_transition_hits(KvTransitionKind kind,KvMeter meter,KvHit hits[KV_BEAT_HITS]) {
    double bar=kv_meter_bar(meter); size_t n=0;
    if(kind==KV_TRANSITION_RISE) {
        hits[n++]=(KvHit){0,KV_DRUM_KICK,1};
        for(double t=0;t<bar-1e-9 && n<KV_BEAT_HITS;t+=.25) hits[n++]=(KvHit){t,KV_DRUM_SNARE,(float)(.3+.7*t/bar)};
    } else if(kind==KV_TRANSITION_BREAK) hits[n++]=(KvHit){0,KV_DRUM_KICK,.9f};
    return n;
}
static const KvSection *first_of(const KvSong *song,KvSectionKind kind) { for(size_t i=0;i<song->count;i++) if(song->sections[i].kind==kind) return &song->sections[i]; return NULL; }
size_t kv_song_suggest(const KvSong *song,size_t after,uint32_t seed,KvSuggestion out[4]) {
    if(!song || after>=song->count || !out) return 0;
    const KvSection *x=&song->sections[after],*verse=x->kind==KV_SECTION_VERSE?x:first_of(song,KV_SECTION_VERSE),*chorus=first_of(song,KV_SECTION_CHORUS);
    if(!verse) verse=x;
    bool last=after+1==song->count; size_t n=0;
    #define SUGGEST(made,lead,kindOfLead,source) do { if(n<4) { KvSuggestion g; memset(&g,0,sizeof(g)); g.section=(made); g.section.id=0; g.section.name[0]=0; \
        g.copy_of=(source); if(!g.copy_of) g.section.edited=false; g.lead_in=(lead); if(lead) g.transition=kv_section_transition(song,x,&g.section,(kindOfLead)); out[n++]=g; } } while(0)
    switch(x->kind) {
        case KV_SECTION_VERSE:
            SUGGEST(chorus?*chorus:kv_section_chorus(song,verse,seed),true,KV_TRANSITION_RISE,chorus?chorus->id:0);
            SUGGEST(kv_section_pit(song,verse),false,0,0);
            SUGGEST(*x,false,0,x->id);
            if(!last) SUGGEST(kv_section_transition(song,x,&song->sections[after+1],KV_TRANSITION_FILL),false,0,0);
            break;
        case KV_SECTION_CHORUS:
            SUGGEST(kv_section_pit(song,verse),false,0,0);
            SUGGEST(*verse,true,KV_TRANSITION_BREAK,verse->id);
            SUGGEST(*x,false,0,x->id);
            break;
        case KV_SECTION_PIT:
            SUGGEST(chorus?*chorus:kv_section_chorus(song,verse,seed),true,KV_TRANSITION_RISE,chorus?chorus->id:0);
            SUGGEST(*verse,false,0,verse->id);
            break;
        case KV_SECTION_INTRO: if(verse!=x) SUGGEST(*verse,false,0,verse->id); break;
        case KV_SECTION_TRANSITION:
            if(last) { SUGGEST(chorus?*chorus:kv_section_chorus(song,verse,seed),false,0,chorus?chorus->id:0); if(verse!=x) SUGGEST(*verse,false,0,verse->id); }
            break;
        default: break;
    }
    if(last && x->kind!=KV_SECTION_OUTRO && n<4) SUGGEST(kv_section_outro(song,x),x->kind!=KV_SECTION_TRANSITION,KV_TRANSITION_DOMINANT,0);
    if(after==0 && x->kind!=KV_SECTION_INTRO && !first_of(song,KV_SECTION_INTRO) && n<4) { SUGGEST(kv_section_intro(song,verse),false,0,0); out[n-1].before=true; }
    #undef SUGGEST
    return n;
}

// ---- the bridge and song forms (spec 1.5 §6) ----
KvSection kv_section_bridge(const KvSong *song,const KvSection *verse,uint32_t seed) {
    static const int major[4][4]={{3,4,5,4},{5,3,4,4},{3,5,4,4},{5,4,3,4}};
    static const int minor[4][4]={{5,6,3,KV_CODE_SECONDARY},{3,5,6,KV_CODE_SECONDARY},{5,3,6,KV_CODE_SECONDARY},{3,6,5,KV_CODE_SECONDARY}};
    bool m=minor_kind(song->key); const int (*turns)[4]=m?minor:major; size_t fit[4],n=0;
    for(size_t t=0;t<4;t++) { bool same=verse->count>=4; for(int k=0;same && k<4;k++) if(kv_code_base(verse->codes[k])!=turns[t][k]) same=false; if(!same) fit[n++]=t; }
    KvArrangement a=verse->arrangement; a.generated=true; a.seed=seed+7;
    KvSection s=derived(KV_SECTION_BRIDGE,turns[fit[seed%n]],4,a,1.05f,verse->beat==KV_SECTION_BEAT_FIXED?KV_SECTION_BEAT_FIXED:KV_SECTION_BEAT_STYLE,song->keyboard_base<=60?12:0);
    s.beat_fixed=verse->beat_fixed;
    double four=4*kv_meter_bar(song->meter); if(fabs(kv_section_pass_beats(song,&s)-four)>1e-9) s.length=four;   // four bars whatever the chord length
    return s;
}
size_t kv_song_forms(const KvForm **forms) {
    enum { I=KV_SECTION_INTRO, V=KV_SECTION_VERSE, C=KV_SECTION_CHORUS, P=KV_SECTION_PIT, O=KV_SECTION_OUTRO, B=KV_SECTION_BRIDGE, U=KV_FORM_BUILD, D=KV_FORM_DROP };
    static const KvForm table[]={{{I,V,C,V,C,B,C,C},8},{{I,V,C,P,V,C,C,O},8},{{I,V,V,C,V,C,B,C,O},9},{{I,U,D,P,U,D,O},7},{{V,C,V,C},4}};
    if(forms) *forms=table; return sizeof(table)/sizeof(table[0]);
}
const char *kv_form_name(size_t index) {
    static const char *names[]={"Поп","С ямой","Баллада","Танцевальная","Короткая"};
    return index<sizeof(names)/sizeof(names[0])?names[index]:"";
}
const char *kv_form_label(int slot) { return slot==KV_FORM_BUILD?"Билд":slot==KV_FORM_DROP?"Дроп":""; }
bool kv_form_slot_valid(int slot) {
    return (slot>=0 && slot<KV_SECTION_KINDS) || (slot>=KV_FORM_TRANSITION && slot<KV_FORM_TRANSITION+KV_TRANSITION_KINDS) || slot==KV_FORM_BUILD || slot==KV_FORM_DROP;
}
bool kv_song_apply_form(KvSong *song,const int *slots,size_t count,size_t verse,uint32_t seed,uint32_t *copy_of) {
    if(!song || !slots || !count || count>KV_FORM_SLOTS || verse>=song->count || !copy_of) return false;
    for(size_t k=0;k<count;k++) if(!kv_form_slot_valid(slots[k])) return false;
    KvSong *old=malloc(sizeof(KvSong)),*result=malloc(sizeof(KvSong)); KvSection *made=malloc(KV_SONG_SECTIONS*sizeof(KvSection));
    if(!old || !result || !made) { free(old); free(result); free(made); return false; }
    *old=*song;
    const KvSection *v=&old->sections[verse],*chorus=NULL;
    for(size_t i=0;i<old->count && !chorus;i++) if(old->sections[i].kind==KV_SECTION_CHORUS) chorus=&old->sections[i];
    KvSection refrain=chorus?*chorus:kv_section_chorus(old,v,seed);
    bool used[KV_SONG_SECTIONS]={false},kept[KV_SONG_SECTIONS]={false}; uint32_t source[KV_SONG_SECTIONS]={0}; size_t n=0;
    for(size_t k=0;k<count && n<KV_SONG_SECTIONS;k++) {
        int slot=slots[k]; KvSection x; uint32_t from=0; bool keep=false,transition=false; const KvSection *prev=n?&made[n-1]:NULL;
        if(slot==KV_FORM_BUILD || (slot>=KV_FORM_TRANSITION && slot<KV_FORM_TRANSITION+KV_TRANSITION_KINDS)) {
            x=kv_section_transition(old,prev,NULL,slot==KV_FORM_BUILD?KV_TRANSITION_RISE:(KvTransitionKind)(slot-KV_FORM_TRANSITION)); transition=true;
            if(slot==KV_FORM_BUILD) { x.repeats=2; snprintf(x.name,sizeof(x.name),"%s",kv_form_label(slot)); }
        } else {
            KvSectionKind kind=slot==KV_FORM_DROP?KV_SECTION_CHORUS:(KvSectionKind)slot;
            // A section edited by hand fills the first slot of its kind.
            for(size_t i=0;slot!=KV_FORM_DROP && !keep && i<old->count;i++) if(!used[i] && old->sections[i].edited && old->sections[i].kind==kind) { x=old->sections[i]; used[i]=keep=true; }
            if(!keep) switch(kind) {
                case KV_SECTION_VERSE: x=*v; from=v->id; break;
                case KV_SECTION_CHORUS: x=refrain; from=chorus?chorus->id:0; break;
                case KV_SECTION_PIT: x=kv_section_pit(old,v); break;
                case KV_SECTION_INTRO: x=kv_section_intro(old,v); break;
                case KV_SECTION_OUTRO: x=kv_section_outro(old,prev?prev:v); break;
                case KV_SECTION_BRIDGE: x=kv_section_bridge(old,v,seed); break;
                default: x=kv_section_transition(old,prev,NULL,KV_TRANSITION_FILL); transition=true; break;
            }
            if(slot==KV_FORM_DROP) { x.beat=KV_SECTION_BEAT_FIXED; x.beat_fixed=KV_BEAT_HOUSE; snprintf(x.name,sizeof(x.name),"%s",kv_form_label(slot)); }
            if(!keep && !from) x.edited=false;
        }
        // Between neighbours that call for it: a rise into a chorus, a break into a breakdown, a dominant into a verse or outro.
        if(prev && !transition && prev->kind!=KV_SECTION_TRANSITION && n<KV_SONG_SECTIONS-1) {
            KvTransitionKind way=kv_transition_for(prev,&x);
            if(way!=KV_TRANSITION_FILL) { made[n]=kv_section_transition(old,prev,&x,way); kept[n]=false; source[n]=0; n++; }
        }
        made[n]=x; kept[n]=keep; source[n]=keep?0:from; n++;
    }
    for(size_t i=0;i<old->count && n<KV_SONG_SECTIONS;i++) if(old->sections[i].edited && !used[i]) { made[n]=old->sections[i]; kept[n]=true; source[n]=0; n++; }   // the rest of the hand-edited ones, at the end
    *result=*old; result->count=0;
    for(size_t k=0;k<n;k++) {
        if(!kept[k]) { made[k].id=++result->next_id; if(!made[k].id) made[k].id=++result->next_id; }
        result->sections[result->count++]=made[k]; copy_of[k]=source[k];
    }
    for(size_t k=n;k<KV_SONG_SECTIONS;k++) copy_of[k]=0;
    kv_song_refresh_transitions(result);
    bool ok=kv_song_valid(result); if(ok) *song=*result;
    free(old); free(result); free(made); return ok;
}
