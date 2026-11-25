#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString * const kDLPreferenceDomain = @"com.codex.depthlayer";
static CFStringRef const kDLChangedNotification = CFSTR("com.codex.depthlayer/settingschanged");

static UIImageView *DLOverlayView;
static UIImage *DLCachedForegroundImage;
static NSUInteger DLCachedWallpaperToken;
static NSUInteger DLProcessingToken;
static NSUInteger DLProcessedToken;
static BOOL DLProcessing;
static BOOL DLPasscodeVisible;
static BOOL DLEnabled = YES;
static BOOL DLRefreshQueued;
static BOOL DLDidLogMissingWallpaper;
static NSInteger DLQuality = VNGeneratePersonSegmentationRequestQualityLevelBalanced;
static UIViewController *DLCurrentDashboardController;
static CIContext *DLCIContext;

static BOOL DLReadBool(NSString *key, BOOL fallback) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDLPreferenceDomain);
    if (!value) return fallback;
    BOOL result = CFGetTypeID(value) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef)value) : [(__bridge id)value boolValue];
    CFRelease(value);
    return result;
}

static NSInteger DLReadQuality(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Quality"), (__bridge CFStringRef)kDLPreferenceDomain);
    NSString *quality = value && CFGetTypeID(value) == CFStringGetTypeID() ? [(__bridge NSString *)value lowercaseString] : @"balanced";
    NSInteger result = VNGeneratePersonSegmentationRequestQualityLevelBalanced;
    if ([quality isEqualToString:@"fast"]) result = VNGeneratePersonSegmentationRequestQualityLevelFast;
    else if ([quality isEqualToString:@"accurate"]) result = VNGeneratePersonSegmentationRequestQualityLevelAccurate;
    if (value) CFRelease(value);
    return result;
}

static UIImage *DLImageFromWallpaperView(id wallpaperView) {
    if (!wallpaperView) return nil;
    SEL selector = sel_registerName("wallpaperImage");
    if ([wallpaperView respondsToSelector:selector]) {
        id image = ((id (*)(id, SEL))objc_msgSend)(wallpaperView, selector);
        if ([image isKindOfClass:UIImage.class]) return image;
    }
    if ([wallpaperView isKindOfClass:UIImageView.class]) return ((UIImageView *)wallpaperView).image;
    return nil;
}

static id DLLockWallpaperView(void) {
    Class controllerClass = objc_getClass("SBWallpaperController");
    SEL sharedSelector = sel_registerName("sharedInstance");
    if (!controllerClass || ![controllerClass respondsToSelector:sharedSelector]) return nil;
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
    if (!controller) return nil;

    SEL lockViewSelector = sel_registerName("lockscreenWallpaperView");
    if ([controller respondsToSelector:lockViewSelector]) {
        id view = ((id (*)(id, SEL))objc_msgSend)(controller, lockViewSelector);
        if (view) return view;
    }
    SEL variantSelector = sel_registerName("_wallpaperViewForVariant:");
    if ([controller respondsToSelector:variantSelector])
        return ((id (*)(id, SEL, long long))objc_msgSend)(controller, variantSelector, 0);
    return nil;
}

static UIImage *DLWallpaperSnapshot(id wallpaperView, UIImage *wallpaperImage) {
    if ([wallpaperView isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)wallpaperView;
        CGSize size = view.bounds.size;
        if (size.width >= 1.0 && size.height >= 1.0) {
            UIGraphicsBeginImageContextWithOptions(size, NO, UIScreen.mainScreen.scale);
            BOOL drawn = [view drawViewHierarchyInRect:(CGRect){CGPointZero, size} afterScreenUpdates:NO];
            UIImage *snapshot = drawn ? UIGraphicsGetImageFromCurrentImageContext() : nil;
            UIGraphicsEndImageContext();
            if (snapshot.CGImage) return snapshot;
        }
    }
    return wallpaperImage;
}

static UIImage *DLNormalizedAndCappedImage(UIImage *image) {
    if (!image.CGImage) return nil;
    UIImage *normalized = image;
    if (image.imageOrientation != UIImageOrientationUp) {
        UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale > 0.0 ? image.scale : UIScreen.mainScreen.scale);
        [image drawInRect:(CGRect){CGPointZero, image.size}];
        normalized = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    CGImageRef cgImage = normalized.CGImage;
    size_t width = CGImageGetWidth(cgImage), height = CGImageGetHeight(cgImage);
    size_t longest = MAX(width, height);
    const size_t maxDimension = 2048;
    if (longest <= maxDimension) return normalized;
    CGFloat ratio = (CGFloat)maxDimension / (CGFloat)longest;
    CGSize target = CGSizeMake(round(width * ratio), round(height * ratio));
    UIGraphicsBeginImageContextWithOptions(target, NO, 1.0);
    [normalized drawInRect:(CGRect){CGPointZero, target}];
    UIImage *capped = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return capped;
}

static UIImage *DLCreateForegroundImage(UIImage *sourceImage) {
    UIImage *image = DLNormalizedAndCappedImage(sourceImage);
    if (!image.CGImage) return nil;

    VNGeneratePersonSegmentationRequest *request = [VNGeneratePersonSegmentationRequest new];
    request.qualityLevel = (VNGeneratePersonSegmentationRequestQualityLevel)DLQuality;
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8;
    request.preferBackgroundProcessing = YES;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
    NSError *error = nil;
    if (![handler performRequests:@[request] error:&error]) {
        NSLog(@"[DepthLayer] Vision request failed: %@", error);
        return nil;
    }

    VNPixelBufferObservation *observation = request.results.firstObject;
    CVPixelBufferRef maskBuffer = observation.pixelBuffer;
    if (!maskBuffer) {
        NSLog(@"[DepthLayer] Vision returned no person mask for the wallpaper.");
        return nil;
    }

    CIImage *input = [CIImage imageWithCGImage:image.CGImage];
    CIImage *mask = [CIImage imageWithCVPixelBuffer:maskBuffer];
    CGRect inputRect = input.extent, maskRect = mask.extent;
    if (CGRectIsEmpty(inputRect) || CGRectIsEmpty(maskRect)) return nil;
    CGAffineTransform scale = CGAffineTransformMakeScale(inputRect.size.width / maskRect.size.width,
                                                          inputRect.size.height / maskRect.size.height);
    mask = [[mask imageByApplyingTransform:scale] imageByCroppingToRect:inputRect];
    CIImage *clearBackground = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:0]] imageByCroppingToRect:inputRect];
    CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
    [blend setValue:input forKey:kCIInputImageKey];
    [blend setValue:clearBackground forKey:kCIInputBackgroundImageKey];
    [blend setValue:mask forKey:kCIInputMaskImageKey];
    CIImage *result = blend.outputImage;
    if (!result) return nil;
    if (!DLCIContext) DLCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    CGImageRef cutout = [DLCIContext createCGImage:result fromRect:inputRect];
    if (!cutout) return nil;
    UIImage *foreground = [UIImage imageWithCGImage:cutout scale:image.scale orientation:UIImageOrientationUp];
    CGImageRelease(cutout);
    return foreground;
}

static void DLRemoveOverlay(void) {
    if (DLOverlayView) {
        [DLOverlayView removeFromSuperview];
        DLOverlayView = nil;
    }
}

static void DLApplyForeground(void) {
    UIViewController *controller = DLCurrentDashboardController;
    if (!DLEnabled || !DLCachedForegroundImage || !controller.isViewLoaded || !controller.view || DLPasscodeVisible) {
        if (DLOverlayView) DLOverlayView.hidden = YES;
        return;
    }
    if (!DLOverlayView) {
        DLOverlayView = [[UIImageView alloc] initWithImage:DLCachedForegroundImage];
        DLOverlayView.contentMode = UIViewContentModeScaleToFill;
        DLOverlayView.userInteractionEnabled = NO;
        DLOverlayView.accessibilityElementsHidden = YES;
        DLOverlayView.opaque = NO;
        DLOverlayView.backgroundColor = UIColor.clearColor;
        DLOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        DLOverlayView.layer.zPosition = 1000.0;
    } else if (DLOverlayView.image != DLCachedForegroundImage) {
        DLOverlayView.image = DLCachedForegroundImage;
    }
    UIView *rootView = controller.view;
    if (DLOverlayView.superview != rootView) {
        [DLOverlayView removeFromSuperview];
        [rootView addSubview:DLOverlayView];
    }
    DLOverlayView.frame = rootView.bounds;
    DLOverlayView.hidden = NO;
    [rootView bringSubviewToFront:DLOverlayView];
}

static void DLRefreshForeground(void);

static void DLScheduleRefresh(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DLScheduleRefresh(); });
        return;
    }
    if (DLRefreshQueued) return;
    DLRefreshQueued = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DLRefreshQueued = NO;
        DLRefreshForeground();
    });
}

static void DLRefreshForeground(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DLRefreshForeground(); });
        return;
    }
    if (!DLEnabled) {
        DLRemoveOverlay();
        return;
    }

    id wallpaperView = DLLockWallpaperView();
    UIImage *wallpaperImage = DLImageFromWallpaperView(wallpaperView);
    const void *imagePointer = wallpaperImage.CGImage ? (const void *)wallpaperImage.CGImage : (__bridge const void *)wallpaperView;
    NSUInteger token = (NSUInteger)imagePointer;
    if (wallpaperImage) token ^= (NSUInteger)(wallpaperImage.size.width * 31.0 + wallpaperImage.size.height * 17.0);
    if (token == 0) {
        if (!DLDidLogMissingWallpaper) {
            NSLog(@"[DepthLayer] Could not find the active Lock Screen wallpaper view/image.");
            DLDidLogMissingWallpaper = YES;
        }
        DLCachedForegroundImage = nil;
        DLRemoveOverlay();
        return;
    }
    DLDidLogMissingWallpaper = NO;

    if (token == DLCachedWallpaperToken) {
        DLApplyForeground();
        if (DLCachedForegroundImage || DLProcessing || DLProcessedToken == token) return;
    } else {
        DLCachedWallpaperToken = token;
        DLCachedForegroundImage = nil;
        DLRemoveOverlay();
    }

    UIImage *snapshot = DLWallpaperSnapshot(wallpaperView, wallpaperImage);
    if (!snapshot.CGImage) {
        NSLog(@"[DepthLayer] Wallpaper was found, but no snapshot could be captured.");
        DLCachedWallpaperToken = 0;
        return;
    }
    if (DLProcessing) return;
    DLProcessing = YES;
    DLProcessingToken = token;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *foreground = DLCreateForegroundImage(snapshot);
        dispatch_async(dispatch_get_main_queue(), ^{
            DLProcessing = NO;
            if (DLProcessingToken != DLCachedWallpaperToken || !DLEnabled) {
                if (DLEnabled) DLRefreshForeground();
                return;
            }
            DLProcessedToken = DLProcessingToken;
            DLCachedForegroundImage = foreground;
            if (foreground) NSLog(@"[DepthLayer] Person cutout created; adding the Lock Screen overlay.");
            DLApplyForeground();
        });
    });
}

static void DLLoadPreferences(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDLPreferenceDomain);
    DLEnabled = DLReadBool(@"Enabled", YES);
    DLQuality = DLReadQuality();
}

static void DLPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger previousQuality = DLQuality;
        DLLoadPreferences();
        if (!DLEnabled) {
            DLRemoveOverlay();
            return;
        }
        if (previousQuality != DLQuality) {
            DLCachedForegroundImage = nil;
            DLProcessedToken = 0;
        }
        DLScheduleRefresh();
    });
}

%hook SBDashBoardViewController
- (void)viewDidAppear:(BOOL)animated { %orig; DLCurrentDashboardController = (UIViewController *)self; DLScheduleRefresh(); }
- (void)viewDidLayoutSubviews { %orig; DLCurrentDashboardController = (UIViewController *)self; if (!DLOverlayView || !DLOverlayView.superview) DLScheduleRefresh(); }
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    UIViewController *controller = (UIViewController *)self;
    if (DLOverlayView.superview == controller.view) DLRemoveOverlay();
    if (DLCurrentDashboardController == controller) DLCurrentDashboardController = nil;
}
%end

%hook CSCoverSheetViewController
- (void)viewDidAppear:(BOOL)animated { %orig; DLCurrentDashboardController = (UIViewController *)self; DLScheduleRefresh(); }
- (void)viewDidLayoutSubviews { %orig; DLCurrentDashboardController = (UIViewController *)self; if (!DLOverlayView || !DLOverlayView.superview) DLScheduleRefresh(); }
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    UIViewController *controller = (UIViewController *)self;
    if (DLOverlayView.superview == controller.view) DLRemoveOverlay();
    if (DLCurrentDashboardController == controller) DLCurrentDashboardController = nil;
}
%end

%hook SBDashBoardPasscodeViewController
- (void)viewWillAppear:(BOOL)animated { %orig; DLPasscodeVisible = YES; DLOverlayView.hidden = YES; }
- (void)viewWillDisappear:(BOOL)animated { %orig; DLPasscodeVisible = NO; DLApplyForeground(); }
%end

%ctor {
    DLLoadPreferences();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, DLPreferencesChanged,
                                    kDLChangedNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
    NSLog(@"[DepthLayer] Loaded; enabled=%@ quality=%ld", DLEnabled ? @"yes" : @"no", (long)DLQuality);
}
