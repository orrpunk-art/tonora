#import <Cocoa/Cocoa.h>
#import "brand.h"

static NSData *renderIcon(NSInteger size) {
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    if(!bitmap) return nil;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
    NSAffineTransform *flip=[NSAffineTransform transform];
    [flip translateXBy:0 yBy:size]; [flip scaleXBy:1 yBy:-1]; [flip concat];
    CGFloat inset=size*0.047;
    KvDrawBrand(NSMakeRect(inset,inset,size-2*inset,size-2*inset));
    [NSGraphicsContext restoreGraphicsState];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if(argc<2 || argc>3) return 1;
        NSString *output=[NSString stringWithUTF8String:argv[1]];
        NSString *iconset=[output stringByAppendingString:@".iconset"];
        NSError *error=nil;
        if(![NSFileManager.defaultManager createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:&error]) { NSLog(@"%@",error); return 1; }
        const NSInteger sizes[]={16,32,128,256,512};
        for(int i=0;i<5;i++) for(int scale=1;scale<=2;scale++) {
            NSString *name=[NSString stringWithFormat:@"icon_%ldx%ld%@.png",(long)sizes[i],(long)sizes[i],scale==2?@"@2x":@""];
            NSData *png=renderIcon(sizes[i]*scale);
            if(!png || ![png writeToFile:[iconset stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error]) { NSLog(@"Cannot write icon: %@",error); return 1; }
        }
        NSTask *task=[NSTask new]; task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/iconutil"];
        task.arguments=@[@"-c",@"icns",@"-o",output,iconset];
        if(![task launchAndReturnError:&error]) { NSLog(@"%@",error); return 1; }
        [task waitUntilExit]; if(task.terminationStatus!=0) return 1;
        if(argc==3 && ![renderIcon(1024) writeToFile:[NSString stringWithUTF8String:argv[2]] options:NSDataWritingAtomic error:&error]) { NSLog(@"%@",error); return 1; }
    }
    return 0;
}
