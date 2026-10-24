#include "mixer.h"
#include "livefx.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <time.h>
#define CHECK(expr) do { if(!(expr)) { fprintf(stderr,"Mixer check failed at %d: %s\n",__LINE__,#expr); return 1; } } while(0)
static void advance(KvMixer *m,float *block,unsigned frames) {
    while(frames) { unsigned n=frames>256?256:frames; kv_mixer_render(m,block,n); frames-=n; }
}
int main(int argc,char **argv) {
    CHECK(argc==4 || argc==5);
    KvPianoBank *banks[3]={kv_piano_load(argv[1]),kv_piano_load(argv[2]),kv_piano_load(argv[3])};
    CHECK(banks[0] && banks[1] && banks[2]);
    KvMixer *a=kv_mixer_create(),*b=kv_mixer_create(); CHECK(a && b);
    for(int i=0;i<3;i++) { kv_mixer_bank(a,i,banks[i]); kv_mixer_bank(b,i,banks[i]); }
    int note=69; float block[512],other[512];
    CHECK(kv_mixer_play(a,&note,1,1,.65,0,true)); CHECK(kv_mixer_play(b,&note,1,1,.65,0,true));
    for(int i=0;i<20;i++) { kv_mixer_render(a,block,256); kv_mixer_render(b,other,256); }
    CHECK(kv_mixer_play(a,&note,1,1,.65,0,true));
    kv_mixer_render(a,block,1); kv_mixer_render(b,other,1);
    CHECK(fabsf(block[0]-other[0])<1e-6 && fabsf(block[1]-other[1])<1e-6);
    int second=72; CHECK(kv_mixer_play(a,&second,1,1,.65,0,true)); kv_mixer_render(a,block,256);
    int active[KV_ACTIVE_NOTES]; CHECK(kv_mixer_active(a,active)==2);
    KvLiveEffects *fx=kv_live_effects_create(); CHECK(fx);
    for(int instrument=0;instrument<3;instrument++) {
        double energy=0;
        for(int i=0;i<100;i++) {
            note=48+i%36;
            if(i%4==0) CHECK(kv_mixer_play(a,&note,1,1,.3,instrument,true));
            kv_mixer_render(a,block,256);
            CHECK(kv_live_effects_process(fx,block,256,(KvEffects){.18,.14,.3}));
            for(int j=0;j<512;j++) { CHECK(isfinite(block[j])); energy+=block[j]*block[j]; }
        }
        CHECK(energy>.001);
    }
    kv_mixer_stop(a); for(int i=0;i<3;i++) kv_mixer_render(a,block,256); CHECK(!kv_mixer_busy(a));
    // Repeated isolated notes have a tightly bounded humanization gain range.
    float min=100,max=0;
    for(int i=0;i<100;i++) {
        kv_mixer_stop(a); kv_mixer_render(a,block,256); kv_mixer_render(a,block,256);
        note=60; CHECK(kv_mixer_play(a,&note,1,1,.3,0,true));
        float peak=0; for(int j=0;j<8;j++) { kv_mixer_render(a,block,256); for(int k=0;k<512;k++) peak=fmaxf(peak,fabsf(block[k])); }
        min=fminf(min,peak); max=fmaxf(max,peak);
    }
    CHECK(min>0 && max/min<1.14);
    // A fresh parallel FX path at zero mix preserves the dry signal bit for bit.
    KvLiveEffects *dry=kv_live_effects_create(); CHECK(dry);
    for(int i=0;i<512;i++) block[i]=other[i]=.2f*sinf(i*.1f);
    CHECK(kv_live_effects_process(dry,block,256,(KvEffects){0,0,.3}));
    CHECK(memcmp(block,other,sizeof(block))==0); kv_live_effects_free(dry);
    // Exercise the exact streaming path and audibility of musical delay divisions.
    for(int bpm=80;bpm<=160;bpm+=80) for(int division=1;division<=4;division*=2) {
        double seconds=60.0/bpm/division;
        unsigned onset=(unsigned)llround(seconds*44100);
        KvLiveEffects *echo=kv_live_effects_create(); CHECK(echo);
        float first=0,second=0,before=0;
        for(unsigned offset=0;offset<onset*2+512;offset+=256) {
            memset(block,0,sizeof(block)); if(!offset) block[0]=.5f;
            CHECK(kv_live_effects_process(echo,block,256,(KvEffects){0,.28f,seconds}));
            for(unsigned i=0;i<256;i++) {
                unsigned at=offset+i;
                if(at>0 && at<onset) before+=fabsf(block[i*2])+fabsf(block[i*2+1]);
                if(at==onset) first=block[i*2];
                if(at>=onset*2 && at<onset*2+40) second+=fabsf(block[i*2+1]);
            }
        }
        CHECK(before<1e-6f); CHECK(fabsf(first-.182f)<.001f); CHECK(second>.04f && second<first);
        kv_live_effects_free(echo);
    }
    // Dragging the tempo slider retimes a synced delay every few milliseconds: no clicks, i.e. no step larger than a steady echo makes.
    {
        float steps[2]={0,0};
        for(int drag=0;drag<2;drag++) {
            KvLiveEffects *echo=kv_live_effects_create(); CHECK(echo); float last=0; unsigned n=0;
            for(int i=0;i<400;i++) {
                for(int j=0;j<256;j++,n++) block[j*2]=block[j*2+1]=.3f*sinf(n*2*(float)M_PI*220/44100);
                double bpm=drag && i>=100?100+(i-100)*.25:100;
                CHECK(kv_live_effects_process(echo,block,256,(KvEffects){0,.28f,30.0/bpm}));
                for(int j=0;j<256;j++) { if(i>=100) steps[drag]=fmaxf(steps[drag],fabsf(block[j*2]-last)); last=block[j*2]; }
            }
            kv_live_effects_free(echo);
        }
        if(steps[1]>steps[0]*1.5f) { fprintf(stderr,"delay retiming steps %.4f vs steady %.4f\n",steps[1],steps[0]); return 1; }
    }
    // Exact sample-count event boundaries with humanization disabled.
    int sequence[]={60,64,67}; kv_mixer_humanize(a,false);
    for(int bpm=80;bpm<=160;bpm+=80) {
        CHECK(kv_mixer_play(a,sequence,3,1,30.0/bpm,0,false));
        unsigned interval=(unsigned)llround(44100*30.0/bpm);
        for(unsigned i=0;i<interval;i++) kv_mixer_render(a,block,1);
        CHECK(kv_mixer_event(a)==0); kv_mixer_render(a,block,1); CHECK(kv_mixer_event(a)==1);
    }
    CHECK(kv_mixer_play(a,sequence,3,1,1,0,false));
    for(int i=0;i<4410;i++) kv_mixer_render(a,block,1);
    kv_mixer_interval(a,.5);
    for(int i=0;i<19845;i++) kv_mixer_render(a,block,1);
    CHECK(kv_mixer_event(a)==0); kv_mixer_render(a,block,1); CHECK(kv_mixer_event(a)==1);
    // Beat-based progression timing and gap-free loop boundaries for 32 cycles.
    for(int bpm=80;bpm<=160;bpm+=80) {
        unsigned beat=(unsigned)llround(44100*60.0/bpm);
        CHECK(kv_mixer_play(a,sequence,3,1,60.0/bpm,0,false)); kv_mixer_loop(a,true);
        kv_mixer_render(a,block,1); CHECK(kv_mixer_event(a)==0);
        for(int event=1;event<=96;event++) {
            advance(a,block,beat-1); CHECK(kv_mixer_event(a)==event-1);
            kv_mixer_render(a,block,1); CHECK(kv_mixer_event(a)==event);
        }
        kv_mixer_loop(a,false); advance(a,block,beat*6); CHECK(kv_mixer_event(a)==98);
        CHECK(!kv_mixer_busy(a));
    }
    // Changing BPM in a loop rescales the remaining phase, including its end.
    CHECK(kv_mixer_play(a,sequence,3,1,1,0,false)); kv_mixer_loop(a,true);
    advance(a,block,110250); CHECK(kv_mixer_event(a)==2);
    kv_mixer_interval(a,.5); advance(a,block,11025); CHECK(kv_mixer_event(a)==2);
    kv_mixer_render(a,block,1); CHECK(kv_mixer_event(a)==3);
    advance(a,block,66150); CHECK(kv_mixer_event(a)==6);
    kv_mixer_stop(a); advance(a,block,512); CHECK(!kv_mixer_busy(a));
    int chords[2][3]={{60,64,67},{69,72,76}};
    for(int style=0;style<KV_PATTERN_COUNT;style++) {
        KvPerformance p; CHECK(kv_two_hand(chords,2,60,(KvPianoPattern)style,&p));
        CHECK(kv_mixer_performance(a,&p,.375,0)); kv_mixer_loop(a,true);
        unsigned bar=p.beats_per_chord*16538; kv_mixer_render(a,block,1);
        for(int chord=1;chord<=6;chord++) {
            advance(a,block,bar-1); CHECK(kv_mixer_event(a)==chord-1);
            kv_mixer_render(a,block,1); CHECK(kv_mixer_event(a)==chord);
        }
        kv_mixer_interval(a,.75); advance(a,block,1000); CHECK(kv_mixer_busy(a));
        kv_mixer_stop(a); advance(a,block,512); CHECK(!kv_mixer_busy(a));
    }
    // An auditioned note during a looping performance neither cancels the sequence nor resets its clock.
    {
        KvPerformance p; CHECK(kv_two_hand(chords,2,60,KV_BALLAD,&p)); CHECK(kv_mixer_performance(a,&p,.5,0)); kv_mixer_loop(a,true);
        advance(a,block,22050); int before=kv_mixer_event(a); uint64_t start_before=kv_mixer_start(a);
        int extra=96; CHECK(kv_mixer_play(a,&extra,1,1,.4,0,true));
        advance(a,block,2205); CHECK(kv_mixer_event(a)>=before && kv_mixer_start(a)==start_before && kv_mixer_busy(a));
        advance(a,block,44100*4); CHECK(kv_mixer_busy(a) && kv_mixer_event(a)>=2); // still looping into the second cycle
        kv_mixer_stop(a); advance(a,block,512); CHECK(!kv_mixer_busy(a));
        // Practice speed: 4.8 s per beat is accepted and rescaling to it works mid-play.
        CHECK(kv_mixer_performance(a,&p,4.8,0)); advance(a,block,1000); kv_mixer_interval(a,.3); advance(a,block,1000); kv_mixer_stop(a); advance(a,block,512);
        CHECK(!kv_mixer_performance(a,&p,5.5,0));
    }
    // Editor previews are monophonic: a quick second preview releases the first within a few milliseconds,
    // while overlaid notes (keyboard, MIDI input) keep sounding together.
    {
        kv_mixer_stop(a); advance(a,block,2048);
        CHECK(kv_mixer_preview(a,60,.5,0)); advance(a,block,1024);
        CHECK(kv_mixer_preview(a,64,.5,0)); advance(a,block,1024);
        int active_notes[KV_ACTIVE_NOTES]; unsigned n=kv_mixer_active(a,active_notes); CHECK(n==1 && active_notes[0]==64);
        int g=67; CHECK(kv_mixer_play(a,&g,1,1,.5,0,true)); advance(a,block,256);
        n=kv_mixer_active(a,active_notes); CHECK(n==2); // a played note is not cut by previews
        CHECK(kv_mixer_preview(a,69,.5,0)); advance(a,block,1024);
        n=kv_mixer_active(a,active_notes); bool has67=false,has69=false; for(unsigned i=0;i<n;i++) { if(active_notes[i]==67) has67=true; if(active_notes[i]==69) has69=true; }
        CHECK(n==2 && has67 && has69);
        kv_mixer_stop(a); advance(a,block,2048); CHECK(!kv_mixer_busy(a));
    }
    // Held keys sound until they are released, however long; a release lets go of that key only, not of played notes.
    {
        kv_mixer_stop(a); advance(a,block,2048);
        CHECK(kv_mixer_hold(a,60,.8f,0)); CHECK(kv_mixer_hold(a,64,.8f,0)); int g=67; CHECK(kv_mixer_play(a,&g,1,1,2,0,true));
        advance(a,block,44100*3/2); int notes[KV_ACTIVE_NOTES]; unsigned n=kv_mixer_active(a,notes);
        bool c=false,e=false; for(unsigned i=0;i<n;i++) { if(notes[i]==60) c=true; if(notes[i]==64) e=true; } CHECK(c && e); // 1.5 s later both keys still sound
        kv_mixer_release(a,60); advance(a,block,4096); n=kv_mixer_active(a,notes);
        c=false; e=false; bool gnote=false; for(unsigned i=0;i<n;i++) { if(notes[i]==60) c=true; if(notes[i]==64) e=true; if(notes[i]==67) gnote=true; }
        CHECK(!c && e && gnote);                                    // C let go; E still held; the played G untouched
        kv_mixer_release(a,-1); advance(a,block,4096); n=kv_mixer_active(a,notes); e=false; for(unsigned i=0;i<n;i++) if(notes[i]==64) e=true; CHECK(!e);
        CHECK(!kv_mixer_hold(a,10,.5f,0) && !kv_mixer_hold(a,60,.5f,7));
        kv_mixer_stop(a); advance(a,block,2048); CHECK(!kv_mixer_busy(a));
    }
    // Legacy block scheduling is still beat-based after switching out of the new mode.
    CHECK(kv_mixer_play(a,sequence,3,1,.375,0,false)); advance(a,block,16538);
    CHECK(kv_mixer_event(a)==0); kv_mixer_render(a,block,1); CHECK(kv_mixer_event(a)==1);
    for(int ext=1;ext<=4;ext++) {
        KvChord ch[2]; CHECK(kv_chord_extended((KvKey){0,false,0,0},0,ext,&ch[0])); CHECK(kv_chord_extended((KvKey){0,false,0,0},3,ext,&ch[1]));
        KvPerformance p; CHECK(kv_arrange(ch,2,60,KV_DARK_JAZZ,(KvKey){0,false,0,0},ext,true,&p));
        CHECK(kv_mixer_performance(a,&p,.375,0)); kv_mixer_loop(a,true);
        double audible=0;
        for(int i=0;i<600;i++) { kv_mixer_render(a,block,256); for(int j=0;j<512;j++) { CHECK(isfinite(block[j])); audible+=block[j]*block[j]; } }
        CHECK(audible>.01 && kv_mixer_event(a)>=2); kv_mixer_stop(a); advance(a,block,512);
    }
    // Bowed strings: an 8 s recording sustains for as long as the key is held, swells in, fades out slowly, and never clicks at the loop seam.
    {
        char dir[]="/tmp/tonora-strings-XXXXXX"; CHECK(mkdtemp(dir)); char path[256];
        snprintf(path,sizeof(path),"%s/tone.wav",dir); FILE *wav=fopen(path,"wb"); CHECK(wav);
        const uint32_t frames=44100*8,bytes=frames*4; const uint8_t header[44]={'R','I','F','F',(uint8_t)(bytes+36),(uint8_t)((bytes+36)>>8),(uint8_t)((bytes+36)>>16),(uint8_t)((bytes+36)>>24),'W','A','V','E','f','m','t',' ',16,0,0,0,1,0,2,0,0x44,0xac,0,0,0x10,0xb1,2,0,4,0,16,0,'d','a','t','a',(uint8_t)bytes,(uint8_t)(bytes>>8),(uint8_t)(bytes>>16),(uint8_t)(bytes>>24)};
        fwrite(header,1,44,wav);
        for(uint32_t n=0;n<frames;n++) { double t=n/44100.0,level=fmin(1,t/.005)*(t>7.5?(8-t)/.5:1); int16_t v=(int16_t)(9000*level*sin(2*M_PI*220*t+.4*sin(2*M_PI*5.5*t))); int16_t lr[2]={v,v}; fwrite(lr,2,2,wav); }
        fclose(wav); snprintf(path,sizeof(path),"%s/index.txt",dir); FILE *index=fopen(path,"w"); CHECK(index); fputs("57 tone.wav\n",index); fclose(index);
        KvPianoBank *strings=kv_piano_load(dir); CHECK(strings); KvMixer *m=kv_mixer_create(); CHECK(m); kv_mixer_bank(m,KV_INSTRUMENT_STRINGS,strings); kv_mixer_humanize(m,false);
        CHECK(kv_mixer_hold(m,57,.8f,KV_INSTRUMENT_STRINGS));
        float early=0,onset=0,steady=0,quietest=1e9f,step=0,last=0; double window=0; unsigned n=0;
        for(int i=0;i<44100*20/256;i++) {
            kv_mixer_render(m,block,256);
            for(int j=0;j<256;j++,n++) { float x=block[j*2]; if(n<882) early=fmaxf(early,fabsf(x)); if(n<44) onset=fmaxf(onset,fabsf(x)); if(n>44100 && n<88200) steady=fmaxf(steady,fabsf(x));
                if(n>44100) step=fmaxf(step,fabsf(x-last)); last=x; window+=x*x;
                if(n%22050==22049) { if(n>88200) quietest=fminf(quietest,(float)sqrt(window/22050)); window=0; } }
        }
        CHECK(steady>.05f); CHECK(early>steady*.4f && onset<steady*.2f);                         /* the engine adds only a 30 ms fade-in to the recording's own attack */
        CHECK(quietest>steady/sqrtf(2)*.6f);                               /* still sounding at 20 s, far past the recording */
        if(step>.03f) { fprintf(stderr,"strings loop step %.4f (steady peak %.3f)\n",step,steady); return 1; }  /* a 220 Hz tone moves < .02 per sample */
        kv_mixer_release(m,57); float tail=0; for(int i=0;i<44100*4/10/256;i++) kv_mixer_render(m,block,256); for(int j=0;j<512;j++) tail=fmaxf(tail,fabsf(block[j]));
        CHECK(tail>steady*.05f); advance(m,block,44100); CHECK(!kv_mixer_busy(m));   /* fades out over ~0.7 s, then silence */
        CHECK(kv_mixer_hold(m,57,.8f,KV_INSTRUMENT_STRINGS)); advance(m,block,44100); kv_mixer_stop(m); advance(m,block,1024); CHECK(!kv_mixer_busy(m)); /* Stop is still immediate */
        snprintf(path,sizeof(path),"%s/index.txt",dir); index=fopen(path,"w"); CHECK(index); fputs("57 tone.wav 2\n",index); fclose(index);
        KvPianoBank *louder=kv_piano_load(dir); CHECK(louder); KvSampleView one,two; CHECK(kv_piano_sample(strings,57,&one) && kv_piano_sample(louder,57,&two));
        CHECK(one.frames==two.frames && fabsf(two.pcm[44100]-2*one.pcm[44100])<1e-5f); kv_piano_free(louder);   /* index gain column */
        kv_mixer_free(m); kv_piano_free(strings); unlink(path); snprintf(path,sizeof(path),"%s/tone.wav",dir); unlink(path); rmdir(dir);
    }
    // The real strings bank: every recording, held 20 s, keeps sounding and its loop seam is no louder a step than its own vibrato.
    if(argc==5) {
        KvPianoBank *strings=kv_piano_load(argv[4]); CHECK(strings); KvMixer *m=kv_mixer_create(); CHECK(m); kv_mixer_bank(m,KV_INSTRUMENT_STRINGS,strings); kv_mixer_humanize(m,false);
        const int notes[]={36,40,43,47,50,53,57,59,62,66,69,72,76,79,83,86,96};
        for(size_t k=0;k<sizeof(notes)/sizeof(*notes);k++) {
            kv_mixer_stop(m); advance(m,block,2048); CHECK(kv_mixer_hold(m,notes[k],.8f,KV_INSTRUMENT_STRINGS));
            float before=0,after=0,last=0; double early=0,quietest=1e9,window=0,first=0; unsigned n=0;
            for(int i=0;i<44100*20/256;i++) { kv_mixer_render(m,block,256);
                for(int j=0;j<256;j++,n++) { float x=block[j*2]; if(n>44100) { float d=fabsf(x-last); if(n<44100*2) before=fmaxf(before,d); else after=fmaxf(after,d); } last=x; window+=x*x;
                    if(n%11025==11024) { double r=sqrt(window/11025); if(n<11025) first=r; if(n>44100*2 && n<44100*4) early=fmax(early,r); if(n>44100*4) quietest=fmin(quietest,r); window=0; } } }
            if(first<early*.25) { fprintf(stderr,"strings note %d speaks too slowly: first 250 ms at %.0f%% of its level\n",notes[k],100*first/early); return 1; }
            if(after>before*2.5f+.002f || quietest<early*.3) { fprintf(stderr,"strings note %d: step %.4f vs %.4f, quietest %.4f vs %.4f\n",notes[k],after,before,quietest,early); return 1; }
        }
        kv_mixer_free(m);
        // 1.1: strokes, legato, dynamics. A helper renders `seconds` and returns RMS per 10 ms window.
        static float env[44100*6/441+1]; static float pcm[44100*6*2];
        #define RENDER(mixer,seconds) do { size_t total=(size_t)((seconds)*44100); for(size_t o=0;o<total;o+=256) { size_t k=total-o<256?total-o:256; kv_mixer_render(mixer,pcm+o*2,k); } \
            for(size_t w=0;w*441+441<=total;w++) { double e=0; for(size_t j=w*441;j<w*441+441;j++) e+=pcm[j*2]*pcm[j*2]; env[w]=(float)sqrt(e/441); } } while(0)
        // Legato: C5 then D5 in one hand, touching. The line does not dip more than 3 dB and makes no click at the change.
        { KvMixer *x=kv_mixer_create(); kv_mixer_bank(x,KV_INSTRUMENT_STRINGS,strings); kv_mixer_humanize(x,false);
          KvPerformance p={0}; p.events[0]=(KvPianoEvent){72,0,2,.8f,0,1,0,0}; p.events[1]=(KvPianoEvent){74,2,2,.8f,1,1,0,0}; p.count=2; p.chord_count=2; p.beats_per_chord=2; p.beats_per_bar=4; p.total_beats=4;
          unsigned char strokes[2]; kv_string_strokes(&p,KV_ARTICULATION_AUTO,strokes); CHECK(strokes[0]==KV_STROKE_SUSTAIN && strokes[1]==KV_STROKE_LEGATO);
          kv_mixer_dynamics(x,.6f,1); CHECK(kv_mixer_performance(x,&p,.5,KV_INSTRUMENT_STRINGS)); RENDER(x,1.6);
          // Section strings swing ±50 % within 50 ms (vibrato, ensemble beating), so compare 300 ms before and after the change,
          // and look for clicks as the largest sample-to-sample step against the same note's own.
          #define POWER(a,b) ({ double e_=0; for(size_t j_=(size_t)((a)*44100);j_<(size_t)((b)*44100);j_++) e_+=pcm[j_*2]*pcm[j_*2]; sqrt(e_/(((b)-(a))*44100)); })
          #define STEP(a,b) ({ float s_=0; for(size_t j_=(size_t)((a)*44100);j_<(size_t)((b)*44100);j_++) s_=fmaxf(s_,fabsf(pcm[j_*2]-pcm[j_*2-2])); s_; })
          double before=POWER(.68,.98),after=POWER(.98,1.28); float own=STEP(.5,.95),change=STEP(.97,1.1);
          if(after<before*.708 || change>own*2) { fprintf(stderr,"legato change: level %.0f%% of before, step %.4f vs %.4f\n",100*after/before,change,own); return 1; }
          // A tone common to two chords goes on without a new bow: C5, C5 legato keeps one voice and its level.
          p.events[1].midi=72; kv_mixer_stop(x); advance(x,block,2048); CHECK(kv_mixer_performance(x,&p,.5,KV_INSTRUMENT_STRINGS)); RENDER(x,1.6);
          CHECK(POWER(.98,1.28)>POWER(.68,.98)*.8); int sounding[KV_ACTIVE_NOTES]; CHECK(kv_mixer_active(x,sounding)==1 && sounding[0]==72);
          #undef POWER
          #undef STEP
          kv_mixer_free(x); }
        // Short strokes: two takes alternate (repeats differ, every second is the same), velocity picks the loud take, a pluck rings past key-up.
        { KvMixer *x=kv_mixer_create(); kv_mixer_bank(x,KV_INSTRUMENT_STRINGS,strings); kv_mixer_humanize(x,false); kv_mixer_articulation(x,KV_ARTICULATION_STACCATO);
          float takes[3][512];
          for(int t=0;t<3;t++) { kv_mixer_stop(x); advance(x,block,4410); CHECK(kv_mixer_hold(x,60,.4f,KV_INSTRUMENT_STRINGS)); advance(x,block,2048); kv_mixer_render(x,takes[t],256); }
          CHECK(memcmp(takes[0],takes[1],sizeof(takes[0]))!=0 && memcmp(takes[0],takes[2],sizeof(takes[0]))==0);
          kv_mixer_stop(x); advance(x,block,4410); CHECK(kv_mixer_hold(x,60,.95f,KV_INSTRUMENT_STRINGS)); advance(x,block,2048); kv_mixer_render(x,block,256);
          CHECK(memcmp(block,takes[0],sizeof(takes[0]))!=0 && memcmp(block,takes[1],sizeof(takes[0]))!=0);
          kv_mixer_articulation(x,KV_ARTICULATION_PIZZICATO); kv_mixer_stop(x); advance(x,block,4410);
          CHECK(kv_mixer_hold(x,50,.8f,KV_INSTRUMENT_STRINGS)); advance(x,block,2205); kv_mixer_release(x,50); RENDER(x,.4);
          CHECK(env[25]>.002f); int sounding[KV_ACTIVE_NOTES]; CHECK(kv_mixer_active(x,sounding)==0);    /* rings, but the key is no longer shown down */
          kv_mixer_stop(x); advance(x,block,1024); CHECK(!kv_mixer_busy(x));
          kv_mixer_free(x); }
        // The mod wheel: soft to loud raises the level and brightens the sound, smoothly; expression only scales.
        { KvMixer *x=kv_mixer_create(); kv_mixer_bank(x,KV_INSTRUMENT_STRINGS,strings); kv_mixer_humanize(x,false);
          kv_mixer_dynamics(x,.1f,1); advance(x,block,44100); CHECK(kv_mixer_hold(x,62,.8f,KV_INSTRUMENT_STRINGS)); RENDER(x,2.5);
          double soft=0,soft_edge=0; for(size_t j=44100;j<44100*2.5;j++) { soft+=pcm[j*2]*pcm[j*2]; double d=pcm[j*2]-pcm[j*2-2]; soft_edge+=d*d; }
          kv_mixer_dynamics(x,.95f,1); RENDER(x,2.5);
          float jump=0; for(int w=1;w<120;w++) jump=fmaxf(jump,fabsf(env[w]-env[w-1])/fmaxf(env[w-1],1e-6f));
          double loud=0,loud_edge=0; for(size_t j=44100;j<44100*2.5;j++) { loud+=pcm[j*2]*pcm[j*2]; double d=pcm[j*2]-pcm[j*2-2]; loud_edge+=d*d; }
          if(!(loud>soft*2.5 && loud_edge/loud>soft_edge/soft*1.05 && jump<.35f)) { fprintf(stderr,"mod wheel: level ×%.2f, brightness ×%.2f, largest 10 ms step %.0f%%\n",sqrt(loud/soft),(loud_edge/loud)/(soft_edge/soft),100*jump); return 1; }
          kv_mixer_dynamics(x,.95f,.5f); RENDER(x,1.5); double half=0; for(size_t j=44100/2;j<44100*1.5;j++) half+=pcm[j*2]*pcm[j*2];
          CHECK(fabs(sqrt(half/44100)/sqrt(loud/(44100*1.5))-.5)<.12);
          kv_mixer_free(x); }
        // Short strokes follow the mod wheel too (arpeggios in «Авто» are spiccato).
        for(int a=KV_ARTICULATION_STACCATO;a<=KV_ARTICULATION_PIZZICATO;a++) {
          double level[2];
          for(int k=0;k<2;k++) { KvMixer *x=kv_mixer_create(); kv_mixer_bank(x,KV_INSTRUMENT_STRINGS,strings); kv_mixer_humanize(x,false); kv_mixer_articulation(x,(KvArticulation)a);
            kv_mixer_dynamics(x,k?.95f:.1f,1); advance(x,block,44100); CHECK(kv_mixer_hold(x,62,.8f,KV_INSTRUMENT_STRINGS)); RENDER(x,.4);
            level[k]=0; for(size_t j=0;j<44100*.4;j++) level[k]+=pcm[j*2]*pcm[j*2]; kv_mixer_free(x); }
          CHECK(level[1]>level[0]*4); }
        #undef RENDER
        kv_piano_free(strings);
    }
    // Polyphony as on a digital piano: under the pedal, 300 strikes in 0.3 s never lose a note, the pool stays bounded,
    // and when it runs short the quietest voice fades (no sample-to-sample jump beyond what the music itself has).
    { KvMixer *p=kv_mixer_create(); CHECK(p); kv_mixer_bank(p,0,banks[0]); kv_mixer_humanize(p,false); kv_mixer_pedal(p,true);
      unsigned peak=0; float jump=0,last[2]={0,0},chunk[64*2];
      for(int i=0;i<300;i++) {
          int midi=21+(i*7)%88; CHECK(kv_mixer_hold(p,midi,.8f,0));
          for(int f=0;f<44;f+=4) { kv_mixer_render(p,chunk,4); for(int k=0;k<8;k++) { float d=fabsf(chunk[k]-last[k%2]); if(d>jump) jump=d; last[k%2]=chunk[k]; } }
          unsigned voices=kv_mixer_voices(p); if(voices>peak) peak=voices;
          int notes[KV_ACTIVE_NOTES]; unsigned n=kv_mixer_active(p,notes); bool sounding=false; for(unsigned j=0;j<n;j++) if(notes[j]==midi) sounding=true;
          if(!sounding) { fprintf(stderr,"polyphony: strike %d (midi %d) is silent with %u voices in use\n",i,midi,voices); return 1; }
      }
      CHECK(peak>64 && peak<=KV_VOICES); CHECK(jump<.5f);
      // The pedal: a key struck again rings on its previous strike for a while; without the pedal it gives way at once.
      kv_mixer_release(p,-1); kv_mixer_stop(p); advance(p,block,44100); CHECK(kv_mixer_voices(p)==0);
      CHECK(kv_mixer_hold(p,60,.8f,0)); advance(p,block,22050); CHECK(kv_mixer_hold(p,60,.8f,0)); advance(p,block,4410); CHECK(kv_mixer_voices(p)==2);
      kv_mixer_pedal(p,false); kv_mixer_release(p,-1); kv_mixer_stop(p); advance(p,block,44100);
      CHECK(kv_mixer_hold(p,60,.8f,0)); advance(p,block,22050); CHECK(kv_mixer_hold(p,60,.8f,0)); advance(p,block,4410); CHECK(kv_mixer_voices(p)==1);
      // Cost of a full pool: render 1 s with every voice busy, well inside real time even on an older Mac.
      kv_mixer_release(p,-1); kv_mixer_stop(p); advance(p,block,44100); kv_mixer_pedal(p,true);
      for(int i=0;i<KV_VOICES;i++) { CHECK(kv_mixer_hold(p,21+i%88,.8f,0)); advance(p,block,16); }
      CHECK(kv_mixer_voices(p)>=KV_VOICES-8);
      clock_t start=clock(); advance(p,block,44100); double seconds=(double)(clock()-start)/CLOCKS_PER_SEC;
      printf("Polyphony: peak %u voices, %.1f%% of one core for a full pool\n",peak,100*seconds);
      CHECK(seconds<.5);
      kv_mixer_free(p); }
    kv_live_effects_free(fx); kv_mixer_free(a); kv_mixer_free(b); for(int i=0;i<3;i++) kv_piano_free(banks[i]);
    puts("Three instruments: retrigger continuity, overlapping voices, live FX, audible synced repeats at 80/160 BPM, release and bounded human dynamics passed."); return 0;
}
