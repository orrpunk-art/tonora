#include "performance.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
const char *kv_pattern_name(KvPianoPattern pattern) {
    static const char *names[]={"Ballad","Flowing","Alberti","Pop","Waltz","Dark Jazz","Trip-Hop","Slow Ambient","Interlude"};
    return pattern>=0 && pattern<KV_PATTERN_COUNT?names[pattern]:"";
}
static int pc(int note) { return note%12; }
static bool append(KvPerformance *out,unsigned chord,unsigned hand,int midi,double beat,double duration,float velocity) {
    if(out->count>=KV_PERFORMANCE_CAPACITY || midi<21 || midi>108) return false;
    out->events[out->count++]=(KvPianoEvent){midi,chord*out->beats_per_chord+beat,duration,velocity,chord,hand,0,0}; return true;
}
static void voicing(const int chord[3],int base,const int previous[3],int result[3]) {
    int best=100000;
    // Enumerate compact inversions, keep all three voices in a distinct upper register.
    for(int low=base+12;low<=base+23;low++) for(int mid=low+1;mid<=base+23;mid++) for(int high=mid+1;high<=base+23;high++) {
        int notes[]={low,mid,high}; bool found[3]={false,false,false};
        for(int i=0;i<3;i++) for(int j=0;j<3;j++) if(pc(notes[i])==pc(chord[j])) found[j]=true;
        if(!found[0] || !found[1] || !found[2] || high-low>9) continue;
        int cost=0; for(int i=0;i<3;i++) cost+=abs(notes[i]-(previous?previous[i]:base+14+i*3));
        if(cost<best) { best=cost; memcpy(result,notes,sizeof(notes)); }
    }
}
static uint32_t random_next(uint32_t *state) {
    *state^=*state<<13; *state^=*state>>17; *state^=*state<<5; return *state;
}
static int nearest(const int *notes,int count,int target) {
    int best=0; for(int i=1;i<count;i++) if(abs(notes[i]-target)<abs(notes[best]-target)) best=i; return best;
}
static bool melodic_bar(KvPerformance *out,unsigned c,const int chords[][3],size_t count,int base,
                        KvPianoPattern pattern,KvKey key,uint32_t seed,const int right[3],int bass,int fifth,int *last) {
    int scale[12],n=0;
    for(int midi=base+12;midi<=base+23;midi++) if(kv_contains(key,midi)) scale[n++]=midi;
    if(n!=7) return false;
    uint32_t random=seed?seed:0x746f6e6f;
    unsigned variant=random_next(&random)%4;
    static const int motifs[4][8]={{0,2,1,-1,3,2,0,-1},{0,-1,1,3,2,0,1,-2},{0,1,3,2,-1,0,2,1},{0,3,2,1,-1,1,0,-2}};
    static const double jazz[8]={.25,.75,1.5,2.25,2.75,3.5,3.75,3.875};
    static const double triphop[8]={0,.75,1.5,2.75,3.5,3.75,3.875,3.9375};
    static const double interlude[8]={0,2.0/3,1,1.5,2,8.0/3,3,3.5};
    const double *times=pattern==KV_DARK_JAZZ?jazz:pattern==KV_TRIP_HOP?triphop:interlude;
#define ADD(hand,note,time,duration,velocity) do { if(!append(out,c,hand,note,time,duration,velocity)) return false; } while(0)
    if(pattern==KV_DARK_JAZZ) {
        ADD(0,bass,0,1.25,.74f); ADD(0,fifth,1.75,.65,.61f); ADD(0,bass+12,2.5,.75,.67f);
        // Diatonic seventh/ninth colour, spread below the melodic line.
        int root=nearest(scale,n,base+12+pc(chords[c][0]));
        ADD(1,scale[(root+6)%n],.75,.7,.52f);
        ADD(1,scale[(root+1)%n],2.25,.7,.53f);
    } else if(pattern==KV_TRIP_HOP) {
        ADD(0,bass,0,.8,.76f); ADD(0,fifth,1.5,.38,.62f);
        ADD(0,bass+12,2.25,.62,.68f); ADD(0,fifth,3.5,.32,.60f);
    } else if(pattern==KV_AMBIENT) {
        ADD(0,bass,0,3.6,.66f); ADD(0,fifth,2.5,1.25,.56f);
        int tone=right[nearest(right,3,*last?*last:base+20)];
        ADD(1,tone,.5,2.1,.70f);
        int index=nearest(scale,n,tone),next=(variant&1) && index+1<n?index+1:index>0?index-1:index+1;
        ADD(1,scale[next],3, .82,.61f);
        if(c%4==3 || c+1==count) {
            int target=nearest(scale,n,base+12+pc(chords[(c+1)%count][0]));
            int neighbour=next<target?next+1:next>target?next-1:next;
            ADD(1,scale[neighbour],3.5,.38,.59f); next=neighbour;
        }
        *last=scale[next]; return true;
    } else {
        ADD(0,bass,0,1.7,.73f); ADD(0,fifth,2,.85,.62f); ADD(0,bass+12,3,.7,.65f);
        ADD(1,right[0],1.5,.32,.50f);
    }
    int first=right[nearest(right,3,*last?*last:base+19)];
    int anchor=nearest(scale,n,first),previous=anchor;
    bool fill=(c%4==3 || c+1==count || pattern==KV_INTERLUDE);
    int note_count=pattern==KV_DARK_JAZZ?6:pattern==KV_TRIP_HOP?5:8;
    for(int i=0;i<note_count;i++) {
        if(fill && times[i]>=3) break;
        int offset=motifs[variant][i];
        // Repeat the phrase with inversion on the answer, then vary its contour.
        if(c%4==1) offset=-offset;
        if(c%4==2 && i>2) offset+=1;
        int index=anchor+offset; if(index<0) index=0; if(index>=n) index=n-1;
        if(i==0 || (pattern==KV_TRIP_HOP && i==4)) index=nearest(scale,n,right[nearest(right,3,scale[index])]);
        while(index-previous>3) index--; while(previous-index>3) index++;
        double gap=(i+1<note_count?times[i+1]:4)-times[i];
        double duration=fmin(gap*.80,pattern==KV_TRIP_HOP?.50:.68);
        ADD(1,scale[index],times[i],duration,i==0 || i==4?.80f:.68f);
        previous=index;
    }
    if(fill) {
        int target=base+12+pc(chords[(c+1)%count][0]);
        int destination=nearest(scale,n,target);
        int steps=pattern==KV_INTERLUDE?6:4;
        for(int i=0;i<steps;i++) {
            if(previous<destination) previous++; else if(previous>destination) previous--;
            else if(i+1<steps) previous=destination>0?destination-1:1;
            double time=3+(double)i/steps;
            ADD(1,scale[previous],time,.78/steps,i+1==steps?.64f:.70f);
        }
    }
    *last=scale[previous];
#undef ADD
    return true;
}

bool kv_two_hand_key(const int chords[][3],size_t count,int base,KvPianoPattern pattern,KvKey key,uint32_t seed,KvPerformance *out) {
    if(!out) return false; memset(out,0,sizeof(*out));
    if(!chords || !count || count>8 || base<36 || base>84 || base%12 || pattern<0 || pattern>=KV_PATTERN_COUNT) return false;
    for(size_t i=0;i<count;i++) {
        if(chords[i][0]<21 || chords[i][2]>127 || chords[i][1]<=chords[i][0] || chords[i][2]<=chords[i][1] || chords[i][2]-chords[i][0]>12) return false;
        if(pc(chords[i][0])==pc(chords[i][2])) return false;
    }
    out->chord_count=count; out->beats_per_chord=pattern==KV_WALTZ?3:4; out->beats_per_bar=out->beats_per_chord; out->total_beats=count*out->beats_per_chord;
    int previous[3]={0},melody_last=0;
    for(unsigned c=0;c<count;c++) {
        int right[3]={0}; voicing(chords[c],base,c?previous:NULL,right); memcpy(previous,right,sizeof(right));
        if(!right[0]) return false;
        int bass=base+pc(chords[c][0]); if(bass>base+5) bass-=12;
        int fifth=bass+chords[c][2]-chords[c][0];
#define NOTE(hand,note,beat,duration,velocity) do { if(!append(out,c,hand,note,beat,duration,velocity)) return false; } while(0)
        if(pattern==KV_BALLAD) {
            NOTE(0,bass,0,1.8,.74f); NOTE(0,bass+12,0,1.65,.57f); NOTE(0,fifth,2,1.8,.65f);
            int order[]={0,1,2,1,0,2,1,2};
            for(int i=0;i<8;i++) NOTE(1,right[order[(i+c%2)%8]],i*.5,.46,i%2?.66f:.75f);
        } else if(pattern==KV_FLOWING) {
            int low[]={bass,fifth,bass+12,fifth};
            for(int i=0;i<4;i++) NOTE(0,low[i],i,.88,i%2?.62f:.71f);
            int order[]={0,1,2,1,0,1,2,1};
            for(int i=0;i<8;i++) NOTE(1,right[order[i]],i*.5,.44,i%2?.65f:.73f);
        } else if(pattern==KV_ALBERTI) {
            int low[]={bass,bass+12,fifth,bass+12};
            for(int i=0;i<8;i++) NOTE(0,low[i%4],i*.5,.4,i%4?.59f:.72f);
            int order[]={2,1,0,2};
            for(int i=0;i<4;i++) NOTE(1,right[order[i]],i,.85,.78f);
        } else if(pattern==KV_POP) {
            NOTE(0,bass,0,1.35,.78f); NOTE(0,fifth,1.5,.4,.64f); NOTE(0,bass+12,2,1.35,.72f); NOTE(0,fifth,3.5,.4,.63f);
            const double times[]={.5,1,2.5,3};
            for(int i=0;i<4;i++) for(int v=0;v<3;v++) NOTE(1,right[v],times[i],.42,v==2?.72f:.58f);
        } else if(pattern==KV_WALTZ) {
            NOTE(0,bass,0,1.6,.78f); NOTE(0,fifth,2,.8,.60f);
            for(int beat=1;beat<=2;beat++) for(int v=0;v<3;v++) NOTE(1,right[v],beat,.82,v==2?.75f:.60f);
            NOTE(1,right[c%3],2.5,.4,.64f);
        } else {
            if(!melodic_bar(out,c,chords,count,base,pattern,key,seed,right,bass,fifth,&melody_last)) return false;
        }
#undef NOTE
    }
    // Stable time order preserves deterministic same-time hand/voice ordering.
    for(size_t i=1;i<out->count;i++) {
        KvPianoEvent event=out->events[i]; size_t j=i;
        while(j && out->events[j-1].beat>event.beat) { out->events[j]=out->events[j-1]; j--; }
        out->events[j]=event;
    }
    return kv_performance_valid(out);
}
bool kv_two_hand(const int chords[][3],size_t count,int base,KvPianoPattern pattern,KvPerformance *out) {
    return kv_two_hand_key(chords,count,base,pattern,(KvKey){0,false,0,0,false},0x746f6e6f,out);
}
bool kv_performance_valid(const KvPerformance *p) {
    if(!p || !p->count || p->count>KV_PERFORMANCE_CAPACITY || !p->chord_count || p->chord_count>8 || !isfinite(p->beats_per_chord) || p->beats_per_chord<1 || p->beats_per_chord>8 || fabs(p->total_beats-p->chord_count*p->beats_per_chord)>1e-9) return false;
    if(p->beats_per_bar && (p->beats_per_bar<3 || p->beats_per_bar>4)) return false;
    for(size_t i=0;i<p->count;i++) {
        KvPianoEvent e=p->events[i];
        if(e.midi<21 || e.midi>108 || !isfinite(e.beat) || !isfinite(e.duration) || !isfinite(e.velocity) || e.beat<0 || e.duration<=0 || e.velocity<.4f || e.velocity>1 || e.chord>=p->chord_count || e.hand>1) return false;
        // A note starts inside its chord's span; it may ring past the chord (edited tracks), never past the end.
        if(e.beat<e.chord*p->beats_per_chord-1e-9 || e.beat>=(e.chord+1)*p->beats_per_chord+1e-9 || e.beat+e.duration>p->total_beats+.00001 || (i && e.beat<p->events[i-1].beat)) return false;
    }
    return true;
}

typedef struct { double beat[8]; unsigned count; } PhraseRhythm;
static const PhraseRhythm pocket[4]={{{0,.75,1.5,2.5},4},{{.5,1.25,2,3},4},{{0,1,2.5,3.25},4},{{.25,1,1.75,3},4}};
static const PhraseRhythm jazz_phrase[4]={{{.5,1.5,2.75},3},{{0,1.25,2.5},3},{{.75,2,3},3},{{0,.75,2.5},3}};
static const PhraseRhythm quiet_phrase[4]={{{.5,2.5},2},{{0,2.75},2},{{.75,2.75},2},{{0,2.5},2}};
static const PhraseRhythm flowing_phrase[4]={{{0,.5,1,1.5,2,2.5,3},7},{{0,.5,1.5,2,2.5,3,3.5},7},{{0,.5,1,2,2.5,3,3.5},7},{{.5,1,1.5,2,2.5,3,3.5},7}};
static const PhraseRhythm waltz_phrase[4]={{{0,1,2},3},{{.5,1.5,2},3},{{0,1,2.5},3},{{0,.75,2},3}};
static int nearest_pitch_class(int pitch,int target,int low,int high) {
    int best=-1; for(int midi=low;midi<=high;midi++) if(pc(midi)==pitch && (best<0 || abs(midi-target)<abs(best-target))) best=midi;
    return best;
}
static bool controlled_phrase(const KvChord *chords,size_t count,int base,KvPianoPattern pattern,KvKey key,uint32_t seed,KvPerformance *out) {
    uint32_t state=seed?seed:0x6d757369;
    unsigned family=random_next(&state)%4,bass_family=random_next(&state)%2;
    bool sparse=pattern==KV_AMBIENT,flow=pattern==KV_FLOWING || pattern==KV_ALBERTI;
    int last=base+19; out->count=0; out->controlled=true;
    const int contours[4][8]={{0,1,2,1,0,-1,0,1},{0,-1,0,2,1,0,-1,0},{0,2,1,0,-1,0,1,0},{0,-1,-2,-1,0,1,0,-1}};
    int scale[12],ns=0; for(int midi=base+12;midi<=base+23;midi++) if(kv_contains(key,midi)) scale[ns++]=midi;
    if(ns!=7) return false;
    for(unsigned c=0;c<count;c++) {
        unsigned phase=c%4;
        // A two-bar question is retained, then answered. Randomness chooses a phrase, never individual beats.
        unsigned variant=(family+(phase>=2?1:0))%4;
        PhraseRhythm rhythm=out->beats_per_chord==3?waltz_phrase[variant]:sparse?quiet_phrase[variant]:flow?flowing_phrase[variant]:pattern==KV_DARK_JAZZ?jazz_phrase[variant]:pocket[variant];
        bool fill=!sparse && (phase==3 || c+1==count || (pattern==KV_INTERLUDE && phase==1));
        double end=out->beats_per_chord,fill_start=end-.75;
        int bass=base+pc(chords[c].midi[0]); if(bass>base+5) bass-=12;
        double bass_second=sparse?end-1:out->beats_per_chord==3?2:bass_family?2.5:2;
        if(!append(out,c,0,bass,0,sparse?end-.25:bass_second-.2,.71f)) return false;
        int fifth=bass+chords[c].midi[2]-chords[c].midi[0]; if(fifth>=base+10) fifth-=12;
        if(!append(out,c,0,phase%2?fifth:bass,bass_second,end-bass_second-.18,.60f)) return false;
        int tones[7],nt=(int)chords[c].count;
        for(int i=0;i<nt;i++) tones[i]=base+12+pc(chords[c].midi[i]);
        int guides[2]={tones[1],nt>=4?tones[3]:tones[2]};
        int anchor=guides[nearest(guides,2,last)];
        if(abs(anchor-last)>5) anchor=tones[nearest(tones,nt,last)];
        int scale_anchor=nearest(scale,ns,anchor);
        double starts[8],durations[8]; int melody[8]; unsigned used=0;
        for(unsigned i=0;i<rhythm.count;i++) {
            double t=rhythm.beat[i]; if(fill && t>=fill_start) break;
            int offset=contours[family][i]; if(phase==2) offset=-offset;
            int index=scale_anchor+offset; if(index<0) index=0; if(index>=ns) index=ns-1;
            int note=i?scale[index]:anchor;
            // A single colour tone is enough; a 13th chord is not a seven-note scale exercise.
            if(i==2 && nt>4) {
                int colour=tones[nt-1]; if(abs(colour-last)<=5) note=colour;
            }
            if(i && abs(note-last)>5) note=scale[nearest(scale,ns,last)+(note>last?1:-1)];
            double next=i+1<rhythm.count?rhythm.beat[i+1]:end;
            if(fill && next>fill_start) next=fill_start;
            if(next-t<.4) continue;
            starts[used]=t; durations[used]=fmax(.08,next-t-.18); melody[used++]=note;
            if(!append(out,c,1,note,t,durations[used-1],i?.68f:.77f)) return false;
            last=note;
        }
        // One soft guide voice, outside the melody's interval of a second, released before its next note.
        if(used) {
            int support=guides[0]==melody[0]?guides[1]:guides[0];
            if(support<melody[0] && melody[0]-support>=3 && melody[0]-support<=12) {
                if(!append(out,c,1,support,starts[0],fmin(.75,durations[0]),.51f)) return false;
            }
        }
        if(fill) {
            const KvChord *next=&chords[(c+1)%count];
            int target=-1;
            for(size_t v=0;v<next->count;v++) {
                int note=nearest_pitch_class(pc(next->midi[v]),last,base+12,base+23);
                if(note>=0 && (target<0 || abs(note-last)<abs(target-last))) target=note;
            }
            int from=nearest(scale,ns,last),to=nearest(scale,ns,target);
            int approach=from<to?to-1:from>to?to+1:to;
            if(approach<0) approach=0; if(approach>=ns) approach=ns-1;
            // Two resolving pickup notes replace the ending; they never stack over an existing line.
            if(!append(out,c,1,scale[approach],fill_start,.20,.65f) || !append(out,c,1,scale[to],end-.375,.20,.68f)) return false;
            last=scale[to];
        }
    }
    return true;
}

bool kv_arrangement_controlled(const KvPerformance *p) {
    if(!kv_performance_valid(p)) return false;
    unsigned density[32]={0}; double melody_end=-1; int previous=-1;
    double bar=p->beats_per_bar>0?p->beats_per_bar:p->beats_per_chord;
    for(size_t i=0;i<p->count;i++) {
        KvPianoEvent e=p->events[i];
        if(!e.hand) continue;
        size_t at=(size_t)floor(e.beat/bar+1e-9); if(at>=32) return false;
        if(++density[at]>12 || e.duration<.19) return false;
        if(e.velocity>=.64f) {
            if(previous>=0 && (abs(e.midi-previous)>7 || e.beat<melody_end-.00001)) return false;
            previous=e.midi; melody_end=e.beat+e.duration;
        }
        unsigned active=0;
        for(size_t j=0;j<p->count;j++) {
            KvPianoEvent other=p->events[j];
            if(other.hand && other.beat<=e.beat && other.beat+other.duration>e.beat) {
                active++;
                if(other.midi!=e.midi && abs(other.midi-e.midi)<3) return false;
            }
        }
        if(active>2) return false;
    }
    return true;
}

/* Independent arrangement generation. The seed owns rhythm, hand roles, voicings and fills,
   so changing/replaying harmony does not silently regenerate the performance. */
bool kv_arrange(const KvChord *chords,size_t count,int base,KvPianoPattern pattern,KvKey key,uint32_t seed,bool generated,KvPerformance *out) {
    if(!chords || !count || count>8 || !out) return false;
    int triads[8][3];
    for(size_t c=0;c<count;c++) {
        if(chords[c].count<3 || chords[c].count>7) return false;
        for(int v=0;v<3;v++) triads[c][v]=chords[c].midi[v];
        for(size_t v=0;v<chords[c].count;v++) if(chords[c].midi[v]<21 || chords[c].midi[v]>127 || (v && chords[c].midi[v]<=chords[c].midi[v-1])) return false;
    }
    if(!kv_two_hand_key(triads,count,base,pattern,key,seed,out)) return false;
    if(generated) {
        if(!controlled_phrase(chords,count,base,pattern,key,seed,out)) return false;
    } else {
        // In fixed styles preserve every existing event and weave the selected extensions into upper onsets.
        size_t original_count=out->count;
        for(unsigned c=0;c<count;c++) {
            double starts[32]; size_t hits=0;
            for(size_t i=0;i<original_count && hits<32;i++) if(out->events[i].chord==c && out->events[i].hand==1) {
                double t=out->events[i].beat-c*out->beats_per_chord;
                if(!hits || t!=starts[hits-1]) starts[hits++]=t;
            }
            for(size_t v=3;v<chords[c].count;v++) {
                double time=hits?starts[(v-3)*hits/(chords[c].count-3)]:0;
                int midi=base+12+pc(chords[c].midi[v]);
                if(!append(out,c,1,midi,time,fmin(.9,out->beats_per_chord-time),.55f)) return false;
            }
        }
    }
    for(size_t i=1;i<out->count;i++) {
        KvPianoEvent e=out->events[i]; size_t j=i;
        while(j && out->events[j-1].beat>e.beat) { out->events[j]=out->events[j-1]; j--; } out->events[j]=e;
    }
    // Two hands/pickups may meet on the same key. Merge simultaneous note-ons instead of
    // retriggering a fresh voice and accidentally replacing its sustain with a short fill.
    size_t written=0,group=0;
    for(size_t i=0;i<out->count;i++) {
        KvPianoEvent event=out->events[i];
        if(!written || out->events[written-1].beat!=event.beat) group=written;
        size_t duplicate=written;
        for(size_t j=group;j<written;j++) if(out->events[j].midi==event.midi) { duplicate=j; break; }
        if(duplicate<written) {
            if(event.duration>out->events[duplicate].duration) out->events[duplicate].duration=event.duration;
            if(event.velocity>out->events[duplicate].velocity) out->events[duplicate].velocity=event.velocity;
        } else out->events[written++]=event;
    }
    out->count=written;
    return kv_performance_valid(out) && (!out->controlled || kv_arrangement_controlled(out));
}

/* ===================== 0.15 arrangement engine =====================
   Meter, chord length and fill rate are independent parameters. A style is written as
   bar templates for 4/4, 3/4 and 6/8; chords are laid over a continuous beat timeline and
   each template hit takes the chord that sounds at its onset. */
/* ---- beats: lanes of steps, X loud, x normal, o soft; a lane of 12 steps in 4/4 counts triplet eighths, otherwise a step
   is a sixteenth ---- */
typedef struct { int drum; const char *steps; } Lane;
#define LANES 5
static const Lane four[KV_BEAT_COUNT][LANES]={
    [KV_BEAT_POP]={{KV_DRUM_KICK,"X.......x.x....."},{KV_DRUM_SNARE,"....X.......X..."},{KV_DRUM_SHAKER,"x.o.x.o.x.o.x.o."},{KV_DRUM_TAMBOURINE,"....o.......o..."}},
    [KV_BEAT_BALLAD]={{KV_DRUM_KICK,"X.........o....."},{KV_DRUM_STICK,"....x.......x..."},{KV_DRUM_HAT,"o.o.o.o.o.o.o.o."}},
    [KV_BEAT_BOSSA]={{KV_DRUM_KICK,"X..x....X..x...."},{KV_DRUM_STICK,"x..x..x...x..x.."},{KV_DRUM_SHAKER,"xoxoxoxoxoxoxoxo"},{KV_DRUM_CONGA_LOW,"..............o."},{KV_DRUM_CONGA_HIGH,"......o.......o."}},
    [KV_BEAT_SHUFFLE]={{KV_DRUM_KICK,"X.....x....."},{KV_DRUM_SNARE,"...X.....X.."},{KV_DRUM_HAT,"x.ox.ox.ox.o"}},
    [KV_BEAT_HIPHOP]={{KV_DRUM_KICK,"X......x..x....."},{KV_DRUM_SNARE,"....X.......X..."},{KV_DRUM_HAT,"x.o.x.o.x.o.x.o."}},
    [KV_BEAT_TRIPHOP]={{KV_DRUM_KICK,"X.........x....."},{KV_DRUM_SNARE,"........X......."},{KV_DRUM_HAT,"o.o.o.o.o.o.o.o."},{KV_DRUM_SHAKER,"..o...o...o...o."}},
    [KV_BEAT_HOUSE]={{KV_DRUM_KICK,"X...x...x...x..."},{KV_DRUM_CLAP,"....x.......x..."},{KV_DRUM_HAT_OPEN,"..x...x...x...x."},{KV_DRUM_HAT,"o...o...o...o..."}},
};
/* 3/4 and 6/8 by kit: [electronic][meter 3/4, 6/8]; a step is a sixteenth (an eighth is two). */
static const Lane odd[2][2][LANES]={
    {{{KV_DRUM_KICK,"X..........."},{KV_DRUM_TAMBOURINE,"....o...o..."},{KV_DRUM_SHAKER,"x.o.x.o.x.o."}},
     {{KV_DRUM_KICK,"X..........."},{KV_DRUM_SNARE,"......x....."},{KV_DRUM_SHAKER,"x.o.o.x.o.o."}}},
    {{{KV_DRUM_KICK,"X..........."},{KV_DRUM_CLAP,"....o...o..."},{KV_DRUM_HAT,"x.o.x.o.x.o."}},
     {{KV_DRUM_KICK,"X..........."},{KV_DRUM_SNARE,"......x....."},{KV_DRUM_HAT,"x.o.o.x.o.o."}}},
};
static int by_beat(const void *a,const void *b) { double d=((const KvHit *)a)->beat-((const KvHit *)b)->beat; return d<0?-1:d>0?1:((const KvHit *)a)->drum-((const KvHit *)b)->drum; }
size_t kv_beat_bar(KvBeat beat,KvMeter meter,KvHit hits[KV_BEAT_HITS]) {
    if(beat<0 || beat>=KV_BEAT_COUNT || meter<0 || meter>=KV_METER_COUNT || !hits) return 0;
    const Lane *lanes=meter==KV_METER_4_4?four[beat]:odd[kv_beat_electronic(beat)][meter==KV_METER_6_8];
    double bar=kv_meter_bar(meter); size_t n=0;
    for(int l=0;l<LANES && lanes[l].steps;l++) {
        size_t steps=strlen(lanes[l].steps); double step=bar/steps;
        for(size_t i=0;i<steps && n<KV_BEAT_HITS;i++) { char c=lanes[l].steps[i];
            if(c=='X' || c=='x' || c=='o') hits[n++]=(KvHit){i*step,lanes[l].drum,c=='X'?1:c=='x'?.75f:.45f}; }
    }
    qsort(hits,n,sizeof *hits,by_beat); return n;
}
bool kv_beat_electronic(KvBeat beat) { return beat==KV_BEAT_HIPHOP || beat==KV_BEAT_TRIPHOP || beat==KV_BEAT_HOUSE; }
KvBeat kv_beat_for_style(KvPianoPattern style) {
    return style==KV_POP?KV_BEAT_POP:style==KV_DARK_JAZZ?KV_BEAT_SHUFFLE:style==KV_TRIP_HOP?KV_BEAT_TRIPHOP:KV_BEAT_BALLAD;   // the waltz becomes one in 3/4
}
const char *kv_beat_name(KvBeat beat) {
    static const char *names[KV_BEAT_COUNT]={"Поп","Баллада","Босса-нова","Шаффл","Хип-хоп","Трип-хоп","Хаус"};
    return beat>=0 && beat<KV_BEAT_COUNT?names[beat]:"";
}
void kv_beat_tempo(KvBeat beat,int *low,int *high) {
    static const int range[KV_BEAT_COUNT][2]={{90,120},{60,80},{120,140},{90,120},{80,95},{70,90},{115,128}};
    if(beat<0 || beat>=KV_BEAT_COUNT) return; if(low) *low=range[beat][0]; if(high) *high=range[beat][1];
}
const char *kv_pattern_russian(KvPianoPattern pattern) {
    static const char *names[]={"Баллада","Перебор","Альберти","Поп","Вальс","Дарк-джаз","Трип-хоп","Эмбиент","Интерлюдия"};
    return pattern>=0 && pattern<KV_PATTERN_COUNT?names[pattern]:"";
}
const char *kv_arpeggio_name(KvArpeggioPattern pattern) { static const char *names[]={"Вверх","Вниз","Вверх-вниз","Ломаное","Волна"}; return pattern>=0 && pattern<KV_ARP_COUNT?names[pattern]:""; }
const char *kv_division_name(KvDivision division) { static const char *names[]={"Восьмые","Шестнадцатые","Триоли"}; return division>=0 && division<KV_DIV_COUNT?names[division]:""; }
double kv_division_beats(KvDivision division) { return division==KV_DIV_SIXTEENTH?.25:division==KV_DIV_TRIPLET?1.0/3:.5; }
const char *kv_meter_name(KvMeter meter) { static const char *names[]={"4/4","3/4","6/8"}; return meter>=0 && meter<KV_METER_COUNT?names[meter]:""; }
double kv_meter_bar(KvMeter meter) { return meter==KV_METER_4_4?4:3; }
double kv_meter_pulse(KvMeter meter) { return meter==KV_METER_6_8?1.5:1; }
double kv_chord_beats(KvMeter meter,KvChordLength length) {
    double bar=kv_meter_bar(meter),pulse=kv_meter_pulse(meter);
    switch(length) { case KV_LENGTH_BEAT: return pulse; case KV_LENGTH_TWO_BEATS: return 2*pulse; case KV_LENGTH_TWO_BARS: return 2*bar; default: return bar; }
}
KvFillRate kv_fill_rate(KvPianoPattern style,KvFillRate requested) {
    if(requested>KV_FILL_STYLE && requested<KV_FILL_COUNT) return requested;
    return style==KV_AMBIENT?KV_FILL_NONE:style==KV_INTERLUDE?KV_FILL_EVERY_BAR:KV_FILL_EVERY_4;
}
void kv_pattern_tempo(KvPianoPattern style,int *low,int *high) {
    static const int range[KV_PATTERN_COUNT][2]={{60,90},{70,110},{80,120},{90,130},{100,160},{60,90},{65,95},{50,75},{60,95}};
    int s=style>=0 && style<KV_PATTERN_COUNT?style:0; if(low) *low=range[s][0]; if(high) *high=range[s][1];
}

enum { R_BASS, R_FIFTH, R_OCTAVE, R_V0, R_V1, R_V2, R_TRIAD, R_ROTATE };
typedef struct { float t,d,v; unsigned char role; } Hit;
typedef struct { const Hit *hits; unsigned count; } HitBar;
#define HB(a) {a,sizeof(a)/sizeof(a[0])}
#define NOHB {NULL,0}
/* ---- 4/4 ---- */
static const Hit L44_ballad[]={{0,1.8f,.74f,R_BASS},{0,1.65f,.57f,R_OCTAVE},{2,1.8f,.65f,R_FIFTH}};
static const Hit R44_ballad_a[]={{0,.46f,.75f,R_V0},{.5f,.46f,.66f,R_V1},{1,.46f,.75f,R_V2},{1.5f,.46f,.66f,R_V1},{2,.46f,.75f,R_V0},{2.5f,.46f,.66f,R_V2},{3,.46f,.75f,R_V1},{3.5f,.46f,.66f,R_V2}};
static const Hit R44_ballad_b[]={{0,.46f,.75f,R_V1},{.5f,.46f,.66f,R_V2},{1,.46f,.75f,R_V1},{1.5f,.46f,.66f,R_V0},{2,.46f,.75f,R_V2},{2.5f,.46f,.66f,R_V1},{3,.46f,.75f,R_V2},{3.5f,.46f,.66f,R_V0}};
static const Hit L44_flowing[]={{0,.88f,.71f,R_BASS},{1,.88f,.62f,R_FIFTH},{2,.88f,.71f,R_OCTAVE},{3,.88f,.62f,R_FIFTH}};
static const Hit R44_flowing[]={{0,.44f,.73f,R_V0},{.5f,.44f,.65f,R_V1},{1,.44f,.73f,R_V2},{1.5f,.44f,.65f,R_V1},{2,.44f,.73f,R_V0},{2.5f,.44f,.65f,R_V1},{3,.44f,.73f,R_V2},{3.5f,.44f,.65f,R_V1}};
static const Hit L44_alberti[]={{0,.4f,.72f,R_BASS},{.5f,.4f,.59f,R_OCTAVE},{1,.4f,.59f,R_FIFTH},{1.5f,.4f,.59f,R_OCTAVE},{2,.4f,.72f,R_BASS},{2.5f,.4f,.59f,R_OCTAVE},{3,.4f,.59f,R_FIFTH},{3.5f,.4f,.59f,R_OCTAVE}};
static const Hit R44_alberti[]={{0,.85f,.78f,R_V2},{1,.85f,.78f,R_V1},{2,.85f,.78f,R_V0},{3,.85f,.78f,R_V2}};
static const Hit L44_pop[]={{0,1.35f,.78f,R_BASS},{1.5f,.4f,.64f,R_FIFTH},{2,1.35f,.72f,R_OCTAVE},{3.5f,.4f,.63f,R_FIFTH}};
static const Hit R44_pop[]={{.5f,.42f,.72f,R_TRIAD},{1,.42f,.72f,R_TRIAD},{2.5f,.42f,.72f,R_TRIAD},{3,.42f,.72f,R_TRIAD}};
static const Hit L44_waltz[]={{0,1.8f,.78f,R_BASS},{2,1.8f,.60f,R_FIFTH}};
static const Hit R44_waltz[]={{1,.82f,.75f,R_TRIAD},{2,.82f,.75f,R_TRIAD},{3,.82f,.75f,R_TRIAD}};
static const Hit L44_jazz[]={{0,1.25f,.74f,R_BASS},{1.75f,.65f,.61f,R_FIFTH},{2.5f,.75f,.67f,R_OCTAVE}};
static const Hit L44_trip[]={{0,.8f,.76f,R_BASS},{1.5f,.38f,.62f,R_FIFTH},{2.25f,.62f,.68f,R_OCTAVE},{3.5f,.32f,.60f,R_FIFTH}};
static const Hit L44_ambient[]={{0,3.6f,.66f,R_BASS},{2.5f,1.25f,.56f,R_FIFTH}};
static const Hit L44_interlude[]={{0,1.7f,.73f,R_BASS},{2,.85f,.62f,R_FIFTH},{3,.7f,.65f,R_OCTAVE}};
/* ---- 3/4 ---- */
static const Hit L34_ballad[]={{0,1.8f,.74f,R_BASS},{0,1.65f,.57f,R_OCTAVE},{2,.9f,.62f,R_FIFTH}};
static const Hit R34_ballad_a[]={{0,.46f,.75f,R_V0},{.5f,.46f,.66f,R_V1},{1,.46f,.75f,R_V2},{1.5f,.46f,.66f,R_V1},{2,.46f,.75f,R_V2},{2.5f,.46f,.66f,R_V1}};
static const Hit R34_ballad_b[]={{0,.46f,.75f,R_V1},{.5f,.46f,.66f,R_V2},{1,.46f,.75f,R_V0},{1.5f,.46f,.66f,R_V2},{2,.46f,.75f,R_V1},{2.5f,.46f,.66f,R_V0}};
static const Hit L34_flowing[]={{0,.88f,.71f,R_BASS},{1,.88f,.62f,R_FIFTH},{2,.88f,.66f,R_OCTAVE}};
static const Hit R34_flowing[]={{0,.44f,.73f,R_V0},{.5f,.44f,.65f,R_V1},{1,.44f,.73f,R_V2},{1.5f,.44f,.65f,R_V1},{2,.44f,.73f,R_V0},{2.5f,.44f,.65f,R_V1}};
static const Hit L34_alberti[]={{0,.4f,.72f,R_BASS},{.5f,.4f,.59f,R_OCTAVE},{1,.4f,.59f,R_FIFTH},{1.5f,.4f,.59f,R_OCTAVE},{2,.4f,.59f,R_FIFTH},{2.5f,.4f,.59f,R_OCTAVE}};
static const Hit R34_alberti[]={{0,.85f,.78f,R_V2},{1,.85f,.78f,R_V1},{2,.85f,.78f,R_V0}};
static const Hit L34_pop[]={{0,1.35f,.78f,R_BASS},{1.5f,.4f,.64f,R_FIFTH},{2,.9f,.70f,R_OCTAVE}};
static const Hit R34_pop[]={{.5f,.42f,.72f,R_TRIAD},{1,.42f,.72f,R_TRIAD},{2,.42f,.72f,R_TRIAD}};
static const Hit L34_waltz[]={{0,1.6f,.78f,R_BASS},{2,.8f,.60f,R_FIFTH}};
static const Hit R34_waltz[]={{1,.82f,.75f,R_TRIAD},{2,.45f,.75f,R_TRIAD},{2.5f,.4f,.64f,R_ROTATE}};
static const Hit L34_jazz[]={{0,1.2f,.74f,R_BASS},{1.75f,.6f,.61f,R_FIFTH},{2.5f,.45f,.64f,R_OCTAVE}};
static const Hit L34_trip[]={{0,.8f,.76f,R_BASS},{1.75f,.55f,.66f,R_OCTAVE},{2.5f,.3f,.60f,R_FIFTH}};
static const Hit L34_ambient[]={{0,2.8f,.66f,R_BASS}};
static const Hit L34_interlude[]={{0,1.6f,.73f,R_BASS},{2,.85f,.62f,R_FIFTH}};
/* ---- 6/8: two dotted-quarter groups at 0 and 1.5 ---- */
static const Hit L68_ballad[]={{0,1.4f,.74f,R_BASS},{0,1.3f,.57f,R_OCTAVE},{1.5f,1.4f,.64f,R_FIFTH}};
static const Hit R68_ballad_a[]={{0,.46f,.75f,R_V0},{.5f,.46f,.64f,R_V1},{1,.46f,.64f,R_V2},{1.5f,.46f,.75f,R_V1},{2,.46f,.64f,R_V2},{2.5f,.46f,.64f,R_V1}};
static const Hit R68_ballad_b[]={{0,.46f,.75f,R_V2},{.5f,.46f,.64f,R_V1},{1,.46f,.64f,R_V0},{1.5f,.46f,.75f,R_V1},{2,.46f,.64f,R_V0},{2.5f,.46f,.64f,R_V1}};
static const Hit L68_flowing[]={{0,.45f,.71f,R_BASS},{.5f,.45f,.58f,R_FIFTH},{1,.45f,.58f,R_OCTAVE},{1.5f,.45f,.66f,R_FIFTH},{2,.45f,.58f,R_OCTAVE},{2.5f,.45f,.58f,R_FIFTH}};
static const Hit R68_flowing[]={{0,1.4f,.72f,R_V2},{1.5f,1.4f,.70f,R_V1}};
static const Hit L68_alberti[]={{0,.4f,.72f,R_BASS},{.5f,.4f,.59f,R_OCTAVE},{1,.4f,.59f,R_FIFTH},{1.5f,.4f,.66f,R_OCTAVE},{2,.4f,.59f,R_FIFTH},{2.5f,.4f,.59f,R_OCTAVE}};
static const Hit R68_alberti[]={{0,1.3f,.76f,R_V2},{1.5f,1.3f,.76f,R_V1}};
static const Hit L68_pop[]={{0,1.4f,.78f,R_BASS},{1.5f,1.4f,.70f,R_OCTAVE}};
static const Hit R68_pop[]={{.5f,.42f,.72f,R_TRIAD},{1,.42f,.72f,R_TRIAD},{2,.42f,.72f,R_TRIAD},{2.5f,.42f,.72f,R_TRIAD}};
static const Hit L68_waltz[]={{0,.95f,.78f,R_BASS},{1.5f,.95f,.62f,R_FIFTH}};
static const Hit R68_waltz[]={{.5f,.45f,.72f,R_TRIAD},{1,.45f,.72f,R_TRIAD},{2,.45f,.72f,R_TRIAD},{2.5f,.4f,.64f,R_ROTATE}};
static const Hit L68_jazz[]={{0,1.2f,.74f,R_BASS},{1.5f,.6f,.62f,R_FIFTH},{2.5f,.45f,.64f,R_OCTAVE}};
static const Hit L68_trip[]={{0,.8f,.76f,R_BASS},{1,.4f,.62f,R_FIFTH},{2,.45f,.66f,R_OCTAVE}};
static const Hit L68_ambient[]={{0,2.8f,.66f,R_BASS},{1.5f,1.3f,.56f,R_FIFTH}};
static const Hit L68_interlude[]={{0,1.4f,.73f,R_BASS},{1.5f,1.4f,.62f,R_FIFTH}};
static const HitBar LEFT[KV_PATTERN_COUNT][KV_METER_COUNT]={
    {HB(L44_ballad),HB(L34_ballad),HB(L68_ballad)},{HB(L44_flowing),HB(L34_flowing),HB(L68_flowing)},
    {HB(L44_alberti),HB(L34_alberti),HB(L68_alberti)},{HB(L44_pop),HB(L34_pop),HB(L68_pop)},
    {HB(L44_waltz),HB(L34_waltz),HB(L68_waltz)},{HB(L44_jazz),HB(L34_jazz),HB(L68_jazz)},
    {HB(L44_trip),HB(L34_trip),HB(L68_trip)},{HB(L44_ambient),HB(L34_ambient),HB(L68_ambient)},
    {HB(L44_interlude),HB(L34_interlude),HB(L68_interlude)}};
/* Right-hand templates exist for the accompaniment styles; [1] alternates on odd bars. */
static const HitBar RIGHT[5][KV_METER_COUNT][2]={
    {{HB(R44_ballad_a),HB(R44_ballad_b)},{HB(R34_ballad_a),HB(R34_ballad_b)},{HB(R68_ballad_a),HB(R68_ballad_b)}},
    {{HB(R44_flowing),NOHB},{HB(R34_flowing),NOHB},{HB(R68_flowing),NOHB}},
    {{HB(R44_alberti),NOHB},{HB(R34_alberti),NOHB},{HB(R68_alberti),NOHB}},
    {{HB(R44_pop),NOHB},{HB(R34_pop),NOHB},{HB(R68_pop),NOHB}},
    {{HB(R44_waltz),NOHB},{HB(R34_waltz),NOHB},{HB(R68_waltz),NOHB}}};
/* Melody rhythm cells: bar-relative onsets. Randomness picks a cell for a phrase, never single notes. */
typedef struct { double beat[8]; unsigned count; } Cell;
static const Cell CELLS[KV_METER_COUNT][4][4]={
    { /* 4/4: pocket, jazz, quiet, flowing */
      {{{0,.75,1.5,2.5},4},{{.5,1.25,2,3},4},{{0,1,2.5,3.25},4},{{.25,1,1.75,3},4}},
      {{{.5,1.5,2.75},3},{{0,1.25,2.5},3},{{.75,2,3},3},{{0,.75,2.5},3}},
      {{{.5,2.5},2},{{0,2.75},2},{{.75,2.75},2},{{0,2.5},2}},
      {{{0,.5,1,1.5,2,2.5,3},7},{{0,.5,1.5,2,2.5,3,3.5},7},{{0,.5,1,2,2.5,3,3.5},7},{{.5,1,1.5,2,2.5,3,3.5},7}}},
    { /* 3/4 */
      {{{0,1,2},3},{{.5,1.5,2},3},{{0,1,2.5},3},{{0,.75,2},3}},
      {{{.5,1.25,2.5},3},{{0,1.5,2.25},3},{{.75,2},2},{{0,1.25,2.5},3}},
      {{{.5},1},{{0,2},2},{{1},1},{{0,1.5},2}},
      {{{0,.5,1,1.5,2,2.5},6},{{0,.5,1,2,2.5},5},{{.5,1,1.5,2,2.5},5},{{0,1,1.5,2,2.5},5}}},
    { /* 6/8 */
      {{{0,1,1.5,2.5},4},{{0,.5,1.5,2},4},{{0,1,1.5,2},4},{{.5,1,1.5,2.5},4}},
      {{{0,1,2},3},{{.5,1.5,2.5},3},{{0,1.5,2.5},3},{{.5,1,2},3}},
      {{{0,1.5},2},{{.5,2},2},{{0,2},2},{{1,1.5},2}},
      {{{0,.5,1,1.5,2,2.5},6},{{0,.5,1,1.5,2},5},{{0,1,1.5,2,2.5},5},{{0,.5,1,1.5,2.5},5}}}};
enum { CELL_POCKET, CELL_JAZZ, CELL_QUIET, CELL_FLOWING };
static int style_cells(KvPianoPattern style) {
    switch(style) { case KV_FLOWING: case KV_ALBERTI: case KV_INTERLUDE: return CELL_FLOWING; case KV_DARK_JAZZ: return CELL_JAZZ; case KV_AMBIENT: return CELL_QUIET; default: return CELL_POCKET; }
}
enum { FILL_RUN, FILL_NEIGHBOR, FILL_BASS };
typedef struct {
    const KvChord *chords; size_t count; int base; KvKey key; KvArrangement a;
    double bar,pulse,length,total; size_t bars;
    int scale[7]; int right[8][3],bass[8],fifth[8];
    int cscale[8][7]; unsigned cmask[8];   /* per chord: the scale with a chord outside the key's notes put in (A7 in C: C♯ for C), and its pitch classes plus the chord's */
    bool fill_bar[32]; unsigned char fill_kind[32];
    /* Variation plan (seeded): rhythm cell and contour per bar, bass figure, melody density, support voice, accents. */
    unsigned char cell_of_bar[32],contour_of_bar[32],invert_bar[32];
    int bass_style,density,support_mode,anchor,accent;
    uint32_t random; int last,forced;
    KvPerformance *out;
} Plan;
static size_t chord_at(const Plan *x,double t) { size_t c=(size_t)floor(t/x->length+1e-9); return c<x->count?c:x->count-1; }
static bool put(Plan *x,unsigned hand,int midi,double t,double d,float v,bool fill) {
    if(t>=x->total-1e-9) return true;
    size_t c=chord_at(x,t); double end=(c+1)*x->length; if(t+d>end) d=end-t;
    if(d<.05) return true;
    if(x->out->count>=KV_PERFORMANCE_CAPACITY || midi<21 || midi>108) return false;
    x->out->events[x->out->count++]=(KvPianoEvent){midi,t,d,v,(unsigned)c,hand,(unsigned char)fill,0}; return true;
}
static int role_note(const Plan *x,size_t c,unsigned char role,size_t bar) {
    switch(role) {
        case R_BASS: return x->bass[c]; case R_FIFTH: return x->fifth[c]; case R_OCTAVE: return x->bass[c]+12;
        case R_V0: case R_V1: case R_V2: return x->right[c][role-R_V0];
        default: return x->right[c][(c+bar)%3];
    }
}
static int tones_of(const Plan *x,size_t c,int tones[7]) {
    int n=(int)x->chords[c].count; for(int i=0;i<n;i++) tones[i]=x->base+12+pc(x->chords[c].midi[i]); return n;
}
static int scale_index(const Plan *x,size_t c,int midi) { return nearest(x->cscale[c],7,midi); }
static bool in_chord_scale(const Plan *x,size_t c,int midi) { return x->cmask[c]>>pc(midi)&1u; }
static int clamp_index(int i) { return i<0?0:i>6?6:i; }
static double bar_end(const Plan *x,size_t b) { return fmin((b+1)*x->bar,x->total); }
static bool place_hits(Plan *x,size_t b,const HitBar *hb,unsigned hand,double cut) {
    double start=b*x->bar;
    for(unsigned i=0;i<hb->count;i++) {
        Hit h=hb->hits[i]; double t=start+h.t; if(t>=cut-1e-9 || t>=x->total-1e-9) continue;
        size_t c=chord_at(x,t);
        if(h.role==R_TRIAD) {
            for(int v=0;v<3;v++) if(!put(x,hand,x->right[c][v],t,h.d,v==2?h.v:h.v-.14f,false)) return false;
        } else if(!put(x,hand,role_note(x,c,h.role,b),t,h.d,h.v,false)) return false;
    }
    return true;
}
/* Fill: a short scale run (or a double neighbour) that resolves onto a tone of the next chord on its downbeat.
   Consecutive fill notes are always different pitches; the first note is never the note just heard. */
static bool run_fill(Plan *x,size_t b,bool controlled) {
    double end=bar_end(x,b),start=end-x->pulse; if(start<b*x->bar) start=b*x->bar;
    size_t next=end>=x->total-1e-9?0:chord_at(x,end);
    int tones[7],nt=tones_of(x,next,tones),target=tones[nearest(tones,nt,x->last)];
    // The run sounds under the current chord, so it walks that chord's scale; it lands on a tone of the next chord.
    size_t now=chord_at(x,start); const int *S=x->cscale[now]; int ti=scale_index(x,now,target),path[6],n=0;
    double window=end-start;
    int limit=(int)floor(window/.25+1e-9),fast=x->a.seconds_per_beat>0?(int)floor(window*x->a.seconds_per_beat/.1125+1e-9):limit;
    if(fast<limit) limit=fast; if(limit<1) limit=1;
    int wanted=limit<3?limit:3;
    bool neighbour=x->fill_kind[b]==FILL_NEIGHBOR && limit>=2 && ti>=1 && ti<=5 && S[ti+1]!=x->last && (!controlled || abs(S[ti+1]-x->last)<=7);
    if(neighbour) { path[n++]=ti+1; path[n++]=ti-1; }
    else for(int length=wanted;length>=1 && !n;length--) {
        int best=0,best_distance=1000;
        for(int dir=-1;dir<=1;dir+=2) {
            int first=ti-dir*length; if(first<0 || first>6) continue;
            int distance=abs(S[first]-x->last);
            if(S[first]==x->last || (controlled && distance>7)) continue;
            if(distance<best_distance) { best_distance=distance; best=dir; }
        }
        if(best) for(int k=length;k>=1;k--) path[n++]=ti-best*k;
    }
    if(!n) { x->forced=-1; return true; }
    double step=window/n;
    for(int k=0;k<n;k++) {
        int note=S[clamp_index(path[k])];
        if(!put(x,1,note,start+k*step,fmax(controlled?.2:.1,step*.8),k+1==n?.66f:.68f,true)) return false;
        x->last=note;
    }
    x->forced=target;
    return true;
}
static bool bass_pickup(Plan *x,size_t b) {
    double end=bar_end(x,b),start=end-x->pulse; if(start<b*x->bar) start=b*x->bar;
    size_t c=chord_at(x,start),next=end>=x->total-1e-9?0:chord_at(x,end);
    int target=x->bass[next],approach=target-1; while(approach>21 && !in_chord_scale(x,next,approach)) approach--;
    int first=x->fifth[c]; if(first>=x->base+12) first-=12; // stay below the right-hand register
    if(first==approach) first=x->bass[c]; if(first==approach) first=x->bass[c]+12;
    double half=(end-start)/2;
    return put(x,0,first,start,half*.85,.64f,true) && put(x,0,approach,start+half,half*.85,.68f,true);
}
enum { BASS_TEMPLATE, BASS_HALVES, BASS_ARPEGGIO, BASS_PEDAL, BASS_WALK, BASS_STYLES };
enum { DENSITY_SPARSE, DENSITY_NORMAL, DENSITY_BUSY };
enum { SUPPORT_NONE, SUPPORT_BAR, SUPPORT_CHORD };
static int diatonic_below(const Plan *x,size_t c,int note) { int n=note-1; while(n>21 && !in_chord_scale(x,c,n)) n--; return n; }
static int diatonic_above(const Plan *x,size_t c,int note) { int n=note+1; while(n<108 && !in_chord_scale(x,c,n)) n++; return n; }
/* Seeded left-hand figure for one bar of a variation. `cut` ends the figure early before a bass pickup. */
static bool bass_bar(Plan *x,size_t b,double cut) {
    double start=b*x->bar,end=bar_end(x,b); size_t c=chord_at(x,start);
    size_t next=end>=x->total-1e-9?0:chord_at(x,end);
    // The next chord tone above the bass (the third in root position; from an inverted bass, the chord tone above it).
    const KvChord *ch=&x->chords[c]; int bt=ch->bass,above=bt==0?1:bt==1?2:0;
    int third=x->bass[c]+((ch->midi[above]-ch->midi[bt])%12+12)%12; if(third>x->base+10) third-=12;
    int approach=x->bass[next]>x->fifth[c]?diatonic_below(x,next,x->bass[next]):diatonic_above(x,next,x->bass[next]);
    if(approach>x->base+10) approach-=12; if(approach<21) approach+=12;
#define BASS(note,t,d,v) do { if(start+(t)<cut-1e-9 && !put(x,0,note,start+(t),d,v,false)) return false; } while(0)
    switch(x->bass_style) {
        case BASS_HALVES: {
            double half=x->a.meter==KV_METER_6_8?1.5:2; size_t c2=chord_at(x,start+half);
            BASS(x->bass[c],0,half-.2,.71f); BASS(b%2?x->fifth[c2]:x->bass[c2],half,x->bar-half-.18,.60f); break;
        }
        case BASS_ARPEGGIO:
            if(x->a.meter==KV_METER_4_4) { BASS(x->bass[c],0,.9,.72f); BASS(x->fifth[c],1,.9,.58f); BASS(x->bass[chord_at(x,start+2)]+12,2,.9,.62f); BASS(x->fifth[chord_at(x,start+3)],3,.9,.56f); }
            else if(x->a.meter==KV_METER_3_4) { BASS(x->bass[c],0,.9,.72f); BASS(x->fifth[c],1,.9,.58f); BASS(x->bass[chord_at(x,start+2)]+12,2,.9,.62f); }
            else { BASS(x->bass[c],0,.9,.72f); BASS(x->fifth[c],1,.45,.56f); BASS(x->bass[chord_at(x,start+1.5)]+12,1.5,.9,.62f); BASS(x->fifth[chord_at(x,start+2.5)],2.5,.45,.56f); }
            break;
        case BASS_PEDAL:
            BASS(x->bass[c],0,fmin(cut,end)-start-.2,.70f);
            BASS(x->fifth[c],end-start-x->pulse,x->pulse-.2,.52f); break;
        case BASS_WALK:
            if(x->a.meter==KV_METER_4_4) { BASS(x->bass[c],0,.9,.72f); BASS(third,1,.9,.60f); BASS(x->fifth[chord_at(x,start+2)],2,.9,.62f); BASS(approach,3,.9,.60f); }
            else if(x->a.meter==KV_METER_3_4) { BASS(x->bass[c],0,.9,.72f); BASS(x->fifth[c],1,.9,.60f); BASS(approach,2,.9,.60f); }
            else { BASS(x->bass[c],0,1.4,.72f); BASS(x->fifth[c],1.5,.9,.60f); BASS(approach,2.5,.45,.60f); }
            break;
        default: return place_hits(x,b,&LEFT[x->a.style][x->a.meter],0,cut);
    }
#undef BASS
    return true;
}
static bool melody_bar(Plan *x,size_t b,int cells) {
    const Cell *cell=&CELLS[x->a.meter][cells][x->cell_of_bar[b]];
    static const int contours[4][8]={{0,1,2,1,0,-1,0,1},{0,-1,0,2,1,0,-1,0},{0,2,1,0,-1,0,1,0},{0,-1,-2,-1,0,1,0,-1}};
    const int *contour=contours[x->contour_of_bar[b]]; bool invert=x->invert_bar[b];
    double start=b*x->bar,end=bar_end(x,b);
    bool fill=x->fill_bar[b] && x->fill_kind[b]!=FILL_BASS;
    double cut=fill?fmax(start,end-x->pulse):end;
    // Onsets: the cell, thinned or with passing notes according to the variation's density.
    double on[16]; int n=0;
    for(unsigned i=0;i<cell->count && n<12;i++) {
        double t=start+cell->beat[i]; if(t>=cut-1e-9) break;
        if(x->density==DENSITY_SPARSE && cell->count>=4 && (i%2)==1) continue;
        if(x->density==DENSITY_BUSY && n && n<11 && t-on[n-1]>=1-1e-9) on[n++]=t-.5;
        on[n++]=t;
    }
    float lead=x->accent?.77f:.74f,inner=x->accent?.68f:.66f;
    int anchor=scale_index(x,chord_at(x,start),x->last),step=0; bool first=true; size_t chord=SIZE_MAX;
    for(int j=0;j<n;j++) {
        double t=on[j],next=j+1<n?on[j+1]:end; if(next>cut) next=cut;
        size_t c=chord_at(x,t); double chord_end=(c+1)*x->length; if(next>chord_end) next=chord_end;
        double duration=next-t-.18; if(duration<.22) continue;
        int tones[7],nt=tones_of(x,c,tones),note;
        int guides[2]={tones[1],nt>=4?tones[3]:tones[2]};
        const int *S=x->cscale[c];
        if(x->forced>=0) { note=x->forced; x->forced=-1; anchor=scale_index(x,c,note); step=0; }
        else if(c!=chord) {
            note=guides[nearest(guides,2,x->last)]; if(abs(note-x->last)>5) note=tones[nearest(tones,nt,x->last)];
            anchor=scale_index(x,c,note); step=0;
        } else {
            step++; int offset=contour[step%8]; if(invert) offset=-offset;
            note=S[clamp_index(anchor+offset)];
            if(step==2 && nt>4) { int colour=tones[nt-1]; if(abs(colour-x->last)<=5) note=colour; }
        }
        if(abs(note-x->last)>5) note=S[clamp_index(scale_index(x,c,x->last)+(note>x->last?1:-1))];
        bool new_chord=c!=chord; chord=c;
        if(!put(x,1,note,t,duration,first?lead:inner,false)) return false;
        if((first && x->support_mode!=SUPPORT_NONE) || (new_chord && x->support_mode==SUPPORT_CHORD)) {
            // One soft guide voice under the note, a third or more below and released with it.
            int support=guides[0]==note?guides[1]:guides[0];
            if(support<note && note-support>=3 && note-support<=12 && !put(x,1,support,t,fmin(.75,duration),.51f,false)) return false;
        }
        first=false; x->last=note;
    }
    return !fill || run_fill(x,b,true);
}
static void sort_and_merge(KvPerformance *out,bool keep_melody) {
    for(size_t i=1;i<out->count;i++) {
        KvPianoEvent e=out->events[i]; size_t j=i;
        while(j && out->events[j-1].beat>e.beat) { out->events[j]=out->events[j-1]; j--; } out->events[j]=e;
    }
    size_t written=0,group=0;
    for(size_t i=0;i<out->count;i++) {
        KvPianoEvent event=out->events[i];
        if(!written || out->events[written-1].beat!=event.beat) group=written;
        size_t duplicate=written;
        for(size_t j=group;j<written;j++) if(out->events[j].midi==event.midi) { duplicate=j; break; }
        if(duplicate<written) {
            KvPianoEvent *kept=&out->events[duplicate];
            if(keep_melody && kept->hand!=event.hand) {
                // A melody note doubled by the left-hand octave stays a melody note with the melody's own length,
                // so the lead line remains continuous and monophonic.
                KvPianoEvent right=event.hand?event:*kept;
                right.fill|=kept->fill|event.fill; // the right hand's own velocity: a soft support note must not become a lead note
                *kept=right;
            } else {
                if(event.duration>kept->duration) kept->duration=event.duration;
                if(event.velocity>kept->velocity) kept->velocity=event.velocity;
                kept->fill|=event.fill;
            }
        } else out->events[written++]=event;
    }
    out->count=written;
}
/* Arpeggio texture. The right hand runs through the chord tones in the chosen order and note value;
   the left hand holds the root. A variation (seeded) chooses span, direction changes, sustain, accents,
   a bass figure and a breathing rest; the template takes the first choice of each. */
/* Position in the chord's tone list for step k of a pattern over n tones. */
static int arp_index(KvArpeggioPattern pattern,unsigned k,int n) {
    int period=n>1?2*n-2:1;
    switch(pattern) {
        case KV_ARP_DOWN: return n-1-(int)(k%n);
        case KV_ARP_UP_DOWN: { int j=(int)(k%period); return j<n?j:period-j; }
        case KV_ARP_BROKEN: { if(n<3) return (int)(k%n); int len=2*(n-2),j=(int)(k%len),pair=j/2; return j%2?pair+2:pair; }
        case KV_ARP_WAVE: { int j=(int)((k/3+k%3)%period); return j<n?j:period-j; }
        default: return (int)(k%n);
    }
}
enum { ARP_PLAIN, ARP_PEDAL_TOP, ARP_BLOCK_FIRST, ARP_OCTAVE_JUMP };
static bool arpeggio_arrangement(Plan *x) {
    const KvArrangement *a=&x->a; KvPerformance *out=x->out;
    bool two_octaves=false,alternate=false,sustain=false,rest=false,accent3=false; int bass_figure=0,accent=0,figure=ARP_PLAIN,pattern_b=-1;
    if(a->generated) {
        two_octaves=random_next(&x->random)%2; alternate=random_next(&x->random)%2; sustain=random_next(&x->random)%2;
        bass_figure=(int)(random_next(&x->random)%4); accent=(int)(random_next(&x->random)%2); rest=random_next(&x->random)%2;
        figure=(int)(random_next(&x->random)%4); accent3=a->division!=KV_DIV_TRIPLET && random_next(&x->random)%2;
        if(random_next(&x->random)%2) pattern_b=(int)((a->arpeggio_pattern+1+random_next(&x->random)%(KV_ARP_COUNT-1))%KV_ARP_COUNT);
    }
    double step=kv_division_beats(a->division);
    for(size_t c=0;c<x->count;c++) {
        double start=c*x->length,end=(c+1)*x->length;
        // Chord tones in the octave above the bass register, ascending from the lowest one there (the inversion
        // that keeps every arpeggio in the same register), then the octave above when the span allows.
        int tones[16],n=0; size_t nt=x->chords[c].count; if(nt>7) nt=7;
        for(int note=x->base+12;note<x->base+24 && n<16;note++) for(size_t v=0;v<nt;v++) if(pc(note)==pc(x->chords[c].midi[v])) { tones[n++]=note; break; }
        if(!n) return false;
        int n1=n; // tones within the first octave: what one hand can hold at once
        int top=x->base+(two_octaves?35:24); if(top>108) top=108; // the highest register stays on the piano
        if(two_octaves) { int m=n; for(int i=0;i<m && n<16;i++) if(tones[i]+12<=top) tones[n++]=tones[i]+12; }
        else if(tones[0]+12<=top && n<16) tones[n++]=tones[0]+12;
        // Left hand: the root in the octave starting at the keyboard base, restruck at every bar.
        int bass=x->bass[c]<x->base?x->bass[c]+12:x->bass[c],fifth=bass+(x->fifth[c]-x->bass[c]); if(fifth>x->base+11) fifth-=12;
        for(double bar=start;bar<end-1e-9;bar+=x->bar) {
            double until=fmin(end,bar+x->bar);
            if(bass_figure==2) { if(!put(x,0,bass,bar,fmin(until-bar,x->bar/2)-.1,.70f,false)) return false; if(bar+x->bar/2<until-1e-9 && !put(x,0,bass+12,bar+x->bar/2,until-bar-x->bar/2-.1,.56f,false)) return false; }
            else if(bass_figure==3) {
                // Walking: root, fifth, octave, fifth on the pulses of the bar.
                int walk[4]={bass,fifth,bass+12,fifth}; int steps=(int)floor((until-bar)/x->pulse+1e-9);
                for(int i=0;i<steps && i<4;i++) if(!put(x,0,walk[i],bar+i*x->pulse,x->pulse-.1,i?.58f:.70f,false)) return false;
            } else {
                if(!put(x,0,bass,bar,until-bar-.1,.70f,false)) return false;
                if(bass_figure==1 && bar+x->pulse<until-1e-9 && !put(x,0,fifth,bar+x->pulse,until-bar-x->pulse-.1,.55f,false)) return false;
            }
        }
        // Right hand: the pattern as a function of the step index, restarting on each chord.
        unsigned k=0,run=0;
        for(double t=start;t<end-1e-6;t+=step,k++) {
            double bar_pos=fmod(t-start+1e-9,x->bar);
            if(rest && bar_pos>x->bar-step-1e-6 && n>2) continue; // breathe before the bar line
            unsigned bar_index=(unsigned)floor((t+1e-9)/x->bar);
            bool backwards=alternate && bar_index%2==1;
            KvArpeggioPattern pattern=pattern_b>=0 && bar_index%4>=2?(KvArpeggioPattern)pattern_b:a->arpeggio_pattern;
            double remaining=end-t,duration=fmin(remaining-.02,sustain?step*2.2:step*.92);
            bool on_beat=fabs(fmod(t-start+1e-9,x->pulse))<1e-6 || fabs(fmod(t-start+1e-9,x->pulse)-x->pulse)<1e-6;
            bool strong=accent3?k%3==0:on_beat;
            float velocity=strong?(accent?.76f:.70f):(accent?.56f:.62f);
            if(figure==ARP_BLOCK_FIRST && t==start) {
                // The chord sounds together on its first step — the tones one hand can hold, within an octave — then breaks into the pattern.
                for(int i=0;i<n1 && tones[i]<=top;i++) if(!put(x,1,tones[i],t,fmin(remaining-.02,step*1.8),i?.60f:.72f,false)) return false;
                continue;
            }
            int index,note;
            if(figure==ARP_PEDAL_TOP && n1>1) {
                // A pedal tone, the root an octave up, between the figure's notes: the figure stays in the octave under it,
                // so the little finger can hold the pedal while the others play (never more than an octave apart).
                if(run%2) { note=tones[0]+12; if(note>top || note>108) note=tones[n1-1]; } // the octave, or the chord's top within reach
                else { index=arp_index(pattern,run/2,n1); if(backwards) index=n1-1-index; note=tones[index]; }
                run++;
            } else {
                index=arp_index(pattern,run++,n); if(backwards) index=n-1-index; note=tones[index];
                // An octave leap every fourth note; not over sustained notes, which would leave a hand stretched past a tenth.
                if(figure==ARP_OCTAVE_JUMP && !sustain && k%4==3 && note+12<=top) note+=12;
            }
            if(!put(x,1,note,t,duration,velocity,false)) return false;
        }
    }
    // Sustained notes ring into the next ones, but a hand cannot keep a key down across a leap of more than a tenth:
    // the ringing note is let go where the leap lands (the sustain pedal, not the finger, would carry it).
    for(size_t i=0;i<out->count;i++) for(size_t j=0;j<out->count;j++) {
        KvPianoEvent *u=&out->events[i]; const KvPianoEvent *v=&out->events[j];
        if(i==j || !u->hand || !v->hand || abs(u->midi-v->midi)<=16 || v->beat<=u->beat+1e-9 || v->beat>=u->beat+u->duration-.02) continue;
        u->duration=fmax(.05,v->beat-u->beat-.01);
    }
    sort_and_merge(out,false); kv_performance_resolve_overlaps(out);
    return kv_performance_valid(out);
}
/* ---- Bowed strings ---- */
const char *kv_string_texture_name(KvStringTexture texture) {
    static const char *names[KV_STRINGS_COUNT]={"","Хорал","Кантилена","Остинато","Пиццикато"};
    return texture>=0 && texture<KV_STRINGS_COUNT?names[texture]:"";
}
/* Up to four upper parts for chord c: the tones (a fifth is left out of chords with more than four), every one present,
   inside [low, low+span], spanning at most an octave, moving as little as possible from `previous` (n parts). */
static int upper_parts(const KvChord *chord,int low,int span,const int *previous,int np,int *parts) {
    int tones[7],n=0; for(size_t i=0;i<chord->count;i++) { if(chord->count>4 && i==2) continue; if(n<4) tones[n++]=pc(chord->midi[i]); }
    int best=1<<30,cand[4];
    for(cand[0]=low;cand[0]<=low+span;cand[0]++) for(cand[1]=cand[0]+1;cand[1]<=low+span;cand[1]++)
    for(cand[2]=n>2?cand[1]+1:cand[1];cand[2]<=low+span;cand[2]++) for(cand[3]=n>3?cand[2]+1:cand[2];cand[3]<=low+span;cand[3]++) {
        if(cand[n-1]-cand[0]>12) continue; bool ok=true;
        for(int t=0;t<n && ok;t++) { bool found=false; for(int v=0;v<n;v++) if(pc(cand[v])==tones[t]) found=true; ok=found; }
        if(!ok) continue;
        int cost=0; for(int v=0;v<n;v++) cost+=np==n?abs(cand[v]-previous[v])*2:abs(cand[v]-(low+span/2));
        if(cost<best) { best=cost; memcpy(parts,cand,sizeof(int)*(size_t)n); }
        if(n<4) break;   // the unused loop levels repeat the same candidate
    }
    return best<(1<<30)?n:0;
}
static int string_bass(const Plan *x,size_t c) { int b=x->bass[c]; while(b<36) b+=12; while(b>47) b-=12; return b; }   // cello section, C2–B2
static int chord_tone_near(const Plan *x,size_t c,int target,int low,int high) {
    int best=-1; for(int m=low;m<=high;m++) if(x->cmask[c]>>pc(m)&1u) { bool tone=false; for(size_t v=0;v<x->chords[c].count;v++) if(pc(x->chords[c].midi[v])==pc(m)) tone=true;
        if(tone && (best<0 || abs(m-target)<abs(best-target))) best=m; }
    return best;
}
static bool sput(Plan *x,unsigned hand,int midi,double t,double d,float v,KvStroke stroke,bool forced) {
    size_t before=x->out->count; if(!put(x,hand,midi,t,d,v,false)) return false;
    if(forced && x->out->count>before) x->out->events[before].stroke=(unsigned char)(stroke+1);
    return true;
}
/* A variation choice from the generator's high bits (the low ones of small seeds repeat). */
static unsigned pick(Plan *x,unsigned n) { return (random_next(&x->random)>>11)%n; }
static bool strings_arrangement(Plan *x) {
    const KvArrangement *a=&x->a; KvPerformance *out=x->out; double L=x->length; size_t count=x->count;
    static const double strong[KV_METER_COUNT][2]={{0,2},{0,-1},{0,1.5}};
    int previous[4]={0},np=0;
    if(a->strings==KV_STRINGS_CHORALE) {
        // Four-part writing: cellos on the bass, violins on up to four voice-led parts; common tones are held (legato).
        // Variations: the register of the violins, a top voice that moves to the next chord tone halfway through the chord,
        // a bass that walks to the fifth in two-bar chords.
        static const int registers[3]={57,62,67};
        int low=a->generated?registers[pick(x,3)]:62; bool walk=a->generated && pick(x,2),motion=a->generated && pick(x,2);
        for(size_t c=0;c<count;c++) {
            int parts[4],n=upper_parts(&x->chords[c],low,14,previous,np,parts); if(!n) return false;
            for(int v=0;v<n;v++) {
                if(v==n-1 && motion && L>=2-1e-9) {
                    int next=chord_tone_near(x,c,parts[v]+3,parts[v]+1,parts[v]+5); if(next<0 || next>88) next=chord_tone_near(x,c,parts[v]-3,parts[v]-5,parts[v]-1);
                    if(next>parts[v-1] && next<=88) { if(!put(x,1,parts[v],c*L,L/2,.68f,false) || !put(x,1,next,c*L+L/2,L/2,.7f,false)) return false; continue; }
                }
                if(!put(x,1,parts[v],c*L,L,.68f,false)) return false;
            }
            memcpy(previous,parts,sizeof(parts)); np=n;
            int bass=string_bass(x,c);
            if(walk && L>=x->bar*2-1e-9) { if(!put(x,0,bass,c*L,L/2,.72f,false) || !put(x,0,x->fifth[c]<36?x->fifth[c]+12:x->fifth[c],c*L+L/2,L/2,.66f,false)) return false; }
            else if(!put(x,0,bass,c*L,L,.72f,false)) return false;
        }
    } else if(a->strings==KV_STRINGS_CANTILENA) {
        // A held chord below (cellos), a slow, singing violin line above: chord tones on the chord's beats, a passing
        // tone only between two chord tones a third apart, every note joined to the next (legato).
        static const double rhythms[4][4]={{1},{.5,.5},{.5,.25,.25},{.75,.25}};   // fractions of the chord
        static const int sizes[4]={1,2,3,2};
        int last=74,direction=a->generated && pick(x,2)?-1:1;
        for(size_t c=0;c<count;c++) {
            int pad[4],n=upper_parts(&x->chords[c],48,11,previous,np,pad); if(!n) return false; memcpy(previous,pad,sizeof(pad)); np=n;
            if(!put(x,0,string_bass(x,c),c*L,L,.62f,false)) return false;
            for(int v=0;v<n && v<3;v++) if(!put(x,0,pad[v],c*L,L,.5f,false)) return false;
            int r=a->generated?(int)(pick(x,4)):(int)((c%2)?1:0); if(L<2-1e-9) r=0;
            int k=sizes[r]; double t=c*L; int first=chord_tone_near(x,c,last+direction,67,86); if(first<0) return false;
            int notes[3]={first,first,first};
            if(k>1) { int step=chord_tone_near(x,c,first+direction*4,67,86); if(step==first || step<0) step=chord_tone_near(x,c,first-direction*4,67,86); notes[k-1]=step; }
            if(k==3) { int gap=notes[2]-notes[0]; notes[1]=notes[0];
                if(abs(gap)>=3 && abs(gap)<=4) { int i=scale_index(x,c,notes[0]+gap/2); int m=x->cscale[c][i]; while(m<67) m+=12; while(m>86) m-=12; if(abs(m-notes[0])<=2 && abs(m-notes[2])<=2) notes[1]=m; } }
            for(int i=0;i<k;i++) { double d=rhythms[r][i]*L; if(!put(x,1,notes[i],t,d,.74f,false)) return false; t+=d; }
            last=notes[k-1]; if(last>82) direction=-1; else if(last<70) direction=1; else if(a->generated && pick(x,3)==0) direction=-direction;
        }
    } else if(a->strings==KV_STRINGS_OSTINATO) {
        // Film-style ostinato: the cellos hold the bass, the violins repeat a spiccato figure; beats a little louder.
        static const int figures[4][4]={{0,2,1,2},{0,1,2,1},{0,2,3,2},{0,3,1,2}};
        int figure=a->generated?(int)(pick(x,4)):0; double step=kv_division_beats(a->division);
        for(size_t c=0;c<count;c++) {
            if(!put(x,0,string_bass(x,c),c*L,L,.7f,false)) return false;
            int parts[4],n=upper_parts(&x->chords[c],60,14,previous,np,parts); if(!n) return false; memcpy(previous,parts,sizeof(parts)); np=n;
            int tones[4]; for(int v=0;v<4;v++) tones[v]=parts[v<n?v:n-1]; if(n==3) tones[3]=parts[0]+12;
            unsigned k=0; for(double t=c*L;t<(c+1)*L-1e-9;t+=step,k++) {
                double in_beat=fmod(t+1e-9,1); float v=in_beat<.01?.8f:.55f;
                if(!sput(x,1,tones[figures[figure][k%4]],t,step*.9,v,KV_STROKE_SPICCATO,true)) return false;
            }
        }
    } else {
        // Pizzicato: a plucked bass on the strong beats, the chord broken above in eighths.
        static const int orders[3][4]={{0,1,2,1},{0,2,1,2},{1,0,2,0}};
        int order=a->generated?(int)(pick(x,3)):0; bool busy=a->generated && pick(x,2);   // busy: plucks on the beats too
        for(size_t c=0;c<count;c++) {
            int parts[4],n=upper_parts(&x->chords[c],55,14,previous,np,parts); if(!n) return false; memcpy(previous,parts,sizeof(parts)); np=n;
            for(double bar=floor(c*L/x->bar+1e-9)*x->bar;bar<(c+1)*L-1e-9;bar+=x->bar) for(int s=0;s<2;s++) {
                if(strong[a->meter][s]<0) continue; double t=bar+strong[a->meter][s];
                if(t<c*L-1e-9 || t>=(c+1)*L-1e-9) continue;
                if(!sput(x,0,string_bass(x,c)+(s?((x->fifth[c]-x->bass[c]+12)%12):0),t,.9,.78f,KV_STROKE_PIZZICATO,true)) return false;
            }
            unsigned k=0; for(double t=c*L+(busy?0:.5);t<(c+1)*L-1e-9;t+=busy?.5:1,k++)
                if((!busy || fmod(t+1e-9,1)>.01) && !sput(x,1,parts[orders[order][k%4]%n],t,.45,.6f,KV_STROKE_PIZZICATO,true)) return false;
                else if(busy && fmod(t+1e-9,1)<=.01 && t>c*L+1e-9 && !sput(x,1,parts[n-1],t,.45,.52f,KV_STROKE_PIZZICATO,true)) return false;
        }
    }
    out->controlled=false;
    sort_and_merge(out,false); kv_performance_resolve_overlaps(out); return kv_performance_valid(out);
}
void kv_performance_resolve_overlaps(KvPerformance *p) {
    if(!p) return;
    bool removed[KV_PERFORMANCE_CAPACITY]={0};
    for(size_t i=0;i<p->count;i++) {
        if(removed[i]) continue;
        for(size_t j=i+1;j<p->count;j++) {
            if(removed[j] || p->events[j].midi!=p->events[i].midi) continue;
            KvPianoEvent *a=&p->events[i],*b=&p->events[j];
            if(b->beat>=a->beat+a->duration-1e-9) break; // the next same-pitch note starts after this one ends
            if(b->beat-a->beat<.05) {
                // Same onset: keep one note, the longer and louder of the two. A clearly longer note keeps its hand
                // (a held bass octave under a passing arpeggio tone stays in the left hand); a true doubling is right-hand.
                if(b->duration>a->duration+.1) a->hand=b->hand; else if(b->duration>=a->duration-.1 && b->hand) a->hand=1;
                if(b->duration>a->duration) a->duration=b->duration;
                if(b->velocity>a->velocity) a->velocity=b->velocity;
                a->fill|=b->fill; removed[j]=true; continue;
            }
            // A short right-hand note would be cut to nothing by a left-hand doubling of its key: drop the doubling instead.
            if(a->hand && !b->hand && b->beat-a->beat<.25) { removed[j]=true; continue; }
            a->duration=b->beat-a->beat; break;
        }
    }
    size_t kept=0; for(size_t i=0;i<p->count;i++) if(!removed[i]) p->events[kept++]=p->events[i];
    p->count=kept;
}
bool kv_arrange_with(const KvChord *chords,size_t count,int base,KvKey key,KvArrangement a,KvPerformance *out) {
    if(!out) return false; memset(out,0,sizeof(*out));
    if(!chords || !count || count>8 || base<36 || base>84 || base%12) return false;
    if(a.style<0 || a.style>=KV_PATTERN_COUNT || a.meter<0 || a.meter>=KV_METER_COUNT || a.length<0 || a.length>=KV_LENGTH_COUNT || a.fills<0 || a.fills>=KV_FILL_COUNT) return false;
    if((a.arpeggio || a.strings) && (a.arpeggio_pattern<0 || a.arpeggio_pattern>=KV_ARP_COUNT || a.division<0 || a.division>=KV_DIV_COUNT)) return false;
    if(a.strings<0 || a.strings>=KV_STRINGS_COUNT) return false;
    for(size_t c=0;c<count;c++) {
        if(chords[c].count<3 || chords[c].count>7) return false;
        for(size_t v=0;v<chords[c].count;v++) if(chords[c].midi[v]<21 || chords[c].midi[v]>127 || (v && chords[c].midi[v]<=chords[c].midi[v-1])) return false;
    }
    Plan x={0}; x.chords=chords; x.count=count; x.base=base; x.key=key; x.a=a; x.out=out; x.forced=-1;
    x.bar=kv_meter_bar(a.meter); x.pulse=kv_meter_pulse(a.meter);
    x.length=a.preview?x.bar:kv_chord_beats(a.meter,a.length);
    x.total=count*x.length; x.bars=(size_t)ceil(x.total/x.bar-1e-9); if(x.bars>32) return false;
    out->chord_count=count; out->beats_per_chord=x.length; out->beats_per_bar=x.bar; out->total_beats=x.total;
    if(a.blocks) {
        // Block chords: strike on the chord, then again on the strong beats of each further bar it spans.
        static const double strong[KV_METER_COUNT][2]={{0,2},{0,0},{0,1.5}};
        for(size_t c=0;c<count;c++) {
            double times[16],span_end=(c+1)*x.length; unsigned hits=0;
            times[hits++]=c*x.length;
            if(x.length>=x.bar) for(double bar=floor(c*x.length/x.bar+1e-9)*x.bar;bar<span_end-1e-9;bar+=x.bar) for(int s=0;s<2;s++) {
                double t=bar+strong[a.meter][s]; if(t>times[hits-1]+1e-9 && t<span_end-1e-9 && t>=c*x.length && hits<16) times[hits++]=t;
            }
            float velocity=(float)fmin(1,sqrt(2.0/chords[c].count));
            for(unsigned h=0;h<hits;h++) {
                double until=h+1<hits?times[h+1]:(c+1)*x.length;
                int voiced[8]; size_t nv=kv_chord_voiced(&chords[c],voiced);
                for(size_t v=0;v<nv;v++) {
                    int note=voiced[v]; while(note>108) note-=12; // keep the top of wide chords on the keyboard
                    if(!put(&x,v?1:0,note,times[h],fmax(.2,until-times[h]-.05),velocity,false)) return false;
                }
            }
        }
        sort_and_merge(out,false); kv_performance_resolve_overlaps(out); return kv_performance_valid(out);
    }
    // Seven scale steps up from the octave above the bass: the octave itself, or 1.4 octaves of a pentatonic.
    { int n=0; for(int midi=base+12;midi<=base+35 && n<7;midi++) if(kv_in_scale(key,midi)) x.scale[n++]=midi; if(n<7) return false; }
    int previous[3]={0};
    for(size_t c=0;c<count;c++) {
        int triad[3]={chords[c].midi[0],chords[c].midi[1],chords[c].midi[2]};
        voicing(triad,base,c?previous:NULL,x.right[c]); if(!x.right[c][0]) return false; memcpy(previous,x.right[c],sizeof(previous));
        // The bass is the chosen inversion's tone; its partner the fifth in root position, else the root above it.
        int bt=chords[c].bass>=0 && chords[c].bass<(int)chords[c].count?chords[c].bass:0;
        x.bass[c]=base+pc(chords[c].midi[bt]); if(x.bass[c]>base+5) x.bass[c]-=12;
        x.fifth[c]=bt?x.bass[c]+pc(chords[c].midi[0]-chords[c].midi[bt]+120):x.bass[c]+chords[c].midi[2]-chords[c].midi[0];
        if(x.fifth[c]>base+11) x.fifth[c]-=12; // stay under the right hand
        // A chord outside the key changes the melody's scale under it: the neighbour of each foreign chord tone gives way
        // to it (raised tones replace the step below, lowered ones the step above), so the tune never rubs against the chord.
        memcpy(x.cscale[c],x.scale,sizeof(x.scale)); unsigned tones=0; for(size_t v=0;v<chords[c].count;v++) tones|=1u<<pc(chords[c].midi[v]);
        int lean=chords[c].lean;
        if(lean) for(size_t v=0;v<chords[c].count;v++) {
            int t=pc(chords[c].midi[v]); if(kv_contains(key,t)) continue;
            for(int side=0;side<2;side++) { int from=(t-(side?-lean:lean)+12)%12; bool done=false;
                if(tones>>from&1u) continue;
                for(int i=0;i<7;i++) if(pc(x.cscale[c][i])==from) { x.cscale[c][i]+=side?-lean:lean; done=true; }
                if(done) break; }
        }
        x.cmask[c]=tones; for(int i=0;i<7;i++) x.cmask[c]|=1u<<pc(x.cscale[c][i]);
    }
    x.random=a.generated?(a.seed?a.seed:1):(0x2545F491u^((uint32_t)(a.style+1)*0x9E3779B9u));
    if(a.strings) return strings_arrangement(&x);
    if(a.arpeggio) return arpeggio_arrangement(&x);
    // The variation plan. Randomness picks whole figures (a cell for a two-bar question, another for its answer,
    // a bass figure, a density), never single notes; the template (generated=false) always takes the first choice.
    unsigned family=random_next(&x.random)%4; (void)family;
    x.bass_style=BASS_TEMPLATE; x.density=DENSITY_NORMAL; x.support_mode=SUPPORT_BAR; x.anchor=base+19; x.accent=1;
    if(a.generated) {
        static const int bass_choices[KV_PATTERN_COUNT][4]={
            {BASS_TEMPLATE,BASS_HALVES,BASS_ARPEGGIO,BASS_PEDAL},{BASS_TEMPLATE,BASS_HALVES,BASS_ARPEGGIO,BASS_ARPEGGIO},{BASS_TEMPLATE,BASS_HALVES,BASS_ARPEGGIO,BASS_WALK},
            {BASS_TEMPLATE,BASS_HALVES,BASS_ARPEGGIO,BASS_PEDAL},{BASS_TEMPLATE,BASS_HALVES,BASS_TEMPLATE,BASS_ARPEGGIO},{BASS_TEMPLATE,BASS_HALVES,BASS_WALK,BASS_PEDAL},
            {BASS_TEMPLATE,BASS_HALVES,BASS_WALK,BASS_PEDAL},{BASS_TEMPLATE,BASS_PEDAL,BASS_HALVES,BASS_PEDAL},{BASS_TEMPLATE,BASS_HALVES,BASS_ARPEGGIO,BASS_WALK}};
        x.bass_style=bass_choices[a.style][random_next(&x.random)%4];
        unsigned density=random_next(&x.random)%3;
        x.density=a.style==KV_AMBIENT?(density==DENSITY_BUSY?DENSITY_NORMAL:(int)density):style_cells(a.style)==CELL_FLOWING && density==DENSITY_BUSY?DENSITY_NORMAL:(int)density;
        x.support_mode=(int)(random_next(&x.random)%3); x.anchor=base+16+3*(int)(random_next(&x.random)%3); x.accent=(int)(random_next(&x.random)%2);
    }
    {
        unsigned question=family,answer=a.generated?(question+1+random_next(&x.random)%3)%4:(question+1)%4,contour=a.generated?random_next(&x.random)%4:family;
        for(size_t b=0;b<x.bars;b++) {
            if(a.generated && b && b%4==0) { question=random_next(&x.random)%4; answer=(question+1+random_next(&x.random)%3)%4; contour=random_next(&x.random)%4; }
            bool second=(b%4)>=2;
            x.cell_of_bar[b]=(unsigned char)(second?answer:question);
            x.contour_of_bar[b]=(unsigned char)(a.generated?contour:family); x.invert_bar[b]=(unsigned char)(second && (b%4)==2);
        }
    }
    KvFillRate rate=a.preview?KV_FILL_NONE:kv_fill_rate(a.style,a.fills);
    unsigned phrase=x.bars%4==0?4:x.bars%2==0?2:(unsigned)x.bars;
    for(size_t b=0;b<x.bars;b++) {
        x.fill_bar[b]=rate==KV_FILL_EVERY_BAR || (rate==KV_FILL_EVERY_2 && ((b+1)%2==0 || b+1==x.bars)) || (rate==KV_FILL_EVERY_4 && (b+1)%phrase==0);
        x.fill_kind[b]=(unsigned char)(random_next(&x.random)%3);
    }
    if(rate!=KV_FILL_EVERY_BAR) for(size_t b=x.bars;b-->1;) if(x.fill_bar[b] && x.fill_bar[b-1]) x.fill_bar[b-1]=false;
    bool written=a.style<=KV_WALTZ && !a.generated;
    if(written) for(size_t b=0;b<x.bars;b++) if(x.fill_kind[b]==FILL_NEIGHBOR) x.fill_kind[b]=FILL_RUN;
    x.last=x.anchor;
    for(size_t b=0;b<x.bars;b++) {
        double start=b*x.bar,end=bar_end(&x,b),fill_start=fmax(start,end-x.pulse);
        bool pickup=x.fill_bar[b] && x.fill_kind[b]==FILL_BASS;
        // Left hand: the style's written bar, or the variation's bass figure.
        if(!bass_bar(&x,b,pickup?fill_start:end)) return false;
        // Every chord that starts inside the bar is announced by its bass.
        for(size_t c=chord_at(&x,start);c<count && c*x.length<end-1e-9;c++) if(c*x.length>start+1e-9 && (!pickup || c*x.length<fill_start-1e-9))
            if(!put(&x,0,x.bass[c],c*x.length,fmin(x.length,x.pulse)*.9,.70f,false)) return false;
        if(pickup && !bass_pickup(&x,b)) return false;
        // Right hand.
        if(written) {
            const HitBar *right=&RIGHT[a.style][a.meter][b%2 && RIGHT[a.style][a.meter][1].count?1:0];
            bool fill=x.fill_bar[b] && !pickup;
            if(!place_hits(&x,b,right,1,fill?fill_start:end)) return false;
            for(size_t c=chord_at(&x,start);c<count && c*x.length<end-1e-9;c++) {
                double span=fmax(c*x.length,start); if(chord_at(&x,span)!=c || (fill && span>=fill_start-1e-9)) continue;
                int tones[7],nt=tones_of(&x,c,tones);
                if(span==c*x.length && nt>3 && !put(&x,1,tones[3],span,fmin(.9,(c+1)*x.length-span),.55f,false)) return false;
                if(span==c*x.length && nt>4) { double t=span+fmin(x.length,x.bar)/2; if((!fill || t<fill_start-1e-9) && !put(&x,1,tones[nt-1],t,fmin(.9,(c+1)*x.length-t),.55f,false)) return false; }
            }
            if(fill) {
                // Continue from the note actually heard last when the whole (partial) bar is a fill after a fill.
                bool continues=b && x.fill_bar[b-1] && x.fill_kind[b-1]!=FILL_BASS && fill_start<=start+1e-9;
                if(!continues) x.last=x.right[chord_at(&x,fill_start)][2];
                if(!run_fill(&x,b,false)) return false; x.forced=-1;
            }
        } else if(!melody_bar(&x,b,style_cells(a.style))) return false;
    }
    out->controlled=!written;
    sort_and_merge(out,out->controlled); kv_performance_resolve_overlaps(out);
    return kv_performance_valid(out) && (!out->controlled || kv_arrangement_controlled(out));
}

void kv_note_roles(const KvPerformance *p,const unsigned *masks,size_t chords,unsigned char *roles) {
    if(!p || !roles) return;
    for(size_t i=0;i<p->count;i++) roles[i]=KV_ROLE_CHORD;
    if(!masks || !chords || p->beats_per_chord<=0) return;
    double span=p->beats_per_chord,lead=span>=2?1:span/2;
    for(size_t i=0;i<p->count;i++) {
        const KvPianoEvent *e=&p->events[i]; int pc=((e->midi%12)+12)%12;
        size_t c=(size_t)floor(e->beat/span+1e-9); if(c>=chords) c=chords-1;
        if(masks[c]>>pc&1u) continue;
        size_t next=(c+1)%chords; double change=(double)(c+1)*span;
        roles[i]=(masks[next]>>pc&1u) && e->beat>=change-lead-1e-9?KV_ROLE_ANTICIPATION:KV_ROLE_PASSING;
    }
}

const char *kv_articulation_name(KvArticulation articulation) {
    static const char *names[KV_ARTICULATION_COUNT]={"Авто","Легато","Стаккато","Пиццикато"};
    return articulation>=0 && articulation<KV_ARTICULATION_COUNT?names[articulation]:"";
}
void kv_string_strokes(const KvPerformance *p,KvArticulation articulation,unsigned char *strokes) {
    if(!p || !strokes) return;
    for(size_t i=0;i<p->count;i++) {
        const KvPianoEvent *e=&p->events[i];
        if(e->stroke>0 && e->stroke<=KV_STROKE_COUNT) { strokes[i]=(unsigned char)(e->stroke-1); continue; }
        if(articulation==KV_ARTICULATION_STACCATO) { strokes[i]=KV_STROKE_SPICCATO; continue; }
        if(articulation==KV_ARTICULATION_PIZZICATO) { strokes[i]=KV_STROKE_PIZZICATO; continue; }
        if(articulation==KV_ARTICULATION_AUTO && e->duration<.5-1e-6) { strokes[i]=KV_STROKE_SPICCATO; continue; }
        bool joined=false;
        for(size_t j=0;j<i && !joined;j++) {
            const KvPianoEvent *b=&p->events[j];
            joined=b->hand==e->hand && b->beat<e->beat-1e-6 && b->beat+b->duration>=e->beat-.05 && strokes[j]<=KV_STROKE_LEGATO;
        }
        strokes[i]=joined?KV_STROKE_LEGATO:KV_STROKE_SUSTAIN;
    }
}
