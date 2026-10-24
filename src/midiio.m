#import "midiio.h"
#import "controls.h"
#import <CoreMIDI/CoreMIDI.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@interface KvMidi () {
    BOOL _sounding[2][128];
}
@property(nonatomic) MIDIClientRef client;
@property(nonatomic) MIDIEndpointRef source;
@property(nonatomic) MIDIPortRef output;
@property(nonatomic) MIDIPortRef input;
@property(nonatomic) NSMutableSet<NSNumber *> *connected;
@end
static NSString *EndpointName(MIDIEndpointRef endpoint) {
    CFStringRef name=NULL; if(MIDIObjectGetStringProperty(endpoint,kMIDIPropertyDisplayName,&name)!=noErr || !name) return @"MIDI";
    return CFBridgingRelease(name);
}
@implementation KvMidi
- (instancetype)init {
    if((self=[super init])) {
        _connected=[NSMutableSet set];
        __weak KvMidi *weakSelf=self;
        OSStatus status=MIDIClientCreateWithBlock(CFSTR("Tonora"),&_client,^(const MIDINotification *message) {
            if(message->messageID==kMIDIMsgObjectAdded || message->messageID==kMIDIMsgObjectRemoved || message->messageID==kMIDIMsgSetupChanged) {
                dispatch_async(dispatch_get_main_queue(),^{ KvMidi *midi=weakSelf; if(!midi) return; if(midi.inputEnabled) [midi connectSources]; if(midi.onDevicesChanged) midi.onDevicesChanged(); });
            }
        });
        if(status!=noErr) return self;
        if(MIDISourceCreate(_client,CFSTR("Tonora"),&_source)!=noErr) _source=0;
        if(MIDIOutputPortCreate(_client,CFSTR("Tonora Out"),&_output)!=noErr) _output=0;
        status=MIDIInputPortCreateWithBlock(_client,CFSTR("Tonora In"),&_input,^(const MIDIPacketList *list,void *connection) {
            (void)connection; const MIDIPacket *packet=&list->packet[0];
            for(UInt32 i=0;i<list->numPackets;i++) {
                const Byte *d=packet->data; UInt16 length=packet->length; Byte running=0;
                for(UInt16 at=0;at<length;) {
                    Byte status=d[at]; if(status&0x80) { running=status; at++; } else status=running;
                    Byte kind=status&0xf0;
                    if((kind==0x90 || kind==0x80) && at+1<length) {
                        int midi=d[at],velocity=d[at+1]; at+=2; BOOL on=kind==0x90 && velocity>0;
                        dispatch_async(dispatch_get_main_queue(),^{ KvMidi *self2=weakSelf; if(self2 && self2.inputEnabled && self2.onNote) self2.onNote(midi,velocity,on); });
                    } else if(kind==0xb0 && at+1<length) {
                        int controller=d[at],value=d[at+1]; at+=2;
                        dispatch_async(dispatch_get_main_queue(),^{ KvMidi *self2=weakSelf; if(self2 && self2.inputEnabled && self2.onControl) self2.onControl(controller,value); });
                    } else if(kind==0xc0 || kind==0xd0) at+=1; else if(kind>=0x80 && kind<=0xe0) at+=2; else break;
                }
                packet=MIDIPacketNext(packet);
            }
        });
        if(status!=noErr) _input=0;
        _available=_client!=0 && _source!=0 && _output!=0;
    }
    return self;
}
- (void)dealloc {
    [self allNotesOff];
    if(_input) MIDIPortDispose(_input); if(_output) MIDIPortDispose(_output); if(_source) MIDIEndpointDispose(_source); if(_client) MIDIClientDispose(_client);
}
- (NSArray<NSString *> *)destinationNames {
    NSMutableArray *names=[NSMutableArray arrayWithObject:T(@"Виртуальный порт «Tonora»")];
    ItemCount count=MIDIGetNumberOfDestinations();
    for(ItemCount i=0;i<count;i++) { MIDIEndpointRef endpoint=MIDIGetDestination(i); if(endpoint && endpoint!=_source) [names addObject:EndpointName(endpoint)]; }
    return names;
}
- (NSUInteger)sourceCount { NSUInteger n=0; ItemCount count=MIDIGetNumberOfSources(); for(ItemCount i=0;i<count;i++) if(MIDIGetSource(i)!=_source) n++; return n; }
- (void)connectSources {
    if(!_input) return;
    ItemCount count=MIDIGetNumberOfSources();
    for(ItemCount i=0;i<count;i++) {
        MIDIEndpointRef endpoint=MIDIGetSource(i); if(!endpoint || endpoint==_source) continue;
        NSNumber *key=@((unsigned long)endpoint);
        if(![_connected containsObject:key] && MIDIPortConnectSource(_input,endpoint,NULL)==noErr) [_connected addObject:key];
    }
}
- (void)setInputEnabled:(BOOL)inputEnabled {
    _inputEnabled=inputEnabled;
    if(inputEnabled) [self connectSources];
    else { if(_input) for(NSNumber *key in _connected) MIDIPortDisconnectSource(_input,(MIDIEndpointRef)key.unsignedLongValue); [_connected removeAllObjects]; }
}
- (MIDIEndpointRef)selectedDestination {
    if(_destinationIndex<=0) return 0;
    NSInteger index=0; ItemCount count=MIDIGetNumberOfDestinations();
    for(ItemCount i=0;i<count;i++) { MIDIEndpointRef endpoint=MIDIGetDestination(i); if(!endpoint || endpoint==_source) continue; if(++index==_destinationIndex) return endpoint; }
    return 0;
}
- (void)send:(const Byte *)bytes length:(int)length {
    if(!_available) return;
    Byte buffer[64]; MIDIPacketList *list=(MIDIPacketList *)buffer; MIDIPacket *packet=MIDIPacketListInit(list);
    packet=MIDIPacketListAdd(list,sizeof(buffer),packet,0,(ByteCount)length,bytes); if(!packet) return;
    MIDIReceived(_source,list);
    MIDIEndpointRef destination=[self selectedDestination]; if(destination) MIDISend(_output,destination,list);
}
- (void)noteOn:(int)midi velocity:(int)velocity channel:(int)channel {
    if(midi<0 || midi>127 || channel<0 || channel>1) return; if(velocity<1) velocity=1; if(velocity>127) velocity=127;
    Byte bytes[3]={(Byte)(0x90|channel),(Byte)midi,(Byte)velocity}; [self send:bytes length:3]; _sounding[channel][midi]=YES;
}
- (void)noteOff:(int)midi channel:(int)channel {
    if(midi<0 || midi>127 || channel<0 || channel>1) return;
    Byte bytes[3]={(Byte)(0x80|channel),(Byte)midi,64}; [self send:bytes length:3]; _sounding[channel][midi]=NO;
}
- (void)allNotesOff { for(int channel=0;channel<2;channel++) for(int midi=0;midi<128;midi++) if(_sounding[channel][midi]) [self noteOff:midi channel:channel]; }
@end
