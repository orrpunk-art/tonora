#include "music.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *major_labels[12] = {"C","G","D","A","E","B","F♯","D♭","A♭","E♭","B♭","F"};
static const char *minor_labels[12] = {"Am","Em","Bm","F♯m","C♯m","G♯m","D♯m","B♭m","Fm","Cm","Gm","Dm"};
static const char *major_ru[12] = {"До мажор","Соль мажор","Ре мажор","Ля мажор","Ми мажор","Си мажор","Фа-диез мажор","Ре-бемоль мажор","Ля-бемоль мажор","Ми-бемоль мажор","Си-бемоль мажор","Фа мажор"};
static const char *minor_ru[12] = {"Ля минор","Ми минор","Си минор","Фа-диез минор","До-диез минор","Соль-диез минор","Ре-диез минор","Си-бемоль минор","Фа минор","До минор","Соль минор","Ре минор"};
static const int major_steps[7] = {0,2,4,5,7,9,11};
static const int minor_steps[7] = {0,2,3,5,7,8,10};
int kv_mod(int n, int divisor) { return (n % divisor + divisor) % divisor; }
int kv_tonic(KvKey key) { return kv_mod(kv_mod(key.circle_index,12)*7 + (key.minor ? 9 : 0),12); }
static const int modal_steps[7][7]={
    {0,2,3,5,7,9,10},{0,1,3,5,7,8,10},{0,2,4,6,7,9,11},
    {0,2,4,5,7,9,10},{0,1,3,5,6,8,10},{0,2,3,5,7,8,11},{0,2,3,5,7,9,11}
};
static const int *scale_steps(KvKey key) { return key.mode>=1 && key.mode<=7?modal_steps[key.mode-1]:key.minor?minor_steps:major_steps; }
const char *kv_mode_name(KvKey key) {
    static const char *names[]={"Дорийский","Фригийский","Лидийский","Миксолидийский","Локрийский","Гарм. минор","Мелод. минор"};
    if(key.pentatonic) return "Пентатоника";
    return key.mode>=1 && key.mode<=7?names[key.mode-1]:key.minor?"Минор":"Мажор";
}
static const int natural_pc[7]={0,2,4,5,7,9,11};
/* Accidental of a spelled tonic: letter 0..6 (C..B) against the tonic pitch class, in -2..2. */
static int spelled_delta(KvKey key) { return kv_mod(kv_tonic(key)-natural_pc[(key.spelling-1)%7]+6,12)-6; }
static bool spelled(KvKey key) { return key.spelling>=1 && key.spelling<=7 && abs(spelled_delta(key))<=1; }
int kv_written_signature(KvKey key) { return kv_signature(key)-(key.mode==6?1:key.mode==7?2:0); }
KvKey kv_key_normalize(KvKey key) {
    if(abs(kv_written_signature(key))<=7) return key;
    KvKey best=key; int best_signs=99;
    for(int letter=1;letter<=7;letter++) {
        KvKey candidate=key; candidate.spelling=letter;
        if(!spelled(candidate)) continue;
        int signs=abs(kv_written_signature(candidate));
        if(signs<best_signs) { best_signs=signs; best=candidate; }
    }
    return best_signs<=7?best:key;
}
const char *kv_key_root(KvKey key) {
    static _Thread_local char root[16];
    if(spelled(key)) {
        static const char *accidentals[5]={"𝄫","♭","","♯","𝄪"};
        snprintf(root,sizeof(root),"%c%s","CDEFGAB"[key.spelling-1],accidentals[spelled_delta(key)+2]); return root;
    }
    snprintf(root,sizeof(root),"%s",(key.minor?minor_labels:major_labels)[kv_mod(key.circle_index,12)]);
    if(key.minor) root[strlen(root)-1]=0;
    return root;
}
const char *kv_key_label(KvKey key) {
    if(!spelled(key)) {
        const char *label=(key.minor?minor_labels:major_labels)[kv_mod(key.circle_index,12)];
        if(!key.mode) return label;
    }
    static _Thread_local char label[24]; snprintf(label,sizeof(label),"%s%s",kv_key_root(key),key.minor && !key.mode?"m":""); return label;
}
bool kv_english;
const char *kv_key_title(KvKey key) {
    if(!kv_english) return kv_key_russian(key);
    static const char *modes[]={"Dorian","Phrygian","Lydian","Mixolydian","Locrian","harmonic minor","melodic minor"};
    static _Thread_local char name[96]; char names[7][8]; kv_scale_names(key,names);
    const char *mode=key.mode>=1 && key.mode<=7?modes[key.mode-1]:key.minor?"minor":"major";   // a pentatonic is named by the app (« · pentatonic»)
    snprintf(name,sizeof(name),"%s %s",names[0],mode); return name;
}
const char *kv_key_russian(KvKey key) {
    static _Thread_local char name[128],root[64];
    if(spelled(key)) {
        static const char *syllables[7]={"До","Ре","Ми","Фа","Соль","Ля","Си"},*accidentals[5]={"-дубль-бемоль","-бемоль","","-диез","-дубль-диез"};
        snprintf(root,sizeof(root),"%s%s",syllables[key.spelling-1],accidentals[spelled_delta(key)+2]);
    } else {
        snprintf(root,sizeof(root),"%s",(key.minor?minor_ru:major_ru)[kv_mod(key.circle_index,12)]);
        char *space=strrchr(root,' '); if(space) *space=0;
    }
    if(key.mode) snprintf(name,sizeof(name),"%s · %s",root,kv_mode_name(key));
    else snprintf(name,sizeof(name),"%s %s",root,key.minor?"минор":"мажор");
    return name;
}
int kv_signature(KvKey key) {
    if(key.mode || spelled(key)) {
        char names[7][8]; kv_scale_names(key,names); int signs=0;
        for(int i=0;i<7;i++) { if(strstr(names[i],"𝄪")) signs+=2; else if(strstr(names[i],"♯")) signs++; if(strstr(names[i],"𝄫")) signs-=2; else if(strstr(names[i],"♭")) signs--; }
        return signs;
    }
    int i=kv_mod(key.circle_index,12); return i<=6?i:i-12;
}
void kv_scale(KvKey key, int midi[8]) {
    const int *steps=scale_steps(key); int base=60+kv_tonic(key);
    for(int i=0;i<7;i++) midi[i]=base+steps[i];
    midi[7]=base+12;
}
void kv_scale_names(KvKey key, char names[7][8]) {
    /* Spell successive diatonic letters, including E-sharp and C-flat. */
    const char *letters="CDEFGAB";
    const int natural[7]={0,2,4,5,7,9,11};
    int first=0;
    const char *label=kv_key_label(key);
    while (first<6 && letters[first]!=label[0]) first++;
    int scale[8]; kv_scale(key,scale);
    for (int i=0;i<7;i++) {
        int letter=(first+i)%7;
        int delta=kv_mod(scale[i]-natural[letter]+6,12)-6;
        const char *acc=delta==1 ? "♯" : delta==-1 ? "♭" : delta==2 ? "𝄪" : delta==-2 ? "𝄫" : "";
        snprintf(names[i],8,"%c%s",letters[letter],acc);
    }
}
bool kv_contains(KvKey key, int pitch_class) {
    int scale[8]; kv_scale(key,scale);
    for(int i=0;i<7;i++) if(kv_mod(scale[i],12)==kv_mod(pitch_class,12)) return true;
    return false;
}
bool kv_chord(KvKey key, int degree, KvChord *out) {
    if(!out || degree<0 || degree>6) return false;
    memset(out,0,sizeof(*out)); out->count=3;
    int scale[8]; kv_scale(key,scale);
    char names[7][8]; kv_scale_names(key,names);
    for(int i=0;i<3;i++) { int step=degree+i*2; out->midi[i]=scale[step%7]+12*(step/7); }
    int third=out->midi[1]-out->midi[0], fifth=out->midi[2]-out->midi[0];
    const char *suffix=fifth==6 ? "dim" : fifth==8 ? "aug" : third==3 ? "m" : "";
    static const char *upper[]={"I","II","III","IV","V","VI","VII"};
    static const char *lower[]={"i","ii","iii","iv","v","vi","vii"};
    static const char *diminished[]={"i°","ii°","iii°","iv°","v°","vi°","vii°"};
    static const char *augmented[]={"I+","II+","III+","IV+","V+","VI+","VII+"};
    snprintf(out->degree,sizeof(out->degree),"%s",(fifth==6?diminished:fifth==8?augmented:third==3?lower:upper)[degree]);
    snprintf(out->name,sizeof(out->name),"%s%s",names[degree],suffix);
    return true;
}

bool kv_chord_extended(KvKey key,int degree,int extension,KvChord *out) {
    if(extension<0 || extension>4 || !kv_chord(key,degree,out)) return false;
    if(!extension) return true;
    int scale[8]; char names[7][8]; kv_scale(key,scale); kv_scale_names(key,names);
    out->count=3+(size_t)extension;
    for(size_t i=3;i<out->count;i++) { int step=degree+(int)i*2; out->midi[i]=scale[step%7]+12*(step/7); }
    int third=out->midi[1]-out->midi[0],fifth=out->midi[2]-out->midi[0],seventh=out->midi[3]-out->midi[0];
    const char *quality=fifth==6 && seventh==9?"dim":third==3 && seventh==11?"mMaj":third==3?"m":seventh==11?"maj":"";
    int degree_number=extension==1?7:extension==2?9:extension==3?11:13;
    snprintf(out->name,sizeof(out->name),"%s%s%d%s",names[degree],quality,degree_number,fifth==6 && seventh!=9?"b5":fifth==8?"#5":"");
    const char *alterations[3]={out->count>4 && out->midi[4]-out->midi[0]==13?"b9":NULL,
        out->count>5 && out->midi[5]-out->midi[0]==18?"#11":NULL,
        out->count>6 && out->midi[6]-out->midi[0]==20?"b13":NULL};
    for(int i=0;i<3;i++) if(alterations[i]) { size_t used=strlen(out->name); snprintf(out->name+used,sizeof(out->name)-used,"(%s)",alterations[i]); }
    return true;
}

/* Degrees (0-based) a pentatonic drops: the 4th and 7th of a major-third mode, the 2nd and 6th of a minor-third one. */
static bool pentatonic_keeps(KvKey key, int degree) {
    if(!key.pentatonic) return true;
    bool minor_third=scale_steps(key)[2]==3;
    return minor_third?(degree!=1 && degree!=5):(degree!=3 && degree!=6);
}
bool kv_in_scale(KvKey key, int pitch_class) {
    int scale[8]; kv_scale(key,scale);
    for(int i=0;i<7;i++) if(kv_mod(scale[i],12)==kv_mod(pitch_class,12)) return pentatonic_keeps(key,i);
    return false;
}
int kv_scale_used(KvKey key, int midi[8]) {
    int scale[8]; kv_scale(key,scale); int n=0;
    for(int i=0;i<7;i++) if(pentatonic_keeps(key,i)) midi[n++]=scale[i];
    midi[n]=scale[7]; return n;
}
bool kv_chord_contains(KvKey key, int degree, int pitch_class) {
    KvChord chord;
    if(!kv_chord(key,degree,&chord)) return false;
    for(int i=0;i<3;i++) if(kv_mod(chord.midi[i],12)==kv_mod(pitch_class,12)) return true;
    return false;
}

/* ---- chord codes ---- */
static const char *const sharp_names[12]={"C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"};
static const char *const flat_names[12]={"C","D♭","D","E♭","E","F","G♭","G","A♭","A","B♭","B"};
/* A note's name in this key: the scale's own spelling, else sharps for raised notes, flats for lowered ones. */
static void note_name(KvKey key,int pitch,int lean,char out[8]) {
    int scale[8]; char names[7][8]; kv_scale(key,scale); kv_scale_names(key,names); int pc=kv_mod(pitch,12);
    for(int i=0;i<7;i++) if(kv_mod(scale[i],12)==pc) { snprintf(out,8,"%s",names[i]); return; }
    bool flats=lean<0 || (lean==0 && kv_written_signature(key)<0);
    snprintf(out,8,"%s",(flats?flat_names:sharp_names)[pc]);
}
/* Same tonic and letter, the other family: major-third modes borrow from the natural minor, the others from major. */
static KvKey parallel_key(KvKey key) {
    bool major=scale_steps(key)[2]==4; int tonic=kv_tonic(key); KvKey p={0,major,0,0,false};
    for(int i=0;i<12;i++) if(kv_tonic((KvKey){i,major,0,0,false})==tonic) p.circle_index=i;
    const char *root=kv_key_root(key); const char *letters="CDEFGAB"; const char *at=strchr(letters,root[0]);
    p.spelling=at?(int)(at-letters)+1:0; return kv_key_normalize(p);
}
static unsigned pc_mask(const KvChord *c) { unsigned m=0; for(size_t i=0;i<c->count;i++) m|=1u<<kv_mod(c->midi[i],12); return m; }
/* A dominant seventh on `root` (pitch class), in the register of the key's chords. */
static void dominant(KvKey key,int root,int lean,KvChord *out) {
    int tonic=kv_tonic(key),r=60+tonic+kv_mod(root-tonic,12); char name[8]; note_name(key,r,lean,name);
    out->count=4; out->midi[0]=r; out->midi[1]=r+4; out->midi[2]=r+7; out->midi[3]=r+10;
    snprintf(out->name,sizeof(out->name),"%s7",name); out->lean=lean;
}
/* A chord tone spelled from the chord's root letter: the third of D♯ is F𝄪, the seventh of D♭7 is C♭. */
static void spell_tone(KvKey key,const KvChord *chord,int index,char out[12]) {
    static const char *letters="CDEFGAB"; static const int natural[7]={0,2,4,5,7,9,11};
    static const char *const marks[5]={"♭♭","♭","","♯","♯♯"};   /* the 𝄫 𝄪 glyphs are missing from the system font */
    const char *at=chord->name[0]?strchr(letters,chord->name[0]):NULL;
    if(!at) { char n[8]; note_name(key,chord->midi[index],chord->lean,n); snprintf(out,12,"%s",n); return; }
    int letter=((int)(at-letters)+2*index)%7,accidental=kv_mod(chord->midi[index]-natural[letter]+6,12)-6;
    if(accidental<-2 || accidental>2) { char n[8]; note_name(key,chord->midi[index],chord->lean,n); snprintf(out,12,"%s",n); return; }
    snprintf(out,12,"%c%s",letters[letter],marks[accidental+2]);
}
bool kv_code_valid(int code) {
    int b=kv_code_base(code); if(code<0 || code>=1024) return false;
    return b<=6 || (b>=KV_CODE_SECONDARY && b<=KV_CODE_SECONDARY+6) || (b>=KV_CODE_TRITONE && b<=KV_CODE_TRITONE+6) || (b>=KV_CODE_BORROWED && b<=KV_CODE_BORROWED+6) || b==KV_CODE_NEAPOLITAN;
}
bool kv_code_chord(KvKey key,int code,int extension,KvChord *out) {
    if(!out || !kv_code_valid(code) || extension<0 || extension>4) return false;
    int base=kv_code_base(code),inversion=kv_code_inversion(code);
    if(base<=6) { if(!kv_chord_extended(key,base,extension,out)) return false; out->lean=0; }
    else if(base>=KV_CODE_BORROWED && base<=KV_CODE_BORROWED+6) {
        int d=base-KV_CODE_BORROWED; KvKey p=parallel_key(key); KvChord own;
        if(!kv_chord_extended(p,d,extension,out) || !kv_chord(key,d,&own)) return false;
        int shift=kv_mod(out->midi[0]-own.midi[0]+6,12)-6; char label[24];
        snprintf(label,sizeof(label),"%s%s",shift<0?"♭":shift>0?"♯":"",out->degree); snprintf(out->degree,sizeof(out->degree),"%s",label);
        out->lean=p.minor?-1:1;
    } else if(base==KV_CODE_NEAPOLITAN) {
        memset(out,0,sizeof(*out)); int tonic=kv_tonic(key),r=60+tonic+1; char name[8]; note_name(key,r,-1,name);
        out->count=3; out->midi[0]=r; out->midi[1]=r+4; out->midi[2]=r+7; snprintf(out->name,sizeof(out->name),"%s",name);
        snprintf(out->degree,sizeof(out->degree),"♭II"); out->lean=-1;
    } else {
        bool tritone=base>=KV_CODE_TRITONE; int target=base-(tritone?KV_CODE_TRITONE:KV_CODE_SECONDARY); KvChord t;
        if(!kv_chord(key,target,&t)) return false;
        memset(out,0,sizeof(*out)); dominant(key,t.midi[0]+(tritone?1:7),tritone?-1:1,out);
        snprintf(out->degree,sizeof(out->degree),"%sV7/%s",tritone?"sub":"",t.degree);
    }
    out->bass=inversion<(int)out->count?inversion:(int)out->count-1;
    if(out->bass>0) { char bass[12]; spell_tone(key,out,out->bass,bass); size_t used=strlen(out->name); snprintf(out->name+used,sizeof(out->name)-used,"/%s",bass); }
    return true;
}
size_t kv_chromatic_codes(KvKey key,int extension,int *codes,int *groups,size_t capacity) {
    unsigned seen[64]; size_t n_seen=0,n=0; KvChord chord;
    for(int d=0;d<7;d++) { if(kv_chord_extended(key,d,extension,&chord)) seen[n_seen++]=pc_mask(&chord); if(kv_chord_extended(key,d,1,&chord)) seen[n_seen++]=pc_mask(&chord); if(kv_chord(key,d,&chord)) seen[n_seen++]=pc_mask(&chord); }
    int wanted[32],group_of[32],w=0;
    for(int t=1;t<=6;t++) { wanted[w]=KV_CODE_SECONDARY+t; group_of[w++]=0; }
    for(int d=0;d<7;d++) { wanted[w]=KV_CODE_BORROWED+d; group_of[w++]=1; }
    wanted[w]=KV_CODE_NEAPOLITAN; group_of[w++]=1;
    static const int sub_targets[5]={0,1,3,4,5}; for(int i=0;i<5;i++) { wanted[w]=KV_CODE_TRITONE+sub_targets[i]; group_of[w++]=2; }
    for(int i=0;i<w && n<capacity;i++) {
        int base=wanted[i];
        if(base<KV_CODE_BORROWED || base==KV_CODE_NEAPOLITAN) {
            if(base!=KV_CODE_NEAPOLITAN) { KvChord t; int target=base>=KV_CODE_TRITONE?base-KV_CODE_TRITONE:base-KV_CODE_SECONDARY;
                if(!kv_chord(key,target,&t) || t.midi[2]-t.midi[0]!=7) continue; } // a dominant needs a major or minor chord to resolve to
        }
        if(!kv_code_chord(key,base,extension,&chord)) continue;
        unsigned mask=pc_mask(&chord); bool duplicate=false; for(size_t s=0;s<n_seen;s++) if(seen[s]==mask) duplicate=true;
        if(duplicate || n_seen>=64) continue;
        seen[n_seen++]=mask; codes[n]=base; if(groups) groups[n]=group_of[i]; n++;
    }
    return n;
}
void kv_code_story(KvKey key,int code,int extension,char *out,size_t capacity) {
    if(!out || !capacity) return; out[0]=0; KvChord chord; if(!kv_code_chord(key,code,extension,&chord)) return;
    char foreign[64]=""; size_t used=0;
    for(size_t i=0;i<chord.count;i++) if(!kv_contains(key,chord.midi[i])) { char nm[12]; spell_tone(key,&chord,(int)i,nm); used+=(size_t)snprintf(foreign+used,sizeof(foreign)-used,"%s%s",used?", ":"",nm); if(used>=sizeof(foreign)) break; }
    char tail[96]=""; if(foreign[0]) snprintf(tail,sizeof(tail),kv_english?" Notes outside the mode: %s.":" Чужие для лада звуки: %s.",foreign);
    int base=kv_code_base(code);
    if(kv_english) {
        if(base<=6) { snprintf(out,capacity,"%s is degree %s of the mode.",chord.name,chord.degree); return; }
        if(base==KV_CODE_NEAPOLITAN) { KvChord v; kv_code_chord(key,4,1,&v); snprintf(out,capacity,"%s (♭II) — Neapolitan: a major triad on the lowered second degree. It leads gently to the dominant %s.%s",chord.name,v.name,tail); return; }
        if(base>=KV_CODE_BORROWED) { KvKey p=parallel_key(key); snprintf(out,capacity,"%s (%s) — borrowed from the parallel mode (%s): a %s colour on the same tonic.%s",chord.name,chord.degree,kv_key_title(p),p.minor?"darker":"brighter",tail); return; }
        bool tritone=base>=KV_CODE_TRITONE; KvChord t; kv_chord(key,base-(tritone?KV_CODE_TRITONE:KV_CODE_SECONDARY),&t);
        if(tritone) snprintf(out,capacity,"%s — tritone substitute for the dominant of %s (%s): the same tritone as its V7, with the bass a semitone above %s, falling into it.%s",chord.name,t.name,t.degree,t.name,tail);
        else snprintf(out,capacity,"%s — secondary dominant of %s (%s): for a moment it makes %s the tonic and resolves into it.%s",chord.name,t.name,t.degree,t.name,tail);
        return;
    }
    if(base<=6) { snprintf(out,capacity,"%s — %s ступень лада.",chord.name,chord.degree); return; }
    if(base==KV_CODE_NEAPOLITAN) { KvChord v; kv_code_chord(key,4,1,&v); snprintf(out,capacity,"%s (♭II) — неаполитанский: мажорное трезвучие на пониженной II ступени. Мягко ведёт к доминанте %s.%s",chord.name,v.name,tail); return; }
    if(base>=KV_CODE_BORROWED) {
        KvKey p=parallel_key(key); snprintf(out,capacity,"%s (%s) — заимствован из одноимённого лада (%s): %s краска на той же тонике.%s",chord.name,chord.degree,kv_key_russian(p),p.minor?"более тёмная":"более светлая",tail); return; }
    bool tritone=base>=KV_CODE_TRITONE; KvChord t; kv_chord(key,base-(tritone?KV_CODE_TRITONE:KV_CODE_SECONDARY),&t);
    if(tritone) snprintf(out,capacity,"%s — тритоновая замена доминанты к %s (%s): тот же тритон, что у её V7, а бас на полтона выше %s и сходит в него вниз.%s",chord.name,t.name,t.degree,t.name,tail);
    else snprintf(out,capacity,"%s — побочная доминанта к %s (%s): на миг делает %s тоникой и разрешается в него.%s",chord.name,t.name,t.degree,t.name,tail);
}
size_t kv_chord_voiced(const KvChord *chord,int *midi) {
    if(!chord || !midi) return 0; size_t n=chord->count; int bass=chord->bass>=0 && chord->bass<(int)n?chord->bass:0;
    midi[0]=chord->midi[bass]; size_t k=1;
    for(size_t i=0;i<n;i++) if((int)i!=bass) { int note=chord->midi[i]; while(note<=midi[0]) note+=12; midi[k++]=note; }
    for(size_t i=1;i<k;i++) for(size_t j=i;j>0 && midi[j]<midi[j-1];j--) { int s=midi[j]; midi[j]=midi[j-1]; midi[j-1]=s; }
    return k;
}

static uint32_t next_random(uint32_t *state) {
    *state^=*state<<13; *state^=*state>>17; *state^=*state<<5; return *state;
}
static const int generator_patterns[2][3][4][4]={
        {{{0,4,5,3},{5,3,0,4},{0,5,3,4},{3,0,4,5}},
         {{0,3,4,0},{0,1,4,0},{0,5,1,4},{0,3,1,4}},
         {{0,2,5,3},{0,5,3,0},{0,3,5,3},{5,2,3,0}}},
        {{{0,5,2,6},{0,3,6,2},{0,6,5,6},{5,2,6,0}},
         {{0,3,4,0},{0,5,3,4},{0,6,3,0},{0,3,6,0}},
         {{0,2,5,3},{0,5,3,0},{0,3,5,3},{5,2,3,0}}}
};
bool kv_generate_more(KvKey key,int style,const int *existing,size_t n,size_t add,uint32_t seed,int *out) {
    if(!out || style<0 || style>2 || !add || n+add>8 || (n && !existing)) return false;
    uint32_t random=seed?seed:0x746f6e6f; int last=n?existing[n-1]:-1; size_t made=0; int family=scale_steps(key)[2]==3?1:0;
    while(made<add) {
        size_t take=add-made>=4?4:add-made; int from=4-(int)take,pattern=(int)(next_random(&random)%4);
        for(int tries=0;tries<4 && generator_patterns[family][style][pattern][from]==last;tries++) pattern=(pattern+1)%4;
        for(size_t j=0;j<take;j++) out[made+j]=generator_patterns[family][style][pattern][from+(int)j];
        if(!n && !made && take==4) { // a fresh progression may start anywhere in its loop (vi–IV–I–V as well as I–V–vi–IV)
            int r=(int)(next_random(&random)%4),turned[4]; bool clean=true;
            for(int j=0;j<4;j++) turned[j]=out[(j+r)%4];
            for(int j=1;j<4;j++) if(turned[j]==turned[j-1]) clean=false;
            if(clean) memcpy(out,turned,sizeof(turned));
        }
        if(out[made]==last && take>1) { int first=out[made]; out[made]=out[made+1]; out[made+1]=first; }
        last=out[made+take-1]; made+=take;
    }
    return true;
}
bool kv_generate(KvKey key, int style, size_t count, uint32_t seed, int *degrees) {
    if(!degrees || style<0 || style>2 || (count!=4 && count!=8)) return false;
    static const int patterns[2][3][4][4]={
        {{{0,4,5,3},{5,3,0,4},{0,5,3,4},{3,0,4,5}},
         {{0,3,4,0},{0,1,4,0},{0,5,1,4},{0,3,1,4}},
         {{0,2,5,3},{0,5,3,0},{0,3,5,3},{5,2,3,0}}},
        {{{0,5,2,6},{0,3,6,2},{0,6,5,6},{5,2,6,0}},
         {{0,3,4,0},{0,5,3,4},{0,6,3,0},{0,3,6,0}},
         {{0,2,5,3},{0,5,3,0},{0,3,5,3},{5,2,3,0}}}
    };
    uint32_t random=seed?seed:0x746f6e6f;
    for(size_t block=0;block<count/4;block++) {
        int pattern=(int)(next_random(&random)%4);
        for(size_t j=0;j<4;j++) degrees[block*4+j]=patterns[scale_steps(key)[2]==3?1:0][style][pattern][j];
        if(block && degrees[block*4]==degrees[block*4-1]) {
            int first=degrees[block*4]; degrees[block*4]=degrees[block*4+1]; degrees[block*4+1]=first;
        }
    }
    return true;
}

/* ---- detection ---- */
static double correlate(const double *a,const double *b) {
    double ma=0,mb=0; for(int i=0;i<12;i++) { ma+=a[i]; mb+=b[i]; } ma/=12; mb/=12;
    double num=0,da=0,db=0; for(int i=0;i<12;i++) { num+=(a[i]-ma)*(b[i]-mb); da+=(a[i]-ma)*(a[i]-ma); db+=(b[i]-mb)*(b[i]-mb); }
    return da>0 && db>0?num/sqrt(da*db):0;
}
static int circle_of(int tonic,bool minor) { for(int i=0;i<12;i++) if(kv_tonic((KvKey){i,minor,0,0,false})==tonic) return i; return 0; }
KvKey kv_detect_key(const double weights[12],bool has_signature,int sharps,double *fit) {
    static const double major[12]={6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88};
    static const double minor[12]={6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17};
    double best=-2,score[2][12]; int best_tonic=0; bool best_minor=false;
    for(int m=0;m<2;m++) for(int t=0;t<12;t++) {
        double profile[12]; for(int i=0;i<12;i++) profile[(i+t)%12]=(m?minor:major)[i];
        score[m][t]=correlate(weights,profile);
        if(score[m][t]>best) { best=score[m][t]; best_tonic=t; best_minor=m; }
    }
    if(has_signature && sharps>=-7 && sharps<=7) {
        int major_tonic=kv_mod(sharps*7,12),minor_tonic=kv_mod(major_tonic+9,12);
        bool m=score[1][minor_tonic]>score[0][major_tonic]; int t=m?minor_tonic:major_tonic;
        if(score[m][t]>=best-.05) { best=score[m][t]; best_tonic=t; best_minor=m; }
    }
    if(fit) *fit=best;
    return kv_key_normalize((KvKey){circle_of(best_tonic,best_minor),best_minor,0,0,false});
}
int kv_detect_chord(KvKey key,const double weights[12],int bass_pitch_class) {
    double total=0; for(int i=0;i<12;i++) total+=weights[i]; if(total<=0) return -1;
    int candidates[40],n=0,outside[24]; for(int d=0;d<7;d++) candidates[n++]=d;
    size_t m=kv_chromatic_codes(key,0,outside,NULL,24); for(size_t i=0;i<m;i++) candidates[n++]=outside[i];
    int best=-1; double best_score=-1e9;
    for(int i=0;i<n;i++) {
        KvChord chord; if(!kv_code_chord(key,candidates[i],0,&chord)) continue;
        unsigned mask=0; double in=0; for(size_t v=0;v<chord.count;v++) mask|=1u<<kv_mod(chord.midi[v],12);
        for(int pc=0;pc<12;pc++) if(mask>>pc&1u) in+=weights[pc];
        double score=in-.7*(total-in);
        if(kv_mod(chord.midi[0],12)==bass_pitch_class) score+=.25*total;         // the root in the bass
        if(weights[kv_mod(chord.midi[0],12)]<=0) score-=.3*total;                  // a chord whose root never sounds
        if(i>=7) score-=.08*total;                                                  // the key's own chords first
        if(score>best_score+1e-9) { best_score=score; best=candidates[i]; }
    }
    if(best<0) return -1;
    KvChord chord; kv_code_chord(key,best,0,&chord);
    for(int v=1;v<3;v++) if(kv_mod(chord.midi[v],12)==bass_pitch_class && kv_mod(chord.midi[0],12)!=bass_pitch_class) return kv_code_with_inversion(best,v);
    return best;
}

size_t kv_common_chords(KvKey from,KvKey to,int *from_degrees,int *to_degrees,size_t capacity) {
    size_t n=0;
    for(int a=0;a<7 && n<capacity;a++) { KvChord x; if(!kv_chord(from,a,&x)) continue; unsigned mx=pc_mask(&x);
        for(int b=0;b<7;b++) { KvChord y; if(kv_chord(to,b,&y) && pc_mask(&y)==mx) { from_degrees[n]=a; to_degrees[n]=b; n++; break; } } }
    return n;
}
