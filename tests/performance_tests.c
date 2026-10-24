#include "performance.h"
#include "music.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"Performance check failed at %d: %s\n",__LINE__,#x); return 1; } } while(0)
int main(void) {
    for(int base=36;base<=84;base+=12) for(int minor=0;minor<2;minor++) for(int key=0;key<12;key++) {
        int chords[8][3]; const int degrees[]={0,5,3,4,2,6,1,0};
        for(int i=0;i<8;i++) { KvChord chord; CHECK(kv_chord((KvKey){key,minor,0,0},degrees[i],&chord)); for(int v=0;v<3;v++) chords[i][v]=chord.midi[v]+base-60; }
        for(int pattern=0;pattern<=KV_WALTZ;pattern++) {
            KvPerformance p; if(!kv_two_hand(chords,8,base,(KvPianoPattern)pattern,&p)) { fprintf(stderr,"base=%d minor=%d key=%d pattern=%d\n",base,minor,key,pattern); return 1; }
            CHECK(p.chord_count==8 && p.beats_per_chord==(pattern==KV_WALTZ?3:4));
            CHECK(p.total_beats==8*p.beats_per_chord && p.count<256);
            unsigned hands[8][2]={{0}}; bool rhythms[8][2][8]={0}; bool right[8][12]={0};
            for(size_t i=0;i<p.count;i++) {
                KvPianoEvent e=p.events[i]; bool chord_note=false;
                for(int v=0;v<3;v++) if(e.midi%12==chords[e.chord][v]%12) chord_note=true;
                CHECK(chord_note && e.velocity>=.57f && e.velocity<=.78f);
                CHECK(e.beat+e.duration<=(e.chord+1)*p.beats_per_chord+.00001);
                hands[e.chord][e.hand]++; unsigned slot=(unsigned)lround((e.beat-e.chord*p.beats_per_chord)*2);
                CHECK(slot<8); rhythms[e.chord][e.hand][slot]=true;
                if(e.hand) { CHECK(e.midi>=base+12 && e.midi<=base+23); right[e.chord][e.midi%12]=true; }
                else CHECK(e.midi>=base-12 && e.midi<=base+17);
            }
            for(int c=0;c<8;c++) {
                CHECK(hands[c][0]>=2 && hands[c][1]>=4);
                CHECK(memcmp(rhythms[c][0],rhythms[c][1],sizeof(rhythms[c][0]))!=0);
                unsigned tones=0; for(int i=0;i<12;i++) tones+=right[c][i]; CHECK(tones==3);
            }
        }
    }
    // Melodies use the selected key (including non-chord scale notes), not only triad permutations.
    for(int base=36;base<=84;base+=12) for(int minor=0;minor<2;minor++) for(int k=0;k<12;k++) {
        KvKey key={k,minor,0,0}; int chords[4][3]; int degrees[]={0,3,1,4};
        for(int c=0;c<4;c++) { KvChord ch; CHECK(kv_chord(key,degrees[c],&ch)); for(int v=0;v<3;v++) chords[c][v]=ch.midi[v]+base-60; }
        for(int style=KV_DARK_JAZZ;style<KV_PATTERN_COUNT;style++) {
            KvPerformance a,b; CHECK(kv_two_hand_key(chords,4,base,(KvPianoPattern)style,key,123,&a));
            CHECK(kv_two_hand_key(chords,4,base,(KvPianoPattern)style,key,123,&b));
            CHECK(a.count==b.count); bool colour=false,fill=false; unsigned right=0;
            for(size_t i=0;i<a.count;i++) {
                KvPianoEvent e=a.events[i],f=b.events[i];
                CHECK(e.midi==f.midi && e.beat==f.beat && e.duration==f.duration && e.velocity==f.velocity);
                CHECK(kv_contains(key,e.midi));
                if(e.hand) {
                    right++; bool triad=false; for(int v=0;v<3;v++) if(e.midi%12==chords[e.chord][v]%12) triad=true;
                    if(!triad) colour=true;
                    double local=e.beat-e.chord*4;
                    if(e.chord==3 && local>=3.5) fill=true;
                }
            }
            CHECK(right>=8 && colour && fill);
            if(style==KV_AMBIENT) CHECK(a.count<24); // Space and sustained notes, rather than a fast arpeggio.
        }
    }
    for(int minor=0;minor<2;minor++) for(int k=0;k<12;k++) for(int ext=0;ext<=4;ext++) {
        KvKey key={k,minor,0,0}; KvChord chords[4]; int degrees[]={0,3,1,4};
        for(int c=0;c<4;c++) CHECK(kv_chord_extended(key,degrees[c],ext,&chords[c]));
        for(int style=0;style<KV_PATTERN_COUNT;style++) for(int gen=0;gen<2;gen++) {
            KvPerformance p,q; CHECK(kv_arrange(chords,4,60,(KvPianoPattern)style,key,123,gen,&p));
            CHECK(kv_arrange(chords,4,60,(KvPianoPattern)style,key,123,gen,&q)); CHECK(p.count==q.count);
            bool heard[4][7]={{0}};
            for(size_t i=0;i<p.count;i++) {
                KvPianoEvent e=p.events[i]; CHECK(e.midi==q.events[i].midi && e.beat==q.events[i].beat && e.duration==q.events[i].duration);
                CHECK(kv_contains(key,e.midi));
                for(size_t v=0;v<chords[e.chord].count;v++) if(e.midi%12==chords[e.chord].midi[v]%12) heard[e.chord][v]=true;
            }
            if(gen) { CHECK(p.controlled); for(int c=0;c<4;c++) CHECK(heard[c][0]); }
        }
    }
    // Independent seeds change actual onset grids, not just pitches or velocity.
    KvChord harmony[4]; for(int i=0;i<4;i++) CHECK(kv_chord_extended((KvKey){0,false,0,0},i,1,&harmony[i]));
    bool unique[16][2][16]={0};
    for(unsigned seed=1;seed<=16;seed++) {
        KvPerformance p; CHECK(kv_arrange(harmony,4,60,KV_DARK_JAZZ,(KvKey){0,false,0,0},seed,true,&p));
        for(size_t i=0;i<p.count;i++) if(p.events[i].chord==0) unique[seed-1][p.events[i].hand][(unsigned)lround(p.events[i].beat*4)]=true;
    }
    unsigned different=0; for(int i=1;i<16;i++) if(memcmp(unique[0],unique[i],sizeof(unique[0]))) different++;
    CHECK(different>=2); // A few deliberate groove families, not maximal random diversity.
    // Every family and phrase phase is reviewed across keys, extensions and keyboard extremes.
    for(int base=36;base<=84;base+=24) for(int minor=0;minor<2;minor++) for(int k=0;k<12;k++) for(int ext=0;ext<=4;ext++) {
        KvKey key={k,minor,0,0}; KvChord chords[4]; const int degrees[]={0,5,3,4};
        for(int c=0;c<4;c++) CHECK(kv_chord_extended(key,degrees[c],ext,&chords[c]));
        for(unsigned seed=1;seed<=16;seed++) for(int style=0;style<KV_PATTERN_COUNT;style++) {
            KvPerformance p; if(!kv_arrange(chords,4,base,(KvPianoPattern)style,key,seed,true,&p)) {
                fprintf(stderr,"Controlled phrase failed base=%d minor=%d key=%d ext=%d seed=%u style=%d\n",base,minor,k,ext,seed,style); return 1;
            }
            CHECK(kv_arrangement_controlled(&p));
        }
    }
    /* Note roles: C major (C E G) then F major (F A C), a bar each. */
    { KvPerformance r={.count=6,.chord_count=2,.beats_per_chord=4,.total_beats=8};
      r.events[0]=(KvPianoEvent){64,0,1,.8f,0,1,0};    /* E: chord tone of C */
      r.events[1]=(KvPianoEvent){62,1,1,.8f,0,1,0};    /* D: in neither chord — passing */
      r.events[2]=(KvPianoEvent){69,3.5,.5,.8f,0,1,0}; /* A in the last beat of C, tone of F — anticipation */
      r.events[3]=(KvPianoEvent){69,1,.5,.8f,0,1,0};   /* A early in the C bar — passing, too early to anticipate */
      r.events[4]=(KvPianoEvent){71,7.5,.5,.8f,1,1,0}; /* B before the loop back to C: not in C either — passing */
      r.events[5]=(KvPianoEvent){67,7.5,.5,.8f,1,1,0}; /* G in the last beat of F, tone of C (the loop) — anticipation */
      unsigned masks[2]={(1u<<0)|(1u<<4)|(1u<<7),(1u<<5)|(1u<<9)|(1u<<0)}; unsigned char roles[6];
      kv_note_roles(&r,masks,2,roles);
      CHECK(roles[0]==KV_ROLE_CHORD && roles[1]==KV_ROLE_PASSING && roles[2]==KV_ROLE_ANTICIPATION && roles[3]==KV_ROLE_PASSING && roles[4]==KV_ROLE_PASSING && roles[5]==KV_ROLE_ANTICIPATION);
      /* Block chords and arpeggios have no non-chord tones; a two-hand melody does, and only in the right hand. */
      KvKey c_major={0,false,0,0}; KvChord chords[4]; const int degrees[]={0,5,3,4}; unsigned m[4];
      for(int c=0;c<4;c++) { CHECK(kv_chord_extended(c_major,degrees[c],1,&chords[c])); m[c]=0; for(size_t v=0;v<chords[c].count;v++) m[c]|=1u<<(chords[c].midi[v]%12); }
      for(int texture=0;texture<3;texture++) {
          KvArrangement a={KV_INTERLUDE,KV_METER_4_4,KV_LENGTH_BAR,KV_FILL_STYLE,3,true,texture==0,texture==2,KV_ARP_UP,KV_DIV_EIGHTH,false,.6};
          KvPerformance q; CHECK(kv_arrange_with(chords,4,60,c_major,a,&q)); unsigned char qr[KV_PERFORMANCE_CAPACITY]; kv_note_roles(&q,m,4,qr);
          int outside=0; for(size_t i=0;i<q.count;i++) if(qr[i]!=KV_ROLE_CHORD) { outside++; CHECK(q.events[i].hand==1); }
          if(texture==1) CHECK(outside>0); else CHECK(outside==0);
      } }
    /* Pentatonic keys: every style and texture arranges, and the right hand plays only chord tones and pentatonic notes. */
    for(int k=0;k<12;k+=3) for(int minor=0;minor<2;minor++) for(int texture=0;texture<3;texture++) for(int style=0;style<KV_PATTERN_COUNT;style++) for(unsigned seed=0;seed<=3;seed++) {
        KvKey key={k,minor,0,0,true}; KvChord chords[4]; const int degrees[]={0,5,3,4};
        for(int c=0;c<4;c++) CHECK(kv_chord_extended(key,degrees[c],1,&chords[c]));
        KvArrangement a={(KvPianoPattern)style,KV_METER_4_4,KV_LENGTH_BAR,KV_FILL_EVERY_BAR,seed,seed>0,texture==0,texture==2,KV_ARP_UP,KV_DIV_EIGHTH,false,.5};
        KvPerformance p; if(!kv_arrange_with(chords,4,60,key,a,&p)) { fprintf(stderr,"Pentatonic arrangement failed key=%d minor=%d texture=%d style=%d seed=%u\n",k,minor,texture,style,seed); return 1; }
        for(size_t i=0;i<p.count;i++) if(p.events[i].hand) {
            int m=p.events[i].midi; bool ok=kv_in_scale(key,m); const KvChord *ch=&chords[p.events[i].chord%4];
            for(size_t v=0;v<ch->count && !ok;v++) if(ch->midi[v]%12==m%12) ok=true;
            if(!ok) { fprintf(stderr,"Pentatonic key=%d minor=%d texture=%d style=%d seed=%u: right hand plays %d outside the pentatonic and the chord\n",k,minor,texture,style,seed,m); return 1; }
        }
    }
    /* Chords outside the key and inversions, every texture and style: the right hand plays only tones of the chord's own
       scale (A7 in C: C♯, never C), the left hand's lowest note at each chord is the chosen bass. */
    { KvKey c={0,false,0,0,false}; const int codes[4]={0,kv_code_with_inversion(KV_CODE_SECONDARY+1,1),1,kv_code_with_inversion(KV_CODE_BORROWED+5,2)};
      KvChord chords[4]; for(int i=0;i<4;i++) CHECK(kv_code_chord(c,codes[i],1,&chords[i]));
      for(int texture=0;texture<3;texture++) for(int style=0;style<KV_PATTERN_COUNT;style++) for(unsigned seed=0;seed<=5;seed++) {
          KvArrangement a={(KvPianoPattern)style,KV_METER_4_4,KV_LENGTH_BAR,KV_FILL_EVERY_BAR,seed,seed>0,texture==0,texture==2,KV_ARP_UP,KV_DIV_EIGHTH,false,.5};
          KvPerformance p; if(!kv_arrange_with(chords,4,48,c,a,&p)) { fprintf(stderr,"Chromatic arrangement failed texture %d style %d seed %u\n",texture,style,seed); return 1; }
          for(size_t i=0;i<p.count;i++) { const KvPianoEvent *e=&p.events[i]; if(!e->hand || e->chord!=1) continue;
              if(e->midi%12==0) { fprintf(stderr,"texture %d style %d seed %u: C natural under A7 at beat %.2f\n",texture,style,seed,e->beat); return 1; } }
          for(int ch=0;ch<4;ch++) { int lowest=999; for(size_t i=0;i<p.count;i++) if(!p.events[i].hand && p.events[i].chord==(unsigned)ch && p.events[i].beat<ch*4+.01 && p.events[i].midi<lowest) lowest=p.events[i].midi;
              if(lowest==999) continue; int want=chords[ch].midi[chords[ch].bass]%12;
              if(lowest%12!=want) { fprintf(stderr,"texture %d style %d seed %u: chord %d bass %d, want pitch class %d\n",texture,style,seed,ch,lowest,want); return 1; } }
      } }
    /* Playable arpeggios: two right-hand notes that sound together are never more than a tenth apart (one hand). */
    { KvKey key={0,false,0,0}; int worst=0;
      for(int ext=0;ext<=2;ext++) for(int pattern=0;pattern<KV_ARP_COUNT;pattern++) for(int div=0;div<KV_DIV_COUNT;div++) for(unsigned seed=0;seed<=40;seed++) {
          KvChord chords[4]; const int degrees[]={0,5,3,4}; for(int c=0;c<4;c++) CHECK(kv_chord_extended(key,degrees[c],ext,&chords[c]));
          KvArrangement a={KV_BALLAD,KV_METER_4_4,KV_LENGTH_BAR,KV_FILL_STYLE,seed,seed>0,false,true,(KvArpeggioPattern)pattern,(KvDivision)div,false,.5};
          KvPerformance p; CHECK(kv_arrange_with(chords,4,48,key,a,&p));
          for(size_t i=0;i<p.count;i++) for(size_t j=i+1;j<p.count;j++) {
              const KvPianoEvent *u=&p.events[i],*v=&p.events[j]; if(!u->hand || !v->hand) continue;
              double s=fmax(u->beat,v->beat),e=fmin(u->beat+u->duration,v->beat+v->duration); if(e-s<.05) continue;
              int span=abs(u->midi-v->midi); if(span>worst) worst=span;
              if(span>16) { fprintf(stderr,"Arpeggio ext %d pattern %d div %d seed %u: right hand holds %d and %d together (%d semitones)\n",ext,pattern,div,seed,u->midi,v->midi,span); return 1; }
          }
      }
      CHECK(worst>=12); /* the pedal figure really holds an octave */ }
    KvPerformance bad={.events={{60,0,.8,.7f,0,1,0},{61,0,.8,.7f,0,1,0}},.count=2,.chord_count=1,.beats_per_chord=4,.total_beats=4,.controlled=true};
    CHECK(kv_performance_valid(&bad) && !kv_arrangement_controlled(&bad));
    bad.events[1]=(KvPianoEvent){72,1,.8,.7f,0,1,0}; CHECK(!kv_arrangement_controlled(&bad)); // octave lurch
    // C -> Am retains the common upper C and E instead of jumping to root position.
    int cad[2][3]={{60,64,67},{69,72,76}}; KvPerformance p;
    CHECK(kv_two_hand(cad,2,60,KV_FLOWING,&p));
    bool c[2]={0},e[2]={0};
    for(size_t i=0;i<p.count;i++) if(p.events[i].hand) { if(p.events[i].midi==72) c[p.events[i].chord]=true; if(p.events[i].midi==76) e[p.events[i].chord]=true; }
    CHECK(c[0] && c[1] && e[0] && e[1]);
    CHECK(!kv_two_hand(cad,2,60,KV_PATTERN_COUNT,&p)); CHECK(!kv_two_hand(cad,0,60,KV_POP,&p));
    CHECK(!kv_two_hand(cad,2,61,KV_POP,&p));
    CHECK(kv_two_hand(cad,2,60,KV_POP,&p)); p.events[0].duration=NAN; CHECK(!kv_performance_valid(&p));
    for(int mode=1;mode<=7;mode++) for(int k=0;k<12;k++) for(int ext=0;ext<5;ext++) {
        KvKey key={k,true,mode,0}; KvChord chords[4]; int degrees[]={0,3,1,4};
        for(int i=0;i<4;i++) CHECK(kv_chord_extended(key,degrees[i],ext,&chords[i]));
        for(int style=0;style<KV_PATTERN_COUNT;style++) for(int generated=0;generated<2;generated++) {
            KvPerformance p; CHECK(kv_arrange(chords,4,48,style,key,123,generated,&p));
            for(size_t n=0;n<p.count;n++) CHECK(kv_contains(key,p.events[n].midi));
        }
    }


    // ---- 0.15: independent meter x chord length x fill rate ----
    {
        unsigned arrangements=0,controlled=0; bool meter_seen[KV_METER_COUNT]={0};
        for(int minor=0;minor<2;minor++) for(int k=0;k<12;k+=1) for(int ext=0;ext<=4;ext+=4) {
            KvKey key={k,minor,minor && k%3==0?6:0,0}; KvChord chords[5]; const int degrees[]={0,5,3,4,1};
            int base=36+12*(k%5);
            for(int c=0;c<5;c++) { CHECK(kv_chord_extended(key,degrees[c],ext,&chords[c])); for(size_t v=0;v<chords[c].count;v++) chords[c].midi[v]+=base-60; }
            for(int style=0;style<KV_PATTERN_COUNT;style++) for(int meter=0;meter<KV_METER_COUNT;meter++) for(int length=0;length<KV_LENGTH_COUNT;length++) for(int fills=0;fills<KV_FILL_COUNT;fills++) for(int gen=0;gen<2;gen++) {
                if((k+style+length)%3 && fills!=KV_FILL_STYLE && fills!=KV_FILL_EVERY_BAR) continue; // keep runtime bounded; every combination still covered across keys
                size_t count=(size_t)(k%2?5:4);
                KvArrangement a={.style=style,.meter=meter,.length=length,.fills=fills,.seed=(uint32_t)(k*31+style+1),.generated=gen,.seconds_per_beat=.6};
                KvPerformance p;
                if(!kv_arrange_with(chords,count,base,key,a,&p)) { fprintf(stderr,"arrange_with failed key=%d minor=%d ext=%d style=%d meter=%d length=%d fills=%d gen=%d\n",k,minor,ext,style,meter,length,fills,gen); return 1; }
                arrangements++; meter_seen[meter]=true;
                double chord_beats=kv_chord_beats(meter,length);
                CHECK(p.beats_per_bar==kv_meter_bar(meter) && fabs(p.beats_per_chord-chord_beats)<1e-9 && fabs(p.total_beats-count*chord_beats)<1e-9);
                if(p.controlled) { CHECK(kv_arrangement_controlled(&p)); controlled++; }
                CHECK(!(style<=KV_WALTZ && !gen) || !p.controlled);
                // Every chord is announced by a bass note exactly on its first beat.
                for(size_t c=0;c<count;c++) { bool bass=false; for(size_t i=0;i<p.count;i++) if(!p.events[i].hand && fabs(p.events[i].beat-c*chord_beats)<1e-9) bass=true; if(!bass) { fprintf(stderr,"no bass key=%d minor=%d ext=%d style=%d meter=%d length=%d fills=%d gen=%d chord=%zu\n",k,minor,ext,style,meter,length,fills,gen,c); for(size_t i=0;i<p.count;i++) if(fabs(p.events[i].beat-c*chord_beats)<1e-9) fprintf(stderr,"  midi %d hand %u dur %.2f\n",p.events[i].midi,p.events[i].hand,p.events[i].duration); return 1; } }
                // All notes diatonic; fills step without repeating a pitch and only appear when requested.
                KvFillRate rate=kv_fill_rate(style,fills); unsigned fill_notes=0; int previous=-1; double previous_beat=-10;
                for(size_t i=0;i<p.count;i++) {
                    KvPianoEvent e=p.events[i]; CHECK(kv_contains(key,e.midi));
                    if(!e.fill && (e.hand || e.midi>=base+12)) previous=-1; // other upper material (merged octaves included) between two fill notes
                    if(e.fill && e.hand) {
                        fill_notes++;
                        if(previous>=0 && e.beat-previous_beat<1.6 && e.midi==previous) { fprintf(stderr,"repeat key=%d minor=%d ext=%d style=%d meter=%d length=%d fills=%d gen=%d at %.3f after %.3f midi %d\n",k,minor,ext,style,meter,length,fills,gen,e.beat,previous_beat,e.midi); return 1; }
                        previous=e.midi; previous_beat=e.beat;
                    }
                }
                if(rate==KV_FILL_NONE) CHECK(fill_notes==0);
                // Same seed, same performance.
                KvPerformance q; CHECK(kv_arrange_with(chords,count,base,key,a,&q)); CHECK(q.count==p.count);
                for(size_t i=0;i<p.count;i++) CHECK(p.events[i].midi==q.events[i].midi && p.events[i].beat==q.events[i].beat);
            }
        }
        CHECK(arrangements>5000 && controlled>1000 && meter_seen[0] && meter_seen[1] && meter_seen[2]);
        // Fills are dense enough to hear when every bar asks for one, and absent from a single auditioned chord.
        KvKey c_major={0,false,0,0}; KvChord four[4]; const int degrees[]={0,5,3,4};
        for(int i=0;i<4;i++) CHECK(kv_chord_extended(c_major,degrees[i],0,&four[i]));
        for(int style=0;style<KV_PATTERN_COUNT;style++) for(int meter=0;meter<KV_METER_COUNT;meter++) {
            KvArrangement a={.style=style,.meter=meter,.length=KV_LENGTH_BAR,.fills=KV_FILL_EVERY_BAR,.generated=true,.seed=7,.seconds_per_beat=.6};
            KvPerformance p; CHECK(kv_arrange_with(four,4,60,c_major,a,&p));
            bool bar_fill[4]={0}; for(size_t i=0;i<p.count;i++) if(p.events[i].fill) bar_fill[(size_t)(p.events[i].beat/p.beats_per_bar)]=true;
            for(int b=0;b<4;b++) CHECK(bar_fill[b]);
            a.preview=true; CHECK(kv_arrange_with(four,1,60,c_major,a,&p));
            CHECK(p.chord_count==1 && p.beats_per_chord==kv_meter_bar(meter)); for(size_t i=0;i<p.count;i++) CHECK(!p.events[i].fill);
            // At 240 BPM fill notes stay audible: at least 90 ms long.
            a.preview=false; a.seconds_per_beat=.25; CHECK(kv_arrange_with(four,4,60,c_major,a,&p));
            for(size_t i=0;i<p.count;i++) if(p.events[i].fill && p.events[i].hand) CHECK(p.events[i].duration*.25>=.09-1e-9);
        }
        // Default fill rates follow the style: ambient none, interlude every bar, others every four bars.
        CHECK(kv_fill_rate(KV_AMBIENT,KV_FILL_STYLE)==KV_FILL_NONE && kv_fill_rate(KV_INTERLUDE,KV_FILL_STYLE)==KV_FILL_EVERY_BAR && kv_fill_rate(KV_BALLAD,KV_FILL_STYLE)==KV_FILL_EVERY_4);
        CHECK(kv_fill_rate(KV_AMBIENT,KV_FILL_EVERY_2)==KV_FILL_EVERY_2);
        // Five bars every two: fills on bars 2 and 5, never on two bars in a row.
        KvChord five[5]; for(int i=0;i<5;i++) CHECK(kv_chord_extended(c_major,(int[]){0,5,3,4,1}[i],0,&five[i]));
        KvArrangement every2={.style=KV_BALLAD,.meter=KV_METER_4_4,.length=KV_LENGTH_BAR,.fills=KV_FILL_EVERY_2,.generated=true,.seed=3,.seconds_per_beat=.6};
        KvPerformance p5; CHECK(kv_arrange_with(five,5,60,c_major,every2,&p5));
        bool filled[5]={0}; for(size_t i=0;i<p5.count;i++) if(p5.events[i].fill) filled[(size_t)(p5.events[i].beat/4)]=true;
        for(int b=1;b<5;b++) CHECK(!(filled[b] && filled[b-1]));
        CHECK(filled[4] && !filled[0]);
        // Seeds change the onset grid of a variation.
        bool grid[12][64]={{0}};
        for(unsigned seed=1;seed<=12;seed++) {
            KvArrangement a={.style=KV_DARK_JAZZ,.meter=KV_METER_4_4,.length=KV_LENGTH_BAR,.fills=KV_FILL_NONE,.generated=true,.seed=seed,.seconds_per_beat=.6};
            KvPerformance p; CHECK(kv_arrange_with(four,4,60,c_major,a,&p));
            for(size_t i=0;i<p.count;i++) if(p.events[i].beat<4) grid[seed-1][(unsigned)lround(p.events[i].beat*8)]=true;
        }
        unsigned distinct=0; for(int i=1;i<12;i++) if(memcmp(grid[0],grid[i],sizeof(grid[0]))) distinct++;
        CHECK(distinct>=3);
        // Block chords: one strike per chord at one beat, strong-beat restrikes when a chord lasts a bar.
        KvArrangement blocks={.style=KV_BALLAD,.meter=KV_METER_4_4,.length=KV_LENGTH_BEAT,.blocks=true,.seconds_per_beat=.6};
        KvPerformance pb; CHECK(kv_arrange_with(four,4,60,c_major,blocks,&pb)); CHECK(pb.count==12 && pb.total_beats==4);
        blocks.length=KV_LENGTH_BAR; CHECK(kv_arrange_with(four,4,60,c_major,blocks,&pb)); CHECK(pb.count==24 && pb.total_beats==16);
        blocks.meter=KV_METER_6_8; CHECK(kv_arrange_with(four,4,60,c_major,blocks,&pb)); CHECK(pb.count==24 && pb.total_beats==12);
        blocks.meter=KV_METER_3_4; CHECK(kv_arrange_with(four,4,60,c_major,blocks,&pb)); CHECK(pb.count==12 && pb.total_beats==12);
        blocks.length=KV_LENGTH_TWO_BARS; CHECK(kv_arrange_with(four,4,60,c_major,blocks,&pb)); CHECK(pb.count==24 && pb.total_beats==24);
        KvArrangement bad_meter={.meter=KV_METER_COUNT}; CHECK(!kv_arrange_with(four,4,60,c_major,bad_meter,&pb));
        // Regression (0.15 review): a lead note doubled by the left-hand octave must not be lost into the bass.
        {
            KvKey cmaj={0,false,0,0},amaj={3,false,0,0}; KvChord a8[8],b8[8]; const int da[8]={2,4,6,3,3,4,2,5},db[8]={0,3,1,4,0,1,4,0};
            for(int i=0;i<8;i++) { CHECK(kv_chord_extended(cmaj,da[i],0,&a8[i])); CHECK(kv_chord_extended(amaj,db[i],0,&b8[i])); for(size_t v=0;v<3;v++) b8[i].midi[v]+=0; }
            KvArrangement r={.style=KV_ALBERTI,.meter=KV_METER_3_4,.length=KV_LENGTH_BEAT,.fills=KV_FILL_STYLE,.generated=true,.seed=382,.seconds_per_beat=.6};
            KvPerformance p; CHECK(kv_arrange_with(a8,8,60,cmaj,r,&p));
            r.seed=2654435761u; CHECK(kv_arrange_with(b8,8,60,amaj,r,&p));
        }
        // Random eight-chord progressions in every key, mode, extension and register always produce an arrangement.
        {
            uint32_t state=0x1234567; unsigned calls=0;
            for(int trial=0;trial<2000;trial++) {
                state^=state<<13; state^=state>>17; state^=state<<5;
                KvKey key={(int)(state%12),(state>>4)&1,(int)((state>>5)%8),0}; int ext=(int)((state>>8)%5),base=36+12*(int)((state>>11)%5);
                size_t count=1+(state>>14)%8; KvChord chords[8];
                for(size_t c=0;c<count;c++) { state^=state<<13; state^=state>>17; state^=state<<5; CHECK(kv_chord_extended(key,(int)(state%7),ext,&chords[c])); for(size_t v=0;v<chords[c].count;v++) chords[c].midi[v]+=base-60; }
                for(int style=0;style<KV_PATTERN_COUNT;style++) for(int meter=0;meter<KV_METER_COUNT;meter++) for(int length=0;length<KV_LENGTH_COUNT;length++) {
                    KvArrangement a={.style=style,.meter=meter,.length=length,.fills=(KvFillRate)((trial+style)%KV_FILL_COUNT),.generated=(trial+length)%2,.seed=state|1,.seconds_per_beat=.25+.95*((trial*7+meter)%10)/9.0};
                    KvPerformance p;
                    if(!kv_arrange_with(chords,count,base,key,a,&p)) { fprintf(stderr,"random trial %d failed style=%d meter=%d length=%d\n",trial,style,meter,length); return 1; }
                    calls++;
                }
            }
            printf("Random progressions: %u arrangements passed.\n",calls);
        }
        // Arpeggio texture: every pattern, division, meter, chord length and extension in every key.
        {
            unsigned arps=0;
            for(int minor=0;minor<2;minor++) for(int k=0;k<12;k++) for(int ext=0;ext<=4;ext+=2) {
                KvKey key={k,minor,0,0}; KvChord ch4[4]; const int degrees[]={0,5,3,4}; int base=36+12*(k%5);
                for(int c=0;c<4;c++) { CHECK(kv_chord_extended(key,degrees[c],ext,&ch4[c])); for(size_t v=0;v<ch4[c].count;v++) ch4[c].midi[v]+=base-60; }
                for(int pattern=0;pattern<KV_ARP_COUNT;pattern++) for(int division=0;division<KV_DIV_COUNT;division++) for(int meter=0;meter<KV_METER_COUNT;meter++) for(int length=0;length<KV_LENGTH_COUNT;length++) for(int gen=0;gen<2;gen++) {
                    if((k+pattern+division)%2 && gen) continue;
                    KvArrangement a={.meter=meter,.length=length,.arpeggio=true,.arpeggio_pattern=pattern,.division=division,.generated=gen,.seed=(uint32_t)(k*17+pattern*3+1),.seconds_per_beat=.6};
                    KvPerformance p;
                    if(!kv_arrange_with(ch4,4,base,key,a,&p)) { fprintf(stderr,"arpeggio failed key=%d minor=%d ext=%d pattern=%d division=%d meter=%d length=%d gen=%d\n",k,minor,ext,pattern,division,meter,length,gen); return 1; }
                    arps++; CHECK(!p.controlled && p.chord_count==4);
                    double step=kv_division_beats(division); unsigned per_chord[4]={0}; int last=-1; unsigned last_chord=99; bool rose=true;
                    for(size_t i=0;i<p.count;i++) {
                        KvPianoEvent e=p.events[i]; bool tone=false;
                        for(size_t v=0;v<ch4[e.chord].count;v++) if(e.midi%12==ch4[e.chord].midi[v]%12) tone=true;
                        CHECK(tone); // only chord tones, both hands
                        if(e.hand) {
                            per_chord[e.chord]++; CHECK(e.midi>=base+12 && e.midi<=base+35);
                            if(pattern==KV_ARP_UP && !gen && e.chord==last_chord && last>=0 && e.midi<last) rose=false; // wraps only after the top
                            last=e.midi; last_chord=e.chord;
                        } else CHECK(e.midi>=base && e.midi<=base+23);
                        if(!e.hand && fabs(e.beat-e.chord*p.beats_per_chord)<1e-9) CHECK(e.velocity>=.69f);
                    }
                    if(pattern==KV_ARP_UP && !gen) {
                        unsigned expected=(unsigned)lround(p.beats_per_chord/step); for(int c=0;c<4;c++) CHECK(per_chord[c]==expected);
                        (void)rose; // an UP template may wrap several times per chord; monotonic inside a cycle is checked below
                    }
                    for(int c=0;c<4;c++) { bool bass=false; for(size_t i=0;i<p.count;i++) if(!p.events[i].hand && fabs(p.events[i].beat-c*p.beats_per_chord)<1e-9) bass=true; CHECK(bass); }
                    KvPerformance q; CHECK(kv_arrange_with(ch4,4,base,key,a,&q)); CHECK(q.count==p.count);
                    for(size_t i=0;i<p.count;i++) CHECK(p.events[i].midi==q.events[i].midi && p.events[i].beat==q.events[i].beat);
                }
            }
            // The UP template climbs through a C major triad in order: C E G C, then again.
            KvArrangement up={.meter=KV_METER_4_4,.length=KV_LENGTH_BAR,.arpeggio=true,.arpeggio_pattern=KV_ARP_UP,.division=KV_DIV_SIXTEENTH,.seconds_per_beat=.6};
            KvPerformance p; CHECK(kv_arrange_with(four,1,60,c_major,up,&p));
            int seen[4]={0},n=0; for(size_t i=0;i<p.count && n<4;i++) if(p.events[i].hand) seen[n++]=p.events[i].midi;
            CHECK(seen[0]==72 && seen[1]==76 && seen[2]==79 && seen[3]==84);
            KvArrangement down=up; down.arpeggio_pattern=KV_ARP_DOWN; CHECK(kv_arrange_with(four,1,60,c_major,down,&p));
            n=0; for(size_t i=0;i<p.count && n<4;i++) if(p.events[i].hand) seen[n++]=p.events[i].midi;
            CHECK(seen[0]==84 && seen[1]==79 && seen[2]==76 && seen[3]==72);
            // Seeded arpeggio variations differ from each other.
            KvPerformance v[24]; unsigned distinct=0;
            for(int s=0;s<24;s++) { KvArrangement a=up; a.generated=true; a.seed=(uint32_t)(500+s*104729); CHECK(kv_arrange_with(four,4,60,c_major,a,&v[s])); }
            for(int i=0;i<24;i++) { bool duplicate=false; for(int j=0;j<i;j++) { if(v[i].count!=v[j].count) continue; bool same=true; for(size_t e=0;e<v[i].count && same;e++) same=v[i].events[e].midi==v[j].events[e].midi && v[i].events[e].beat==v[j].events[e].beat && v[i].events[e].duration==v[j].events[e].duration && v[i].events[e].velocity==v[j].events[e].velocity; if(same) duplicate=true; } if(!duplicate) distinct++; }
            CHECK(distinct>=20);
            KvArrangement bad=up; bad.arpeggio_pattern=KV_ARP_COUNT; CHECK(!kv_arrange_with(four,4,60,c_major,bad,&p));
            printf("Arpeggio texture: %u arrangements across %d patterns, %d divisions, 3 meters passed.\n",arps,KV_ARP_COUNT,KV_DIV_COUNT);
        }
        // Variations must sound different: 24 seeds per style give 24 distinct performances sharing few events.
        for(int style=0;style<KV_PATTERN_COUNT;style++) {
            KvPerformance v[24]; unsigned distinct=0; double similarity=0; unsigned pairs=0;
            for(int s=0;s<24;s++) { KvArrangement a={.style=style,.meter=KV_METER_4_4,.length=KV_LENGTH_BAR,.fills=KV_FILL_STYLE,.generated=true,.seed=(uint32_t)(1000+s*7919),.seconds_per_beat=.6}; CHECK(kv_arrange_with(four,4,60,c_major,a,&v[s])); }
            for(int i=0;i<24;i++) {
                bool duplicate=false;
                for(int j=0;j<i;j++) {
                    unsigned common=0;
                    for(size_t e=0;e<v[i].count;e++) for(size_t f=0;f<v[j].count;f++) if(v[i].events[e].hand==v[j].events[f].hand && v[i].events[e].midi==v[j].events[f].midi && fabs(v[i].events[e].beat-v[j].events[f].beat)<1e-9) { common++; break; }
                    double jaccard=(double)common/(v[i].count+v[j].count-common); similarity+=jaccard; pairs++;
                    if(jaccard>.999) duplicate=true;
                }
                if(!duplicate) distinct++;
            }
            if(distinct<23 || similarity/pairs>.35) { fprintf(stderr,"style %d: %u distinct of 24, similarity %.0f%%\n",style,distinct,100*similarity/pairs); return 1; }
        }
        printf("Arrangement engine: %u arrangements (%u melodic) across 3 meters, 4 chord lengths, 5 fill rates passed.\n",arrangements,controlled);
    }
    /* Bowed strings: the Auto rule, then the four strings textures in every key, meter and chord length. */
    {
        KvPerformance p={0}; p.chord_count=1; p.beats_per_chord=8; p.beats_per_bar=4; p.total_beats=8;
        p.events[0]=(KvPianoEvent){60,0,1,.7f,0,1,0,0};        /* first note: a new bow */
        p.events[1]=(KvPianoEvent){62,1,1,.7f,0,1,0,0};        /* starts as 60 ends: legato */
        p.events[2]=(KvPianoEvent){64,2.5,.5,.7f,0,1,0,0};     /* after a gap, an eighth: still long enough to bow */
        p.events[3]=(KvPianoEvent){65,3,.25,.7f,0,1,0,0};      /* a sixteenth: spiccato */
        p.events[4]=(KvPianoEvent){48,3,2,.7f,0,0,0,0};        /* the other hand starts alone: a new bow */
        p.events[5]=(KvPianoEvent){67,5,1,.7f,0,1,0,KV_STROKE_PIZZICATO+1};   /* its own stroke wins */
        p.count=6; unsigned char st[6];
        kv_string_strokes(&p,KV_ARTICULATION_AUTO,st);
        CHECK(st[0]==KV_STROKE_SUSTAIN && st[1]==KV_STROKE_LEGATO && st[2]==KV_STROKE_SUSTAIN && st[3]==KV_STROKE_SPICCATO && st[4]==KV_STROKE_SUSTAIN && st[5]==KV_STROKE_PIZZICATO);
        kv_string_strokes(&p,KV_ARTICULATION_LEGATO,st); CHECK(st[3]==KV_STROKE_LEGATO && st[1]==KV_STROKE_LEGATO);   /* Legato never shortens */
        kv_string_strokes(&p,KV_ARTICULATION_STACCATO,st); CHECK(st[0]==KV_STROKE_SPICCATO && st[4]==KV_STROKE_SPICCATO && st[5]==KV_STROKE_PIZZICATO);
        kv_string_strokes(&p,KV_ARTICULATION_PIZZICATO,st); CHECK(st[0]==KV_STROKE_PIZZICATO && st[2]==KV_STROKE_PIZZICATO);
        CHECK(sizeof(KvPianoEvent)==40);   /* saved tracks keep reading */
        int checked=0;
        for(int texture=1;texture<KV_STRINGS_COUNT;texture++) {
            KvPerformance variants[6];
            for(int k=0;k<12;k++) for(int minor=0;minor<2;minor++) for(int meter=0;meter<KV_METER_COUNT;meter++) for(int length=KV_LENGTH_TWO_BEATS;length<KV_LENGTH_COUNT;length++)
            for(int ext=0;ext<2;ext++) for(unsigned seed=0;seed<4;seed++) {
                KvKey key={k,minor,0,0}; KvChord chords[4]; const int degrees[]={0,5,3,4};
                for(int c=0;c<4;c++) CHECK(kv_chord_extended(key,degrees[c],ext,&chords[c]));
                KvArrangement a={.style=KV_BALLAD,.meter=(KvMeter)meter,.length=(KvChordLength)length,.fills=KV_FILL_STYLE,.seed=seed+1,.generated=seed>0,.division=seed%2?KV_DIV_SIXTEENTH:KV_DIV_EIGHTH,.seconds_per_beat=.6,.strings=(KvStringTexture)texture};
                KvPerformance out; if(!kv_arrange_with(chords,4,48,key,a,&out)) { fprintf(stderr,"strings texture %d key %d minor %d meter %d length %d ext %d seed %u fails\n",texture,k,minor,meter,length,ext,seed); return 1; }
                unsigned char strokes[KV_PERFORMANCE_CAPACITY]; kv_string_strokes(&out,KV_ARTICULATION_AUTO,strokes);
                int line[KV_PERFORMANCE_CAPACITY],nl=0; for(size_t i=0;i<out.count;i++) if(out.events[i].hand==1) line[nl++]=(int)i;
                for(size_t i=0;i<out.count;i++) { const KvPianoEvent *e=&out.events[i];
                    CHECK(e->hand ? e->midi>=55 && e->midi<=88 : e->midi>=36 && e->midi<=59);   /* cellos below, violins above */
                    bool tone=false; for(size_t v=0;v<chords[e->chord].count;v++) if(chords[e->chord].midi[v]%12==e->midi%12) tone=true;
                    if(!tone) { /* only the cantilena may pass, and only by step on both sides */
                        CHECK(texture==KV_STRINGS_CANTILENA && e->hand==1); int at=0; while(line[at]!=(int)i) at++;
                        CHECK(at>0 && at+1<nl && abs(out.events[line[at-1]].midi-e->midi)<=2 && abs(out.events[line[at+1]].midi-e->midi)<=2); }
                    if(texture==KV_STRINGS_OSTINATO && e->hand==1) CHECK(strokes[i]==KV_STROKE_SPICCATO);
                    if(texture==KV_STRINGS_PIZZICATO) CHECK(strokes[i]==KV_STROKE_PIZZICATO);
                    if(texture==KV_STRINGS_CHORALE || texture==KV_STRINGS_CANTILENA) CHECK(strokes[i]<=KV_STROKE_LEGATO);
                }
                if(texture==KV_STRINGS_CHORALE) for(size_t c=1;c<4;c++) {   /* chorale voices move at most a fourth */
                    int now[4],before[4],nn=0,nb=0;
                    for(size_t i=0;i<out.count;i++) if(out.events[i].hand==1) { if(fabs(out.events[i].beat-c*out.beats_per_chord)<1e-9 && nn<4) now[nn++]=out.events[i].midi; if(fabs(out.events[i].beat-(c-1)*out.beats_per_chord)<1e-9 && nb<4) before[nb++]=out.events[i].midi; }
                    if(nn==nb) for(int v=0;v<nn;v++) if(abs(now[v]-before[v])>5) { fprintf(stderr,"chorale voice %d leaps %d→%d (key %d minor %d ext %d)\n",v,before[v],now[v],k,minor,ext); return 1; }
                }
                if(k==0 && !minor && meter==0 && length==KV_LENGTH_BAR && ext==0) variants[seed]=out;
                checked++;
            }
            int distinct=0; for(int i=0;i<4;i++) { bool same=false; for(int j=0;j<i;j++) if(variants[i].count==variants[j].count && !memcmp(variants[i].events,variants[j].events,sizeof(KvPianoEvent)*variants[i].count)) same=true; if(!same) distinct++; }
            if(distinct<2) { fprintf(stderr,"strings texture %d: the dice changes nothing\n",texture); return 1; }
        }
        CHECK(checked==4*12*2*KV_METER_COUNT*3*2*4);
    }
    puts("Legacy and melodic piano patterns: 24 keys, five registers, independent hands, scale/chord membership, fills, voice leading and invalid inputs passed."); return 0;
}
