// Experimental native presentation host. Included after WindowWrapper and the
// registry. It shares the logical window, Metal device and command submission.
#import <QuartzCore/CAShapeLayer.h>
#import <QuartzCore/CATransaction.h>
static BOOL zenitHeaderVisible(NSView *view) {
    return view.window.visible && (view.window.occlusionState&NSWindowOcclusionStateVisible) && !NSIsEmptyRect(view.visibleRect);
}

@interface ZenitHeaderView : NSView
@property (nonatomic) CGFloat controlsInset;
@end
@implementation ZenitHeaderView
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (NSView *)hitTest:(NSPoint)point {
    if([self convertPoint:point fromView:self.superview].x<self.controlsInset) return nil;
    return [super hitTest:point];
}
- (void)mouseDown:(NSEvent *)event {} // The owner pump queues each event once.
- (void)rightMouseDown:(NSEvent *)event {}
@end

// Paint behind the actual NSButtons without participating in native hit testing.
@interface ZenitControlsBackgroundView : NSView
@end
@implementation ZenitControlsBackgroundView
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@interface ZenitHeaderBodyView : NSView
@property (nonatomic, weak) ZenitFullscreenHeaderHost *host;
@end
@implementation ZenitHeaderBodyView
- (void)layout {
    [super layout];
    MetalView *view=self.host.owner.metalView;
    if(!self.host.bodyReserveCommitted)
        self.host.bodyReserve=MAX(self.host.height,self.bounds.size.height-NSMaxY(self.host.owner.window.contentLayoutRect));
    CGFloat reserve=(!self.host.active || self.host.policy==2) ? self.host.bodyReserve : 0;
    CGFloat bodyHeight=MAX(1,self.bounds.size.height-reserve);
    [CATransaction begin];[CATransaction setDisableActions:YES];
    CAShapeLayer *mask=[CAShapeLayer layer];
    CGPathRef path=CGPathCreateWithRect(CGRectMake(0,0,self.bounds.size.width,bodyHeight),NULL);
    mask.path=path;CGPathRelease(path);self.layer.mask=mask;
    // setFrameSize synchronously renders. Publish clipping first so that
    // callback sees a complete layout, and never redraw for an unchanged frame.
    NSRect frame=NSMakeRect(0,0,self.bounds.size.width,bodyHeight+self.host.height);
    if(!NSEqualRects(view.frame,frame)) view.frame=frame;
    [CATransaction commit];
}
@end

@interface ZenitFullscreenHeaderHost ()
@property (nonatomic, strong) NSTitlebarAccessoryViewController *accessory;
@property (nonatomic, strong) NSToolbar *savedToolbar;
@property (nonatomic) NSWindowToolbarStyle savedToolbarStyle;
@property (nonatomic, strong) ZenitHeaderBodyView *body;
@property (nonatomic, strong) NSLock *drawableLock;
@property (nonatomic, strong) id<CAMetalDrawable> cachedDrawable;
@property (nonatomic) BOOL acquisitionPending;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) NSUInteger acquisitionSerial;

@property (nonatomic) BOOL wasVisible;
@property (nonatomic) BOOL hasPresented;
@property (nonatomic, strong) NSColor *background;
@property (nonatomic, strong) ZenitControlsBackgroundView *controlsBackground;
@property (nonatomic, strong) NSArray<NSButton *> *observedButtons;
@property (nonatomic) BOOL correctingButtonAlpha;
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) CALayer *retainedPaint;
@property (nonatomic) CGFloat retainedInset;
@property (nonatomic) BOOL windowedPaintReady;
@end
static void zenitReleaseHeaderPixels(void *info,const void *data,size_t size) { free((void *)data); }
@implementation ZenitFullscreenHeaderHost
- (void)commitBodyLayout {
    if(!self.active) return;
    [self installBody];
    [self.body setNeedsLayout:YES];[self.body layoutSubtreeIfNeeded];
    // The menu bar later changes contentLayoutRect while sliding over the
    // fullscreen surface. It must not reflow the pinned Header's body.
    self.bodyReserveCommitted=YES;
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context!=(__bridge void *)self) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];return;
    }
    // AppKit fades the controls independently when the system menu bar retracts.
    // Correct the public property synchronously, within that same transaction;
    // a per-frame correction lets a faded frame reach the compositor first.
    NSButton *button=object;
    if(!self.active || self.exiting || self.correctingButtonAlpha || button.alphaValue==1) return;
    self.correctingButtonAlpha=YES;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    button.alphaValue=1;
    [CATransaction commit];self.correctingButtonAlpha=NO;
}
- (void)observeNativeButtons {
    WindowWrapper *w=self.owner;
    NSMutableArray<NSButton *> *buttons=[NSMutableArray new];
    for(NSNumber *kind in @[@(NSWindowCloseButton),@(NSWindowMiniaturizeButton),@(NSWindowZoomButton)]) {
        NSButton *button=[w.window standardWindowButton:kind.integerValue];
        if(button) [buttons addObject:button];
    }
    if([self.observedButtons isEqualToArray:buttons]) return;
    [self stopObservingNativeButtons];self.observedButtons=buttons;
    for(NSButton *button in self.observedButtons) {
        [button addObserver:self forKeyPath:@"alphaValue" options:NSKeyValueObservingOptionInitial context:(__bridge void *)self];
    }
}
- (void)stopObservingNativeButtons {
    for(NSButton *button in self.observedButtons)
        [button removeObserver:self forKeyPath:@"alphaValue" context:(__bridge void *)self];
    self.observedButtons=nil;
}
- (void)prepare {
    if(self.header || self.policy==0 || !self.owner.window) return;
    WindowWrapper *w=self.owner;
    self.savedToolbar=w.window.toolbar;self.savedToolbarStyle=w.window.toolbarStyle;
    if(!self.drawableLock) self.drawableLock=[NSLock new];
    [self.drawableLock lock];self.generation++;self.acquisitionSerial++;self.acquisitionPending=NO;[self.drawableLock unlock];
    self.header=[[ZenitHeaderView alloc] initWithFrame:NSMakeRect(0,0,w.window.frame.size.width,self.height)];
    self.header.wantsLayer=YES;
    CAMetalLayer *layer=[CAMetalLayer layer];layer.device=w.metalView.metalLayer.device;
    layer.pixelFormat=w.metalView.metalLayer.pixelFormat;layer.framebufferOnly=NO;
    layer.allowsNextDrawableTimeout=YES;layer.maximumDrawableCount=3;
    // The original client Header remains visible until this layer has a frame.
    layer.opacity=0;
    self.header.layer=[CALayer layer];self.header.layer.opacity=0;
    self.retainedPaint=[CALayer layer];
    self.retainedPaint.contentsGravity=kCAGravityTopLeft;
    self.retainedPaint.anchorPoint=CGPointZero;
    [self.header.layer addSublayer:self.retainedPaint];
    self.header.layer.contentsScale=w.window.backingScaleFactor;
    layer.opacity=1;layer.opaque=NO;layer.frame=self.header.bounds;
    [self.header.layer addSublayer:layer];self.metalLayer=layer;
    self.accessory=[NSTitlebarAccessoryViewController new];self.accessory.view=self.header;
    self.accessory.layoutAttribute=NSLayoutAttributeTrailing;self.accessory.automaticallyAdjustsSize=NO;
    w.window.toolbar=[[NSToolbar alloc] initWithIdentifier:@"dev.zenit.fullscreen-header"];
    w.window.toolbarStyle=NSWindowToolbarStyleUnifiedCompact;
    w.window.toolbar.visible=YES;
    [w.window addTitlebarAccessoryViewController:self.accessory];
    self.hasPresented=NO;self.windowedPaintReady=NO;w.chromeStateGeneration++;
}
- (void)start {
    if(self.active || self.policy==0 || !self.owner.window) return;
    [self prepare];
    WindowWrapper *w=self.owner;
    // Body and Header already have their stable windowed presentation hosts.
    // Fullscreen entry changes policy, never their native view ownership.
    self.presentationEpoch++;
    self.active=YES;self.exiting=NO;self.hasPresented=NO;
    // Freeze the accessory before NSWindow captures its transition surface,
    // rather than switching between Metal and retained paint mid-animation.
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.metalLayer.opacity=0;[self update];[CATransaction commit];
    [CATransaction flush];
    [self observeNativeButtons];
    w.window.toolbar.visible=self.policy==2 || self.locked;
    [w.window makeFirstResponder:w.metalView];[self.body setNeedsLayout:YES];
    [self.body layoutSubtreeIfNeeded];w.chromeStateGeneration++;
}
- (void)installBody {
    if(self.body) return;
    WindowWrapper *w=self.owner;
    self.bodyReserve=self.height;self.bodyReserveCommitted=NO;
    self.body=[[ZenitHeaderBodyView alloc] initWithFrame:w.metalView.frame];self.body.host=self;
    self.body.wantsLayer=YES;self.body.layer.masksToBounds=YES;
    [w.metalView removeFromSuperview];w.window.contentView=self.body;
    w.metalView.autoresizingMask=NSViewNotSizable;[self.body addSubview:w.metalView];
    [self.body setNeedsLayout:YES];[self.body layoutSubtreeIfNeeded];
}
- (void)beginExit {
    if(!self.active || self.exiting) return;
    self.presentationEpoch++;
    // AppKit animates the existing presentation. Keep that completed Metal
    // surface intact until its normal windowed resize can be submitted.
    self.exiting=YES;
}
- (void)finishExit {
    if(!self.header) return;
    self.presentationEpoch++;
    // Normal exit is a size/policy update. Preserve the accessory, body,
    // completed paint, drawable acquisition and native control background.
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.active=NO;self.exiting=NO;self.pendingFullscreen=NO;
    self.bodyReserveCommitted=NO;
    self.windowedPaintReady=NO;
    // The fullscreen drawable has the old width. Reveal the completed
    // windowed paint before resizing its layer; keep it until a matching GPU
    // submission completes, so the old texture cannot stretch into the Header.
    self.metalLayer.opacity=0;
    [self stopObservingNativeButtons];
    [self update];
    [CATransaction commit];
}
- (void)stop {
    if(!self.header) return;
    self.presentationEpoch++;
    WindowWrapper *w=self.owner;self.active=NO;self.exiting=NO;
    self.pendingFullscreen=NO;
    [self stopObservingNativeButtons];
    [self.controlsBackground removeFromSuperview];self.controlsBackground=nil;
    [self.drawableLock lock];self.generation++;self.acquisitionSerial++;self.cachedDrawable=nil;self.acquisitionPending=NO;[self.drawableLock unlock];
    [self.accessory removeFromParentViewController];
    if(self.body) {
        [w.metalView removeFromSuperview];w.window.contentView=w.metalView;
        w.metalView.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        w.metalView.frame=NSMakeRect(0,0,self.body.bounds.size.width,self.body.bounds.size.height);
    }
    w.window.toolbar=self.savedToolbar;w.window.toolbarStyle=self.savedToolbarStyle;
    self.accessory=nil;self.header=nil;self.metalLayer=nil;self.retainedPaint=nil;self.body=nil;self.savedToolbar=nil;
    [w.window makeFirstResponder:w.metalView];w.chromeStateGeneration++;
}
- (void)update {
    if(!self.header) return;
    WindowWrapper *w=self.owner;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    BOOL reveal=!self.active || self.policy==2 || self.locked;
    if(w.window.toolbar.visible!=reveal) {
        w.window.toolbar.visible=reveal;
        if(reveal && self.active) { // Fullscreen-only workaround for accessory sibling order.
            [self.accessory removeFromParentViewController];
            [w.window addTitlebarAccessoryViewController:self.accessory];
        }
        w.chromeStateGeneration++;
    }
    if(self.header.frame.size.width!=w.window.frame.size.width || (reveal && self.header.frame.size.height!=self.height))
        self.header.frame=NSMakeRect(0,0,w.window.frame.size.width,self.height);
    [self.body setNeedsLayout:YES];[self.body layoutSubtreeIfNeeded];
    BOOL visible=zenitHeaderVisible(self.header);
    self.header.layer.backgroundColor=self.background.CGColor;
    if(self.active) [self observeNativeButtons];
    if(visible!=self.wasVisible) {self.wasVisible=visible;w.chromeStateGeneration++;}
    CGFloat inset=0;
    for(NSNumber *kind in @[@(NSWindowCloseButton),@(NSWindowMiniaturizeButton),@(NSWindowZoomButton)]) {
        NSButton *button=[w.window standardWindowButton:kind.integerValue];
        NSRect r=[self.header convertRect:button.bounds fromView:button];inset=MAX(inset,NSMaxX(r)+8);
    }
    if(w.chromeFullscreenTransition && self.active && self.retainedPaint.contents) inset=self.retainedInset;
    else if(inset<=0) inset=((ZenitHeaderView *)self.header).controlsInset;
    ((ZenitHeaderView *)self.header).controlsInset=inset;
    NSButton *close=[w.window standardWindowButton:NSWindowCloseButton];
    if(self.background && close.superview) {
        if(!self.controlsBackground) {
            self.controlsBackground=[ZenitControlsBackgroundView new];
            self.controlsBackground.wantsLayer=YES;
        }
        if(self.controlsBackground.superview!=close.superview)
            [close.superview addSubview:self.controlsBackground positioned:NSWindowBelow relativeTo:close];
        // AppKit's native titlebar background sits above the accessory during
        // reparenting. Paint its exposed area, but punch out the exact GPU
        // rectangle so sibling ordering can never cover the client content.
        self.controlsBackground.frame=close.superview.bounds;
        NSRect gpu=[self.controlsBackground convertRect:NSMakeRect(inset,0,MAX(0,self.header.bounds.size.width-inset),self.header.bounds.size.height) fromView:self.header];
        CGMutablePathRef exposed=CGPathCreateMutable();
        CGPathAddRect(exposed,NULL,NSRectToCGRect(self.controlsBackground.bounds));
        CGPathAddRect(exposed,NULL,NSRectToCGRect(gpu));
        CAShapeLayer *nativeMask=[CAShapeLayer layer];nativeMask.fillRule=kCAFillRuleEvenOdd;
        nativeMask.path=exposed;CGPathRelease(exposed);self.controlsBackground.layer.mask=nativeMask;
        self.controlsBackground.layer.backgroundColor=self.background.CGColor;
    }
    CAShapeLayer *mask=[CAShapeLayer layer];
    CGPathRef path=CGPathCreateWithRect(CGRectMake(inset,0,MAX(0,self.header.bounds.size.width-inset),self.header.bounds.size.height),NULL);
    mask.path=path;CGPathRelease(path);self.header.layer.mask=mask;
    if(!self.exiting) self.metalLayer.frame=self.header.bounds;
    // Do not translate paint using model-space button frames while AppKit
    // animates their presentation geometry. The entire strip stays rigid.
    self.retainedPaint.position=CGPointZero;
    if(w.chromeFullscreenTransition && !self.exiting && self.retainedPaint.contents) self.metalLayer.opacity=0;
    if(getenv("ZENIT_DEBUG_HEADER")) fprintf(stderr,"[header-layout] transition=%d frame=%s bounds=%s inset=%g retained=%g\n",w.chromeFullscreenTransition,NSStringFromRect(self.header.frame).UTF8String,NSStringFromRect(self.header.bounds).UTF8String,inset,self.retainedInset);
    [CATransaction commit];
}
- (void)prefetch {
    if(self.exiting || !self.header || !zenitHeaderVisible(self.header)) return;
    CAMetalLayer *layer=self.metalLayer;
    CGFloat scale=zenitRenderScaleOverride();
    layer.contentsScale=scale>0?scale:self.owner.window.backingScaleFactor;
    self.header.layer.contentsScale=layer.contentsScale;
    CGSize size=CGSizeMake(self.header.bounds.size.width*layer.contentsScale,self.header.bounds.size.height*layer.contentsScale);
    if(!CGSizeEqualToSize(layer.drawableSize,size)) {
        [self.drawableLock lock];self.generation++;self.cachedDrawable=nil;[self.drawableLock unlock];
        self.hasPresented=NO;
        [CATransaction begin];[CATransaction setDisableActions:YES];layer.opacity=0;[CATransaction commit];
        layer.drawableSize=size;
    }
    [self.drawableLock lock];
    if(self.acquisitionPending || self.cachedDrawable) {[self.drawableLock unlock];return;}
    self.acquisitionPending=YES;NSUInteger generation=self.generation,serial=++self.acquisitionSerial;
    [self.drawableLock unlock];
    // Acquisition can wait for AppKit's clipped/reparented layer. It never
    // blocks the owner event loop or the body submission.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{
        @autoreleasepool {
            id<CAMetalDrawable> drawable=[layer nextDrawable];
            if(getenv("ZENIT_DEBUG_HEADER")) fprintf(stderr,"[header] acquire %p %lux%lu\n",(__bridge void *)drawable,(unsigned long)drawable.texture.width,(unsigned long)drawable.texture.height);
            [self.drawableLock lock];
            BOOL valid=generation==self.generation && serial==self.acquisitionSerial;
            if(valid) self.cachedDrawable=drawable;
            if(serial==self.acquisitionSerial) self.acquisitionPending=NO;
            [self.drawableLock unlock];
            dispatch_async(dispatch_get_main_queue(),^{
                if(self.header && !self.hasPresented) {self.owner.chromeStateGeneration++;macos_post_empty_event();}
            });
        }
    });
}
- (void)encodeTexture:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)buffer {
    if(self.exiting || !self.header || !zenitHeaderVisible(self.header)) return;
    // CAMetalLayer's drawable can disappear when AppKit reparents its view to
    // the fullscreen toolbar window. Keep a completed windowed Header image
    // behind it, rather than exposing an empty native layer during handoff.
    if(!self.active && (!self.owner.chromeFullscreenTransition || self.pendingFullscreen) && (source.pixelFormat==MTLPixelFormatBGRA8Unorm || source.pixelFormat==MTLPixelFormatRGBA8Unorm)) {
        NSUInteger h=MIN(source.height,(NSUInteger)ceil(self.height*self.metalLayer.contentsScale));
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat width:source.width height:h mipmapped:NO];
        desc.storageMode=MTLStorageModeShared;
        id<MTLTexture> snapshot=[source.device newTextureWithDescriptor:desc];
        if(snapshot) {
            id<MTLBlitCommandEncoder> copy=[buffer blitCommandEncoder];
            [copy copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(source.width,h,1) toTexture:snapshot destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
            [copy endEncoding];NSUInteger generation=self.generation, epoch=self.presentationEpoch;
            CGFloat capturedInset=((ZenitHeaderView *)self.header).controlsInset, capturedScale=self.metalLayer.contentsScale;
            BOOL capturedBodyReady=self.body!=nil;
            CGSize capturedSourceSize=CGSizeMake(source.width,source.height);
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                if(completed.status!=MTLCommandBufferStatusCompleted) return;
                size_t row=snapshot.width*4,size=row*snapshot.height;void *pixels=malloc(size);
                if(!pixels) return;
                [snapshot getBytes:pixels bytesPerRow:row fromRegion:MTLRegionMake2D(0,0,snapshot.width,snapshot.height) mipmapLevel:0];
                CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,pixels,size,zenitReleaseHeaderPixels);
                if(!provider) {free(pixels);return;}
                CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGBitmapInfo format=snapshot.pixelFormat==MTLPixelFormatBGRA8Unorm ? kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst : kCGBitmapByteOrder32Big|kCGImageAlphaPremultipliedLast;
                CGImageRef image=CGImageCreate(snapshot.width,snapshot.height,8,32,row,color,format,provider,NULL,NO,kCGRenderingIntentDefault);
                CGColorSpaceRelease(color);CGDataProviderRelease(provider);
                if(!image) return;
                dispatch_async(dispatch_get_main_queue(),^{
                    if(generation==self.generation && epoch==self.presentationEpoch && self.header && !self.active && !self.exiting) {
                        [CATransaction begin];[CATransaction setDisableActions:YES];
                        self.retainedPaint.contents=(__bridge id)image;
                        self.retainedPaint.contentsScale=capturedScale;
                        self.retainedPaint.bounds=CGRectMake(0,0,snapshot.width/capturedScale,snapshot.height/capturedScale);
                        self.retainedInset=capturedInset;
                        self.retainedPaint.position=CGPointZero;
                        self.header.layer.opacity=1;
                        [self installBody];
                        self.windowedPaintReady=capturedBodyReady &&
                            CGSizeEqualToSize(capturedSourceSize,self.owner.metalView.metalLayer.drawableSize);
                        [CATransaction commit];
                        if(!self.windowedPaintReady) {
                            self.owner.chromeStateGeneration++;macos_post_empty_event();
                        }
                        // The first strip precedes body installation. Enter
                        // only after a completed frame of the installed body's
                        // final viewport, never from that earlier layout.
                        if(self.pendingFullscreen && self.windowedPaintReady) {
                            self.pendingFullscreen=NO;[self.owner.window toggleFullScreen:nil];
                        }
                    }
                    CGImageRelease(image);
                });
            }];
        }
    }
    [self.drawableLock lock];id<CAMetalDrawable> drawable=self.cachedDrawable;self.cachedDrawable=nil;[self.drawableLock unlock];
    if(getenv("ZENIT_DEBUG_HEADER")) fprintf(stderr,"[header] encode src=%lux%lu dst=%lux%lu visible=%g window=%ld frame=%s shown=%d level=%ld alpha=%g\n",(unsigned long)source.width,(unsigned long)source.height,(unsigned long)drawable.texture.width,(unsigned long)drawable.texture.height,self.header.visibleRect.size.height,(long)self.header.window.windowNumber,NSStringFromRect(self.header.window.frame).UTF8String,self.header.window.visible,(long)self.header.window.level,[self.owner.window standardWindowButton:NSWindowCloseButton].alphaValue);
    if(!self.owner.chromeFullscreenTransition && drawable && drawable.texture.width==source.width && drawable.texture.height<=source.height) {
        id<MTLBlitCommandEncoder> blit=[buffer blitCommandEncoder];
        [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(source.width,drawable.texture.height,1) toTexture:drawable.texture
            destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [blit endEncoding];[buffer presentDrawable:drawable];self.hasPresented=YES;
        if(self.header.layer.opacity==0 || self.metalLayer.opacity==0) {
            NSUInteger generation=self.generation, epoch=self.presentationEpoch;
            CGRect capturedBounds=self.header.bounds;
            CGSize capturedDrawableSize=self.metalLayer.drawableSize;
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                if(completed.status!=MTLCommandBufferStatusCompleted) return;
                dispatch_async(dispatch_get_main_queue(),^{
                    if(generation!=self.generation || epoch!=self.presentationEpoch || !self.header || self.exiting || self.owner.chromeFullscreenTransition ||
                        !CGRectEqualToRect(capturedBounds,self.header.bounds) ||
                        !CGSizeEqualToSize(capturedDrawableSize,self.metalLayer.drawableSize)) return;
                    [CATransaction begin];[CATransaction setDisableActions:YES];
                    self.header.layer.opacity=1;self.metalLayer.opacity=1;[CATransaction commit];
                });
            }];
        }
    }
    [self prefetch];
}
@end

static NSPoint zenitLogicalScreenPoint(WindowWrapper *w,NSPoint screen) {
    ZenitFullscreenHeaderHost *host=w.fullscreenHeader;
    if(host.active && zenitHeaderVisible(host.header)) {
        NSPoint p=[host.header convertPoint:[host.header.window convertPointFromScreen:screen] fromView:nil];
        if(NSPointInRect(p,host.header.visibleRect)) return NSMakePoint(p.x,host.height-p.y);
    }
    NSPoint p=[w.metalView convertPoint:[w.window convertPointFromScreen:screen] fromView:nil];
    return NSMakePoint(p.x,w.metalView.bounds.size.height-p.y);
}
static NSPoint zenitLogicalEventPoint(WindowWrapper *w,NSEvent *event) {
    return zenitLogicalScreenPoint(w,event.window?[event.window convertPointToScreen:event.locationInWindow]:event.locationInWindow);
}
static NSRect zenitLogicalScreenRect(WindowWrapper *w,CGFloat x,CGFloat y,CGFloat width,CGFloat height) {
    if(!w) return NSZeroRect;
    NSView *view=w.metalView;
    if(w.fullscreenHeader.active && y>=0 && y+height<=w.fullscreenHeader.height+.5) {
        view=w.fullscreenHeader.header;
        if(!zenitHeaderVisible(view)) return NSZeroRect;
    }
    NSRect local=NSMakeRect(x,view.bounds.size.height-y-height,width,height);
    return [view.window convertRectToScreen:[view convertRect:local toView:nil]];
}
static BOOL zenitLogicalHeaderHidden(WindowWrapper *w,CGFloat y,CGFloat height) {
    return w.fullscreenHeader.active && y>=0 && y+height<=w.fullscreenHeader.height+.5 && !zenitHeaderVisible(w.fullscreenHeader.header);
}
int macos_fullscreen_header_configure(void *owner,int policy,float height) {
    WindowWrapper *w=(__bridge WindowWrapper *)owner;
    if(!w.window || policy<0 || policy>2 || !isfinite(height) || height<=0) return 0;
    if(policy && (!(w.window.styleMask&NSWindowStyleMaskTitled) || w.chromeHideControls)) return 0;
    if(!w.fullscreenHeader) {w.fullscreenHeader=[ZenitFullscreenHeaderHost new];w.fullscreenHeader.owner=w;}
    w.fullscreenHeader.height=height;w.fullscreenHeader.policy=policy;
    if(!policy) [w.fullscreenHeader stop];
    else if(w.window.styleMask&NSWindowStyleMaskFullScreen) [w.fullscreenHeader start];
    else [w.fullscreenHeader prepare];
    return 1;
}
void macos_fullscreen_header_layout(void *owner,int locked,float *offsetX,float *offsetY) {
    WindowWrapper *w=(__bridge WindowWrapper *)owner;ZenitFullscreenHeaderHost *host=w.fullscreenHeader;
    host.locked=!!locked;[host update];*offsetX=0;*offsetY=0;
    [host prefetch];
    if(!host.active || !host.header.window) return;
    NSPoint screen=[host.header.window convertPointToScreen:[host.header convertPoint:NSMakePoint(0,host.height) toView:nil]];
    NSPoint body=[w.metalView convertPoint:[w.window convertPointFromScreen:screen] fromView:nil];
    *offsetX=body.x;*offsetY=w.metalView.bounds.size.height-body.y;
}
void macos_fullscreen_header_encode(void *layer,void *texture,void *buffer) {
    for(WindowWrapper *w in g_window_registry.objectEnumerator)
        if((__bridge void *)w.metalView.metalLayer==layer) {
            [w.fullscreenHeader encodeTexture:(__bridge id<MTLTexture>)texture commandBuffer:(__bridge id<MTLCommandBuffer>)buffer];return;
        }
}
void macos_fullscreen_header_background(void *owner,uint8_t r,uint8_t g,uint8_t b,uint8_t a) {
    WindowWrapper *w=(__bridge WindowWrapper *)owner;
    if(!w.fullscreenHeader) return;
    w.fullscreenHeader.background=[NSColor colorWithSRGBRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
}
int macos_fullscreen_header_post_pointer(void *owner,float x,float y,int right) {
    WindowWrapper *w=(__bridge WindowWrapper *)owner;ZenitFullscreenHeaderHost *host=w.fullscreenHeader;
    if(!host.header || !zenitHeaderVisible(host.header)) return 0;
    NSPoint point=[host.header convertPoint:NSMakePoint(x,host.height-y) toView:nil];
    for(NSNumber *type in right?@[@(NSEventTypeRightMouseDown),@(NSEventTypeRightMouseUp)]:@[@(NSEventTypeLeftMouseDown),@(NSEventTypeLeftMouseUp)]) {
        NSEvent *e=[NSEvent mouseEventWithType:type.integerValue location:point modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:host.header.window.windowNumber
            context:nil eventNumber:1 clickCount:1 pressure:1];
        [NSApp postEvent:e atStart:NO];
    }
    return 1;
}
int macos_fullscreen_header_test_hover(void *owner,int edge) {
    WindowWrapper *w=(__bridge WindowWrapper *)owner;
    if(!w.fullscreenHeader.active || !CGPreflightPostEventAccess()) return 0;
    NSRect screen=w.window.screen.frame;
    CGFloat mainHeight=NSScreen.screens.firstObject.frame.size.height;
    CGPoint point=CGPointMake(NSMidX(screen),mainHeight-NSMaxY(screen)+(edge?1:200));
    CGEventRef event=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,point,kCGMouseButtonLeft);
    if(!event) return 0;
    CGEventPost(kCGHIDEventTap,event);CFRelease(event);return 1;
}
int macos_fullscreen_header_test_ready(void *owner) {
    WindowWrapper *w=(__bridge WindowWrapper *)owner;
    return w.fullscreenHeader.windowedPaintReady && w.fullscreenHeader.header.layer.opacity==1;
}
