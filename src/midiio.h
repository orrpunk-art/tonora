#import <Foundation/Foundation.h>
/* CoreMIDI bridge: a virtual source "Tonora" that DAWs can record from, an output port to any
   destination, and an input port that listens to every connected keyboard. Callbacks arrive on the main thread. */
@interface KvMidi : NSObject
@property(nonatomic,readonly) BOOL available;
@property(nonatomic,copy) void (^onNote)(int midi,int velocity,BOOL on);
@property(nonatomic,copy) void (^onControl)(int controller,int value);   /* control change: mod wheel, expression, pedal */
@property(nonatomic,copy) void (^onDevicesChanged)(void);
@property(nonatomic) BOOL inputEnabled;
/* Index 0 is always the virtual port; the rest are hardware or software destinations by name. */
- (NSArray<NSString *> *)destinationNames;
- (NSUInteger)sourceCount;
@property(nonatomic) NSInteger destinationIndex;
- (void)noteOn:(int)midi velocity:(int)velocity channel:(int)channel;
- (void)noteOff:(int)midi channel:(int)channel;
- (void)allNotesOff;
@end
