#include "piano.h"
#include "livefx.h"
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static double energy(const float *pcm,size_t start,size_t frames) {
    double value=0; for(size_t i=start*2;i<frames*2;i++) value+=(double)pcm[i]*pcm[i]; return value;
}
static void wav(const char *path,const float *pcm,size_t frames) {
    FILE *f=fopen(path,"wb"); assert(f);
    uint32_t data=(uint32_t)(frames*4),size=data+36,rate=44100,bytes=176400,fmt=16;
    uint16_t encoding=1,channels=2,align=4,bits=16;
    assert(fwrite("RIFF",1,4,f)==4); assert(fwrite(&size,4,1,f)==1); assert(fwrite("WAVEfmt ",1,8,f)==8);
    assert(fwrite(&fmt,4,1,f)==1); assert(fwrite(&encoding,2,1,f)==1); assert(fwrite(&channels,2,1,f)==1);
    assert(fwrite(&rate,4,1,f)==1); assert(fwrite(&bytes,4,1,f)==1); assert(fwrite(&align,2,1,f)==1); assert(fwrite(&bits,2,1,f)==1);
    assert(fwrite("data",1,4,f)==4); assert(fwrite(&data,4,1,f)==1);
    for(size_t i=0;i<frames*2;i++) { int16_t v=(int16_t)(pcm[i]*32767); assert(fwrite(&v,2,1,f)==1); }
    assert(fclose(f)==0);
}
int main(int argc,char **argv) {
    assert(argc==3); KvPianoBank *piano=kv_piano_load(argv[1]); assert(piano);
    float *dry=NULL,*wet=NULL; size_t dry_frames=0,wet_frames=0;
    int notes[12]={57,60,64,53,57,60,48,52,55,55,59,62};
    KvEffects none={0,0,0.3}, effects={0.25,0.25,0.3};
    assert(kv_piano_render(piano,notes,12,3,0.7,none,&dry,&dry_frames));
    assert(kv_piano_render(piano,notes,12,3,0.7,effects,&wet,&wet_frames));
    assert(wet_frames==dry_frames+44100*4 && energy(dry,0,dry_frames)>0.1);
    double stereo=0;
    for(size_t i=0;i<dry_frames;i++) stereo+=fabs(dry[i*2]-dry[i*2+1]);
    assert(stereo>0.1); assert(energy(wet,dry_frames,wet_frames)>0.001);
    for(size_t i=0;i<wet_frames*2;i++) assert(isfinite(wet[i]) && fabsf(wet[i])<=0.951);
    wav(argv[2],wet,wet_frames); free(dry); free(wet);
    // Measure actual piano return level through the live processor, with delay disabled.
    int reference_note=60; float *reference=NULL; size_t reference_frames=0;
    assert(kv_piano_render(piano,&reference_note,1,1,.4,none,&reference,&reference_frames));
    size_t audition_frames=reference_frames+44100*3;
    float *audition=calloc(audition_frames*2,sizeof(float)); assert(audition);
    memcpy(audition,reference,reference_frames*2*sizeof(float));
    KvLiveEffects *live=kv_live_effects_create(); assert(live);
    for(size_t at=0;at<audition_frames;at+=256) {
        size_t n=audition_frames-at<256?audition_frames-at:256;
        assert(kv_live_effects_process(live,audition+at*2,n,(KvEffects){.22,0,.3}));
    }
    double dry_energy=energy(reference,0,reference_frames),return_energy=0;
    for(size_t i=0;i<audition_frames*2;i++) {
        double diff=audition[i]-(i<reference_frames*2?reference[i]*cos(.22*M_PI_2):0); return_energy+=diff*diff;
    }
    printf("Piano reverb at 22%%: return/dry %.2f dB; isolated tail %.2f dB relative to dry energy\n",10*log10(return_energy/dry_energy),10*log10(energy(audition,reference_frames,audition_frames)/dry_energy));
    double tail_energy=energy(audition,reference_frames,audition_frames);
    // Regression: a detectable impulse is insufficient; the actual piano return and tail must be substantial.
    assert(return_energy/dry_energy>.2 && return_energy/dry_energy<1);
    assert(tail_energy/dry_energy>.005);
    float *comparison=calloc(audition_frames*4,sizeof(float)); assert(comparison);
    memcpy(comparison,reference,reference_frames*2*sizeof(float));
    memcpy(comparison+audition_frames*2,audition,audition_frames*2*sizeof(float));
    char comparison_path[4096]; int length=snprintf(comparison_path,sizeof(comparison_path),"%s.reverb-comparison.wav",argv[2]);
    assert(length>0 && (size_t)length<sizeof(comparison_path)); wav(comparison_path,comparison,audition_frames*2); free(comparison);
    float *wet_only=calloc(audition_frames*2,sizeof(float)); assert(wet_only);
    memcpy(wet_only,reference,reference_frames*2*sizeof(float));
    KvLiveEffects *isolated=kv_live_effects_create(); assert(isolated);
    for(size_t at=0;at<audition_frames;at+=256) {
        size_t n=audition_frames-at<256?audition_frames-at:256;
        assert(kv_live_effects_process(isolated,wet_only+at*2,n,(KvEffects){1,0,.3}));
    }
    assert(energy(wet_only,0,800)<1e-10); // No dry hammer transient in 100% wet mode.
    assert(energy(wet_only,reference_frames,audition_frames)>tail_energy*5);
    kv_live_effects_free(isolated); free(wet_only);
    kv_live_effects_free(live); free(audition); free(reference);
    size_t frames=44100; float *impulse=calloc(frames*2,sizeof(float)); assert(impulse); impulse[0]=0.5;
    assert(kv_effects_process(impulse,frames,(KvEffects){0,0.5,0.1}));
    double before=energy(impulse,100,4300),first=energy(impulse,4300,4900),second=energy(impulse,8700,9500);
    assert(before<1e-8 && first>1e-5 && second>1e-7 && second<first);
    free(impulse);
    float *room=calloc(44100*3*2,sizeof(float)); assert(room); room[0]=0.2f;
    assert(kv_effects_process(room,44100*3,(KvEffects){.3,0,.3}));
    double early=energy(room,4410,44100),late=energy(room,44100*2,44100*3);
    assert(early>1e-6 && late<early*.1);
    free(room);
    float dry_identity[8]={.2f,-.1f,.3f,-.4f,0,0,.02f,.03f},original[8]; memcpy(original,dry_identity,sizeof(original));
    assert(kv_effects_process(dry_identity,4,none)); assert(memcmp(original,dry_identity,sizeof(original))==0);
    int invalid=128; assert(!kv_piano_render(piano,&invalid,1,1,0.5,none,&dry,&dry_frames));
    assert(!kv_effects_valid((KvEffects){NAN,0,0.3}));
    assert(!kv_effects_valid((KvEffects){0,0,0}));
    kv_piano_free(piano);
    puts("Recorded piano, stereo playback, effect tails, Freeverb and stereo delay timing, peak safety and invalid input passed.");
    return 0;
}
