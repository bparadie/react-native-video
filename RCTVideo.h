#import "RCTView.h"
#import <AVFoundation/AVFoundation.h>
#import "AVKit/AVKit.h"

extern NSString *const RNVideoEventLoaded;
extern NSString *const RNVideoEventLoading;
extern NSString *const RNVideoEventProgress;
extern NSString *const RNVideoEventSeek;
extern NSString *const RNVideoEventLoadingError;
extern NSString *const RNVideoEventEnd;
extern NSString *const RNVideoEventPlay;
extern NSString *const RNVideoEventPause;

@class RCTEventDispatcher;

@interface RCTVideo : UIView

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher NS_DESIGNATED_INITIALIZER;

- (AVPlayerViewController*)createPlayerViewController:(AVPlayer*)player withPlayerItem:(AVPlayerItem*)playerItem;

@end
