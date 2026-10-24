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
/* Render `frames` and return the frames where a click starts (dry left channel rising from silence) and its peak. */
static size_t clicks(KvMixer *m,size_t frames,size_t *at,float *peak,size_t max) {
    static float out[256*2]; size_t n=0,quiet=4096; uint64_t base=kv_mixer_clock(m);
    for(size_t done=0;done<frames;done+=256) {
        size_t k=frames-done<256?frames-done:256; kv_mixer_render(m,out,k); const float *dry=kv_mixer_dry(m);
        for(size_t f=0;f<k;f++) { float x=fabsf(dry[f*2]);
            if(x>0 && quiet>=64 && n<max) { at[n]=(size_t)(base+done+f); peak[n]=0; n++; }
            if(x>0) { if(n && x>peak[n-1]) peak[n-1]=x; quiet=0; } else quiet++; }
    }
    return n;
}
static void advance(KvMixer *m,float *block,unsigned frames) {
    while(frames) { unsigned n=frames>256?256:frames; kv_mixer_render(m,block,n); frames-=n; }
}
int main(int argc,char **argv) {
    CHECK(argc>=4 && argc<=6);   /* pianos, then optionally the strings and the percussion */
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
    if(argc>=5) {
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
    // The metronome: clicks on the exact frame of each beat at 60/100/160 BPM, accents on the bar in 4/4, 3/4 and 6/8 (two
    // dotted quarters), subdivisions softer; it joins a sequence on its first beat, counts it in, and keeps the beat across a tempo change.
    { size_t at[64]; float peak[64];
      const KvMeter meters[3]={KV_METER_4_4,KV_METER_3_4,KV_METER_6_8}; const double bars[3]={4,3,3},pulses[3]={1,1,.5};   /* 6/8: every eighth */
      for(int t=0;t<3;t++) for(int mt=0;mt<3;mt++) {
          double bpm=(double[]){60,100,160}[t],beat=44100*60/bpm; KvMixer *r=kv_mixer_create(); CHECK(r);
          kv_mixer_rhythm(r,true,KV_GRID_BEATS,meters[mt],60/bpm,.6f); uint64_t origin=kv_mixer_clock(r);
          size_t n=clicks(r,(size_t)(beat*7),at,peak,64); size_t want=(size_t)(7/pulses[mt]-1e-9)+1; CHECK(n==want);
          for(size_t i=0;i<n;i++) {
              double expected=origin+i*pulses[mt]*beat; CHECK(fabs((double)at[i]-1-expected)<=.5+1e-9);   /* a click's first sample is 0 (its 1 ms rise): heard from the next frame */
              bool accent=fmod(i*pulses[mt]+1e-9,bars[mt])<1e-6; CHECK(accent?peak[i]>peak[1%n]*1.15f || i==1:true);
          }
          CHECK(peak[0]>peak[1]*1.15f);
          kv_mixer_free(r);
      }
      // No tick after the click: its wave fades to silence, so the last sound before each silence is tiny (a cut wave leaves a step).
      { KvMixer *q=kv_mixer_create(); kv_mixer_rhythm(q,true,KV_GRID_EIGHTHS,KV_METER_4_4,1,1); float out[512],previous=0,step=0; int silences=0;
        for(int k=0;k<44100*2/256;k++) { kv_mixer_render(q,out,256); const float *dry=kv_mixer_dry(q);
            for(int f=0;f<256;f++) { float x=dry[f*2]; if(x==0 && previous!=0) { silences++; if(fabsf(previous)>step) step=fabsf(previous); } previous=x; } }
        CHECK(silences>=3 && step<2e-4f); kv_mixer_free(q); }
      // Eighths: the off-beat clicks are softer than the beats.
      KvMixer *r=kv_mixer_create(); kv_mixer_rhythm(r,true,KV_GRID_EIGHTHS,KV_METER_4_4,.5,.6f);
      size_t n=clicks(r,44100*2,at,peak,64); CHECK(n==8 && fabs((double)at[1]-at[0]-11025)<=1 && peak[1]<peak[2]*.8f && peak[2]<peak[0]);
      // Joins a sequence: started off-grid, the clicks move onto the sequence's first beat.
      advance(r,block,7777);   // off the click grid
      KvPerformance perf={0}; KvArrangement arr={.style=KV_BALLAD,.meter=KV_METER_4_4,.length=KV_LENGTH_BAR,.blocks=true,.seconds_per_beat=.5};
      KvChord c; CHECK(kv_chord((KvKey){0,false,0,0},0,&c)); CHECK(kv_arrange_with(&c,1,60,(KvKey){0,false,0,0},arr,&perf));
      kv_mixer_bank(r,0,banks[0]); CHECK(kv_mixer_performance(r,&perf,.5,0)); uint64_t start=kv_mixer_start(r);
      n=clicks(r,44100,at,peak,64); CHECK(n>=1 && at[0]==start+1 && peak[0]>.2f);
      // Count-in: one bar of clicks, then the sequence on the next accent.
      kv_mixer_stop(r); kv_mixer_rhythm(r,false,KV_GRID_BEATS,KV_METER_4_4,.5,.6f); advance(r,block,4410);
      kv_mixer_rhythm(r,true,KV_GRID_BEATS,KV_METER_4_4,.5,.6f); kv_mixer_count_in(r,4); CHECK(kv_mixer_performance(r,&perf,.5,0)); uint64_t now=kv_mixer_clock(r);
      CHECK(kv_mixer_start(r)==now+4*22050 && kv_mixer_running(r));
      n=clicks(r,4*22050+100,at,peak,64); CHECK(n==5 && at[0]==now+1 && at[4]==now+4*22050+1 && peak[4]>peak[1]*1.15f);
      int sounding[KV_ACTIVE_NOTES]; CHECK(kv_mixer_active(r,sounding)>0);
      // A tempo change keeps the beat: the beat counted just before is the beat counted just after, and the next click follows the new tempo.
      kv_mixer_stop(r); double before=kv_mixer_rhythm_beat(r); kv_mixer_rhythm(r,true,KV_GRID_BEATS,KV_METER_4_4,.25,.6f); CHECK(fabs(kv_mixer_rhythm_beat(r)-before)<1e-9);
      n=clicks(r,44100,at,peak,64); CHECK(n>=3 && fabs((double)(at[2]-at[1])-11025)<=1);
      kv_mixer_rhythm(r,false,KV_GRID_BEATS,KV_METER_4_4,.25,.6f); advance(r,block,2400); CHECK(kv_mixer_rhythm_beat(r)<0 && clicks(r,44100,at,peak,64)==0);
      kv_mixer_free(r); }
    // Queue: the next part starts on the exact frame the current one ends, the current voices ring on under it, the rhythm
    // switches with it; a stop or a new performance drops the queue.
    { KvMixer *q=kv_mixer_create(); kv_mixer_bank(q,0,banks[0]); KvKey ck={0,false,0,0};
      KvPerformance first={0},next={0},third={0}; KvArrangement arr={.style=KV_BALLAD,.meter=KV_METER_4_4,.length=KV_LENGTH_BAR,.blocks=true,.seconds_per_beat=.5};
      KvChord c; CHECK(kv_chord(ck,0,&c) && kv_arrange_with(&c,1,60,ck,arr,&first));
      CHECK(kv_chord(ck,4,&c) && kv_arrange_with(&c,1,60,ck,arr,&next));
      CHECK(kv_chord(ck,3,&c) && kv_arrange_with(&c,1,60,ck,arr,&third));
      CHECK(!kv_mixer_queue(q,&next,-1,NULL,0,0));                       // nothing playing yet
      CHECK(kv_mixer_performance(q,&first,.5,0)); uint64_t start=kv_mixer_start(q);
      kv_mixer_rhythm(q,false,KV_GRID_BEATS,KV_METER_4_4,.5,.6f);
      CHECK(kv_mixer_queue(q,&next,-1,NULL,0,0) && kv_mixer_part(q)==0 && kv_mixer_busy(q));
      advance(q,block,(unsigned)(start-kv_mixer_clock(q))+88200-8); CHECK(kv_mixer_part(q)==0);
      advance(q,block,16); CHECK(kv_mixer_part(q)==1 && kv_mixer_start(q)==start+88200);
      unsigned struck=0; for(size_t i=0;i<next.count;i++) if(next.events[i].beat<.01) struck++;
      advance(q,block,512); CHECK(struck==3 && kv_mixer_voices(q)>=2*struck);   // the C chord's release tails sound under G      // the C chord's release tails sound under G
      int sounding[KV_ACTIVE_NOTES]; unsigned ns=kv_mixer_active(q,sounding); bool g=false; for(unsigned i=0;i<ns;i++) if(sounding[i]%12==7) g=true; CHECK(g);
      advance(q,block,88200+44100*2); CHECK(kv_mixer_part(q)==1 && !kv_mixer_running(q));
      // The rhythm follows the parts: off in the first, a beat in the second, off again in the third.
      KvHit kicks[2]={{0,KV_DRUM_KICK,1},{2,KV_DRUM_KICK,.8f}};
      CHECK(kv_mixer_performance(q,&first,.5,0)); start=kv_mixer_start(q); CHECK(kv_mixer_queue(q,&next,1,kicks,2,0));
      advance(q,block,88200-256); CHECK(kv_mixer_drum_voices(q)==0 && kv_mixer_rhythm_beat(q)<0);
      advance(q,block,512); CHECK(kv_mixer_part(q)==1 && kv_mixer_drum_voices(q)>0 && kv_mixer_rhythm_beat(q)>=0 && kv_mixer_rhythm_beat(q)<.05);
      CHECK(kv_mixer_queue(q,&third,0,NULL,0,0)); advance(q,block,88200); CHECK(kv_mixer_part(q)==2 && kv_mixer_rhythm_beat(q)<0);
      // A stop drops the queue; so does a fresh performance.
      CHECK(kv_mixer_performance(q,&first,.5,0) && kv_mixer_part(q)==0 && kv_mixer_queue(q,&next,-1,NULL,0,0)); kv_mixer_stop(q);
      advance(q,block,88200*2); CHECK(kv_mixer_part(q)==0 && !kv_mixer_running(q));
      CHECK(kv_mixer_performance(q,&first,.5,0) && kv_mixer_queue(q,&next,-1,NULL,0,0) && kv_mixer_performance(q,&third,.5,0));
      advance(q,block,88200*2); CHECK(kv_mixer_part(q)==0);
      // A part without notes (every track muted) still lasts its beats, and the next one starts on time after it.
      KvPerformance hush=next; hush.count=0; hush.total_beats=2; CHECK(kv_performance_playable(&hush) && !kv_performance_valid(&hush));
      CHECK(kv_mixer_performance(q,&hush,.5,0)); start=kv_mixer_start(q); CHECK(kv_mixer_queue(q,&next,-1,NULL,0,0));
      advance(q,block,44100-64); CHECK(kv_mixer_part(q)==0 && kv_mixer_running(q) && !kv_mixer_silent(q));
      advance(q,block,128); CHECK(kv_mixer_part(q)==1 && kv_mixer_start(q)==start+44100);
      // A part that begins inside a bar: its beat starts that far into the bar, the queued one's and the first one's alike.
      CHECK(kv_mixer_performance(q,&first,.5,0) && kv_mixer_queue(q,&next,1,kicks,2,1.5)); start=kv_mixer_start(q);
      advance(q,block,88200+64); CHECK(kv_mixer_part(q)==1 && fabs(kv_mixer_rhythm_beat(q)-1.5)<.01);
      kv_mixer_phase(q,3); CHECK(kv_mixer_performance(q,&first,.5,0)); advance(q,block,64); CHECK(fabs(kv_mixer_rhythm_beat(q)-3)<.01);
      CHECK(!kv_mixer_queue(q,&next,1,kicks,2,-1));
      kv_mixer_rhythm(q,false,KV_GRID_BEATS,KV_METER_4_4,.5,.6f);
      // Silence: once everything has died away nothing can sound and a skip only moves the clock; not with the rhythm on,
      // not while a count-in waits for its sequence.
      kv_mixer_stop(q); advance(q,block,44100); CHECK(kv_mixer_silent(q));
      uint64_t was=kv_mixer_clock(q); kv_mixer_skip(q,256); CHECK(kv_mixer_clock(q)==was+256 && kv_mixer_silent(q));
      kv_mixer_rhythm(q,true,KV_GRID_BEATS,KV_METER_4_4,.5,.6f); CHECK(!kv_mixer_silent(q));
      kv_mixer_rhythm(q,false,KV_GRID_BEATS,KV_METER_4_4,.5,.6f); advance(q,block,4410); CHECK(kv_mixer_silent(q));
      kv_mixer_count_in(q,4); CHECK(kv_mixer_performance(q,&first,.5,0) && !kv_mixer_silent(q));
      kv_mixer_free(q); }
    // Beats: hits on the exact frames of the bar; without recordings the synthesized kit plays; the recorded kit has every drum
    // the beats use (soft and loud, two takes); a count-in is clicked and the beat comes in with the sequence.
    { size_t at[64]; float peak[64];
      KvMixer *r=kv_mixer_create(); CHECK(r); kv_mixer_humanize(r,false);
      kv_mixer_rhythm(r,false,KV_GRID_BEATS,KV_METER_4_4,.6,.6f); uint64_t origin=kv_mixer_clock(r);   // the click off: the drums alone start the grid
      KvHit two[2]={{0,KV_DRUM_KICK,1},{2,KV_DRUM_KICK,.75f}}; kv_mixer_beat(r,two,2,true);
      size_t n=clicks(r,(size_t)(26460*4.5),at,peak,64);
      CHECK(n==3 && at[0]<=origin+1 && llabs((long long)at[1]-(long long)(origin+2*26460))<=1 && llabs((long long)at[2]-(long long)(origin+4*26460))<=1 && peak[0]>peak[1]);
      KvHit pop[KV_BEAT_HITS]; size_t np=kv_beat_bar(KV_BEAT_POP,KV_METER_4_4,pop);
      kv_mixer_beat(r,pop,np,false); advance(r,block,26460*2); CHECK(kv_mixer_drum_voices(r)>0);   // no recordings: the synthesized kit plays instead
      if(argc==6) {
          KvPianoBank *kit=kv_piano_load(argv[5]); CHECK(kit);
          for(int b=0;b<KV_BEAT_COUNT;b++) for(int mt=0;mt<KV_METER_COUNT;mt++) { KvHit h[KV_BEAT_HITS]; size_t k=kv_beat_bar((KvBeat)b,(KvMeter)mt,h);
              for(size_t i=0;i<k;i++) for(int layer=0;layer<4;layer++) { KvSampleView v; CHECK(kv_piano_layer(kit,h[i].drum,layer,&v) && v.midi==h[i].drum && v.frames>441); } }
          kv_mixer_drums(r,kit); kv_mixer_beat(r,pop,np,false); float energy=0;
          for(int i=0;i<40;i++) { advance(r,block,2646); const float *dry=kv_mixer_dry(r); for(int f=0;f<256;f++) energy+=dry[f*2]*dry[f*2]; }
          CHECK(energy>.01f);
          // Count-in: one bar of clicks only, then the drums start on the sequence's first beat.
          KvPerformance perf={0}; KvArrangement arr={.style=KV_BALLAD,.meter=KV_METER_4_4,.length=KV_LENGTH_BAR,.blocks=true,.seconds_per_beat=.6};
          KvChord c; CHECK(kv_chord((KvKey){0,false,0,0},0,&c)); CHECK(kv_arrange_with(&c,1,60,(KvKey){0,false,0,0},arr,&perf));
          kv_mixer_bank(r,0,banks[0]); advance(r,block,44100); kv_mixer_count_in(r,4); CHECK(kv_mixer_performance(r,&perf,.6,0));
          uint64_t start=kv_mixer_start(r); advance(r,block,(unsigned)(start-kv_mixer_clock(r)-600));
          CHECK(kv_mixer_drum_voices(r)==0);
          advance(r,block,1200); CHECK(kv_mixer_drum_voices(r)>0);
          kv_mixer_stop(r); kv_mixer_free(r); r=NULL; kv_piano_free(kit);
      }
      if(r) kv_mixer_free(r); }
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
