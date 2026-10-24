#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>
#include "fingering.h"
#include "music.h"
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"%s:%d: %s\n",__FILE__,__LINE__,#x); return 1; } } while(0)

/* A one-hand line of quarter notes. */
static void line(const int *midi, int n, unsigned hand, unsigned char *fingers) {
    KvPianoEvent events[64]; for(int i=0;i<n;i++) events[i]=(KvPianoEvent){midi[i],i*.5,.5,.8f,0,hand,0};
    kv_finger_events(events,(size_t)n,hand,fingers);
}
static int same(const unsigned char *got, const char *want) {
    for(int i=0;want[i];i++) if(got[i]!=want[i]-'0') {
        fprintf(stderr,"  got "); for(int j=0;want[j];j++) fprintf(stderr,"%d",got[j]); fprintf(stderr,", want %s\n",want); return 0;
    }
    return 1;
}
static int is_black(int midi) { int pc=midi%12; return pc==1 || pc==3 || pc==6 || pc==8 || pc==10; }


int main(void) {
    unsigned char f[64];
    /* Textbook one-octave scales. */
    int c_up[8]={60,62,64,65,67,69,71,72}, c_down[8]={72,71,69,67,65,64,62,60};
    line(c_up,8,1,f); CHECK(same(f,"12312345"));                 /* right hand up */
    line(c_down,8,1,f); CHECK(same(f,"54321321"));               /* right hand down */
    int c3_up[8]={48,50,52,53,55,57,59,60}, c3_down[8]={60,59,57,55,53,52,50,48};
    line(c3_up,8,0,f); CHECK(same(f,"54321321"));                /* left hand up */
    line(c3_down,8,0,f); CHECK(same(f,"12312345"));              /* left hand down */
    int g_up[8]={67,69,71,72,74,76,78,79}; line(g_up,8,1,f); CHECK(same(f,"12312345"));
    int d_up[8]={62,64,66,67,69,71,73,74}; line(d_up,8,1,f); CHECK(same(f,"12312345"));
    int f_up[8]={65,67,69,70,72,74,76,77}; line(f_up,8,1,f); CHECK(same(f,"12341234")); /* thumb avoids B♭ */
    /* Every major and minor scale, both hands, both directions: all fingers 1–5, no thumb on a black key,
       never the same finger on two neighbouring different keys, and the hand travels: an octave needs a thumb crossing. */
    for(int k=0;k<12;k++) for(int minor=0;minor<2;minor++) for(unsigned hand=0;hand<2;hand++) for(int down=0;down<2;down++) {
        KvKey key={k,minor,0,0}; int scale[8]; kv_scale(key,scale);
        int notes[8]; for(int i=0;i<8;i++) notes[i]=scale[down?7-i:i]+(hand?0:-12);
        line(notes,8,hand,f); int crossings=0;
        for(int i=0;i<8;i++) {
            CHECK(f[i]>=1 && f[i]<=5); if(i && (f[i]==1)!=(f[i-1]==1) && abs(f[i]-f[i-1])>1) crossings++;
            if(f[i]==1 && is_black(notes[i])) { fprintf(stderr,"thumb on black: key %d minor %d hand %u down %d note %d\n",k,minor,hand,down,i); return 1; }
            if(i && f[i]==f[i-1] && notes[i]!=notes[i-1]) { fprintf(stderr,"repeated finger: key %d minor %d hand %u down %d note %d\n",k,minor,hand,down,i); return 1; }
        }
        CHECK(crossings>=1);
    }
    /* Chords. */
    KvPianoEvent triad[3]={{60,0,1,.8f,0,1,0},{64,0,1,.8f,0,1,0},{67,0,1,.8f,0,1,0}};
    kv_finger_events(triad,3,1,f); CHECK(same(f,"135"));
    KvPianoEvent left[3]={{48,0,1,.8f,0,0,0},{52,0,1,.8f,0,0,0},{55,0,1,.8f,0,0,0}};
    kv_finger_events(left,3,0,f); CHECK(same(f,"531"));
    KvPianoEvent seventh[4]={{60,0,1,.8f,0,1,0},{64,0,1,.8f,0,1,0},{67,0,1,.8f,0,1,0},{71,0,1,.8f,0,1,0}};
    kv_finger_events(seventh,4,1,f); CHECK(same(f,"1235"));
    KvPianoEvent octave[2]={{48,0,1,.8f,0,0,0},{60,0,1,.8f,0,0,0}};
    kv_finger_events(octave,2,0,f); CHECK(same(f,"51"));
    /* A spread arpeggio climbs with 1-2-3(-4) between thumb crossings, not 1-3-1-3. */
    int arp[7]={60,64,67,71,72,76,79}; line(arp,7,1,f);
    CHECK(!memcmp(f,"\1\2\3\4\1\2\3",7) || !memcmp(f,"\1\2\3\1\2\3\5",7));
    for(int i=2;i<7;i++) CHECK(!(f[i]==1 && f[i-2]==1));                 /* never 1-x-1 */
    int triad_up[7]={60,64,67,72,76,79,84}; line(triad_up,7,1,f); CHECK(same(f,"1231235"));
    int seventh_up[5]={72,76,79,83,84}; line(seventh_up,5,1,f); CHECK(same(f,"12345"));            /* C E G B C: no 1-3-1-3-5 */
    /* The arpeggio texture: the right hand never brings the thumb back after a single note. */
    { KvKey c_major={0,false,0,0}; KvChord chords[4]; const int degrees[]={0,5,3,4};
      for(int c=0;c<4;c++) CHECK(kv_chord_extended(c_major,degrees[c],1,&chords[c]));
      for(int pattern=0;pattern<KV_ARP_COUNT;pattern++) for(unsigned seed=1;seed<=6;seed++) {
          KvArrangement a={KV_BALLAD,KV_METER_4_4,KV_LENGTH_BAR,KV_FILL_STYLE,seed,seed>1,false,true,(KvArpeggioPattern)pattern,KV_DIV_EIGHTH,false,.6};
          KvPerformance p; CHECK(kv_arrange_with(chords,4,60,c_major,a,&p)); unsigned char fp[KV_PERFORMANCE_CAPACITY]; kv_finger_performance(&p,fp);
          int rh[KV_PERFORMANCE_CAPACITY],n=0; for(size_t i=0;i<p.count;i++) if(p.events[i].hand==1) rh[n++]=(int)i;
          int thumbBack=0,crossings=0;
          for(int i=2;i<n;i++) { const KvPianoEvent *a0=&p.events[rh[i-2]],*a1=&p.events[rh[i-1]],*a2=&p.events[rh[i]];
              bool rising=a0->midi<a1->midi && a1->midi<a2->midi; if(!rising || a2->beat-a0->beat>2) continue;
              if(fp[rh[i]]==1 && fp[rh[i-1]]>1) crossings++;
              if(fp[rh[i]]==1 && fp[rh[i-2]]==1) thumbBack++; }
          if(thumbBack*4>crossings+3) { fprintf(stderr,"arpeggio %d seed %u: thumb back after one note %d of %d crossings\n",pattern,seed,thumbBack,crossings); return 1; }
      } }
    /* Other hand's events are left alone. */
    KvPianoEvent mixed[2]={{48,0,1,.8f,0,0,0},{72,0,1,.8f,0,1,0}}; memset(f,9,2);
    kv_finger_events(mixed,2,1,f); CHECK(f[0]==9 && f[1]==1);
    /* A held key keeps its finger: a bass held under a moving line never loses its finger to the line. */
    KvPianoEvent held[5]={{48,0,4,.8f,0,0,0},{55,0,.5,.8f,0,0,0},{52,1,.5,.8f,0,0,0},{55,2,.5,.8f,0,0,0},{52,3,.5,.8f,0,0,0}};
    kv_finger_events(held,5,0,f); for(int i=1;i<5;i++) CHECK(f[i]!=f[0]);

    /* Generated performances: no finger is asked to hold two keys at once (when the hand holds at most five). */
    int checked=0;
    for(int k=0;k<12;k+=5) for(int style=0;style<KV_PATTERN_COUNT;style++) for(int texture=0;texture<3;texture++) for(unsigned seed=1;seed<=4;seed++) {
        KvKey key={k,0,0,0}; KvChord chords[4]; const int degrees[]={0,5,3,4};
        for(int c=0;c<4;c++) CHECK(kv_chord_extended(key,degrees[c],1,&chords[c]));
        KvArrangement a={(KvPianoPattern)style,KV_METER_4_4,KV_LENGTH_BAR,KV_FILL_STYLE,seed,true,texture==0,texture==2,KV_ARP_UP,KV_DIV_EIGHTH,false,.6};
        KvPerformance p; if(!kv_arrange_with(chords,4,60,key,a,&p)) continue;
        unsigned char fingers[KV_PERFORMANCE_CAPACITY]; kv_finger_performance(&p,fingers);
        for(size_t i=0;i<p.count;i++) {
            CHECK(fingers[i]<=5);
            int together=0; for(size_t j=0;j<p.count;j++) if(p.events[j].hand==p.events[i].hand && p.events[j].beat<p.events[i].beat+.01 && p.events[j].beat+p.events[j].duration>p.events[i].beat+.03) together++;
            if(together>5) continue;
            CHECK(fingers[i]>=1);
            for(size_t j=0;j<p.count;j++) if(j!=i && p.events[j].hand==p.events[i].hand && p.events[j].midi!=p.events[i].midi && fingers[j]==fingers[i]) {
                double s=fmax(p.events[i].beat,p.events[j].beat),e=fmin(p.events[i].beat+p.events[i].duration,p.events[j].beat+p.events[j].duration);
                if(fabs(p.events[i].beat-p.events[j].beat)>1e-6 ? e-s>.15 : e-s>.03) { /* ringing tails are pedal, not fingers */ fprintf(stderr,"finger %d holds two keys: style %d texture %d seed %u events %zu %zu\n",fingers[i],style,texture,seed,i,j); return 1; }
            }
        }
        checked++;
    }
    CHECK(checked>100);


    puts("fingering ok"); return 0;
}
