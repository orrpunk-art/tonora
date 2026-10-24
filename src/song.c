#include "song.h"
#include <math.h>
#include <string.h>

const char *kv_section_kind_name(KvSectionKind kind) {
    static const char *names[KV_SECTION_KINDS]={"Интро","Куплет","Припев","Яма","Переход","Концовка"};
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
    const KvArrangement *a=&s->arrangement;
    return a->style>=0 && a->style<KV_PATTERN_COUNT && a->length>=0 && a->length<KV_LENGTH_COUNT && a->fills>=0 && a->fills<KV_FILL_COUNT
        && a->arpeggio_pattern>=0 && a->arpeggio_pattern<KV_ARP_COUNT && a->division>=0 && a->division<KV_DIV_COUNT && a->strings>=0 && a->strings<KV_STRINGS_COUNT;
}
bool kv_song_valid(const KvSong *song) {
    if(!song || song->meter<0 || song->meter>=KV_METER_COUNT || !isfinite(song->bpm) || song->bpm<20 || song->bpm>300) return false;
    if(song->keyboard_base<36 || song->keyboard_base>84 || song->keyboard_base%12 || song->extension<0 || song->extension>4 || song->count>KV_SONG_SECTIONS) return false;
    for(size_t i=0;i<song->count;i++) {
        if(!kv_section_valid(&song->sections[i])) return false;
        for(size_t j=0;j<i;j++) if(song->sections[j].id==song->sections[i].id) return false;
    }
    return true;
}
double kv_section_chord_beats(const KvSong *song,const KvSection *s) { return kv_chord_beats(song->meter,s->arrangement.length); }
double kv_section_pass_beats(const KvSong *song,const KvSection *s) { return s->count*kv_section_chord_beats(song,s); }
double kv_section_beats(const KvSong *song,size_t index) {
    if(!song || index>=song->count) return 0;
    const KvSection *s=&song->sections[index]; return kv_section_pass_beats(song,s)*s->repeats;
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

bool kv_section_notes(const KvSong *song,size_t index,KvPerformance *out) {
    if(!out) return false; memset(out,0,sizeof(*out));
    if(!kv_song_valid(song) || index>=song->count) return false;
    const KvSection *s=&song->sections[index]; KvChord chords[8];
    for(size_t c=0;c<s->count;c++) {
        if(!kv_code_chord(song->key,s->codes[c],song->extension,&chords[c])) return false;
        for(size_t v=0;v<chords[c].count;v++) chords[c].midi[v]+=song->keyboard_base-60;
    }
    KvArrangement a=s->arrangement; a.meter=song->meter; a.preview=false; a.seconds_per_beat=60.0/song->bpm;
    if(!kv_arrange_with(chords,s->count,song->keyboard_base,song->key,a,out)) return false;
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

uint32_t kv_song_insert(KvSong *song,size_t index,const KvSection *section) {
    if(!song || !section || song->count>=KV_SONG_SECTIONS || index>song->count) return 0;
    KvSection s=*section; s.id=++song->next_id; if(!s.id) s.id=++song->next_id;
    if(!kv_section_valid(&s)) return 0;
    memmove(&song->sections[index+1],&song->sections[index],(song->count-index)*sizeof(KvSection));
    song->sections[index]=s; song->count++; return s.id;
}
bool kv_song_remove(KvSong *song,size_t index) {
    if(!song || index>=song->count) return false;
    memmove(&song->sections[index],&song->sections[index+1],(song->count-index-1)*sizeof(KvSection)); song->count--; return true;
}
bool kv_song_move(KvSong *song,size_t from,size_t to) {
    if(!song || from>=song->count || to>=song->count) return false;
    KvSection s=song->sections[from];
    if(from<to) memmove(&song->sections[from],&song->sections[from+1],(to-from)*sizeof(KvSection));
    else memmove(&song->sections[to+1],&song->sections[to],(from-to)*sizeof(KvSection));
    song->sections[to]=s; return true;
}
uint32_t kv_song_duplicate(KvSong *song,size_t index) {
    if(!song || index>=song->count) return 0;
    KvSection copy=song->sections[index]; copy.name[0]=0;
    return kv_song_insert(song,index+1,&copy);
}
bool kv_song_set_repeats(KvSong *song,size_t index,int repeats) {
    if(!song || index>=song->count || repeats<1 || repeats>KV_SECTION_REPEATS) return false;
    song->sections[index].repeats=repeats; return true;
}

/* Chords per cut step: the fewest chords that end on a bar line (3/4 with two-beat chords: three chords, two bars). */
static size_t cut_step(const KvSong *song,const KvSection *s) {
    double chord=kv_section_chord_beats(song,s),bar=kv_meter_bar(song->meter);
    for(size_t k=1;k<=8;k++) { double r=k*chord/bar; if(fabs(r-round(r))<1e-9) return k; }
    return 8;
}
static bool unrollable(const KvSection *s) { return s->repeats==1 || s->count*(size_t)s->repeats<=8; }
double kv_song_snap_cut(const KvSong *song,size_t index,double beat) {
    if(!song || index>=song->count) return -1;
    const KvSection *s=&song->sections[index];
    double total=kv_section_beats(song,index),step=unrollable(s)?cut_step(song,s)*kv_section_chord_beats(song,s):kv_section_pass_beats(song,s);
    double best=-1; for(double t=step;t<total-1e-9;t+=step) if(best<0 || fabs(t-beat)<fabs(best-beat)) best=t;
    return best;
}
bool kv_track_repeat(const KvPerformance *track,int times,KvPerformance *out) {
    if(!track || !out || times<1 || track->chord_count*(size_t)times>8 || track->count*(size_t)times>KV_PERFORMANCE_CAPACITY) return false;
    KvPerformance r=*track; r.count=0;
    for(int k=0;k<times;k++) for(size_t i=0;i<track->count;i++) {
        KvPianoEvent e=track->events[i]; e.beat+=k*track->total_beats; e.chord+=(unsigned)(k*track->chord_count); r.events[r.count++]=e;
    }
    r.chord_count=track->chord_count*times; r.total_beats=track->total_beats*times;
    *out=r; return true;
}
bool kv_track_split(const KvPerformance *track,size_t chord,KvPerformance *left,KvPerformance *right) {
    if(!track || !left || !right || !chord || chord>=track->chord_count) return false;
    double cut=chord*track->beats_per_chord;
    KvPerformance l=*track,r=*track; l.count=r.count=0;
    for(size_t i=0;i<track->count;i++) {
        KvPianoEvent e=track->events[i];
        if(e.beat<cut-1e-9) { e.duration=fmin(e.duration,cut-e.beat); l.events[l.count++]=e; }
        else { e.beat-=cut; e.chord-=(unsigned)chord; r.events[r.count++]=e; }
    }
    l.chord_count=chord; l.total_beats=cut; r.chord_count=track->chord_count-chord; r.total_beats=track->total_beats-cut;
    *left=l; *right=r; return true;
}
void kv_track_transpose(KvPerformance *track,int semitones) {
    if(!track || !semitones) return;
    for(size_t i=0;i<track->count;i++) {
        int m=track->events[i].midi+semitones; while(m>108) m-=12; while(m<21) m+=12; track->events[i].midi=m;
    }
    kv_performance_resolve_overlaps(track);   // folding an octave back can land on a note already there
}
bool kv_song_cut(KvSong *song,size_t index,double beat,const KvPerformance *edited,KvPerformance *left,KvPerformance *right) {
    if(!song || index>=song->count || song->count>=KV_SONG_SECTIONS) return false;
    double snapped=kv_song_snap_cut(song,index,beat); if(snapped<0 || fabs(snapped-beat)>1e-6) return false;
    const KvSection original=song->sections[index]; KvSection s=original; bool has_track=s.edited && edited;
    if(has_track && (!kv_performance_valid(edited) || edited->chord_count!=s.count)) return false;
    KvSection a=s,b=s; b.name[0]=0;
    KvPerformance ta,tb; if(has_track) ta=tb=*edited;
    double pass=kv_section_pass_beats(song,&s); double passes=beat/pass;
    if(s.repeats>1 && fabs(passes-round(passes))<1e-9) {
        a.repeats=(int)round(passes); b.repeats=s.repeats-a.repeats;   // between passes: both keep the whole progression
    } else {
        if(s.repeats>1) {   // unroll into one pass, then cut inside it
            KvSection u=s; u.count=s.count*(size_t)s.repeats; u.repeats=1;
            for(size_t i=0;i<u.count;i++) u.codes[i]=s.codes[i%s.count];
            if(has_track && !kv_track_repeat(edited,s.repeats,&ta)) return false;
            s=u;
        }
        size_t chord=(size_t)llround(beat/kv_section_chord_beats(song,&s)); if(!chord || chord>=s.count) return false;
        a=s; b=s; b.name[0]=0;
        a.count=chord; b.count=s.count-chord; memcpy(b.codes,s.codes+chord,b.count*sizeof(int));
        if(has_track) { KvPerformance whole=ta; if(!kv_track_split(&whole,chord,&ta,&tb)) return false; }
    }
    if(has_track) { a.edited=ta.count>0; b.edited=tb.count>0; } else a.edited=b.edited=false;
    song->sections[index]=a;
    if(!kv_song_insert(song,index+1,&b)) { song->sections[index]=original; return false; }
    if(left) { if(a.edited) *left=ta; else memset(left,0,sizeof(*left)); }
    if(right) { if(b.edited) *right=tb; else memset(right,0,sizeof(*right)); }
    return true;
}
KvSection kv_section_from_draft(KvSectionKind kind,const int *codes,size_t count,KvArrangement arrangement) {
    KvSection s; memset(&s,0,sizeof(s));
    s.kind=kind; s.count=count>8?8:count; if(codes) memcpy(s.codes,codes,s.count*sizeof(int));
    s.repeats=1; s.arrangement=arrangement; s.arrangement.preview=false; s.level=1; s.beat=KV_SECTION_BEAT_SONG; s.beat_fixed=KV_BEAT_POP;
    return s;
}
