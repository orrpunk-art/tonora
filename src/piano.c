#include "piano.h"
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RATE 44100
#define BANK_SIZE 192
#define RELEASE 0.45
struct Recording { float *pcm; size_t frames; int midi,layer; float cents; };
struct KvPianoBank { struct Recording samples[BANK_SIZE]; size_t count; };
static const char *filenames[17]={"A2","C3","D#3","F#3","A3","C4","D#4","F#4","A4","C5","D#5","F#5","A5","C6","D#6","F#6","A6"};
void kv_piano_free(KvPianoBank *piano) {
    if(!piano) return;
    for(int i=0;i<BANK_SIZE;i++) free(piano->samples[i].pcm);
    free(piano);
}
KvPianoBank *kv_piano_load(const char *directory) {
    if(!directory) return NULL;
    KvPianoBank *piano=calloc(1,sizeof(*piano)); if(!piano) return NULL;
    char index_path[4096]; int index_length=snprintf(index_path,sizeof(index_path),"%s/index.txt",directory);
    if(index_length<0 || (size_t)index_length>=sizeof(index_path)) { free(piano); return NULL; }
    FILE *index=fopen(index_path,"r");
    char names[BANK_SIZE][256]; int roots[BANK_SIZE]; float gains[BANK_SIZE],skips[BANK_SIZE],cents[BANK_SIZE]; int layers[BANK_SIZE]; size_t count=0;
    if(index) {
        // "root file [gain [skip [layer [cents]]]]" per line: the gain evens out recordings made at different levels,
        // the skip (seconds) starts a slowly swelling recording where its sound is already there, the layer groups
        // recordings of one articulation and dynamic (0 is what kv_piano_sample plays), cents is how sharp it is.
        char line[512];
        while(count<BANK_SIZE && fgets(line,sizeof(line),index)) {
            gains[count]=1; skips[count]=0; layers[count]=0; cents[count]=0;
            int fields=sscanf(line,"%d %255s %f %f %d %f",&roots[count],names[count],&gains[count],&skips[count],&layers[count],&cents[count]);
            if(fields<=0) continue;
            if(fields<2 || roots[count]<21 || roots[count]>108 || strchr(names[count],'/') || !isfinite(gains[count]) || gains[count]<=0 || gains[count]>16 || !isfinite(skips[count]) || skips[count]<0 || skips[count]>2 || layers[count]<0 || layers[count]>=KV_LAYERS || !isfinite(cents[count]) || fabsf(cents[count])>100) { fclose(index); free(piano); return NULL; }
            count++;
        }
        if(fclose(index)!=0 || !count) { free(piano); return NULL; }
    } else {
        count=17; for(size_t i=0;i<count;i++) { snprintf(names[i],sizeof(names[i]),"%sv8.flac",filenames[i]); roots[i]=45+(int)i*3; gains[i]=1; skips[i]=0; layers[i]=0; cents[i]=0; }
    }
    for(size_t i=0;i<count;i++) {
        char path[4096];
        int length=snprintf(path,sizeof(path),"%s/%s",directory,names[i]);
        if(length<0 || (size_t)length>=sizeof(path)) { kv_piano_free(piano); return NULL; }
        CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8 *)path,strlen(path),false);
        if(!url) { kv_piano_free(piano); return NULL; }
        ExtAudioFileRef file=NULL;
        OSStatus status=ExtAudioFileOpenURL(url,&file); CFRelease(url);
        if(status!=noErr) { fprintf(stderr,"Piano open: %s (%d)\n",path,(int)status); kv_piano_free(piano); return NULL; }
        AudioStreamBasicDescription format={0}; format.mSampleRate=RATE; format.mFormatID=kAudioFormatLinearPCM;
        format.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked;
        format.mBytesPerPacket=8; format.mFramesPerPacket=1; format.mBytesPerFrame=8; format.mChannelsPerFrame=2; format.mBitsPerChannel=32;
        status=ExtAudioFileSetProperty(file,kExtAudioFileProperty_ClientDataFormat,sizeof(format),&format);
        // Long notes keep 8 s; short articulations (layers ≥ 2: spiccato, pizzicato) die away within 3 s.
        const UInt32 cap=layers[i]>=2?RATE*3:RATE*8; UInt32 frames=cap;
        float *pcm=calloc((size_t)frames*2,sizeof(float));
        if(status==noErr && pcm) {
            AudioBufferList buffer={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=2,.mDataByteSize=frames*8,.mData=pcm}}};
            status=ExtAudioFileRead(file,&frames,&buffer);
        } else if(!pcm) status=kAudio_MemFullError;
        OSStatus close_status=ExtAudioFileDispose(file);
        if(status!=noErr || close_status!=noErr || frames<2) { free(pcm); kv_piano_free(piano); return NULL; }
        // Remove recording pre-roll, keeping 2 ms before the first audible attack.
        size_t start=0;
        while(start<(size_t)frames-2 && start<RATE/2 && fabsf(pcm[start*2])+fabsf(pcm[start*2+1])<0.00015f) start++;
        start=start>88?start-88:0; start+=(size_t)(skips[i]*RATE); if(start>(size_t)frames/2) start=(size_t)frames/2;
        if(start) { memmove(pcm,pcm+start*2,((size_t)frames-start)*2*sizeof(float)); frames-=(UInt32)start; }
        if(gains[i]!=1) for(size_t j=0;j<(size_t)frames*2;j++) pcm[j]*=gains[i];
        // A recording cut by the cap fades out over 50 ms instead of stopping on a click; the buffer shrinks to fit.
        if(frames+start>=cap) for(size_t j=0;j<2205 && j<frames;j++) for(int c=0;c<2;c++) pcm[(frames-1-j)*2+c]*=(float)j/2205;
        float *fitted=realloc(pcm,(size_t)frames*2*sizeof(float)); if(fitted) pcm=fitted;
        piano->samples[i]=(struct Recording){pcm,frames,roots[i],layers[i],cents[i]}; piano->count++;
    }
    return piano;
}
bool kv_effects_valid(KvEffects effects) {
    return isfinite(effects.reverb) && effects.reverb>=0 && effects.reverb<=1.0f && isfinite(effects.delay) && effects.delay>=0 && effects.delay<=0.6f && isfinite(effects.delay_seconds) && effects.delay_seconds>=0.04 && effects.delay_seconds<=1.2;
}
bool kv_piano_render(const KvPianoBank *piano, const int *notes, size_t count, size_t voices, double seconds, KvEffects effects, float **output, size_t *frames) {
    if(output) *output=NULL;
    if(frames) *frames=0;
    if(!piano || !notes || !output || !frames || !count || !voices || voices>8 || count>256 || count%voices || !isfinite(seconds) || seconds<0.08 || seconds>3 || !kv_effects_valid(effects)) return false;
    for(size_t i=0;i<count;i++) if(notes[i]<21 || notes[i]>108) return false;
    size_t event_frames=(size_t)(seconds*RATE), events=count/voices;
    size_t release_frames=(size_t)(RELEASE*RATE);
    size_t tail=(effects.delay>0 || effects.reverb>0)?RATE*4:0;
    size_t total=events*event_frames+release_frames+tail;
    float *pcm=calloc(total*2,sizeof(float)); if(!pcm) return false;
    for(size_t event=0;event<events;event++) for(size_t voice=0;voice<voices;voice++) {
        int note=notes[event*voices+voice]; KvSampleView view;
        if(!kv_piano_sample(piano,note,&view)) { free(pcm); return false; }
        const KvSampleView *sample=&view;
        double ratio=pow(2,(note-sample->midi)/12.0);
        float gain=0.9f/sqrtf((float)voices);
        for(size_t f=0;f<event_frames+release_frames;f++) {
            double position=f*ratio; size_t at=(size_t)position;
            if(at+1>=sample->frames) break;
            float fraction=(float)(position-at);
            float envelope=f<event_frames?1:(float)(1-(double)(f-event_frames)/release_frames);
            // Short attack and release envelope prevents clicks while retaining the recorded hammer.
            if(f>=event_frames) envelope*=envelope;
            envelope*=f<44?(float)f/44:1;
            for(size_t channel=0;channel<2;channel++) {
                float value=sample->pcm[at*2+channel]*(1-fraction)+sample->pcm[(at+1)*2+channel]*fraction;
                pcm[((event*event_frames)+f)*2+channel]+=value*gain*envelope;
            }
        }
    }
    if(!kv_effects_process(pcm,total,effects)) { free(pcm); return false; }
    // Taper the end of the effect tail to silence.
    for(size_t i=0;i<441 && i<total;i++) for(int channel=0;channel<2;channel++) pcm[(total-1-i)*2+channel]*=(float)i/441;
    *output=pcm; *frames=total; return true;
}

bool kv_piano_layer(const KvPianoBank *piano,int midi,int layer,KvSampleView *sample) {
    if(!piano || !sample || !piano->count || midi<21 || midi>108) return false;
    const struct Recording *nearest=NULL;
    for(size_t i=0;i<piano->count;i++) { const struct Recording *r=&piano->samples[i];
        if(r->layer==layer && (!nearest || abs(r->midi-midi)<abs(nearest->midi-midi))) nearest=r; }
    if(!nearest) return false;
    *sample=(KvSampleView){nearest->pcm,nearest->frames,nearest->midi,nearest->cents}; return true;
}
bool kv_piano_sample(const KvPianoBank *piano,int midi,KvSampleView *sample) { return kv_piano_layer(piano,midi,0,sample); }
