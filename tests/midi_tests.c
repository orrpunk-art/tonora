#include "midi.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define CHECK(x) do { if(!(x)) { fprintf(stderr,"MIDI check failed at %d: %s\n",__LINE__,#x); return 1; } } while(0)
static uint32_t be32(const uint8_t *p){ return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static uint32_t vlq(const uint8_t **p){ uint32_t v=0; for(;;){ uint8_t c=*(*p)++; v=(v<<7)|(c&0x7f); if(!(c&0x80)) return v; } }
/* Walk one track: count note-ons/offs, remember last tick, tempo and signatures. */
typedef struct { unsigned ons,offs,programs; uint32_t last_tick,tempo; int numerator,power,sharps,minor; char name[64]; int min_vel,max_vel; } Track;
static int parse_track(const uint8_t *data,size_t length,Track *t){
    const uint8_t *p=data,*end=data+length; uint32_t tick=0; uint8_t running=0; memset(t,0,sizeof(*t)); t->min_vel=200;
    while(p<end){ tick+=vlq(&p); uint8_t status=*p; if(status==0xff){ p++; uint8_t type=*p++; uint32_t n=vlq(&p);
            if(type==0x51) t->tempo=((uint32_t)p[0]<<16)|((uint32_t)p[1]<<8)|p[2]; else if(type==0x58){ t->numerator=p[0]; t->power=p[1]; } else if(type==0x59){ t->sharps=(int8_t)p[0]; t->minor=p[1]; } else if(type==0x03){ size_t c=n<63?n:63; memcpy(t->name,p,c); t->name[c]=0; }
            else if(type==0x2f){ t->last_tick=tick; return p+n==end; } p+=n; continue; }
        if(status&0x80){ running=status; p++; } uint8_t kind=running&0xf0;
        if(kind==0x90){ int vel=p[1]; if(vel){ t->ons++; if(vel<t->min_vel) t->min_vel=vel; if(vel>t->max_vel) t->max_vel=vel; } else t->offs++; p+=2; }
        else if(kind==0x80){ t->offs++; p+=2; } else if(kind==0xc0){ t->programs++; p+=1; } else return 0; }
    return 0;
}
/* Reading files back: our own export round-trips; damaged and random files never crash and say no. */
static int decode_checks(void){
    KvKey key={0,true,0,0}; KvChord chords[4]; const int degrees[]={0,5,3,4};
    for(int i=0;i<4;i++) CHECK(kv_chord_extended(key,degrees[i],1,&chords[i]));
    KvArrangement a={.style=KV_POP,.meter=KV_METER_3_4,.length=KV_LENGTH_BAR,.fills=KV_FILL_STYLE,.generated=true,.seed=5,.seconds_per_beat=.6};
    KvPerformance p; CHECK(kv_arrange_with(chords,4,48,key,a,&p));
    static uint8_t buffer[1<<17]; size_t size=kv_midi_encode(&p,96,3,2,0,true,0,"Round trip",buffer,sizeof(buffer)); CHECK(size>0);
    static KvMidiSong song; CHECK(kv_midi_decode(buffer,size,&song));
    CHECK(song.count==p.count && !song.dropped && fabs(song.bpm-96)<.01 && song.numerator==3 && song.denominator==4 && song.has_key && song.minor && song.sharps==0);
    for(size_t i=0;i<p.count;i++) { /* same notes; both lists are in time order, ties by pitch */
        bool found=false; for(size_t j=0;j<song.count && !found;j++) if(song.notes[j].midi==p.events[i].midi && fabs(song.notes[j].beat-p.events[i].beat)<.01 && song.notes[j].hand==p.events[i].hand) found=true;
        CHECK(found); }
    for(size_t cut=0;cut<size;cut+=7) { KvMidiSong *partial=malloc(sizeof(KvMidiSong)); kv_midi_decode(buffer,cut,partial); free(partial); } /* no crash on any prefix */
    uint32_t seed=1; for(int round=0;round<3000;round++) { /* random bytes after a valid header */
        uint8_t junk[200]; memcpy(junk,buffer,22); for(int i=22;i<200;i++) { seed=seed*1664525u+1013904223u; junk[i]=(uint8_t)(seed>>24); }
        junk[18]=0; junk[19]=0; junk[20]=0; junk[21]=(uint8_t)(seed%200); KvMidiSong *s=malloc(sizeof(KvMidiSong)); kv_midi_decode(junk,200,s); free(s); }
    CHECK(!kv_midi_decode((const uint8_t *)"MThd",4,&song) && !kv_midi_decode(NULL,0,&song));
    /* Key and chords from what sounds. */
    double cmaj[12]={0}; int scale[8]; kv_scale((KvKey){0,false,0,0},scale); for(int i=0;i<7;i++) cmaj[scale[i]%12]=i==0||i==4?3:1.5;
    KvKey found=kv_detect_key(cmaj,false,0,NULL); CHECK(kv_tonic(found)==0 && !found.minor);
    double amin[12]={0}; kv_scale((KvKey){0,true,0,0},scale); for(int i=0;i<7;i++) amin[scale[i]%12]=i==0||i==4?3:1.5; amin[8]=1; /* a little G♯ */
    found=kv_detect_key(amin,false,0,NULL); CHECK(kv_tonic(found)==9 && found.minor);
    KvKey c={0,false,0,0}; double w[12]={0}; w[0]=2; w[4]=1; w[7]=1; CHECK(kv_detect_chord(c,w,0)==0);
    double a7[12]={0}; a7[9]=2; a7[1]=1; a7[4]=1; a7[7]=.5; CHECK(kv_detect_chord(c,a7,9)==KV_CODE_SECONDARY+1);
    double ce[12]={0}; ce[0]=1; ce[4]=1.5; ce[7]=1; CHECK(kv_detect_chord(c,ce,4)==kv_code_with_inversion(0,1));
    double none[12]={0}; CHECK(kv_detect_chord(c,none,0)==-1);
    return 0;
}
int main(void){
    if(decode_checks()) return 1;
    KvKey key={0,true,0,0}; KvChord chords[4]; const int degrees[]={0,5,3,4};
    for(int i=0;i<4;i++) CHECK(kv_chord_extended(key,degrees[i],1,&chords[i]));
    KvArrangement a={.style=KV_BALLAD,.meter=KV_METER_3_4,.length=KV_LENGTH_BAR,.fills=KV_FILL_STYLE,.generated=true,.seed=9,.seconds_per_beat=.6};
    KvPerformance p; CHECK(kv_arrange_with(chords,4,60,key,a,&p));
    static uint8_t buffer[1<<17]; size_t size=kv_midi_encode(&p,100,3,2,0,true,0,"Tonora test",buffer,sizeof(buffer));
    CHECK(size>100 && memcmp(buffer,"MThd",4)==0 && be32(buffer+4)==6 && buffer[9]==1 && buffer[11]==3 && ((buffer[12]<<8)|buffer[13])==KV_MIDI_PPQ);
    const uint8_t *q=buffer+14; Track tracks[3]; unsigned left=0,right=0; for(size_t i=0;i<p.count;i++) { if(p.events[i].hand) right++; else left++; }
    for(int t=0;t<3;t++){ CHECK(q+8<=buffer+size && memcmp(q,"MTrk",4)==0); uint32_t length=be32(q+4); CHECK(q+8+length<=buffer+size); CHECK(parse_track(q+8,length,&tracks[t])); q+=8+length; }
    CHECK(q==buffer+size);
    CHECK(tracks[0].tempo==600000 && tracks[0].numerator==3 && tracks[0].power==2 && tracks[0].sharps==0 && tracks[0].minor==1 && strcmp(tracks[0].name,"Tonora test")==0);
    CHECK(tracks[1].ons==left && tracks[1].offs==left && tracks[2].ons==right && tracks[2].offs==right && tracks[1].programs==1 && tracks[2].programs==1);
    CHECK(strcmp(tracks[1].name,"Left hand")==0 && strcmp(tracks[2].name,"Right hand")==0);
    CHECK(tracks[1].last_tick==(uint32_t)(p.total_beats*KV_MIDI_PPQ) && tracks[2].last_tick==tracks[1].last_tick);
    CHECK(tracks[2].min_vel>=51 && tracks[2].max_vel<=127);
    // 6/8 is written with an eighth-note denominator; a sharp key signature is negative-free.
    KvArrangement arp={.meter=KV_METER_6_8,.length=KV_LENGTH_BAR,.arpeggio=true,.arpeggio_pattern=KV_ARP_UP,.division=KV_DIV_EIGHTH,.seconds_per_beat=.5};
    CHECK(kv_arrange_with(chords,4,60,key,arp,&p)); size=kv_midi_encode(&p,120,6,3,3,false,2,NULL,buffer,sizeof(buffer)); CHECK(size>0);
    q=buffer+14; { uint32_t length=be32(q+4); Track t; CHECK(parse_track(q+8,length,&t) && t.numerator==6 && t.power==3 && t.sharps==3 && !t.minor && strcmp(t.name,"Tonora")==0); }
    CHECK(kv_midi_encode(&p,100,4,2,0,false,0,"x",buffer,64)==0); // too small
    CHECK(kv_midi_encode(&p,10,4,2,0,false,0,"x",buffer,sizeof(buffer))==0); // absurd tempo
    // A clip from loose notes: two notes, ending on the bar line.
    { KvPianoEvent clip[2]={{60,0,1,.7f,0,1,0},{43,2,2,.6f,0,0,0}}; size=kv_midi_encode_events(clip,2,4,90,4,2,-2,false,0,"Clip",buffer,sizeof(buffer));
      CHECK(size>0 && memcmp(buffer,"MThd",4)==0); q=buffer+14; Track t[3];
      for(int i=0;i<3;i++) { uint32_t length=be32(q+4); CHECK(parse_track(q+8,length,&t[i])); q+=8+length; }
      CHECK(t[0].sharps==-2 && t[1].ons==1 && t[2].ons==1 && t[1].last_tick==4*KV_MIDI_PPQ && t[2].last_tick==4*KV_MIDI_PPQ);
      KvPianoEvent bad={60,-1,1,.7f,0,1,0}; CHECK(kv_midi_encode_events(&bad,1,4,90,4,2,0,false,0,"x",buffer,sizeof(buffer))==0); }
    char name[32]; int root;
    int am[]={57,60,64}; CHECK(kv_midi_chord_name(am,3,name,&root) && strcmp(name,"Am")==0 && root==9);
    int g7[]={55,59,62,65}; CHECK(kv_midi_chord_name(g7,4,name,&root) && strcmp(name,"G7")==0);
    int c_e[]={64,67,72}; CHECK(kv_midi_chord_name(c_e,3,name,&root) && strcmp(name,"C/E")==0 && root==0);
    int sus[]={60,65,67}; CHECK(kv_midi_chord_name(sus,3,name,&root) && strcmp(name,"Csus4")==0);
    int dm7b5[]={62,65,68,72}; CHECK(kv_midi_chord_name(dm7b5,4,name,&root) && strcmp(name,"Dm7b5")==0);
    int cluster[]={60,61,62}; CHECK(!kv_midi_chord_name(cluster,3,name,&root));
    { // A song: more notes than one plan holds, drums on channel 10 in a fourth track, section markers; read back without the drums.
        static KvPianoEvent notes[600]; for(int i=0;i<600;i++) notes[i]=(KvPianoEvent){.midi=48+i%24,.beat=i*.25,.duration=.25,.velocity=.7f,.hand=(unsigned)(i%2)};
        KvHit drums[3]={{0,36,1},{1,38,.8f},{2,42,.5f}}; KvMidiMarker marks[2]={{0,"Verse"},{64,"Chorus"}};
        static uint8_t file[1<<16]; size_t size=kv_midi_encode_song(notes,600,drums,3,marks,2,150,100,4,2,0,false,0,"Song",file,sizeof(file));
        CHECK(size>0 && file[11]==4);   // four tracks
        bool verse=false,chorus=false; for(size_t i=0;i+6<size;i++) { if(!memcmp(file+i,"Verse",5) && file[i-2]==0x06) verse=true; if(!memcmp(file+i,"Chorus",6) && file[i-2]==0x06) chorus=true; }
        CHECK(verse && chorus);
        bool percussion=false; for(size_t i=0;i+2<size;i++) if(file[i]==0x99 && file[i+1]==38) percussion=true; CHECK(percussion);
        static KvMidiSong back; CHECK(kv_midi_decode(file,size,&back) && back.count==KV_PERFORMANCE_CAPACITY && back.dropped==600-KV_PERFORMANCE_CAPACITY);
        for(size_t i=0;i<back.count;i++) CHECK(back.notes[i].midi>=48 && back.notes[i].midi<72);   // no drum among them
        CHECK(!kv_midi_encode_song(notes,600,drums,3,(KvMidiMarker[]){{64,"B"},{0,"A"}},2,150,100,4,2,0,false,0,"Song",file,sizeof(file)));   // markers out of order
        CHECK(!kv_midi_encode_events(notes,600,150,100,4,2,0,false,0,"Song",file,sizeof(file)));   // the plan entry point keeps its limit
    }
    puts("MIDI file: header, three tracks, tempo, signatures, note pairs, hold to the bar line, chord naming, songs with drums and markers passed."); return 0;
}
