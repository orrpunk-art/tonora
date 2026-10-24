#include "mixer.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#define RATE 44100
#define VOICES 64
/* One recording being read: position and pitch ratio in recording frames, an optional sustain loop. */
struct Head { KvSampleView s; double pos,ratio,loop_start,loop_end,crossfade; };
/* bowed: a sustained strings voice — two heads (soft and loud recording of the same note) mixed by the dynamics.
   ring: a short stroke (spiccato, pizzicato) that plays its recording out; neither its gate nor a key-up stops it. */
struct Voice { struct Head head[2]; int heads; float tone[2]; uint64_t age,gate; unsigned attack,release_floor,release,release_total,note_release; float release_level,gain; int midi; unsigned hand; unsigned char stroke; bool active,preview,held,sequenced,bowed,strings,ring; };
#define CAP KV_PERFORMANCE_CAPACITY
struct KvMixer { const KvPianoBank *banks[KV_INSTRUMENTS]; struct Voice voices[VOICES]; int sequence[CAP]; uint64_t onset[CAP],gate[CAP]; float gain[CAP],velocity[CAP]; unsigned chord[CAP],hand[CAP]; unsigned short source[CAP]; unsigned char stroke[CAP],event_stroke[CAP],round_robin[128];
    KvPerformance performance; bool custom,humanize,loop,marking_preview,marking_held; uint32_t random; size_t count,next,stride; uint64_t interval,sequence_start,clock,cycle_end,cycle; int instrument;
    KvArticulation articulation; float dynamics_target,dynamics_now,expression_target,expression_now; };
KvMixer *kv_mixer_create(void) {
    KvMixer *m=calloc(1,sizeof(KvMixer));
    if(m) { m->humanize=true; m->random=0x746f6e6f; m->dynamics_target=m->dynamics_now=.6f; m->expression_target=m->expression_now=1; }
    return m;
}
void kv_mixer_humanize(KvMixer *m,bool enabled) { if(m) m->humanize=enabled; }
static float random_unit(KvMixer *m) { m->random^=m->random<<13; m->random^=m->random>>17; m->random^=m->random<<5; return (float)(m->random&65535)/65535; }
static float humanity(KvMixer *m) { return m->humanize?.94f+.12f*random_unit(m):1; }
void kv_mixer_free(KvMixer *mixer) { free(mixer); }
void kv_mixer_bank(KvMixer *mixer,int instrument,const KvPianoBank *bank) { if(mixer && instrument>=0 && instrument<KV_INSTRUMENTS) mixer->banks[instrument]=bank; }
static float envelope(const struct Voice *v) {
    float attack=v->age<v->attack?(float)(.5-.5*cos(M_PI*v->age/(double)v->attack)):1;
    if(v->release_total) return v->release_level*(float)(.5-.5*cos(M_PI*v->release/v->release_total));
    return attack;
}
/* Fade out over `frames` (only ever shortens a running fade). */
static void cut(struct Voice *v,unsigned frames) {
    if(!v->active || (v->release_total && v->release<=frames)) return;
    v->release_level=envelope(v); v->release=v->release_total=frames;
}
static void release(struct Voice *v,unsigned frames) { cut(v,frames<v->release_floor?v->release_floor:frames); }   // a bow leaves the string slowly
void kv_mixer_stop(KvMixer *m) { if(!m) return; m->loop=false; m->count=m->next=0; for(int i=0;i<VOICES;i++) cut(&m->voices[i],441); }
static bool open_head(const KvPianoBank *bank,int midi,int layer,struct Head *h) {
    KvSampleView s; if(!kv_piano_layer(bank,midi,layer,&s)) return false;
    *h=(struct Head){.s=s,.ratio=pow(2,(midi-s.midi)/12.0-s.cents/1200.0)}; return true;
}
/* A held bow sustains as long as wanted: the middle of the recording (past the attack, before its end) loops with an
   equal-power crossfade. */
static void loop_head(struct Head *h) {
    if(h->s.frames<=RATE*2) return;
    h->loop_start=h->s.frames*.3; h->loop_end=h->s.frames*.9-2; h->crossfade=fmin(RATE*.6,(h->loop_end-h->loop_start)/2);
}
/* Reads one interpolated stereo frame and advances; false once a non-looping recording has run out. */
static bool head_step(struct Head *h,float *left,float *right) {
    size_t at=(size_t)h->pos; if(at+1>=h->s.frames) return false;
    const float *p=h->s.pcm; float mix=(float)(h->pos-at),x[2];
    for(int c=0;c<2;c++) x[c]=p[at*2+c]*(1-mix)+p[(at+1)*2+c]*mix;
    if(h->loop_end>0 && h->pos>h->loop_end-h->crossfade) {
        // Approaching the loop end: blend in the same place one loop earlier, then jump there unheard.
        double back=h->pos-(h->loop_end-h->loop_start); size_t b=(size_t)back; float bmix=(float)(back-b);
        float t=(float)((h->pos-(h->loop_end-h->crossfade))/h->crossfade),out=cosf(t*(float)M_PI_2),in=sinf(t*(float)M_PI_2);
        for(int c=0;c<2;c++) x[c]=x[c]*out+(p[b*2+c]*(1-bmix)+p[(b+1)*2+c]*bmix)*in;
    }
    *left=x[0]; *right=x[1];
    h->pos+=h->ratio; if(h->loop_end>0 && h->pos>=h->loop_end) h->pos-=h->loop_end-h->loop_start;
    return true;
}
/* The stroke a keyboard note gets: legato is decided when it sounds (an overlapped held key), short strokes by the choice. */
static int live_stroke(const KvMixer *m,bool legato) {
    return m->articulation==KV_ARTICULATION_STACCATO?KV_STROKE_SPICCATO:m->articulation==KV_ARTICULATION_PIZZICATO?KV_STROKE_PIZZICATO:legato?KV_STROKE_LEGATO:KV_STROKE_SUSTAIN;
}
static void note_on(KvMixer *m,int midi,uint64_t gate,int instrument,float gain,unsigned note_release,int stroke,unsigned hand,float velocity,bool sequenced) {
    const KvPianoBank *bank=m->banks[instrument]; bool strings=instrument==KV_INSTRUMENT_STRINGS,bowed=strings && stroke<=KV_STROKE_LEGATO;
    if(bowed && stroke==KV_STROKE_LEGATO && sequenced)
        // A tone common to two chords is not bowed again: the voice already holding it goes on.
        for(int i=0;i<VOICES;i++) { struct Voice *v=&m->voices[i];
            if(v->active && v->bowed && v->sequenced && v->midi==midi && !v->release_total && v->gate<=v->age+2646) { v->gate=v->age+gate; return; } }
    for(int i=0;i<VOICES;i++) if(m->voices[i].active && m->voices[i].midi==midi) cut(&m->voices[i],strings && m->voices[i].bowed?2205:529);
    struct Voice *slot=NULL; for(int i=0;i<VOICES && !slot;i++) if(!m->voices[i].active) slot=&m->voices[i];
    if(!slot) return;
    // Match the hotter electric-piano recordings to the acoustic bank; strings are level-matched per recording.
    static const float bank_gain[KV_INSTRUMENTS]={1,.25f,.28f,1.3f};
    struct Voice v={.gate=gate,.gain=gain*bank_gain[instrument],.note_release=note_release,.midi=midi,.hand=hand,.stroke=(unsigned char)stroke,.active=true,
                    .preview=m->marking_preview,.held=m->marking_held,.sequenced=sequenced,.strings=strings,.attack=176,.heads=1};
    if(!strings) { if(!open_head(bank,midi,0,&v.head[0])) return; }
    else if(bowed) {
        if(!open_head(bank,midi,0,&v.head[0])) return;
        loop_head(&v.head[0]); if(open_head(bank,midi,1,&v.head[1])) { loop_head(&v.head[1]); v.heads=2; }
        v.bowed=true; v.attack=(unsigned)(RATE*.03); v.release_floor=(unsigned)(RATE*.7);   // the recording carries the bow's own attack
        if(stroke==KV_STROKE_LEGATO) {
            // Legato: the line passes from the closest note that is ending (on a keyboard: a key held for more than 80 ms,
            // so a chord struck together is not legato) to this one, without a new bow attack.
            struct Voice *from=NULL;
            for(int i=0;i<VOICES;i++) { struct Voice *o=&m->voices[i];
                if(!o->active || !o->bowed) continue;
                bool ending=sequenced?(o->sequenced && o->hand==hand && (o->release_total?o->release_total-o->release<=4410:o->gate<=o->age+2646))
                                    :(o->held && !o->release_total && o->age>=3528);
                if(ending && (!from || abs(o->midi-midi)<abs(from->midi-midi))) from=o; }
            // It starts where its recording is steady (the loop start, seconds in), so it is already at full voice.
            if(from) { cut(from,3969); v.attack=3087; for(int h=0;h<v.heads;h++) v.head[h].pos=v.head[h].loop_end>0?v.head[h].loop_start:fmin(RATE*.12,v.head[h].s.frames/2.0); }
        }
    } else {
        // Short strokes: the soft or loud recording by velocity, two takes alternating so repeats are not identical.
        int layer=(stroke==KV_STROKE_PIZZICATO?6:2)+(velocity>=.62f?2:0)+m->round_robin[midi]; m->round_robin[midi]^=1;
        if(!open_head(bank,midi,layer,&v.head[0]) && !open_head(bank,midi,0,&v.head[0])) return;
        v.attack=88; v.ring=true;
    }
    *slot=v;
}
static void schedule(KvMixer *m) {
    if(m->custom) {
        for(size_t i=0;i<m->count;i++) {
            KvPianoEvent event=m->performance.events[i];
            int64_t onset=(int64_t)llround(event.beat*m->interval);
            if(m->humanize && event.beat>0) {
                double eighth=event.beat*2;
                if(fabs(eighth-round(eighth))<.001 && ((int)lround(eighth))%2) onset+=(int64_t)fmin(529,m->interval*.025);
                onset+=(int64_t)((random_unit(m)*2-1)*220);
                int64_t boundary=(int64_t)(event.chord*m->performance.beats_per_chord*m->interval);
                if(onset<boundary) onset=boundary;
            }
            m->sequence[i]=event.midi; m->onset[i]=(uint64_t)onset;
            m->gate[i]=(uint64_t)llround(event.duration*m->interval);
            m->gain[i]=.70f*event.velocity*humanity(m)/sqrtf(2); m->chord[i]=event.chord;
            m->velocity[i]=event.velocity; m->hand[i]=event.hand; m->source[i]=(unsigned short)i;
        }
        kv_string_strokes(&m->performance,m->articulation,m->event_stroke);
        for(size_t i=0;i<m->count;i++) m->stroke[i]=m->event_stroke[i];
    }
    size_t voices=m->stride;
    for(size_t i=0;!m->custom && i<m->count;i++) {
        size_t event=i/voices;
        int64_t onset=(int64_t)(event*m->interval);
        if(m->humanize) {
            // Subtle swing (max 12 ms) and bounded jitter, never accumulated drift.
            if(event%2) onset+=(int64_t)fmin(529,m->interval*.025);
            if(event) onset+=(int64_t)((random_unit(m)*2-1)*220);
            if(i%voices) onset+=(int64_t)(random_unit(m)*176);
        }
        m->onset[i]=(uint64_t)(onset<0?0:onset); m->gain[i]=.70f*humanity(m)/sqrtf((float)voices); m->gate[i]=m->interval; m->chord[i]=(unsigned)event;
        m->velocity[i]=.7f; m->hand[i]=1; m->source[i]=(unsigned short)i; m->stroke[i]=(unsigned char)live_stroke(m,false);
    }
    // Keep microtimed chord tones in chronological order without allocations.
    for(size_t i=1;i<m->count;i++) {
        size_t j=i;
        while(j && m->onset[j]<m->onset[j-1]) {
            uint64_t t=m->onset[j]; m->onset[j]=m->onset[j-1]; m->onset[j-1]=t;
            int note=m->sequence[j]; m->sequence[j]=m->sequence[j-1]; m->sequence[j-1]=note;
            float gain=m->gain[j]; m->gain[j]=m->gain[j-1]; m->gain[j-1]=gain;
            uint64_t gate=m->gate[j]; m->gate[j]=m->gate[j-1]; m->gate[j-1]=gate;
            unsigned chord=m->chord[j]; m->chord[j]=m->chord[j-1]; m->chord[j-1]=chord;
            float velocity=m->velocity[j]; m->velocity[j]=m->velocity[j-1]; m->velocity[j-1]=velocity;
            unsigned hand=m->hand[j]; m->hand[j]=m->hand[j-1]; m->hand[j-1]=hand;
            unsigned short source=m->source[j]; m->source[j]=m->source[j-1]; m->source[j-1]=source;
            unsigned char stroke=m->stroke[j]; m->stroke[j]=m->stroke[j-1]; m->stroke[j-1]=stroke; j--;
        }
    }
    m->cycle_end=m->custom?(uint64_t)llround(m->performance.total_beats*m->interval):(m->count/m->stride)*m->interval;
}
void kv_mixer_loop(KvMixer *m,bool enabled) {
    if(!m) return;
    if(enabled && !m->loop && m->count && m->next==m->count && m->clock-m->sequence_start>=m->cycle_end) {
        m->sequence_start=m->clock; m->cycle++; m->next=0; schedule(m);
    }
    m->loop=enabled && m->count>0;
}
bool kv_mixer_play(KvMixer *m,const int *notes,size_t count,size_t voices,double duration,int instrument,bool overlay) {
    if(!m || !notes || !count || count>256 || !voices || voices>8 || count%voices || duration<.08 || duration>3 || !isfinite(duration) || instrument<0 || instrument>=KV_INSTRUMENTS || !m->banks[instrument]) return false;
    for(size_t i=0;i<count;i++) if(notes[i]<21 || notes[i]>108) return false;
    if(overlay) {
        // An auditioned note joins whatever is scheduled; the sequence, its loop and its clock are untouched.
        for(size_t i=0;i<count;i++) note_on(m,notes[i],(uint64_t)llround(duration*RATE),instrument,.70f*humanity(m)/sqrtf((float)voices),11025,live_stroke(m,false),1,.7f,false);
        if(!m->count) m->sequence_start=m->clock;
        return true;
    }
    m->custom=false; m->loop=false; m->cycle=0;
    {
        m->next=0; m->count=count; m->stride=voices; m->interval=(uint64_t)llround(duration*RATE); m->instrument=instrument;
        memcpy(m->sequence,notes,count*sizeof(int));
        schedule(m);
        for(int i=0;i<VOICES;i++) release(&m->voices[i],1323);
    }
    m->sequence_start=m->clock; return true;
}
/* A key held on a keyboard: sounds until kv_mixer_release (or the sample dies away); velocity 0…1. */
bool kv_mixer_hold(KvMixer *m,int midi,float velocity,int instrument) {
    if(!m || midi<21 || midi>108 || !isfinite(velocity) || instrument<0 || instrument>=KV_INSTRUMENTS || !m->banks[instrument]) return false;
    velocity=fmaxf(0,fminf(1,velocity));
    m->marking_held=true; note_on(m,midi,(uint64_t)RATE*120,instrument,.70f*humanity(m)*(.35f+.65f*velocity),2646,live_stroke(m,true),1,velocity,false); m->marking_held=false;
    if(!m->count) m->sequence_start=m->clock;
    return true;
}
/* The key went up: its held voice fades out in 60 ms (a bow in 0.7 s; a plucked or bounced note rings on).
   midi < 0 releases every held key. Other voices are untouched. */
void kv_mixer_release(KvMixer *m,int midi) {
    if(!m) return;
    for(int i=0;i<VOICES;i++) { struct Voice *v=&m->voices[i];
        if(v->active && v->held && (midi<0 || v->midi==midi)) { if(v->ring) v->gate=v->age; else release(v,2646); } }
}
void kv_mixer_articulation(KvMixer *m,KvArticulation articulation) {
    if(!m || articulation<0 || articulation>=KV_ARTICULATION_COUNT) return;
    m->articulation=articulation;
    if(m->custom) { kv_string_strokes(&m->performance,articulation,m->event_stroke); for(size_t i=0;i<m->count;i++) m->stroke[i]=m->event_stroke[m->source[i]]; }
    else for(size_t i=0;i<m->count;i++) m->stroke[i]=(unsigned char)live_stroke(m,false);
}
void kv_mixer_dynamics(KvMixer *m,float dynamics,float expression) {
    if(!m || !isfinite(dynamics) || !isfinite(expression)) return;
    m->dynamics_target=fmaxf(0,fminf(1,dynamics)); m->expression_target=fmaxf(0,fminf(1,expression));
}
bool kv_mixer_preview(KvMixer *m,int midi,double duration,int instrument) {
    if(!m || midi<21 || midi>108 || !isfinite(duration) || duration<.08 || duration>3 || instrument<0 || instrument>=KV_INSTRUMENTS || !m->banks[instrument]) return false;
    for(int i=0;i<VOICES;i++) if(m->voices[i].active && m->voices[i].preview) release(&m->voices[i],529);
    m->marking_preview=true; note_on(m,midi,(uint64_t)llround(duration*RATE),instrument,.70f*humanity(m),2646,live_stroke(m,false),1,.7f,false); m->marking_preview=false;
    if(!m->count) m->sequence_start=m->clock;
    return true;
}
bool kv_mixer_performance(KvMixer *m,const KvPerformance *p,double seconds,int instrument) {
    if(!m || !kv_performance_valid(p) || !isfinite(seconds) || seconds<.25 || seconds>5 || instrument<0 || instrument>=KV_INSTRUMENTS || !m->banks[instrument]) return false;
    m->performance=*p; m->custom=true; m->loop=false; m->cycle=0; m->next=0; m->count=p->count; m->stride=1;
    m->interval=(uint64_t)llround(seconds*RATE); m->instrument=instrument; m->sequence_start=m->clock;
    schedule(m); for(int i=0;i<VOICES;i++) release(&m->voices[i],1323); return true;
}
void kv_mixer_render(KvMixer *m,float *stereo,size_t frames) {
    memset(stereo,0,frames*2*sizeof(float));
    for(size_t f=0;f<frames;f++,m->clock++) {
        if(m->loop && m->next==m->count && m->clock-m->sequence_start>=m->cycle_end) {
            m->sequence_start+=m->cycle_end; m->cycle++; m->next=0; schedule(m);
        }
        while(m->next<m->count && m->clock-m->sequence_start>=m->onset[m->next]) {
            size_t n=m->next;
            note_on(m,m->sequence[n],m->gate[n],m->instrument,m->gain[n],m->custom && m->performance.controlled?(unsigned)fmin(2646,m->interval*.12):11025,m->stroke[n],m->hand[n],m->velocity[n],true); m->next++;
        }
        // Dynamics (mod wheel, the slider) move smoothly (~45 ms). In a texture every chord breathes: a swell to its middle and
        // back, as deep as the dynamics are high. The soft and loud recordings cross-fade with equal power, the level follows.
        m->dynamics_now+=(m->dynamics_target-m->dynamics_now)*.0005f; m->expression_now+=(m->expression_target-m->expression_now)*.0005f;
        float weights[2][4];
        for(int kind=0;kind<2;kind++) {
            float d=m->dynamics_now;
            if(kind && m->custom && m->count && m->performance.beats_per_chord>0 && m->interval) {
                double beats=(double)(m->clock-m->sequence_start)/m->interval,phase=fmod(beats,m->performance.beats_per_chord)/m->performance.beats_per_chord;
                d*=1-.45f*d*(1-(float)sin(M_PI*phase));
            }
            float level=(.3f+.7f*d)*m->expression_now;
            weights[kind][0]=cosf(d*(float)M_PI_2)*level; weights[kind][1]=sinf(d*(float)M_PI_2)*level; weights[kind][2]=level;
            // The soft and loud recordings of this library differ little in colour, so a gentle low-pass opens with the
            // dynamics as in orchestral libraries: 1.5 kHz at the softest, wide open at the loudest.
            weights[kind][3]=1-expf(-2*(float)M_PI*1500*exp2f(4.5f*d)/RATE);
        }
        for(int i=0;i<VOICES;i++) {
            struct Voice *v=&m->voices[i]; if(!v->active) continue;
            if(v->age>=v->gate && !v->release_total && !v->ring) release(v,v->note_release);
            if(v->release_total && !v->release) { v->active=false; continue; }
            float left,right,gain=v->gain*envelope(v);
            if(!head_step(&v->head[0],&left,&right)) { v->active=false; continue; }
            if(v->bowed) {
                const float *w=weights[v->sequenced];
                if(v->heads==2) { float l2=0,r2=0; head_step(&v->head[1],&l2,&r2); left=left*w[0]+l2*w[1]; right=right*w[0]+r2*w[1]; }
                else { left*=w[2]; right*=w[2]; }
                if(v->age==0) { v->tone[0]=left; v->tone[1]=right; }
                v->tone[0]+=w[3]*(left-v->tone[0]); v->tone[1]+=w[3]*(right-v->tone[1]); left=v->tone[0]; right=v->tone[1];
            }
            // Short strokes take their recording by velocity; the dynamics scale the level around the default (.6 → ×1).
            else if(v->strings) { float s=weights[v->sequenced][2]/.72f; left*=s; right*=s; }
            stereo[f*2]+=left*gain; stereo[f*2+1]+=right*gain;
            v->age++; if(v->release) v->release--;
        }
    }
}
bool kv_mixer_running(const KvMixer *m) {
    if(!m) return false;
    if(m->count && (m->loop || m->clock-m->sequence_start<m->cycle_end)) return true;
    int notes[64]; return kv_mixer_active(m,notes)>0;
}
bool kv_mixer_busy(const KvMixer *m) { if(!m) return false; if(m->loop || m->next<m->count) return true; for(int i=0;i<VOICES;i++) if(m->voices[i].active) return true; return false; }
uint64_t kv_mixer_clock(const KvMixer *m) { return m?m->clock:0; }
uint64_t kv_mixer_start(const KvMixer *m) { return m?m->sequence_start:0; }
unsigned kv_mixer_active(const KvMixer *m,int notes[64]) {
    unsigned count=0; if(!m || !notes) return 0;
    for(int i=0;i<VOICES;i++) if(m->voices[i].active && !m->voices[i].release_total && m->voices[i].age<m->voices[i].gate) {
        bool duplicate=false; for(unsigned j=0;j<count;j++) if(notes[j]==m->voices[i].midi) duplicate=true;
        if(!duplicate) notes[count++]=m->voices[i].midi;
    }
    return count;
}

void kv_mixer_interval(KvMixer *m,double seconds) {
    if(!m || !isfinite(seconds) || seconds<.08 || seconds>5 || !m->interval) return;
    uint64_t frames=(uint64_t)llround(seconds*RATE),elapsed=m->clock-m->sequence_start;
    double ratio=(double)frames/m->interval;
    for(size_t i=m->next;i<m->count;i++) {
        uint64_t remaining=m->onset[i]>elapsed?m->onset[i]-elapsed:0;
        m->onset[i]=elapsed+(uint64_t)llround(remaining*ratio);
        m->gate[i]=(uint64_t)llround(m->gate[i]*ratio);
    }
    uint64_t remaining=m->cycle_end>elapsed?m->cycle_end-elapsed:0;
    m->cycle_end=elapsed+(uint64_t)llround(remaining*ratio);
    m->interval=frames;
}
int kv_mixer_event(const KvMixer *m) {
    if(!m || !m->count || !m->next) return -1;
    size_t chords=m->custom?m->performance.chord_count:m->count/m->stride;
    return (int)(m->cycle*chords+m->chord[m->next-1]);
}
