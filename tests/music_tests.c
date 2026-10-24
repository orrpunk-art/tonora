#include "music.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) assert(x)
static int pentatonic_checks(void) {
    KvKey c={0,false,0,0,true}; int used[8]; int n=kv_scale_used(c,used);          /* C major pentatonic: C D E G A */
    CHECK(n==5 && used[0]==60 && used[1]==62 && used[2]==64 && used[3]==67 && used[4]==69 && used[5]==72);
    CHECK(kv_in_scale(c,0) && !kv_in_scale(c,5) && !kv_in_scale(c,11) && kv_contains(c,5));
    KvKey a={0,true,0,0,true}; n=kv_scale_used(a,used);                             /* A minor pentatonic: A C D E G */
    CHECK(n==5 && used[0]==69 && used[1]==72 && used[2]==74 && used[3]==76 && used[4]==79);
    KvKey d={0,false,1,0,true}; n=kv_scale_used(d,used); CHECK(n==5 && used[1]==63 && used[3]==67);   /* C dorian: minor kind, C E♭ F G B♭ */
    KvKey plain={0,false,0,0,false}; CHECK(kv_scale_used(plain,used)==7);
    KvChord chord; CHECK(kv_chord_extended(c,4,1,&chord) && chord.count==4 && chord.midi[3]%12==5); /* chords keep the seven-note mode: G7 has an F */
    return 0;
}
static int code_checks(void) {
    KvKey c={0,false,0,0,false}; KvChord ch; char story[400];
    CHECK(kv_code_chord(c,3,0,&ch) && !strcmp(ch.name,"F") && !strcmp(ch.degree,"IV"));                  /* diatonic codes as before */
    CHECK(kv_code_chord(c,KV_CODE_SECONDARY+1,0,&ch) && !strcmp(ch.name,"A7") && !strcmp(ch.degree,"V7/ii") && ch.midi[1]%12==1 && ch.lean==1);
    CHECK(kv_code_chord(c,KV_CODE_SECONDARY+4,0,&ch) && !strcmp(ch.name,"D7"));                            /* V7/V */
    CHECK(kv_code_chord(c,KV_CODE_TRITONE+0,0,&ch) && !strcmp(ch.name,"D♭7") && !strcmp(ch.degree,"subV7/I"));
    CHECK(kv_code_chord(c,KV_CODE_BORROWED+5,0,&ch) && !strcmp(ch.name,"A♭") && !strcmp(ch.degree,"♭VI") && ch.lean==-1);
    CHECK(kv_code_chord(c,KV_CODE_BORROWED+3,0,&ch) && !strcmp(ch.name,"Fm") && !strcmp(ch.degree,"iv"));
    CHECK(kv_code_chord(c,KV_CODE_NEAPOLITAN,0,&ch) && !strcmp(ch.name,"D♭") && !strcmp(ch.degree,"♭II"));
    KvKey a={0,true,0,0,false};                                                                                /* A minor borrows from A major */
    CHECK(kv_code_chord(a,KV_CODE_BORROWED+4,0,&ch) && !strcmp(ch.name,"E") && ch.lean==1);
    /* Inversions: name with the bass, voiced with the bass lowest. */
    CHECK(kv_code_chord(c,kv_code_with_inversion(0,1),0,&ch) && !strcmp(ch.name,"C/E") && ch.bass==1);
    int v[8]; size_t n=kv_chord_voiced(&ch,v); CHECK(n==3 && v[0]%12==4 && v[1]%12==7 && v[2]%12==0 && v[0]<v[1] && v[1]<v[2]);
    CHECK(kv_code_chord(c,kv_code_with_inversion(KV_CODE_SECONDARY+1,3),0,&ch) && !strcmp(ch.name,"A7/G"));
    CHECK(kv_code_chord(c,kv_code_with_inversion(0,3),0,&ch) && ch.bass==2);                              /* a triad has no seventh: fifth */
    CHECK(!kv_code_valid(7) && !kv_code_valid(-1) && kv_code_valid(KV_CODE_NEAPOLITAN) && !kv_code_valid(41));
    /* The palette for C major: dominants, borrowed, subV; nothing equal to C major's own chords; no duplicates. */
    int codes[32],groups[32]; size_t count=kv_chromatic_codes(c,0,codes,groups,32); int per[3]={0};
    CHECK(count>=12); for(size_t i=0;i<count;i++) { per[groups[i]]++; CHECK(kv_code_chord(c,codes[i],0,&ch));
        for(int d=0;d<7;d++) { KvChord own; kv_chord_extended(c,d,0,&own); unsigned m1=0,m2=0; for(size_t k=0;k<own.count;k++) m1|=1u<<(own.midi[k]%12); for(size_t k=0;k<ch.count;k++) m2|=1u<<(ch.midi[k]%12); CHECK(m1!=m2); } }
    CHECK(per[0]==5 && per[1]>=4 && per[2]==5);
    for(int k=0;k<12;k++) for(int minor=0;minor<2;minor++) for(int mode=0;mode<8;mode++) for(int ext=0;ext<5;ext++) {
        KvKey key={k,minor,mode,0,false}; size_t m=kv_chromatic_codes(key,ext,codes,groups,32); CHECK(m>=5);
        for(size_t i=0;i<m;i++) { CHECK(kv_code_chord(key,codes[i],ext,&ch) && ch.count>=3); kv_code_story(key,codes[i],ext,story,sizeof(story)); CHECK(strlen(story)>20); }
    }
    { KvKey g={1,false,0,0,false}; int fd[7],td[7]; size_t m=kv_common_chords(c,g,fd,td,7); CHECK(m==4);   /* C, Em, G, Am */
      bool am=false; for(size_t i=0;i<m;i++) if(fd[i]==5 && td[i]==1) am=true; CHECK(am);                   /* Am: vi in C, ii in G */
      KvKey fs={6,false,0,0,false}; CHECK(kv_common_chords(c,fs,fd,td,7)==0); }                             /* C and F♯ share nothing */
    kv_code_story(c,KV_CODE_SECONDARY+1,0,story,sizeof(story)); CHECK(strstr(story,"A7") && strstr(story,"Dm") && strstr(story,"C♯"));
    KvKey e={4,false,0,0,false}; kv_code_story(e,KV_CODE_SECONDARY+2,0,story,sizeof(story));     /* E major: D♯7 = D♯ F♯♯ A♯ C♯ */
    CHECK(strstr(story,"D♯7") && strstr(story,"F♯♯") && strstr(story,"A♯") && !strstr(story," G,"));
    CHECK(kv_code_chord(c,kv_code_with_inversion(KV_CODE_TRITONE+0,3),0,&ch) && !strcmp(ch.name,"D♭7/C♭"));   /* the seventh of D♭7 is C♭ */
    return 0;
}
static int continue_checks(void) {
    KvKey c={0,false,0,0,false}; int out[8];
    for(int style=0;style<3;style++) for(unsigned seed=1;seed<200;seed++) for(size_t n=0;n<8;n++) for(size_t add=1;n+add<=8;add++) {
        int existing[8]; for(size_t i=0;i<n;i++) existing[i]=(int)((seed+i*3)%7);
        CHECK(kv_generate_more(c,style,existing,n,add,seed,out));
        for(size_t i=0;i<add;i++) CHECK(out[i]>=0 && out[i]<=6);
        if(n) CHECK(out[0]!=existing[n-1] || add==1);              /* never starts on the chord before it (but a single added chord may) */
        for(size_t i=1;i<add;i++) if(i%4==0) CHECK(out[i]!=out[i-1]);   /* nor does a later block */
    }
    CHECK(!kv_generate_more(c,0,NULL,0,0,1,out) && !kv_generate_more(c,0,out,4,5,1,out) && !kv_generate_more(c,3,NULL,0,4,1,out));
    for(int style=0;style<3;style++) { bool start[7]={false}; int kinds=0;            /* fresh progressions do not all start alike */
        for(unsigned seed=1;seed<=100;seed++) { CHECK(kv_generate_more(c,style,NULL,0,4,seed,out)); if(!start[out[0]]) { start[out[0]]=true; kinds++; }
            for(int i=1;i<4;i++) CHECK(out[i]!=out[i-1]); }
        CHECK(kinds>=3); }
    return 0;
}
int main(void) {
    if(pentatonic_checks()) return 1;
    if(continue_checks()) return 1;
    if(code_checks()) return 1;
    const int major_intervals[7]={2,2,1,2,2,2,1};
    const int minor_intervals[7]={2,1,2,2,1,2,2};
    for(int minor=0;minor<2;minor++) for(int i=0;i<12;i++) {
        KvKey key={i,minor,0,0}; int scale[8]; kv_scale(key,scale);
        for(int j=0;j<7;j++) {
            assert(scale[j+1]-scale[j]==(minor?minor_intervals:major_intervals)[j]);
            assert(kv_contains(key,scale[j]));
            KvChord chord; assert(kv_chord(key,j,&chord));
            assert(chord.midi[0]<chord.midi[1] && chord.midi[1]<chord.midi[2]);
            for(int v=0;v<3;v++) assert(kv_contains(key,chord.midi[v]));
        }
        assert(scale[7]-scale[0]==12);
        assert(kv_tonic((KvKey){i+1,minor,0,0})==kv_mod(kv_tonic(key)+7,12));
        assert(kv_signature(key)>=-5 && kv_signature(key)<=6);
    }
    for(int minor=0;minor<2;minor++) for(int i=0;i<12;i++) for(int degree=0;degree<7;degree++) {
        KvKey key={i,minor,0,0}; KvChord triad; assert(kv_chord(key,degree,&triad));
        int count=0;
        for(int pitch=0;pitch<12;pitch++) {
            bool expected=false;
            for(int v=0;v<3;v++) if(triad.midi[v]%12==pitch) expected=true;
            assert(kv_chord_contains(key,degree,pitch)==expected);
            assert(kv_chord_contains(key,degree,pitch+12)==expected);
            count+=kv_chord_contains(key,degree,pitch);
        }
        assert(count==3);
    }
    assert(!kv_chord_contains((KvKey){0,true,0,0},7,60));
    KvChord chord;
    assert(kv_chord((KvKey){0,false,0,0},6,&chord)); assert(strcmp(chord.name,"Bdim")==0);
    assert(kv_chord((KvKey){0,true,0,0},1,&chord)); assert(strcmp(chord.name,"Bdim")==0);
    assert(kv_chord((KvKey){0,true,0,0},4,&chord)); assert(strcmp(chord.name,"Em")==0);
    char names[7][8]; kv_scale_names((KvKey){6,false,0,0},names); assert(strcmp(names[6],"E♯")==0);
    kv_scale_names((KvKey){7,true,0,0},names); assert(strcmp(names[1],"C")==0); assert(strcmp(names[5],"G♭")==0);
    // Spelled tonic: A-flat minor instead of G-sharp minor.
    KvKey a_flat={5,true,0,6}; assert(strcmp(kv_key_label(a_flat),"A♭m")==0 && strcmp(kv_key_russian(a_flat),"Ля-бемоль минор")==0 && kv_signature(a_flat)==-7);
    kv_scale_names(a_flat,names); assert(strcmp(names[2],"C♭")==0 && strcmp(names[5],"F♭")==0);
    KvKey a_flat_harmonic={8,false,6,6}; assert(strcmp(kv_key_label(a_flat_harmonic),"A♭")==0 && strcmp(kv_key_russian(a_flat_harmonic),"Ля-бемоль · Гарм. минор")==0 && kv_signature(a_flat_harmonic)==-6);
    // English: the spelled tonic and the mode in words; explanations in English, no Cyrillic left.
    kv_english=true;
    assert(strcmp(kv_key_title(a_flat),"A♭ minor")==0 && strcmp(kv_key_title(a_flat_harmonic),"A♭ harmonic minor")==0 && strcmp(kv_key_title((KvKey){0,false,0,0}),"C major")==0 && strcmp(kv_key_title((KvKey){0,true,0,0,true}),"A minor")==0);
    { char story[256]; kv_code_story((KvKey){0,false,0,0},KV_CODE_SECONDARY+1,0,story,sizeof(story)); assert(strstr(story,"secondary dominant of Dm"));
      for(int code=0;code<48;code++) { story[0]=0; kv_code_story((KvKey){0,false,0,0},code,0,story,sizeof(story)); for(const unsigned char *c=(const unsigned char *)story;*c;c++) assert(!(*c==0xD0 || *c==0xD1)); } }
    kv_english=false; assert(strcmp(kv_key_title(a_flat),"Ля-бемоль минор")==0);
    assert(strcmp(kv_key_label((KvKey){5,true,0,0}),"G♯m")==0); // default spelling unchanged
    assert(strcmp(kv_key_label((KvKey){7,true,0,2}),"B♭m")==0); // a double-flat tonic (C𝄫) is never used
    // Every normalized key is written with consecutive letters, correct accidentals and at most seven of them.
    { static const int natural[7]={0,2,4,5,7,9,11}; int respelled=0;
      for(int minor=0;minor<2;minor++) for(int i=0;i<12;i++) for(int mode=0;mode<8;mode++) for(int sp=0;sp<8;sp++) {
        KvKey raw={i,minor,mode,sp},key=kv_key_normalize(raw); if(key.spelling!=raw.spelling) respelled++;
        char spelled[7][8]; int scale[8]; kv_scale_names(key,spelled); kv_scale(key,scale); int sum=0;
        int first=(int)(strchr("CDEFGAB",spelled[0][0])-"CDEFGAB");
        for(int d=0;d<7;d++) {
            int letter=(int)(strchr("CDEFGAB",spelled[d][0])-"CDEFGAB"); assert(letter==(first+d)%7);
            int a=strstr(spelled[d],"𝄪")?2:strstr(spelled[d],"𝄫")?-2:strstr(spelled[d],"♯")?1:strstr(spelled[d],"♭")?-1:0;
            assert(a==((scale[d]-natural[letter])%12+18)%12-6); sum+=a;
            KvChord c; assert(kv_chord(key,d,&c) && c.name[0]==spelled[d][0]);
        }
        assert(kv_signature(key)==sum && abs(kv_written_signature(key))<=7 && kv_key_root(key)[0]==spelled[0][0] && kv_tonic(key)==kv_tonic(raw));
      }
      assert(respelled>0);
      KvKey ds={6,true,7,0}; assert(kv_signature(ds)==8 && kv_written_signature(ds)==6 && kv_key_normalize(ds).spelling==0); // D♯ melodic minor: 6 sharps written, B♯ and C𝄪 are accidentals
      KvKey db={7,false,2,0}; assert(kv_signature(db)==-9 && strcmp(kv_key_root(kv_key_normalize(db)),"C♯")==0);
      KvKey ab={5,true,0,6}; assert(kv_signature(ab)==-7 && kv_key_normalize(ab).spelling==6);
      KvKey dbm={4,true,7,2}; assert(kv_signature(dbm)==-6 && kv_written_signature(dbm)==-8 && strcmp(kv_key_root(kv_key_normalize(dbm)),"C♯")==0); // D♭ melodic minor: 8 flats at the clef
      KvKey asm_={7,true,6,6}; assert(kv_written_signature(asm_)==7 && kv_key_normalize(asm_).spelling==6); } // A♯ harmonic minor stays: 7 sharps written, G𝄪 is an accidental
    assert(strcmp(kv_key_label((KvKey){5,true,0,3}),"G♯m")==0); // impossible letter (E for G-sharp) falls back
    assert(!kv_chord((KvKey){0,false,0,0},-1,&chord)); assert(!kv_chord((KvKey){0,false,0,0},7,&chord));
    assert(!kv_chord((KvKey){0,false,0,0},0,NULL));
    assert(kv_tonic((KvKey){-1,false,0,0})==5);
    for(int minor=0;minor<2;minor++) for(int index=0;index<12;index++) for(int style=0;style<3;style++) for(unsigned seed=1;seed<40;seed++) {
        KvKey key={index,minor,0,0}; int degrees[8],again[8];
        assert(kv_generate(key,style,8,seed,degrees)); assert(kv_generate(key,style,8,seed,again));
        assert(memcmp(degrees,again,sizeof(degrees))==0);
        for(int i=0;i<8;i++) {
            KvChord chord; assert(kv_chord(key,degrees[i],&chord));
            for(int j=0;j<3;j++) assert(kv_contains(key,chord.midi[j]));
        }
        assert(degrees[3]!=degrees[4]);
        assert(kv_generate(key,style,4,seed,degrees));
    }
    for(int minor=0;minor<2;minor++) for(int k=0;k<12;k++) for(int d=0;d<7;d++) for(int ext=0;ext<=4;ext++) {
        KvChord ch; KvKey key={k,minor,0,0}; assert(kv_chord_extended(key,d,ext,&ch)); assert(ch.count==(size_t)(3+ext));
        for(size_t v=0;v<ch.count;v++) { assert(kv_contains(key,ch.midi[v])); if(v) assert(ch.midi[v]>ch.midi[v-1]); }
    }
    KvChord extended; assert(kv_chord_extended((KvKey){0,false,0,0},0,1,&extended)); assert(strcmp(extended.name,"Cmaj7")==0);
    assert(kv_chord_extended((KvKey){0,false,0,0},4,1,&extended)); assert(strcmp(extended.name,"G7")==0);
    assert(kv_chord_extended((KvKey){0,false,0,0},1,2,&extended)); assert(strcmp(extended.name,"Dm9")==0);
    assert(kv_chord_extended((KvKey){0,false,0,0},6,1,&extended)); assert(strcmp(extended.name,"Bm7b5")==0);
    const int expected[7][7]={{0,2,3,5,7,9,10},{0,1,3,5,7,8,10},{0,2,4,6,7,9,11},{0,2,4,5,7,9,10},{0,1,3,5,6,8,10},{0,2,3,5,7,8,11},{0,2,3,5,7,9,11}};
    for(int mode=1;mode<=7;mode++) for(int minor=0;minor<2;minor++) for(int root=0;root<12;root++) {
        KvKey key={root,minor,mode,0}; int scale[8]; kv_scale(key,scale);
        assert(kv_tonic(key)==kv_tonic((KvKey){root,minor,0,0}));
        for(int i=0;i<7;i++) assert(scale[i]-scale[0]==expected[mode-1][i]);
        char names[7][8]; kv_scale_names(key,names);
        for(int d=0;d<7;d++) for(int ext=0;ext<5;ext++) {
            KvChord chord; assert(kv_chord_extended(key,d,ext,&chord));
            for(size_t n=0;n<chord.count;n++) assert(kv_contains(key,chord.midi[n]));
        }
        assert(strstr(kv_key_russian(key),kv_mode_name(key)));
    }
    assert(kv_chord_extended((KvKey){0,true,6,0},6,1,&extended)); assert(strcmp(extended.name,"G♯dim7")==0);
    assert(kv_chord_extended((KvKey){0,true,6,0},0,1,&extended)); assert(strcmp(extended.name,"AmMaj7")==0);
    assert(kv_chord((KvKey){0,true,6,0},2,&extended)); assert(strcmp(extended.name,"Caug")==0);
    int invalid[8]; assert(!kv_generate((KvKey){0,false,0,0},3,4,1,invalid));
    assert(!kv_generate((KvKey){0,false,0,0},0,5,1,invalid));
    puts("All 24 keys: scale intervals, fifths, triads and enharmonic spelling passed.");
    return 0;
}
