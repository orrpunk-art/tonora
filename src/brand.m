#import "brand.h"
void KvDrawBrand(NSRect rect) {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *transform=[NSAffineTransform transform];
    [transform translateXBy:rect.origin.x yBy:rect.origin.y];
    [transform scaleXBy:rect.size.width/100 yBy:rect.size.height/100];
    [transform concat];
    [[NSColor colorWithCalibratedRed:0.075 green:0.13 blue:0.22 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0,0,100,100) xRadius:23 yRadius:23] fill];
    NSBezierPath *orbit=[NSBezierPath bezierPath];
    [orbit moveToPoint:NSMakePoint(70,24)];
    [orbit curveToPoint:NSMakePoint(19,50) controlPoint1:NSMakePoint(48,8) controlPoint2:NSMakePoint(19,22)];
    [orbit curveToPoint:NSMakePoint(70,76) controlPoint1:NSMakePoint(19,78) controlPoint2:NSMakePoint(48,92)];
    [[NSColor colorWithCalibratedRed:0.96 green:0.95 blue:0.89 alpha:1] setStroke];
    orbit.lineWidth=4; orbit.lineCapStyle=NSLineCapStyleRound; [orbit stroke];
    NSBezierPath *letter=[NSBezierPath bezierPath];
    [letter moveToPoint:NSMakePoint(37,34)]; [letter lineToPoint:NSMakePoint(65,34)];
    [letter moveToPoint:NSMakePoint(51,34)]; [letter lineToPoint:NSMakePoint(51,70)];
    letter.lineWidth=6; letter.lineCapStyle=NSLineCapStyleRound; letter.lineJoinStyle=NSLineJoinStyleRound; [letter stroke];
    [[NSColor colorWithCalibratedRed:0.28 green:0.85 blue:0.72 alpha:1] setFill];
    for(int i=0;i<3;i++) {
        NSPoint p=i==0?NSMakePoint(77,29):i==1?NSMakePoint(84,50):NSMakePoint(77,71);
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x-3.7,p.y-3.7,7.4,7.4)] fill];
    }
    [NSGraphicsContext restoreGraphicsState];
}
