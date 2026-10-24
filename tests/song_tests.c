#include "song.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"Song check failed at %d: %s\n",__LINE__,#x); return 1; } } while(0)

static KvSong song_in(KvKey key,KvMeter meter) {
    KvSong s; memset(&s,0,sizeof(s)); s.key=key; s.meter=meter; s.bpm=100; s.keyboard_base=60; s.extension=0; return s;
}
static KvArrangement hands(KvPianoPattern style,KvChordLength length) {
    return (KvArrangement){.style=style,.length=length,.fills=KV_FILL_STYLE};
}
static int total_notes(const KvPerformance *a,const KvPerformance *b) { return (int)(a->count+b->count); }

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
        KvPerformance half,rest; CHECK(kv_track_split(&a,2,&half,&rest)); CHECK(!kv_section_plan(&song,0,&half,&played));
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
    { // Cuts: inside an unrollable section on bar lines, between passes otherwise; tracks split by time.
        KvSong song=song_in(c_major,KV_METER_4_4);
        KvSection verse=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_BALLAD,KV_LENGTH_BAR)); verse.repeats=2;
        kv_song_insert(&song,0,&verse);
        CHECK(fabs(kv_song_snap_cut(&song,0,12.3)-12)<1e-9 && kv_song_snap_cut(&song,0,0.2)==4);
        CHECK(!kv_song_cut(&song,0,13,NULL,NULL,NULL));
        CHECK(kv_song_cut(&song,0,12,NULL,NULL,NULL) && song.count==2 && kv_song_valid(&song));
        CHECK(song.sections[0].count==3 && song.sections[0].repeats==1 && song.sections[1].count==5 && song.sections[1].codes[0]==4 && song.sections[1].codes[1]==0);
        CHECK(fabs(kv_song_beats(&song)-32)<1e-9 && song.sections[1].id!=song.sections[0].id);
        // Four passes of four chords cannot be unrolled: cuts fall between passes.
        KvSong many=song_in(c_major,KV_METER_4_4); verse.repeats=4; kv_song_insert(&many,0,&verse);
        CHECK(fabs(kv_song_snap_cut(&many,0,21)-16)<1e-9);
        CHECK(kv_song_cut(&many,0,16,NULL,NULL,NULL) && many.sections[0].repeats==1 && many.sections[1].repeats==3 && many.sections[1].count==4);
        // 3/4 with two-beat chords: the first bar line that is also a chord change is after three chords.
        KvSong waltz=song_in(c_major,KV_METER_3_4); KvSection w=kv_section_from_draft(KV_SECTION_VERSE,(const int[]){0,5,3,4,0,5},6,hands(KV_WALTZ,KV_LENGTH_TWO_BEATS));
        kv_song_insert(&waltz,0,&w); CHECK(fabs(kv_song_snap_cut(&waltz,0,2)-6)<1e-9);
        // An edited track is split at the cut: nothing lost, notes across the cut end there, both halves valid.
        KvSong edited=song_in(c_major,KV_METER_4_4); KvSection e=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_POP,KV_LENGTH_BAR));
        e.arrangement.generated=true; e.arrangement.seed=5; kv_song_insert(&edited,0,&e); edited.sections[0].edited=true;
        KvPerformance track; CHECK(kv_section_notes(&edited,0,&track));
        KvPerformance l,r; CHECK(kv_song_cut(&edited,0,8,&track,&l,&r));
        CHECK(total_notes(&l,&r)==(int)track.count && kv_performance_valid(&l) && kv_performance_valid(&r) && l.chord_count==2 && r.chord_count==2);
        for(size_t i=0;i<l.count;i++) CHECK(l.events[i].beat+l.events[i].duration<=8+1e-9);
        CHECK(edited.sections[0].edited && edited.sections[1].edited);
        // A note held across the cut ends at it.
        KvPerformance held=track; held.events[0]=(KvPianoEvent){.midi=60,.beat=7,.duration=3,.velocity=.8f,.chord=1,.hand=1}; held.count=1;
        CHECK(kv_track_split(&held,2,&l,&r) && l.count==1 && r.count==0 && fabs(l.events[0].duration-1)<1e-9);
        // Repeated edited track unrolls with it.
        KvPerformance twice; CHECK(kv_track_repeat(&track,2,&twice) && twice.count==2*track.count && twice.chord_count==8 && kv_performance_valid(&twice));
        CHECK(!kv_track_repeat(&track,3,&twice));
    }
    { // Transposing an edited track keeps it valid and on the keyboard.
        KvSong song=song_in(c_major,KV_METER_4_4); KvSection v=kv_section_from_draft(KV_SECTION_VERSE,pop,4,hands(KV_ALBERTI,KV_LENGTH_BAR));
        kv_song_insert(&song,0,&v); KvPerformance t; CHECK(kv_section_notes(&song,0,&t));
        KvPerformance up=t; kv_track_transpose(&up,7); CHECK(kv_performance_valid(&up));
        for(size_t i=0;i<up.count;i++) CHECK(up.events[i].midi>=21 && up.events[i].midi<=108);
        KvPerformance high=t; kv_track_transpose(&high,60); CHECK(kv_performance_valid(&high));
    }
    puts("Song: time, row edits, notes in every texture, level and lift, cuts and tracks passed.");
    return 0;
}
