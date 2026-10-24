#import <Cocoa/Cocoa.h>
/* A small "MIDI" handle: drag it onto a DAW track (or the Finder) to drop the clip as a .mid file.
   The provider writes the file at drag start and returns its URL, or nil when there is nothing to export. */
@interface KvMidiDragHandle : NSView <NSDraggingSource>
@property(nonatomic,copy) NSURL *(^provider)(void);
@property(nonatomic,copy) NSString *title;
@property(nonatomic,copy) NSString *hint;   /* hover label; also read by VoiceOver */
@end
