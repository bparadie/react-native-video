#import "RCTConvert.h"
#import "RCTVideo.h"
#import "RCTBridgeModule.h"
#import "RCTEventDispatcher.h"
#import "UIView+React.h"

NSString *const RNVideoEventLoaded = @"videoLoaded";
NSString *const RNVideoEventLoading = @"videoLoading";
NSString *const RNVideoEventProgress = @"videoProgress";
NSString *const RNVideoEventSeek = @"videoSeek";
NSString *const RNVideoEventLoadingError = @"videoLoadError";
NSString *const RNVideoEventEnd = @"videoEnd";

static NSString *const statusKeyPath = @"status";

@implementation RCTVideo
{
  AVPlayer *_player;
  AVPlayerItem *_playerItem;
  AVPlayerViewController *_playerLayer;
  BOOL _playerItemObserverSet;
  NSURL *_videoURL;

  /* Required to publish events */
  RCTEventDispatcher *_eventDispatcher;

  bool _pendingSeek;
  float _pendingSeekTime;
  float _lastSeekTime;

  /* For sending videoProgress events */
  id _progressUpdateTimer;
  int _progressUpdateInterval;
  NSDate *_prevProgressUpdateTime;

  /* Keep track of any modifiers, need to be applied after each play */
  float _volume;
  float _rate;
  float _seek;
  BOOL _muted;
  BOOL _paused;
  id _timeObserver;
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
  if ((self = [super init])) {
    _eventDispatcher = eventDispatcher;
    _rate = 1.0;
    _volume = 1.0;
    _seek = -1.0;
    
    _pendingSeek = false;
    _pendingSeekTime = 0.0f;
    _lastSeekTime = 0.0f;
    _paused = YES;
    _progressUpdateInterval = 250;
  }

  return self;
}

#pragma mark - Progress

/* ---------------------------------------------------------
 **  Get the duration for a AVPlayerItem.
 ** ------------------------------------------------------- */

- (CMTime)playerItemDuration
{
  AVPlayerItem *playerItem = [_player currentItem];
  if (playerItem.status == AVPlayerItemStatusReadyToPlay)
  {
    return([playerItem duration]);
  }
  
  return(kCMTimeInvalid);
}

- (void)sendProgressUpdate
{
   AVPlayerItem *video = [_player currentItem];
   if (video == nil || video.status != AVPlayerItemStatusReadyToPlay) {
     return;
   }

  CMTime playerDuration = [self playerItemDuration];
  if (CMTIME_IS_INVALID(playerDuration))
  {
    return;
  }
  const Float64 duration = CMTimeGetSeconds(playerDuration);
  const Float64 currentTime = CMTimeGetSeconds([_player currentTime]);
  if( currentTime <= duration)
  {
    if (_prevProgressUpdateTime == nil ||
        (([_prevProgressUpdateTime timeIntervalSinceNow] * -1000.0) >= _progressUpdateInterval)) {
      [_eventDispatcher sendInputEventWithName:RNVideoEventProgress body:@{
                                                                           @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(video.currentTime)],
                                                                           @"target": self.reactTag
                                                                           }];
      
      _prevProgressUpdateTime = [NSDate date];
    }
  }
}

- (void)stopProgressTimer
{
  [_progressUpdateTimer invalidate];
}

- (void)startProgressTimer
{
  _prevProgressUpdateTime = nil;

  [self stopProgressTimer];

  _progressUpdateTimer = [CADisplayLink displayLinkWithTarget:self selector:@selector(sendProgressUpdate)];
  [_progressUpdateTimer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
}

- (void)notifyEnd:(NSNotification *)notification
{
    [_eventDispatcher sendInputEventWithName:RNVideoEventEnd body:@{
        @"target": self.reactTag
    }];
}

- (void)addPlayerItemObserver
{
  [_playerItem addObserver:self forKeyPath:statusKeyPath options:0 context:nil];
  _playerItemObserverSet = YES;
}

/* Fixes https://github.com/brentvatne/react-native-video/issues/43
 * Crashes caused when trying to remove the observer when there is no
 * observer set */
- (void)removePlayerItemObserver
{
  if (_playerItemObserverSet) {
    [_playerItem removeObserver:self forKeyPath:statusKeyPath];
    _playerItemObserverSet = NO;
  }
}

#pragma mark - Player and source

- (AVPlayerViewController*)createPlayerViewController:(AVPlayer*)player withPlayerItem:(AVPlayerItem*)playerItem {
  AVPlayerViewController* playerLayer= [[AVPlayerViewController alloc] init];
  playerLayer.view.frame = self.bounds;
  playerLayer.player = _player;
  playerLayer.view.frame = self.bounds;
  return playerLayer;
}


- (void)setSrc:(NSDictionary *)source
{
  [self removePlayerItemObserver];
  _playerItem = [self playerItemForSource:source];
  [self addPlayerItemObserver];

  [_player pause];
  [_playerLayer.view removeFromSuperview];

  _player = [AVPlayer playerWithPlayerItem:_playerItem];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
  
  Float64 progressUpdateIntervalMS = _progressUpdateInterval;
  progressUpdateIntervalMS = progressUpdateIntervalMS / 1000;
  // CMTimeShow(CMTimeMakeWithSeconds(progressUpdateIntervalMS, NSEC_PER_SEC));
  
  // @see endScrubbing in AVPlayerDemoPlaybackViewController.m of https://developer.apple.com/library/ios/samplecode/AVPlayerDemo/Introduction/Intro.html
  __weak RCTVideo *weakSelf = self;
  _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(progressUpdateIntervalMS, NSEC_PER_SEC) queue:NULL usingBlock:
                   ^(CMTime time)
                   {
                     [weakSelf sendProgressUpdate];
                   }];
  
  _playerLayer = [self createPlayerViewController:_player withPlayerItem:_playerItem];
  [self addSubview:_playerLayer.view];

  [_eventDispatcher sendInputEventWithName:RNVideoEventLoading body:@{
    @"src": @{
      @"uri": [source objectForKey:@"uri"],
      @"type": [source objectForKey:@"type"],
      @"isNetwork":[NSNumber numberWithBool:(bool)[source objectForKey:@"isNetwork"]]
    },
    @"target": self.reactTag
  }];
}

/* Cancels the previously registered time observer. */
-(void)removePlayerTimeObserver
{
  if (_timeObserver)
  {
    [_player removeTimeObserver:_timeObserver];
    _timeObserver = nil;
  }
}


- (AVPlayerItem*)playerItemForSource:(NSDictionary *)source
{
  bool isNetwork = [RCTConvert BOOL:[source objectForKey:@"isNetwork"]];
  bool isAsset = [RCTConvert BOOL:[source objectForKey:@"isAsset"]];
  NSString *uri = [source objectForKey:@"uri"];
  NSString *type = [source objectForKey:@"type"];

  NSURL *url = (isNetwork || isAsset) ?
    [NSURL URLWithString:uri] :
    [[NSURL alloc] initFileURLWithPath:[[NSBundle mainBundle] pathForResource:uri ofType:type]];

  if (isAsset) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    return [AVPlayerItem playerItemWithAsset:asset];
  }

  return [AVPlayerItem playerItemWithURL:url];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
  if (object == _playerItem) {
    if (_playerItem.status == AVPlayerItemStatusReadyToPlay) {
      float duration = CMTimeGetSeconds(_playerItem.asset.duration);

      if (isnan(duration)) {
        duration = 0.0;
      }

      [_eventDispatcher sendInputEventWithName:RNVideoEventLoaded body:@{
        @"duration": [NSNumber numberWithFloat:duration],
        @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(_playerItem.currentTime)],
        @"canPlayReverse": [NSNumber numberWithBool:_playerItem.canPlayReverse],
        @"canPlayFastForward": [NSNumber numberWithBool:_playerItem.canPlayFastForward],
        @"canPlaySlowForward": [NSNumber numberWithBool:_playerItem.canPlaySlowForward],
        @"canPlaySlowReverse": [NSNumber numberWithBool:_playerItem.canPlaySlowReverse],
        @"canStepBackward": [NSNumber numberWithBool:_playerItem.canStepBackward],
        @"canStepForward": [NSNumber numberWithBool:_playerItem.canStepForward],
        @"target": self.reactTag
      }];

      [self startProgressTimer];
      [self attachListeners];
      [self applyModifiers];
    } else if(_playerItem.status == AVPlayerItemStatusFailed) {
      [_eventDispatcher sendInputEventWithName:RNVideoEventLoadingError body:@{
        @"error": @{
          @"code": [NSNumber numberWithInteger:_playerItem.error.code],
          @"domain": _playerItem.error.domain
        },
        @"target": self.reactTag
      }];
    }
  } else {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

- (void)attachListeners
{
    // listen for end of file
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(notifyEnd:)
        name:AVPlayerItemDidPlayToEndTimeNotification
        object:[_player currentItem]];

}

- (void)playerItemDidReachEnd:(NSNotification *)notification
{
    AVPlayerItem *item = [notification object];
    [item seekToTime:kCMTimeZero];
    [self applyModifiers];
}

#pragma mark - Prop setters

- (void)setResizeMode:(NSString*)mode
{
  _playerLayer.videoGravity = mode;
}

- (void)setPaused:(BOOL)paused
{
  if (paused) {
    [self stopProgressTimer];
    [_player pause];
  } else {
    [self startProgressTimer];
    [_player play];
  }
  
  _paused = paused;
}


- (void)setSeek:(float)seekTime
{
  if (_seek >= 0 ) {
    [self doSeek:seekTime];
  }
  _seek = seekTime;
}

- (void)doSeek:(float)seekTime
{
  int timeScale = 10000;

  AVPlayerItem *item = _player.currentItem;
  if (item && item.status == AVPlayerItemStatusReadyToPlay) {
    // TODO check loadedTimeRanges

    CMTime cmSeekTime = CMTimeMakeWithSeconds(seekTime, timeScale);
    CMTime current = item.currentTime;
    // TODO figure out a good tolerance level
    CMTime tolerance = CMTimeMake(1000, timeScale);

    // CMTimeShow(current);
    // CMTimeShow(cmSeekTime);
    
    if (CMTimeCompare(current, cmSeekTime) != 0) {
      [_player seekToTime:cmSeekTime toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
        [_eventDispatcher sendInputEventWithName:RNVideoEventSeek body:@{
          @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(item.currentTime)],
          @"seekTime": [NSNumber numberWithFloat:seekTime],
          @"target": self.reactTag
        }];
      }];

      _pendingSeek = false;
    }

  } else {
    // TODO see if this makes sense and if so,
    // actually implement it
    _pendingSeek = true;
    _pendingSeekTime = seekTime;
  }
}

- (void)setRate:(float)rate
{
  _rate = rate;
  [self applyModifiers];
}

- (void)setMuted:(BOOL)muted
{
  _muted = muted;
  [self applyModifiers];
}

- (void)setVolume:(float)volume
{
  _volume = volume;
  [self applyModifiers];
}

- (void)applyModifiers
{
  /* volume must be set to 0 if muted is YES, or the video freezes playback */
  if (_muted) {
    [_player setVolume:0];
    [_player setMuted:YES];
  } else {
    [_player setVolume:_volume];
    [_player setMuted:NO];
  }

  [_player setRate:_rate];
  [self setPaused:_paused];
  [self setSeek:_seek];
}

- (void)setRepeatEnabled
{
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playerItemDidReachEnd:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:[_player currentItem]];
}

- (void)setRepeatDisabled
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setRepeat:(BOOL)repeat {
  if (repeat) {
    [self setRepeatEnabled];
  } else {
    [self setRepeatDisabled];
  }
}

#pragma mark - React View Management

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
  // Why not?
  // RCTLogError(@"video cannot have any subviews");
  
  view.frame = self.bounds;
  [_playerLayer.contentOverlayView insertSubview:view atIndex:atIndex];
  return;
}

- (void)removeReactSubview:(UIView *)subview
{
  // Why not?
  // RCTLogError(@"video cannot have any subviews");
  [subview removeFromSuperview];
  return;
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  _playerLayer.view.frame = self.bounds;
  
  // also adjust all subviews of contentOverlayView
  for (UIView* subview in _playerLayer.contentOverlayView.subviews) {
    subview.frame = self.bounds;
  }
}

#pragma mark - Lifecycle

- (void)removeFromSuperview
{
  [self removePlayerTimeObserver];
  [_progressUpdateTimer invalidate];
  _prevProgressUpdateTime = nil;

  [_player pause];
  _player = nil;

  [_playerLayer.view removeFromSuperview];
  _playerLayer = nil;

  [self removePlayerItemObserver];

  _eventDispatcher = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
