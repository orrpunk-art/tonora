#include "song.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"Song check failed at %d: %s\n",__LINE__,#x); return 1; } } while(0)

static KvSong song_in(KvKey key,KvMeter meter) {
    KvSong s; memset(&s,0,sizeof(s)); s.key=key; s.meter=meter; s.bpm=100; s.keyboard_base=60; s.extension=0; kv_song_reset(&s); return s;
}
static KvArrangement hands(KvPianoPattern style,KvChordLength length) {
    return (KvArrangement){.style=style,.length=length,.fills=KV_FILL_STYLE};
}
static size_t hand_notes(const KvPerformance *p,unsigned hand) { size_t n=0; for(size_t i=0;i<p->count;i++) if(p->events[i].hand==hand) n++; return n; }

int main(void) {
    const KvKey c_major={0,false,0,0,false};
    const int pop[4]={0,5,3,4};   /* I vi IV V */
    { // Time and the row.
        KvSong song=song_in(c_major,KV_METER_4_4);
        KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_BALLAD,KV_LENGTH_BAR));
        CHECK(kv_song_insert(&song,0,&verse)==1 && song.count==1 && kv_song_valid(&song));
        CHECK(fabs(kv_section_beats(&song,0)-16)<1e-9 && fabs(kv_song_beats(&song)-16)<1e-9);
        CHECK(kv_song_set_repeats(&song,0,2) && fabs(kv_song_beats(&song)-32)<1e-9);
        CHECK(!kv_song_set_repeats(&song,0,0) && !kv_song_set_repeats(&song,0,KV_SECTION_REPEATS+1));
        KvSection chorus=kv_section_from_draft(KV_SECTION_CHORUS,(const int[]){3,4,5,0},4,hands(KV_POP,KV_LENGTH_BAR));
        CHECK(kv_song_insert(&song,1,&chorus)==2);
        double offset; CHECK(kv_song_section_at(&song,20,&offset)==0 && fabs(offset-20)<1e-9);
        CHECK(kv_song_section_at(&song,32,&offset)==1 && fabs(offset)<1e-9);
        CHECK(kv_song_section_at(&song,48,&offset)==2);
        CHECK(fabs(kv_section_start(&song,1)-32)<1e-9);
        // Duplicate, move, remove keep ids unique and the song valid.
        CHECK(kv_song_duplicate(&song,1)==3 && song.count==3 && song.sections[2].kind==KV_SECTION_CHORUS && kv_song_valid(&song));
        CHECK(kv_song_move(&song,2,0) && song.sections[0].id==3 && song.sections[1].id==1 && kv_song_valid(&song));
        CHECK(kv_song_move(&song,0,2) && song.sections[2].id==3);
        CHECK(kv_song_remove(&song,1) && song.count==2 && song.sections[1].id==3 && kv_song_valid(&song));
        CHECK(!kv_song_remove(&song,5) && !kv_song_move(&song,0,9));
        // A full row refuses another section.
        KvSong full=song_in(c_major,KV_METER_4_4);
        for(int i=0;i<KV_SONG_SECTIONS;i++) CHECK(kv_song_insert(&full,full.count,&verse));
        CHECK(!kv_song_insert(&full,0,&verse) && !kv_song_duplicate(&full,0) && kv_song_valid(&full));
    }
    { // Notes: deterministic, valid, one pass; level and lift.
        KvSong song=song_in(c_major,KV_METER_4_4);
        KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_BALLAD,KV_LENGTH_BAR));
        kv_song_insert(&song,0,&verse);
        KvPerformance a,b; CHECK(kv_section_notes(&song,0,&a) && kv_section_notes(&song,0,&b));
        CHECK(a.count==b.count && !memcmp(a.events,b.events,a.count*sizeof(KvPianoEvent)) && a.chord_count==4 && fabs(a.total_beats-16)<1e-9);
        song.sections[0].lift=12; KvPerformance up; CHECK(kv_section_notes(&song,0,&up) && up.count==a.count);
        for(size_t i=0;i<a.count;i++) CHECK(up.events[i].midi==a.events[i].midi+(a.events[i].hand && a.events[i].midi+12<=108?12:0));
        song.sections[0].lift=-12; KvPerformance down; CHECK(kv_section_notes(&song,0,&down));
        for(size_t i=0;i<a.count;i++) CHECK(down.events[i].midi==a.events[i].midi-(a.events[i].midi-12>=21?12:0));
        song.sections[0].lift=0; song.sections[0].level=.5f;
        KvPerformance quiet; CHECK(kv_section_plan(&song,0,NULL,&quiet) && kv_performance_valid(&quiet));
        for(size_t i=0;i<a.count;i++) CHECK(fabsf(quiet.events[i].velocity-fmaxf(.4f,a.events[i].velocity*.5f))<1e-6f);
        // An edited section plays its track; a track of the wrong length is refused.
        song.sections[0].level=1; song.sections[0].edited=true;
        KvPerformance mine=a; mine.events[0].midi=a.events[0].midi+1; KvPerformance played;
        CHECK(kv_section_plan(&song,0,&mine,&played) && played.events[0].midi==mine.events[0].midi);
        KvPerformance half=a; half.chord_count=2; half.total_beats=8; CHECK(!kv_section_plan(&song,0,&half,&played));
        // Every texture, style, meter and chord length fits one pass of eight chords.
        const int eight[8]={0,5,3,4,0,5,3,4};
        for(int m=0;m<KV_METER_COUNT;m++) for(int l=0;l<KV_LENGTH_COUNT;l++) for(int t=0;t<KV_PATTERN_COUNT+2+KV_STRINGS_COUNT-1;t++) {
            KvSong s=song_in(c_major,(KvMeter)m); KvArrangement arr=hands(t<KV_PATTERN_COUNT?(KvPianoPattern)t:KV_BALLAD,(KvChordLength)l);
            arr.blocks=t==KV_PATTERN_COUNT; arr.arpeggio=t==KV_PATTERN_COUNT+1; arr.strings=t>KV_PATTERN_COUNT+1?(KvStringTexture)(t-KV_PATTERN_COUNT-1):KV_STRINGS_NONE;
            arr.generated=true; arr.seed=77; arr.division=KV_DIV_SIXTEENTH;
            KvSection x=kv_section_from_draft(KV_SECTION_VERSE,eight,8,arr); kv_song_insert(&s,0,&x);
            KvPerformance p; CHECK(kv_section_notes(&s,0,&p) && p.chord_count==8);
        }
    }
    { // Length, trim and cuts anywhere: the pass laid end to end from the section's start and cut at its length.
        KvSong song=song_in(c_major,KV_METER_4_4);
        KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_POP,KV_LENGTH_BAR)); verse.repeats=2; verse.arrangement.generated=true; verse.arrangement.seed=5;
        kv_song_insert(&song,0,&verse);
        KvPerformance pass,p; CHECK(kv_section_notes(&song,0,&pass) && fabs(pass.total_beats-16)<1e-9);
        CHECK(kv_section_part(&song,0,NULL,0,16,&p) && p.count==pass.count && fabs(p.total_beats-16)<1e-9);
        CHECK(kv_section_part(&song,0,NULL,16,16,&p) && p.count==pass.count && p.events[0].midi==pass.events[0].midi);
        CHECK(!kv_section_part(&song,0,NULL,32,4,&p) && !kv_section_part(&song,0,NULL,0,0,&p));
        // Snapping on the song's grid; anywhere without one; never at the edges.
        CHECK(fabs(kv_song_snap_cut(&song,0,12.3,4)-12)<1e-9 && fabs(kv_song_snap_cut(&song,0,13.3,0)-13.3)<1e-9);
        CHECK(kv_song_snap_cut(&song,0,.01,0)<0 && kv_song_snap_cut(&song,0,40,4)<0 && kv_song_snap_cut(&song,0,1,4)<0);
        // A cut in the middle of a chord: the left part ends there, the right one begins there in the pass; nothing lost or doubled.
        KvSong before=song; uint32_t right=kv_song_cut(&song,0,13);
        CHECK(right && song.count==2 && song.sections[1].id==right && kv_song_valid(&song) && fabs(kv_song_beats(&song)-32)<1e-9);
        CHECK(fabs(kv_section_beats(&song,0)-13)<1e-9 && fabs(kv_section_beats(&song,1)-19)<1e-9 && fabs(song.sections[1].start-13)<1e-9 && song.sections[1].count==4);
        KvPerformance l,r1,r2; CHECK(kv_section_part(&song,0,NULL,0,16,&l) && fabs(l.total_beats-13)<1e-9);
        CHECK(kv_section_part(&song,1,NULL,0,16,&r1) && kv_section_part(&song,1,NULL,16,16,&r2) && fabs(r2.total_beats-3)<1e-9);
        CHECK(l.count+r1.count+r2.count==2*pass.count);
        for(size_t i=0;i<l.count;i++) CHECK(l.events[i].beat+l.events[i].duration<=13+1e-9);
        size_t first=0; while(first<pass.count && pass.events[first].beat<13-1e-9) first++;
        CHECK(r1.events[0].midi==pass.events[first].midi && fabs(r1.events[0].beat-(pass.events[first].beat-13))<1e-9);
        CHECK(!kv_song_cut(&song,0,13) && !kv_song_cut(&song,0,.05));
        // A cut on a whole pass reads back as repeats; length and repeats agree.
        song=before; CHECK(kv_song_cut(&song,0,16) && song.sections[0].length==0 && song.sections[0].repeats==1 && song.sections[1].start==0 && song.sections[1].repeats==1);
        song=before; CHECK(kv_song_set_length(&song,0,24) && song.sections[0].length==24 && fabs(kv_song_beats(&song)-24)<1e-9);
        CHECK(kv_song_set_length(&song,0,48) && song.sections[0].length==0 && song.sections[0].repeats==3);
        CHECK(kv_song_set_repeats(&song,0,2) && song.sections[0].length==0 && fabs(kv_song_beats(&song)-32)<1e-9 && !kv_song_set_length(&song,0,0));
        // Trimming the start keeps the end where it was; trimming back past the pass's start wraps round it.
        CHECK(kv_song_trim_start(&song,0,4) && fabs(song.sections[0].start-4)<1e-9 && fabs(kv_section_beats(&song,0)-28)<1e-9);
        CHECK(kv_section_part(&song,0,NULL,0,16,&p)); first=0; while(first<pass.count && pass.events[first].beat<4-1e-9) first++;
        CHECK(p.events[0].midi==pass.events[first].midi && fabs(p.events[0].beat-(pass.events[first].beat-4))<1e-9);
        CHECK(kv_song_trim_start(&song,0,-8) && fabs(song.sections[0].start-12)<1e-9 && fabs(kv_section_beats(&song,0)-36)<1e-9 && kv_song_valid(&song));
        // An edited pass plays in every window; an edited section cut keeps its pass on both sides (the app copies the track).
        song=before; song.sections[0].edited=true; KvPerformance mine=pass; mine.events[0].midi=pass.events[0].midi+1;
        CHECK(kv_section_part(&song,0,&mine,16,16,&p) && p.events[0].midi==mine.events[0].midi);
        CHECK(kv_song_cut(&song,0,8) && song.sections[0].edited && song.sections[1].edited);
    }
    { // Regions and tracks: mute, solo, level, shift.
        KvSong song=song_in(c_major,KV_METER_4_4);
        KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_ALBERTI,KV_LENGTH_BAR)); kv_song_insert(&song,0,&verse);
        KvPerformance all,p; CHECK(kv_section_part(&song,0,NULL,0,16,&all) && hand_notes(&all,0) && hand_notes(&all,1));
        CHECK(kv_region_audible(&song,0,KV_TRACK_DRUMS));
        song.sections[0].regions[KV_TRACK_BASS].mute=true; CHECK(kv_section_part(&song,0,NULL,0,16,&p) && !hand_notes(&p,0) && hand_notes(&p,1)==hand_notes(&all,1));
        song.sections[0].regions[KV_TRACK_MELODY].mute=true; CHECK(kv_section_part(&song,0,NULL,0,16,&p) && p.count==0 && fabs(p.total_beats-16)<1e-9);   // an empty part still lasts
        song.sections[0].regions[KV_TRACK_BASS].mute=song.sections[0].regions[KV_TRACK_MELODY].mute=false;
        song.track_solo[KV_TRACK_BASS]=true; CHECK(kv_section_part(&song,0,NULL,0,16,&p) && !hand_notes(&p,1) && hand_notes(&p,0)==hand_notes(&all,0) && !kv_region_audible(&song,0,KV_TRACK_DRUMS));
        song.track_solo[KV_TRACK_BASS]=false; song.track_mute[KV_TRACK_DRUMS]=true; CHECK(!kv_region_audible(&song,0,KV_TRACK_DRUMS)); song.track_mute[KV_TRACK_DRUMS]=false;
        song.sections[0].regions[KV_TRACK_MELODY].level=.5f; CHECK(kv_section_part(&song,0,NULL,0,16,&p));
        for(size_t i=0,k=0;i<all.count;i++) if(all.events[i].hand) { while(!p.events[k].hand) k++; CHECK(fabsf(p.events[k].velocity-fmaxf(.4f,all.events[i].velocity*.5f))<1e-6f); k++; }
        song.sections[0].regions[KV_TRACK_MELODY].level=1;
        // The bass moved two beats later: its notes follow, those pushed past the end are gone, nothing comes in from outside.
        song.sections[0].regions[KV_TRACK_BASS].shift=2; CHECK(kv_section_part(&song,0,NULL,0,16,&p));
        size_t kept=0; for(size_t i=0;i<all.count;i++) if(!all.events[i].hand && all.events[i].beat<14-1e-9) kept++;
        CHECK(hand_notes(&p,0)==kept && hand_notes(&p,1)==hand_notes(&all,1));
        double firstBass=-1; for(size_t i=0;i<p.count && firstBass<0;i++) if(!p.events[i].hand) firstBass=p.events[i].beat;
        CHECK(firstBass>=2-1e-9);
        for(size_t i=0;i<p.count;i++) CHECK(p.events[i].beat+p.events[i].duration<=16+1e-9 && (i==0 || p.events[i].beat>=p.events[i-1].beat));
        song.sections[0].regions[KV_TRACK_BASS].shift=-1; CHECK(kv_section_part(&song,0,NULL,0,16,&p));
        kept=0; for(size_t i=0;i<all.count;i++) if(!all.events[i].hand && all.events[i].beat>=1-1e-9) kept++; CHECK(hand_notes(&p,0)==kept);
        // In a section shorter than its pass, a region moved earlier does not pull in notes from past the section's end.
        CHECK(kv_song_set_length(&song,0,12)); song.sections[0].regions[KV_TRACK_BASS].shift=-2; CHECK(kv_section_part(&song,0,NULL,0,12,&p));
        kept=0; for(size_t i=0;i<all.count;i++) if(!all.events[i].hand && all.events[i].beat>=2-1e-9 && all.events[i].beat<12-1e-9) kept++; CHECK(kept && hand_notes(&p,0)==kept);
        CHECK(kv_song_set_repeats(&song,0,1));
        song.sections[0].regions[KV_TRACK_BASS].shift=40; CHECK(!kv_song_valid(&song)); song.sections[0].regions[KV_TRACK_BASS].shift=0;
        // A stretch with more notes than a plan holds is refused (the app asks for a shorter one).
        KvSong dense=song_in(c_major,KV_METER_4_4); KvArrangement arp=hands(KV_BALLAD,KV_LENGTH_TWO_BARS); arp.arpeggio=true; arp.division=KV_DIV_SIXTEENTH;
        KvSection busy=kv_section_from_draft(KV_SECTION_VERSE,(const int[]){0,5,3,4,0,5,3,4},8,arp); busy.repeats=8; kv_song_insert(&dense,0,&busy);
        CHECK(kv_section_part(&dense,0,NULL,0,64,&p) && !kv_section_part(&dense,0,NULL,0,512,&p));
    }
    { // Transposing an edited track keeps it valid and on the keyboard.
        KvSong song=song_in(c_major,KV_METER_4_4); KvSection v=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_ALBERTI,KV_LENGTH_BAR));
        kv_song_insert(&song,0,&v); KvPerformance t; CHECK(kv_section_notes(&song,0,&t));
        KvPerformance up=t; kv_track_transpose(&up,7); CHECK(kv_performance_valid(&up));
        for(size_t i=0;i<up.count;i++) CHECK(up.events[i].midi>=21 && up.events[i].midi<=108);
        KvPerformance high=t; kv_track_transpose(&high,60); CHECK(kv_performance_valid(&high));
    }
    { // Chorus: another turn than the verse's, opening on I, IV or vi (i or VI), closing on the tonic, in every key; louder and up.
        const int verses[3][4]={{0,5,3,4},{0,4,5,3},{5,3,0,4}};
        for(int index=0;index<12;index++) for(int minor=0;minor<2;minor++) for(int v=0;v<3;v++) for(uint32_t seed=0;seed<4;seed++) {
            KvKey key={index,minor!=0,0,0,false}; KvSong song=song_in(key,KV_METER_4_4);
            KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,verses[v],4,hands(KV_AMBIENT,KV_LENGTH_BAR)); kv_song_insert(&song,0,&verse);
            KvSection chorus=kv_section_chorus(&song,&song.sections[0],seed);
            bool same=true; for(int k=0;k<4;k++) if(kv_code_base(chorus.codes[k])!=verses[v][k]) same=false;
            int first=kv_code_base(chorus.codes[0]);
            CHECK(!same && chorus.count==8 && kv_code_base(chorus.codes[7])==0 && chorus.kind==KV_SECTION_CHORUS);
            CHECK(minor?(first==0 || first==5):(first==0 || first==3 || first==5));
            CHECK(first!=kv_code_base(verses[v][3]));
            CHECK(chorus.level>1.1f && chorus.lift==12 && chorus.arrangement.style==KV_BALLAD && chorus.beat==KV_SECTION_BEAT_STYLE);
            CHECK(kv_song_insert(&song,1,&chorus)); KvPerformance p; CHECK(kv_section_notes(&song,1,&p));
        }
        // Seeds pick different turns.
        KvSong song=song_in(c_major,KV_METER_4_4); KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_POP,KV_LENGTH_BAR)); kv_song_insert(&song,0,&verse);
        KvSection a=kv_section_chorus(&song,&song.sections[0],0),b=kv_section_chorus(&song,&song.sections[0],1);
        CHECK(memcmp(a.codes,b.codes,sizeof(a.codes))!=0);
    }
    { // Breakdown, intro, outro.
        KvSong song=song_in(c_major,KV_METER_4_4); KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_POP,KV_LENGTH_BAR)); kv_song_insert(&song,0,&verse);
        KvSection pit=kv_section_pit(&song,&song.sections[0]);
        CHECK(pit.count==2 && kv_code_base(pit.codes[0])!=0 && pit.arrangement.length==KV_LENGTH_TWO_BARS && pit.level<.8f && pit.beat==KV_SECTION_BEAT_OFF && pit.arrangement.style==KV_AMBIENT);
        song.bpm=120; pit=kv_section_pit(&song,&song.sections[0]); CHECK(pit.arrangement.arpeggio && pit.beat==KV_SECTION_BEAT_QUIET);
        KvSection intro=kv_section_intro(&song,&song.sections[0]),outro=kv_section_outro(&song,&song.sections[0]);
        CHECK(intro.kind==KV_SECTION_INTRO && intro.beat==KV_SECTION_BEAT_OFF && kv_code_base(intro.codes[1])!=0);
        CHECK(outro.count==3 && kv_code_base(outro.codes[2])==0 && outro.codes[1]==KV_CODE_SECONDARY && outro.arrangement.blocks);
        for(KvSection *x=&pit;x;x=x==&pit?&intro:x==&intro?&outro:NULL) { KvSong t=song; CHECK(kv_song_insert(&t,1,x)); KvPerformance p; CHECK(kv_section_notes(&t,1,&p)); }
    }
    { // Transitions: one bar in every meter; the break strikes, rests and picks up; the rise grows; neighbours give the chord.
        for(int m=0;m<KV_METER_COUNT;m++) for(int k=0;k<KV_TRANSITION_KINDS;k++) {
            KvSong song=song_in(c_major,(KvMeter)m);
            KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_POP,KV_LENGTH_BAR)),chorus=kv_section_from_draft(KV_SECTION_CHORUS,(const int[]){3,4,5,0},4,hands(KV_POP,KV_LENGTH_BAR));
            kv_song_insert(&song,0,&verse); kv_song_insert(&song,1,&chorus);
            KvSection t=kv_section_transition(&song,&song.sections[0],&song.sections[1],(KvTransitionKind)k); CHECK(kv_song_insert(&song,1,&t));
            KvPerformance p; CHECK(kv_section_notes(&song,1,&p)); double bar=kv_meter_bar((KvMeter)m);
            CHECK(fabs(p.total_beats-bar)<1e-9 && fabs(kv_section_beats(&song,1)-bar)<1e-9);
            if(k==KV_TRANSITION_RISE || k==KV_TRANSITION_DOMINANT) CHECK(song.sections[1].codes[0]==KV_CODE_SECONDARY+3);   // V7/IV leads to F
            if(k==KV_TRANSITION_BREAK) { CHECK(p.events[0].beat==0 && fabs(p.events[p.count-1].beat-(bar-.25))<1e-9);
                for(size_t i=0;i<p.count;i++) CHECK(p.events[i].beat==0 || p.events[i].beat>=bar-.5-1e-9); }
            if(k==KV_TRANSITION_RISE) CHECK(p.events[0].velocity<p.events[p.count-1].velocity);
            KvHit hits[KV_BEAT_HITS]; size_t n=kv_transition_hits((KvTransitionKind)k,(KvMeter)m,hits);
            if(k==KV_TRANSITION_RISE) { CHECK(n==1+(size_t)llround(bar/.25) && hits[n-1].velocity>hits[1].velocity); for(size_t i=1;i<n;i++) CHECK(hits[i].beat>=hits[i-1].beat); }
            else if(k==KV_TRANSITION_BREAK) CHECK(n==1 && hits[0].drum==KV_DRUM_KICK); else CHECK(n==0);
        }
        // Moving the neighbours retunes the transition: at the end it leads to the tonic.
        KvSong song=song_in(c_major,KV_METER_4_4);
        KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_POP,KV_LENGTH_BAR)),chorus=kv_section_from_draft(KV_SECTION_CHORUS,(const int[]){3,4,5,0},4,hands(KV_POP,KV_LENGTH_BAR));
        kv_song_insert(&song,0,&verse); kv_song_insert(&song,1,&chorus);
        KvSection rise=kv_section_transition(&song,&song.sections[0],&song.sections[1],KV_TRANSITION_RISE); kv_song_insert(&song,1,&rise);
        CHECK(song.sections[1].codes[0]==KV_CODE_SECONDARY+3);
        CHECK(kv_song_move(&song,2,0) && song.sections[2].kind==KV_SECTION_TRANSITION && song.sections[2].codes[0]==KV_CODE_SECONDARY);
        CHECK(kv_transition_for(&verse,&chorus)==KV_TRANSITION_RISE && kv_transition_for(&chorus,&verse)==KV_TRANSITION_DOMINANT);
    }
    { // Suggestions: after a lone verse a chorus led in by a rise comes first, an outro and an intro are offered too.
        KvSong song=song_in(c_major,KV_METER_4_4); KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_POP,KV_LENGTH_BAR)); kv_song_insert(&song,0,&verse);
        KvSuggestion g[4]; size_t n=kv_song_suggest(&song,0,7,g);
        CHECK(n==4 && g[0].section.kind==KV_SECTION_CHORUS && g[0].lead_in && g[0].transition.transition==KV_TRANSITION_RISE && !g[0].copy_of);
        CHECK(g[1].section.kind==KV_SECTION_PIT && g[2].section.kind==KV_SECTION_VERSE && g[2].copy_of==song.sections[0].id);
        CHECK(g[3].section.kind==KV_SECTION_OUTRO || (g[3].section.kind==KV_SECTION_INTRO && g[3].before));
        for(size_t i=0;i<n;i++) { KvSong t=song; size_t at=g[i].before?0:1; if(g[i].lead_in) CHECK(kv_song_insert(&t,at++,&g[i].transition)); CHECK(kv_song_insert(&t,at,&g[i].section) && kv_song_valid(&t)); }
        // With a chorus in the song, «+ chorus» repeats it.
        KvSection chorus=g[0].section; kv_song_insert(&song,1,&chorus); n=kv_song_suggest(&song,0,7,g);
        CHECK(g[0].section.kind==KV_SECTION_CHORUS && g[0].copy_of==song.sections[1].id);
        n=kv_song_suggest(&song,1,7,g); CHECK(n>=3 && g[0].section.kind==KV_SECTION_PIT && g[1].section.kind==KV_SECTION_VERSE && g[1].lead_in && g[1].transition.transition==KV_TRANSITION_BREAK);
        CHECK(n==4 && g[2].section.kind==KV_SECTION_BRIDGE && g[3].section.kind==KV_SECTION_OUTRO);   // the first chorus, last: the bridge third, the outro last
        // After the second chorus the bridge comes first; after the bridge, the chorus led in by a rise; with a bridge in the song, no other.
        KvSection again=song.sections[1]; kv_song_insert(&song,2,&verse); kv_song_insert(&song,3,&again); n=kv_song_suggest(&song,3,7,g);
        CHECK(n>=3 && g[0].section.kind==KV_SECTION_BRIDGE && !g[0].lead_in && g[0].section.count==4);
        KvSection bridge=g[0].section; kv_song_insert(&song,4,&bridge); n=kv_song_suggest(&song,4,7,g);
        CHECK(n>=2 && g[0].section.kind==KV_SECTION_CHORUS && g[0].lead_in && g[0].transition.transition==KV_TRANSITION_RISE && g[0].copy_of==song.sections[1].id);
        n=kv_song_suggest(&song,3,7,g); for(size_t i=0;i<n;i++) CHECK(g[i].section.kind!=KV_SECTION_BRIDGE);
    }
    { // Bridge: four bars away from the tonic, back to the dominant, in every key and chord length.
        for(int index=0;index<12;index++) for(int minor=0;minor<2;minor++) for(int l=0;l<KV_LENGTH_COUNT;l++) {
            KvKey key={index,minor!=0,0,0,false}; KvSong song=song_in(key,KV_METER_4_4);
            KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_POP,(KvChordLength)l)); kv_song_insert(&song,0,&verse);
            KvSection bridge=kv_section_bridge(&song,&song.sections[0],(uint32_t)index);
            int first=kv_code_base(bridge.codes[0]),last=bridge.codes[3];
            CHECK(bridge.kind==KV_SECTION_BRIDGE && bridge.count==4 && (first==3 || first==5) && (last==4 || last==KV_CODE_SECONDARY) && bridge.lift==12);
            CHECK(kv_song_insert(&song,1,&bridge) && fabs(kv_section_beats(&song,1)-16)<1e-9);
            KvPerformance p; CHECK(kv_section_part(&song,1,NULL,0,16,&p) && p.count>0);
        }
    }
    { // Forms: a song in a form from one verse; transitions where the neighbours call for them; hand-edited sections kept.
        const KvForm *forms; size_t n=kv_song_forms(&forms); CHECK(n==5);
        for(size_t f=0;f<n;f++) {
            KvSong song=song_in(c_major,KV_METER_4_4); KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_POP,KV_LENGTH_BAR));
            kv_song_insert(&song,0,&verse); uint32_t copy_of[KV_SONG_SECTIONS]; uint32_t origin=song.sections[0].id;
            CHECK(kv_song_apply_form(&song,forms[f].slots,forms[f].count,0,3,copy_of) && kv_song_valid(&song) && *kv_form_name(f));
            size_t k=0;
            for(size_t i=0;i<song.count;i++) {
                const KvSection *x=&song.sections[i];
                if(x->kind==KV_SECTION_TRANSITION && !x->name[0]) { CHECK(i>0 && i+1<song.count && x->transition!=KV_TRANSITION_FILL); continue; }   // inserted between neighbours
                int slot=forms[f].slots[k++];
                if(slot==KV_FORM_BUILD) CHECK(x->kind==KV_SECTION_TRANSITION && x->repeats==2 && !strcmp(x->name,"Билд"));
                else if(slot==KV_FORM_DROP) CHECK(x->kind==KV_SECTION_CHORUS && x->beat==KV_SECTION_BEAT_FIXED && x->beat_fixed==KV_BEAT_HOUSE && !strcmp(x->name,"Дроп"));
                else CHECK(x->kind==(KvSectionKind)slot);
                if(x->kind==KV_SECTION_VERSE) CHECK(copy_of[i]==origin && x->codes[0]==0 && x->count==4);
            }
            CHECK(k==forms[f].count);
        }
        // Verse into chorus goes through a rise; an existing chorus is reused; an edited verse stays itself, its copies carry its notes.
        KvSong song=song_in(c_major,KV_METER_4_4); KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_POP,KV_LENGTH_BAR));
        KvSection chorus=kv_section_from_draft(KV_SECTION_CHORUS,(const int[]){3,4,0,0},4,hands(KV_POP,KV_LENGTH_BAR));
        KvSection pit=kv_section_from_draft(KV_SECTION_PIT,(const int[]){5,3},2,hands(KV_AMBIENT,KV_LENGTH_TWO_BARS));
        kv_song_insert(&song,0,&verse); kv_song_insert(&song,1,&chorus); kv_song_insert(&song,2,&pit);
        song.sections[0].edited=true; song.sections[2].edited=true; uint32_t v=song.sections[0].id,c=song.sections[1].id,b=song.sections[2].id;
        const int shortForm[4]={KV_SECTION_VERSE,KV_SECTION_CHORUS,KV_SECTION_VERSE,KV_SECTION_CHORUS}; uint32_t copy_of[KV_SONG_SECTIONS];
        CHECK(kv_song_apply_form(&song,shortForm,4,0,1,copy_of) && kv_song_valid(&song));
        CHECK(song.sections[0].id==v && copy_of[0]==0 && song.sections[1].kind==KV_SECTION_TRANSITION && song.sections[1].transition==KV_TRANSITION_RISE);
        CHECK(song.sections[2].kind==KV_SECTION_CHORUS && song.sections[2].codes[0]==3 && copy_of[2]==c && song.sections[2].id!=c);
        size_t secondVerse=3; while(secondVerse<song.count && song.sections[secondVerse].kind!=KV_SECTION_VERSE) secondVerse++;
        CHECK(secondVerse<song.count && copy_of[secondVerse]==v && song.sections[secondVerse].edited);
        CHECK(song.sections[song.count-1].id==b && song.sections[song.count-1].kind==KV_SECTION_PIT);   // the edited breakdown has no slot: kept at the end
        const int bad[2]={KV_SECTION_VERSE,99}; CHECK(!kv_song_apply_form(&song,bad,2,0,1,copy_of));
        CHECK(!*kv_form_label(KV_SECTION_VERSE) && !strcmp(kv_form_label(KV_FORM_BUILD),"Билд") && !strcmp(kv_section_kind_name(KV_SECTION_BRIDGE),"Бридж"));
    }
    puts("Song: time, row edits, notes in every texture, level and lift, length, trim and cuts anywhere, parts, regions and tracks, chorus, breakdown, bridge, intro, outro, transitions, suggestions and forms passed.");
    return 0;
}
