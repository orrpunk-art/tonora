#include "mixer.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#define RATE 44100
#define VOICES KV_VOICES
#define SPARE 8   /* voices kept free: below this the quietest voice fades out in 3 ms, so a new note always has a slot */
/* One recording being read: position and pitch ratio in recording frames, an optional sustain loop. */
struct Head { KvSampleView s; double pos,ratio,loop_start,loop_end,crossfade; };
/* bowed: a sustained strings voice — two heads (soft and loud recording of the same note) mixed by the dynamics.
   ring: a short stroke (spiccato, pizzicato) that plays its recording out; neither its gate nor a key-up stops it. */
struct Voice { struct Head head[2]; int heads; float tone[2]; uint64_t age,gate; unsigned attack,release_floor,release,release_total,note_release; float release_level,gain; int midi; unsigned hand; unsigned char stroke; bool active,preview,held,sequenced,bowed,strings,ring; };
#define CAP KV_PERFORMANCE_CAPACITY
#define CLICK_FRAMES 2205   /* 50 ms */
enum { CLICK_ACCENT, CLICK_PULSE, CLICK_SUB, CLICKS };
/* A sounding metronome click: which wave, where in it, how loud. */
struct Click { int wave; unsigned pos; float gain; bool active; };
/* The electronic kit, synthesized once per mixer (mono). */
enum { SYNTH_KICK, SYNTH_STICK, SYNTH_SNARE, SYNTH_CLAP, SYNTH_HAT, SYNTH_HAT_OPEN, SYNTH_TAMBOURINE, SYNTH_CONGA_HIGH, SYNTH_CONGA_LOW, SYNTH_SHAKER, SYNTHS };
#define SYNTH_FRAMES 22050
#define DRUM_VOICES 24
/* A sounding drum: its recording (stereo) or synthesized sound (mono), where in it (negative: still waiting, for a humanized
   late start), its level and a choke fade (an open hi-hat closed by the closed one). */
struct Drum { const float *pcm; size_t frames; long pos; unsigned channels,fade,fade_total; float gain; int drum; bool active; };
struct KvMixer { const KvPianoBank *banks[KV_INSTRUMENTS]; struct Voice voices[VOICES]; int sequence[CAP]; uint64_t onset[CAP],gate[CAP]; float gain[CAP],velocity[CAP]; unsigned chord[CAP],hand[CAP]; unsigned short source[CAP]; unsigned char stroke[CAP],event_stroke[CAP],round_robin[128];
    KvPerformance performance; bool custom,humanize,loop,marking_preview,marking_held,pedal; uint32_t random; size_t count,next,stride; uint64_t interval,sequence_start,clock,cycle_end,cycle; int instrument;
    KvArticulation articulation; float dynamics_target,dynamics_now,expression_target,expression_now;
    /* rhythm: on, grid, bar and pulse in beats, step between clicks, frames per beat, origin (frame of beat 0), next click */
    bool rhythm; KvGrid grid; double bar,pulse,step,beat_frames,origin,lead_beats; uint64_t hit; float rhythm_volume;
    struct Click clicks[4]; float click_wave[CLICKS][CLICK_FRAMES]; float dry[KV_DRY_FRAMES*2];
    /* beat: one bar of hits, the next one due (bar, hit), the kit; counting: a count-in is under way */
    const KvPianoBank *drums; KvHit beat[KV_BEAT_HITS]; size_t beat_count,beat_hit; uint64_t beat_bar; bool electronic,counting;
    unsigned char take[128]; struct Drum drum_voices[DRUM_VOICES]; float synth[SYNTHS][SYNTH_FRAMES]; size_t synth_frames[SYNTHS];
    /* the queued part (kv_mixer_queue): its plan, its rhythm (−1 as is, 0 off, 1 on) and hits, and parts started so far */
    KvPerformance queued; bool has_queued; int queued_rhythm; KvHit queued_hits[KV_BEAT_HITS]; size_t queued_hit_count; unsigned part; };
/* Drum-machine sounds: a kick that drops from 150 to 48 Hz, a snare of tone and noise, a stick, a clap of three bursts and a
   tail, closed and open hi-hats and a tambourine of bright noise, two congas, a shaker. Peaks by role. */
static void synthesize_kit(KvMixer *m) {
    static const float length[SYNTHS]={.5f,.1f,.3f,.3f,.12f,.5f,.3f,.3f,.3f,.12f},peak[SYNTHS]={.38f,.18f,.25f,.23f,.13f,.13f,.13f,.23f,.25f,.1f};   // level with the recorded kit (measured RMS of the beats)
    uint32_t seed=0x2545f491;
    for(int k=0;k<SYNTHS;k++) {
        size_t n=(size_t)(length[k]*RATE); float *x=m->synth[k],phase=0,last=0,hp=0,top=0; m->synth_frames[k]=n;
        for(size_t i=0;i<n;i++) {
            float t=(float)i/RATE; seed^=seed<<13; seed^=seed>>17; seed^=seed<<5; float noise=(float)(seed&65535)/32767.5f-1;
            hp=noise-last; last=noise;   // a first difference: noise with its lows taken out
            float v=0;
            switch(k) {
                case SYNTH_KICK: phase+=2*(float)M_PI*(48+102*expf(-t/.03f))/RATE; v=sinf(phase)*expf(-t/.18f)+.15f*noise*expf(-t/.002f); break;
                case SYNTH_STICK: v=(.7f*sinf(2*(float)M_PI*1700*t)+.5f*sinf(2*(float)M_PI*820*t))*expf(-t/.012f)+.4f*noise*expf(-t/.004f); break;
                case SYNTH_SNARE: v=.5f*sinf(2*(float)M_PI*190*t)*expf(-t/.06f)+.7f*hp*expf(-t/.12f); break;
                case SYNTH_CLAP: { float burst=0; for(int b=0;b<3;b++) { float u=t-b*.01f; if(u>=0) burst+=expf(-u/.006f); } v=hp*(burst+.5f*expf(-fmaxf(0,t-.02f)/.08f)*(t>.02f)); break; }
                case SYNTH_HAT: v=hp*expf(-t/.03f); break;
                case SYNTH_HAT_OPEN: v=hp*expf(-t/.25f); break;
                case SYNTH_TAMBOURINE: v=hp*expf(-t/.12f)*(.6f+.4f*sinf(2*(float)M_PI*18*t)); break;
                case SYNTH_CONGA_HIGH: phase+=2*(float)M_PI*(330+40*expf(-t/.02f))/RATE; v=sinf(phase)*expf(-t/.09f); break;
                case SYNTH_CONGA_LOW: phase+=2*(float)M_PI*(220+30*expf(-t/.02f))/RATE; v=sinf(phase)*expf(-t/.12f); break;
                case SYNTH_SHAKER: v=hp*fminf(1,t/.01f)*expf(-t/.05f); break;
            }
            float tail=i+441>n?(float)(n-i)/441:1; x[i]=v*tail; top=fmaxf(top,fabsf(x[i]));   // a 10 ms fade at the end
        }
        if(top>0) for(size_t i=0;i<n;i++) x[i]*=peak[k]/top;
    }
}
static int synth_of(int drum) {
    switch(drum) { case KV_DRUM_KICK: return SYNTH_KICK; case KV_DRUM_STICK: return SYNTH_STICK; case KV_DRUM_SNARE: return SYNTH_SNARE; case KV_DRUM_CLAP: return SYNTH_CLAP;
        case KV_DRUM_HAT: return SYNTH_HAT; case KV_DRUM_HAT_OPEN: return SYNTH_HAT_OPEN; case KV_DRUM_TAMBOURINE: return SYNTH_TAMBOURINE;
        case KV_DRUM_CONGA_HIGH: return SYNTH_CONGA_HIGH; case KV_DRUM_CONGA_LOW: return SYNTH_CONGA_LOW; case KV_DRUM_SHAKER: return SYNTH_SHAKER; default: return -1; }
}
/* A woodblock-like click: a tone with an overtone and a breath of noise, 1 ms rise, ~12 ms decay and a 20 ms fade that
   reaches zero exactly at the end — a wave cut short would tick once more, 50 ms after every beat. Accent higher and louder. */
static void synthesize_clicks(KvMixer *m) {
    static const float pitch[CLICKS]={1975.5f,1318.5f,1318.5f},level[CLICKS]={1,.72f,.38f};
    uint32_t noise=0x9e3779b9;
    for(int c=0;c<CLICKS;c++) for(int i=0;i<CLICK_FRAMES;i++) {
        float t=(float)i/RATE,rise=i<44?(float)i/44:1,decay=expf(-t/.012f);
        int left=CLICK_FRAMES-1-i; float fade=left<882?.5f-.5f*cosf((float)M_PI*left/882):1;
        noise^=noise<<13; noise^=noise>>17; noise^=noise<<5;
        float n=((float)(noise&65535)/32767.5f-1)*expf(-t/.002f)*.25f;
        m->click_wave[c][i]=level[c]*rise*decay*fade*(.8f*sinf(2*(float)M_PI*pitch[c]*t)+.25f*sinf(4*(float)M_PI*pitch[c]*t)+n)*.5f;
    }
}
KvMixer *kv_mixer_create(void) {
    KvMixer *m=calloc(1,sizeof(KvMixer));
    if(m) { m->humanize=true; m->random=0x746f6e6f; m->dynamics_target=m->dynamics_now=.6f; m->expression_target=m->expression_now=1;
            m->bar=4; m->pulse=1; m->step=1; m->beat_frames=RATE*.6; m->rhythm_volume=.6f; synthesize_clicks(m); synthesize_kit(m); }
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
/* Make room: the voice that is quietest now fades out in 3 ms. A struck note (piano, short strokes) is taken as decaying
   over a few seconds, a bowed one as steady, so an old ringing tail goes before a fresh chord. */
static void steal(KvMixer *m) {
    struct Voice *quietest=NULL; float lowest=INFINITY;
    for(int i=0;i<VOICES;i++) { struct Voice *v=&m->voices[i];
        if(!v->active || (v->release_total && v->release<=132)) continue;
        float level=v->gain*envelope(v)*(v->bowed?1:expf(-(float)v->age/(3*RATE)));
        if(level<lowest) { lowest=level; quietest=v; } }
    if(quietest) cut(quietest,132);
}
void kv_mixer_pedal(KvMixer *m,bool down) { if(m) m->pedal=down; }
/* The next hit of the beat: the first one at or after now. */
static void beat_align(KvMixer *m) {
    double at=((double)m->clock-.5-m->origin)/m->beat_frames; if(at<0) at=0;
    uint64_t bar=(uint64_t)floor(at/m->bar+1e-9); size_t j=0;
    while(j<m->beat_count && bar*m->bar+m->beat[j].beat<at-1e-9) j++;
    if(j==m->beat_count) { bar++; j=0; }
    m->beat_bar=bar; m->beat_hit=j;
}
/* The rhythm grid restarts at origin: the next click is the first one at or after now. */
static void rhythm_align(KvMixer *m,double origin) {
    m->origin=origin; double ahead=((double)m->clock-origin)/(m->step*m->beat_frames);
    m->hit=ahead<=0?0:(uint64_t)ceil(ahead-1e-9);
    beat_align(m);
}
/* A new beat length that keeps the current beat: the origin moves so that the beat counted now stays the same. */
static void rhythm_retime(KvMixer *m,double beat_frames) {
    if(fabs(beat_frames-m->beat_frames)<1e-6) return;
    double beat=((double)m->clock-m->origin)/m->beat_frames; m->beat_frames=beat_frames; rhythm_align(m,(double)m->clock-beat*beat_frames);
}
void kv_mixer_rhythm(KvMixer *m,bool on,KvGrid grid,KvMeter meter,double seconds_per_beat,float volume) {
    if(!m || grid<0 || grid>=KV_GRID_COUNT || meter<0 || meter>=KV_METER_COUNT || !isfinite(seconds_per_beat) || seconds_per_beat<.08 || seconds_per_beat>5 || !isfinite(volume)) return;
    bool was=m->rhythm; m->rhythm_volume=fmaxf(0,fminf(1,volume));
    m->bar=kv_meter_bar(meter); m->pulse=kv_meter_pulse(meter); m->grid=grid;
    // 6/8 clicks every eighth (louder on the two dotted quarters); other meters click their beats.
    m->step=grid==KV_GRID_SIXTEENTHS?.25:meter==KV_METER_6_8?.5:grid==KV_GRID_BEATS?1:grid==KV_GRID_TRIPLETS?1.0/3:.5;
    m->rhythm=on; if(!on) return;
    if(was) { rhythm_retime(m,seconds_per_beat*RATE); rhythm_align(m,m->origin); return; }
    m->beat_frames=seconds_per_beat*RATE;
    // Switched on: with a sequence under way it joins the sequence's beats, otherwise it starts now.
    rhythm_align(m,m->count && m->clock>=m->sequence_start?(double)m->sequence_start:(double)m->clock);
}
void kv_mixer_count_in(KvMixer *m,double beats) { if(m && isfinite(beats) && beats>=0 && beats<=16) m->lead_beats=beats; }
double kv_mixer_rhythm_beat(const KvMixer *m) { return m && m->rhythm?((double)m->clock-m->origin)/m->beat_frames:-1; }
const float *kv_mixer_dry(const KvMixer *m) { return m?m->dry:NULL; }
void kv_mixer_drums(KvMixer *m,const KvPianoBank *bank) { if(m) m->drums=bank; }
void kv_mixer_beat(KvMixer *m,const KvHit *hits,size_t count,bool electronic) {
    if(!m || (count && !hits)) return;
    if(count>KV_BEAT_HITS) count=KV_BEAT_HITS;
    if(count) memcpy(m->beat,hits,count*sizeof *hits);
    m->beat_count=count; m->electronic=electronic; beat_align(m);
    if(!count) rhythm_align(m,m->origin);   // back to the click from now on
}
unsigned kv_mixer_drum_voices(const KvMixer *m) { unsigned n=0; if(m) for(int i=0;i<DRUM_VOICES;i++) if(m->drum_voices[i].active) n++; return n; }
/* Strike a drum: the recorded kit's soft or loud layer (two takes alternating), or the synthesized sound. Humanized, it lands
   up to 4 ms late and ±6 % in level; a closed hi-hat chokes an open one. */
static void strike(KvMixer *m,int drum,float velocity) {
    const float *pcm=NULL; size_t frames=0; unsigned channels=1;
    if(m->electronic || !m->drums) { int s=synth_of(drum); if(s<0) return; pcm=m->synth[s]; frames=m->synth_frames[s]; }
    else {
        int layer=(velocity>=.62f?2:0)+(m->take[drum&127]^=1); KvSampleView v;
        if(!kv_piano_layer(m->drums,drum,layer,&v) || v.midi!=drum) return;
        pcm=v.pcm; frames=v.frames; channels=2;
    }
    if(drum==KV_DRUM_HAT) for(int i=0;i<DRUM_VOICES;i++) { struct Drum *d=&m->drum_voices[i]; if(d->active && d->drum==KV_DRUM_HAT_OPEN && !d->fade_total) d->fade=d->fade_total=441; }
    struct Drum *slot=&m->drum_voices[0];
    for(int i=0;i<DRUM_VOICES;i++) { struct Drum *d=&m->drum_voices[i]; if(!d->active) { slot=d; break; } if(d->pos>slot->pos) slot=d; }   // else the oldest
    long late=m->humanize?(long)(random_unit(m)*176):0; float gain=velocity*(m->humanize?.94f+.12f*random_unit(m):1);
    *slot=(struct Drum){.pcm=pcm,.frames=frames,.pos=-late,.channels=channels,.gain=gain,.drum=drum,.active=true};
}
/* The click due at grid position k: accent on the bar, louder on the pulse, soft between. */
static void click(KvMixer *m,uint64_t k) {
    double at=fmod(k*m->step+1e-6,m->bar),within=fmod(at,m->pulse);
    int wave=at<2e-6?CLICK_ACCENT:within<2e-6?CLICK_PULSE:CLICK_SUB;
    struct Click *slot=&m->clicks[0];
    for(int i=0;i<4;i++) { if(!m->clicks[i].active) { slot=&m->clicks[i]; break; } if(m->clicks[i].pos>slot->pos) slot=&m->clicks[i]; }
    *slot=(struct Click){.wave=wave,.pos=0,.gain=m->rhythm_volume,.active=true};
}
unsigned kv_mixer_voices(const KvMixer *m) { unsigned n=0; if(m) for(int i=0;i<VOICES;i++) if(m->voices[i].active) n++; return n; }
void kv_mixer_stop(KvMixer *m) { if(!m) return; m->loop=false; m->has_queued=false; m->count=m->next=0; for(int i=0;i<VOICES;i++) cut(&m->voices[i],441); }
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
    // The same key again: the previous strike gives way — in 12 ms, a bow in 50 ms, a held key under the pedal in 0.4 s.
    for(int i=0;i<VOICES;i++) { struct Voice *v=&m->voices[i];
        if(v->active && v->midi==midi) cut(v,strings && v->bowed?2205:m->pedal && v->held && !strings?17640:529); }
    struct Voice *slot=NULL; int free=0;
    for(int i=0;i<VOICES;i++) if(!m->voices[i].active) { if(!slot) slot=&m->voices[i]; free++; }
    if(free<=SPARE) steal(m);
    if(!slot) return;   // only if more than SPARE notes start within 3 ms of a full pool
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
    if(enabled && !m->loop && m->count && m->next==m->count && m->clock>=m->sequence_start && m->clock-m->sequence_start>=m->cycle_end) {
        m->sequence_start=m->clock; m->cycle++; m->next=0; schedule(m); if(m->rhythm) rhythm_align(m,(double)m->sequence_start);
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
    m->custom=false; m->loop=false; m->cycle=0; m->has_queued=false;
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
    m->performance=*p; m->custom=true; m->loop=false; m->cycle=0; m->next=0; m->count=p->count; m->stride=1; m->has_queued=false; m->part=0;
    m->interval=(uint64_t)llround(seconds*RATE); m->instrument=instrument;
    // A count-in puts the start a few beats ahead: the rhythm starts now and counts up to it.
    uint64_t lead=(uint64_t)llround(m->lead_beats*m->interval); m->lead_beats=0; m->sequence_start=m->clock+lead;
    if(m->rhythm) { rhythm_retime(m,(double)m->interval); rhythm_align(m,(double)m->clock); }
    schedule(m); for(int i=0;i<VOICES;i++) release(&m->voices[i],1323); return true;
}
bool kv_mixer_queue(KvMixer *m,const KvPerformance *p,int rhythm,const KvHit *hits,size_t count) {
    if(!m || !m->custom || !m->count || !kv_performance_valid(p) || rhythm<-1 || rhythm>1 || count>KV_BEAT_HITS || (count && !hits)) return false;
    m->queued=*p; m->queued_rhythm=rhythm; m->queued_hit_count=count; if(count) memcpy(m->queued_hits,hits,count*sizeof *hits);
    m->has_queued=true; return true;
}
unsigned kv_mixer_part(const KvMixer *m) { return m?m->part:0; }
/* The queued part takes over on the frame the current one ends; the current voices ring on under it. */
static void start_queued(KvMixer *m) {
    m->sequence_start+=m->cycle_end; m->performance=m->queued; m->count=m->queued.count; m->next=0; m->cycle=0; m->has_queued=false; m->part++;
    schedule(m);
    if(m->queued_rhythm==0) m->rhythm=false;
    else if(m->queued_rhythm==1) {
        if(m->queued_hit_count) memcpy(m->beat,m->queued_hits,m->queued_hit_count*sizeof *m->beat);
        m->beat_count=m->queued_hit_count; m->beat_frames=(double)m->interval; m->rhythm=true;
    }
    if(m->rhythm) rhythm_align(m,(double)m->sequence_start);   // every part starts on a downbeat
}
void kv_mixer_render(KvMixer *m,float *stereo,size_t frames) {
    memset(stereo,0,frames*2*sizeof(float)); memset(m->dry,0,(frames<KV_DRY_FRAMES?frames:KV_DRY_FRAMES)*2*sizeof(float));
    for(size_t f=0;f<frames;f++,m->clock++) {
        bool started=m->clock>=m->sequence_start;   // false during a count-in
        if(started && m->has_queued && m->next==m->count && m->clock-m->sequence_start>=m->cycle_end) start_queued(m);
        else if(started && m->loop && m->next==m->count && m->clock-m->sequence_start>=m->cycle_end) {
            m->sequence_start+=m->cycle_end; m->cycle++; m->next=0; schedule(m); if(m->rhythm) rhythm_align(m,(double)m->sequence_start);
        }
        bool counting=m->count && m->clock<m->sequence_start;
        if(m->counting && !counting) beat_align(m);   // the count-in is over: the beat starts on the sequence's first beat
        m->counting=counting;
        if(m->rhythm && m->beat_count && !counting)
            while((double)m->clock>=m->origin+(m->beat_bar*m->bar+m->beat[m->beat_hit].beat)*m->beat_frames-.5) {
                strike(m,m->beat[m->beat_hit].drum,m->beat[m->beat_hit].velocity);
                if(++m->beat_hit==m->beat_count) { m->beat_hit=0; m->beat_bar++; }
            }
        else if(m->rhythm) while((double)m->clock>=m->origin+m->hit*m->step*m->beat_frames-.5) { click(m,m->hit); m->hit++; }
        for(int i=0;i<DRUM_VOICES;i++) { struct Drum *d=&m->drum_voices[i]; if(!d->active) continue;
            if(d->pos<0) { d->pos++; continue; }
            float g=d->gain*m->rhythm_volume; if(d->fade_total) { g*=(float)d->fade/d->fade_total; if(!--d->fade) d->active=false; }
            const float *p=d->pcm+(size_t)d->pos*d->channels; float l=p[0]*g,r=(d->channels==2?p[1]:p[0])*g;
            if(f<KV_DRY_FRAMES) { m->dry[f*2]+=l; m->dry[f*2+1]+=r; }
            if((size_t)++d->pos>=d->frames) d->active=false; }
        for(int i=0;i<4;i++) { struct Click *c=&m->clicks[i]; if(!c->active) continue;   // a click plays out even once switched off
            float x=m->click_wave[c->wave][c->pos]*c->gain; if(f<KV_DRY_FRAMES) { m->dry[f*2]+=x; m->dry[f*2+1]+=x; } if(++c->pos>=CLICK_FRAMES) c->active=false; }
        while(started && m->next<m->count && m->clock-m->sequence_start>=m->onset[m->next]) {
            size_t n=m->next;
            note_on(m,m->sequence[n],m->gate[n],m->instrument,m->gain[n],m->custom && m->performance.controlled?(unsigned)fmin(2646,m->interval*.12):11025,m->stroke[n],m->hand[n],m->velocity[n],true); m->next++;
        }
        // Dynamics (mod wheel, the slider) move smoothly (~45 ms). In a texture every chord breathes: a swell to its middle and
        // back, as deep as the dynamics are high. The soft and loud recordings cross-fade with equal power, the level follows.
        m->dynamics_now+=(m->dynamics_target-m->dynamics_now)*.0005f; m->expression_now+=(m->expression_target-m->expression_now)*.0005f;
        float weights[2][4];
        for(int kind=0;kind<2;kind++) {
            float d=m->dynamics_now;
            if(kind && started && m->custom && m->count && m->performance.beats_per_chord>0 && m->interval) {
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
    if(m->count && (m->loop || m->has_queued || m->clock<m->sequence_start || m->clock-m->sequence_start<m->cycle_end)) return true;
    int notes[KV_ACTIVE_NOTES]; return kv_mixer_active(m,notes)>0;
}
bool kv_mixer_busy(const KvMixer *m) { if(!m) return false; if(m->loop || m->has_queued || m->next<m->count) return true; for(int i=0;i<VOICES;i++) if(m->voices[i].active) return true; return false; }
uint64_t kv_mixer_clock(const KvMixer *m) { return m?m->clock:0; }
bool kv_mixer_silent(const KvMixer *m) {
    if(!m || m->rhythm || kv_mixer_busy(m)) return false;
    for(int i=0;i<DRUM_VOICES;i++) if(m->drum_voices[i].active) return false;
    for(int i=0;i<4;i++) if(m->clicks[i].active) return false;
    return true;
}
void kv_mixer_skip(KvMixer *m,size_t frames) { if(!m) return; m->clock+=frames; memset(m->dry,0,(frames<KV_DRY_FRAMES?frames:KV_DRY_FRAMES)*2*sizeof(float)); }
uint64_t kv_mixer_start(const KvMixer *m) { return m?m->sequence_start:0; }
unsigned kv_mixer_active(const KvMixer *m,int notes[KV_ACTIVE_NOTES]) {
    unsigned count=0; if(!m || !notes) return 0;
    for(int i=0;i<VOICES;i++) if(m->voices[i].active && !m->voices[i].release_total && m->voices[i].age<m->voices[i].gate) {
        bool duplicate=false; for(unsigned j=0;j<count;j++) if(notes[j]==m->voices[i].midi) duplicate=true;
        if(!duplicate && count<KV_ACTIVE_NOTES) notes[count++]=m->voices[i].midi;
    }
    return count;
}

void kv_mixer_interval(KvMixer *m,double seconds) {
    if(!m || !isfinite(seconds) || seconds<.08 || seconds>5 || !m->interval) return;
    uint64_t frames=(uint64_t)llround(seconds*RATE),elapsed=0;
    double ratio=(double)frames/m->interval;
    if(m->clock<m->sequence_start) m->sequence_start=m->clock+(uint64_t)llround((m->sequence_start-m->clock)*ratio);   // in a count-in
    else elapsed=m->clock-m->sequence_start;
    if(m->rhythm) rhythm_retime(m,m->beat_frames*ratio);
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
