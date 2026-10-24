#include "midi.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { uint8_t *data; size_t size,capacity; bool overflow; } Buffer;
static void bytes(Buffer *b,const void *src,size_t n) { if(b->size+n>b->capacity) { b->overflow=true; return; } memcpy(b->data+b->size,src,n); b->size+=n; }
static void byte(Buffer *b,uint8_t v) { bytes(b,&v,1); }
static void be32(Buffer *b,uint32_t v) { uint8_t d[4]={(uint8_t)(v>>24),(uint8_t)(v>>16),(uint8_t)(v>>8),(uint8_t)v}; bytes(b,d,4); }
static void be16(Buffer *b,uint16_t v) { uint8_t d[2]={(uint8_t)(v>>8),(uint8_t)v}; bytes(b,d,2); }
static void vlq(Buffer *b,uint32_t v) {
    uint8_t stack[5]; int n=0; do { stack[n++]=v&0x7f; v>>=7; } while(v);
    while(n--) byte(b,(uint8_t)(stack[n]|(n?0x80:0)));
}
static void meta(Buffer *b,uint32_t delta,uint8_t type,const void *payload,size_t n) { vlq(b,delta); byte(b,0xff); byte(b,type); vlq(b,(uint32_t)n); bytes(b,payload,n); }
typedef struct { uint32_t tick; uint8_t status,data1,data2; } Message;
static int compare(const void *x,const void *y) {
    const Message *a=x,*b=y;
    if(a->tick!=b->tick) return a->tick<b->tick?-1:1;
    if((a->status&0xf0)!=(b->status&0xf0)) return (a->status&0xf0)==0x80?-1:1; // note-offs first at equal ticks
    return a->data1<b->data1?-1:a->data1>b->data1;
}
static void track_begin(Buffer *b,size_t *start) { bytes(b,"MTrk",4); be32(b,0); *start=b->size; }
static void track_end(Buffer *b,size_t start) {
    uint8_t end[]={0x00,0xff,0x2f,0x00}; bytes(b,end,sizeof(end));
    if(b->overflow) return; uint32_t length=(uint32_t)(b->size-start);
    b->data[start-4]=(uint8_t)(length>>24); b->data[start-3]=(uint8_t)(length>>16); b->data[start-2]=(uint8_t)(length>>8); b->data[start-1]=(uint8_t)length;
}
size_t kv_midi_encode(const KvPerformance *p,double bpm,int numerator,int denominator_power,int sharps,bool minor,int program,const char *title,uint8_t *out,size_t capacity) {
    if(!p || !kv_performance_valid(p)) return 0;
    return kv_midi_encode_events(p->events,p->count,p->total_beats,bpm,numerator,denominator_power,sharps,minor,program,title,out,capacity);
}
size_t kv_midi_encode_events(const KvPianoEvent *events,size_t count,double length_beats,double bpm,int numerator,int denominator_power,int sharps,bool minor,int program,const char *title,uint8_t *out,size_t capacity) {
    if(count>KV_PERFORMANCE_CAPACITY) return 0;
    return kv_midi_encode_song(events,count,NULL,0,NULL,0,length_beats,bpm,numerator,denominator_power,sharps,minor,program,title,out,capacity);
}
static void put_track(Buffer *b,const char *label,Message *messages,size_t n,int channel,int program,uint32_t total) {
    qsort(messages,n,sizeof(Message),compare);
    size_t start; track_begin(b,&start); meta(b,0,0x03,label,strlen(label));
    if(program>=0) { vlq(b,0); byte(b,(uint8_t)(0xc0|channel)); byte(b,(uint8_t)program); }
    uint32_t tick=0;
    for(size_t i=0;i<n;i++) { vlq(b,messages[i].tick-tick); tick=messages[i].tick; byte(b,messages[i].status); byte(b,messages[i].data1); byte(b,messages[i].data2); }
    // Hold the track to the end of the last chord so loops in a DAW line up with the bar.
    uint8_t end[]={0xff,0x2f,0x00}; vlq(b,total>tick?total-tick:0); bytes(b,end,3);
    if(b->overflow) return;
    uint32_t length=(uint32_t)(b->size-start);
    b->data[start-4]=(uint8_t)(length>>24); b->data[start-3]=(uint8_t)(length>>16); b->data[start-2]=(uint8_t)(length>>8); b->data[start-1]=(uint8_t)length;
}
size_t kv_midi_encode_song(const KvPianoEvent *events,size_t count,const KvHit *drums,size_t drum_count,const KvMidiMarker *markers,size_t marker_count,double length_beats,double bpm,int numerator,int denominator_power,int sharps,bool minor,int program,const char *title,uint8_t *out,size_t capacity) {
    if((count && !events) || (!count && !drum_count) || (drum_count && !drums) || (marker_count && !markers) || !out || !isfinite(bpm) || bpm<20 || bpm>400 || numerator<1 || numerator>16 || denominator_power<1 || denominator_power>4 || sharps<-7 || sharps>7 || program<0 || program>127 || !isfinite(length_beats) || length_beats<=0) return 0;
    for(size_t i=0;i<count;i++) if(events[i].midi<0 || events[i].midi>127 || !isfinite(events[i].beat) || events[i].beat<0 || !isfinite(events[i].duration) || events[i].duration<=0 || events[i].hand>1) return 0;
    for(size_t i=0;i<drum_count;i++) if(drums[i].drum<0 || drums[i].drum>127 || !isfinite(drums[i].beat) || drums[i].beat<0 || !isfinite(drums[i].velocity)) return 0;
    for(size_t i=0;i<marker_count;i++) if(!markers[i].name || !isfinite(markers[i].beat) || markers[i].beat<0 || (i && markers[i].beat<markers[i-1].beat)) return 0;
    Buffer b={out,0,capacity,false};
    bytes(&b,"MThd",4); be32(&b,6); be16(&b,1); be16(&b,drum_count?4:3); be16(&b,KV_MIDI_PPQ);
    size_t start; track_begin(&b,&start);
    const char *name=title && *title?title:"Tonora";
    meta(&b,0,0x03,name,strlen(name));
    uint32_t micro=(uint32_t)llround(60000000.0/bpm); uint8_t tempo[3]={(uint8_t)(micro>>16),(uint8_t)(micro>>8),(uint8_t)micro}; meta(&b,0,0x51,tempo,3);
    uint8_t timesig[4]={(uint8_t)numerator,(uint8_t)denominator_power,(uint8_t)(denominator_power==3?12:24),8}; meta(&b,0,0x58,timesig,4);
    uint8_t keysig[2]={(uint8_t)(int8_t)sharps,(uint8_t)(minor?1:0)}; meta(&b,0,0x59,keysig,2);
    { uint32_t tick=0; for(size_t i=0;i<marker_count;i++) { uint32_t at=(uint32_t)llround(markers[i].beat*KV_MIDI_PPQ); meta(&b,at-tick,0x06,markers[i].name,strlen(markers[i].name)); tick=at; } }   // section markers
    track_end(&b,start);
    Message *messages=malloc((count>drum_count?count:drum_count)*2*sizeof(Message)); if(!messages) return 0;
    uint32_t total=(uint32_t)llround(length_beats*KV_MIDI_PPQ);
    for(unsigned hand=0;hand<2;hand++) {
        size_t n=0;
        for(size_t i=0;i<count;i++) {
            KvPianoEvent e=events[i]; if(e.hand!=hand) continue;
            uint32_t on=(uint32_t)llround(e.beat*KV_MIDI_PPQ),off=(uint32_t)llround((e.beat+e.duration)*KV_MIDI_PPQ); if(off<=on) off=on+1;
            int velocity=(int)lround(e.velocity*127); if(velocity<1) velocity=1; if(velocity>127) velocity=127;
            messages[n++]=(Message){on,(uint8_t)(0x90|hand),(uint8_t)e.midi,(uint8_t)velocity};
            messages[n++]=(Message){off,(uint8_t)(0x80|hand),(uint8_t)e.midi,64};
        }
        put_track(&b,hand?"Right hand":"Left hand",messages,n,(int)hand,program,total);
    }
    if(drum_count) {   // General MIDI percussion: channel 10, an eighth of a beat per hit
        size_t n=0;
        for(size_t i=0;i<drum_count;i++) {
            uint32_t on=(uint32_t)llround(drums[i].beat*KV_MIDI_PPQ); int velocity=(int)lround(drums[i].velocity*127); velocity=velocity<1?1:velocity>127?127:velocity;
            messages[n++]=(Message){on,0x99,(uint8_t)drums[i].drum,(uint8_t)velocity}; messages[n++]=(Message){on+KV_MIDI_PPQ/8,0x89,(uint8_t)drums[i].drum,64};
        }
        put_track(&b,"Drums",messages,n,9,-1,total);
    }
    free(messages);
    return b.overflow?0:b.size;
}
bool kv_midi_write(const KvPerformance *p,double bpm,int numerator,int denominator_power,int sharps,bool minor,int program,const char *title,const char *path) {
    static uint8_t buffer[1<<17];
    size_t size=kv_midi_encode(p,bpm,numerator,denominator_power,sharps,minor,program,title,buffer,sizeof(buffer));
    if(!size || !path) return false;
    FILE *f=fopen(path,"wb"); if(!f) return false;
    bool ok=fwrite(buffer,1,size,f)==size; return fclose(f)==0 && ok;
}
bool kv_midi_chord_name(const int *midi,size_t count,char name[32],int *root_out) {
    if(!midi || !count || !name) return false;
    unsigned mask=0; for(size_t i=0;i<count;i++) mask|=1u<<(((midi[i]%12)+12)%12);
    static const struct { const char *suffix; unsigned intervals; int size; } templates[]={
        {"maj7",(1u<<0)|(1u<<4)|(1u<<7)|(1u<<11),4},{"7",(1u<<0)|(1u<<4)|(1u<<7)|(1u<<10),4},{"m7",(1u<<0)|(1u<<3)|(1u<<7)|(1u<<10),4},
        {"mMaj7",(1u<<0)|(1u<<3)|(1u<<7)|(1u<<11),4},{"m7b5",(1u<<0)|(1u<<3)|(1u<<6)|(1u<<10),4},{"dim7",(1u<<0)|(1u<<3)|(1u<<6)|(1u<<9),4},
        {"6",(1u<<0)|(1u<<4)|(1u<<7)|(1u<<9),4},{"m6",(1u<<0)|(1u<<3)|(1u<<7)|(1u<<9),4},
        {"",(1u<<0)|(1u<<4)|(1u<<7),3},{"m",(1u<<0)|(1u<<3)|(1u<<7),3},{"dim",(1u<<0)|(1u<<3)|(1u<<6),3},{"aug",(1u<<0)|(1u<<4)|(1u<<8),3},
        {"sus4",(1u<<0)|(1u<<5)|(1u<<7),3},{"sus2",(1u<<0)|(1u<<2)|(1u<<7),3},{"5",(1u<<0)|(1u<<7),2}};
    static const char *names[12]={"C","C♯","D","E♭","E","F","F♯","G","A♭","A","B♭","B"};
    int bass=midi[0]%12; for(size_t i=1;i<count;i++) if(midi[i]<midi[0]) bass=midi[i]%12;
    // Prefer the template that uses every sounding pitch class; among equals prefer the bass note as root.
    for(size_t t=0;t<sizeof(templates)/sizeof(templates[0]);t++) {
        for(int pass=0;pass<2;pass++) for(int root=0;root<12;root++) {
            if(pass==0 && root!=bass) continue; if(pass==1 && root==bass) continue;
            unsigned rotated=0; for(int i=0;i<12;i++) if(templates[t].intervals&(1u<<i)) rotated|=1u<<((root+i)%12);
            if(rotated==mask) { snprintf(name,32,"%s%s%s",names[root],templates[t].suffix,root!=bass?"/":""); if(root!=bass) { size_t used=strlen(name); snprintf(name+used,32-used,"%s",names[bass]); } if(root_out) *root_out=root; return true; }
        }
    }
    return false;
}

/* ---- reading ---- */
static bool read_vlq(const uint8_t **p,const uint8_t *end,uint32_t *value) {
    *value=0; for(int i=0;i<4;i++) { if(*p>=end) return false; uint8_t c=*(*p)++; *value=(*value<<7)|(c&0x7f); if(!(c&0x80)) return true; }
    return false;
}
static uint32_t get32(const uint8_t *p) { return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static uint16_t get16(const uint8_t *p) { return (uint16_t)((p[0]<<8)|p[1]); }
typedef struct { uint32_t on,off; uint8_t key,velocity,channel; } RawNote;
static int compare_raw(const void *x,const void *y) { const RawNote *a=x,*b=y; return a->on!=b->on?(a->on<b->on?-1:1):(a->key<b->key?-1:a->key>b->key); }
bool kv_midi_decode(const uint8_t *data,size_t size,KvMidiSong *out) {
    if(!data || !out) return false;
    memset(out,0,sizeof(*out)); out->bpm=120; out->numerator=4; out->denominator=4;
    if(size<14 || memcmp(data,"MThd",4)) return false;
    uint32_t header=get32(data+4); if(header<6 || header>size-8) return false;
    unsigned format=get16(data+8),tracks=get16(data+10),division=get16(data+12);
    if(format>1 || (division&0x8000) || !division) return false;   // SMPTE time is not supported
    size_t capacity=8192,raw_count=0; RawNote *raw=malloc(capacity*sizeof(RawNote)); if(!raw) return false;
    bool tempo=false,ok=true; const uint8_t *p=data+8+header,*end=data+size;
    for(unsigned t=0;t<tracks && ok;t++) {
        if((size_t)(end-p)<8 || memcmp(p,"MTrk",4)) { ok=false; break; }
        uint32_t length=get32(p+4); if(length>(size_t)(end-p)-8) { ok=false; break; }
        const uint8_t *q=p+8,*qe=q+length; uint32_t tick=0; uint8_t running=0;
        struct { uint32_t on; uint8_t velocity; bool active; } open[16][128]; memset(open,0,sizeof(open));
        while(q<qe) {
            uint32_t delta; if(!read_vlq(&q,qe,&delta) || q>=qe) { ok=false; break; }
            if(delta>0x0fffffff-tick) { ok=false; break; } tick+=delta;
            uint8_t status=*q;
            if(status==0xff) {
                q++; if(q>=qe) { ok=false; break; } uint8_t type=*q++; uint32_t n;
                if(!read_vlq(&q,qe,&n) || n>(uint32_t)(qe-q)) { ok=false; break; }
                if(type==0x51 && n>=3 && !tempo) { uint32_t us=((uint32_t)q[0]<<16)|((uint32_t)q[1]<<8)|q[2]; if(us) { out->bpm=60e6/us; tempo=true; } }
                else if(type==0x58 && n>=2 && !out->has_meter) { out->numerator=q[0]; out->denominator=1<<(q[1]&7); out->has_meter=true; }
                else if(type==0x59 && n>=2 && !out->has_key) { out->sharps=(int8_t)q[0]; out->minor=q[1]!=0; out->has_key=true; }
                q+=n; if(type==0x2f) break; continue;
            }
            if(status==0xf0 || status==0xf7) { q++; uint32_t n; if(!read_vlq(&q,qe,&n) || n>(uint32_t)(qe-q)) { ok=false; break; } q+=n; continue; }
            if(status&0x80) { running=status; q++; } else if(!running) { ok=false; break; }
            uint8_t kind=running&0xf0,channel=running&0x0f; int need=kind==0xc0 || kind==0xd0?1:2;
            if(kind==0xf0 || qe-q<need) { ok=false; break; }
            if(kind==0x90 || kind==0x80) {
                uint8_t key=q[0]&0x7f,velocity=q[1]&0x7f; bool on=kind==0x90 && velocity>0;
                if(open[channel][key].active) { // the key's previous note ends here (also when struck again without a note-off)
                    if(raw_count==capacity) { RawNote *grown=realloc(raw,capacity*2*sizeof(RawNote)); if(!grown) { ok=false; break; } raw=grown; capacity*=2; }
                    raw[raw_count++]=(RawNote){open[channel][key].on,tick,key,open[channel][key].velocity,channel}; open[channel][key].active=false;
                }
                if(on) { open[channel][key].on=tick; open[channel][key].velocity=velocity; open[channel][key].active=true; }
            }
            q+=need;
        }
        for(int c=0;c<16 && ok;c++) for(int k=0;k<128;k++) if(open[c][k].active) { // notes left open end with their track
            if(raw_count==capacity) { RawNote *grown=realloc(raw,capacity*2*sizeof(RawNote)); if(!grown) { ok=false; break; } raw=grown; capacity*=2; }
            raw[raw_count++]=(RawNote){open[c][k].on,tick,(uint8_t)k,open[c][k].velocity,(uint8_t)c};
        }
        p+=8+length;
    }
    if(ok) {
        qsort(raw,raw_count,sizeof(RawNote),compare_raw);
        unsigned channels=0; for(size_t i=0;i<raw_count;i++) if(raw[i].channel!=9) channels|=1u<<raw[i].channel;
        bool own=channels==3u; // exactly channels 1 and 2: Tonora's left and right hand
        for(size_t i=0;i<raw_count;i++) {
            if(raw[i].channel==9) continue;   // General MIDI drums (channel 10) are not notes of the harmony
            if(out->count==KV_PERFORMANCE_CAPACITY) { out->dropped++; continue; }
            KvPianoEvent *e=&out->notes[out->count++];
            e->midi=raw[i].key; e->beat=(double)raw[i].on/division; e->duration=fmax(.05,(double)(raw[i].off-raw[i].on)/division);
            e->velocity=raw[i].velocity/127.0f; e->hand=own?(raw[i].channel==1):(raw[i].key>=60);
            if(e->beat+e->duration>out->length) out->length=e->beat+e->duration;
        }
    }
    free(raw); return ok;
}
