#import "RCTConvert.h"
#import "RCTVideo.h"
#import "RCTBridgeModule.h"
#import "RCTEventDispatcher.h"
#import "UIView+React.h"
#import <AVFoundation/AVFoundation.h>

NSString *const RNVideoEventLoaded = @"videoLoaded";
NSString *const RNVideoEventLoading = @"videoLoading";
NSString *const RNVideoEventProgress = @"videoProgress";
NSString *const RNVideoEventSeek = @"videoSeek";
NSString *const RNVideoEventLoadingError = @"videoLoadError";
NSString *const RNVideoEventEnd = @"videoEnd";

// HTML5 compatible events, @see http://www.w3schools.com/tags/ref_av_dom.asp
NSString *const RNVideoEventPlay = @"videoPlay";    // http://www.w3schools.com/tags/av_event_play.asp
NSString *const RNVideoEventPause = @"videoPause"; // http://www.w3schools.com/tags/av_event_pause.asp

static NSString *const statusKeyPath = @"status";

@implementation RCTVideo
{
  AVPlayer *_player;
  AVPlayerItem *_playerItem;
  BOOL _playerItemObserverSet;
  AVPlayerLayer *_playerLayer;
  NSURL *_videoURL;
  BOOL _playerObserverSet;
  BOOL _ignoreFirstPlay;
  BOOL _ignoreFirstPause;
  AVPlayerViewController *_playerViewController;

  /* Required to publish events */
  RCTEventDispatcher *_eventDispatcher;

  bool _pendingSeek;
  float _pendingSeekTime;
  float _lastSeekTime;

  /* For sending videoProgress events */
  Float64 _progressUpdateInterval;
  BOOL _controls;
  id _timeObserver;

  /* Keep track of any modifiers, need to be applied after each play */
  float _volume;
  float _rate;
  BOOL _muted;
  BOOL _paused;
  BOOL _repeat;
  NSString * _resizeMode;
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
  if ((self = [super init])) {
    _eventDispatcher = eventDispatcher;

    _rate = 1.0;
    _volume = 1.0;
    _resizeMode = @"AVLayerVideoGravityResizeAspectFill";
    _pendingSeek = false;
    _pendingSeekTime = 0.0f;
    _lastSeekTime = 0.0f;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationWillResignActive:)
                                          name:UIApplicationWillResignActiveNotification
                                          object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationWillEnterForeground:)
                                          name:UIApplicationWillEnterForegroundNotification
                                          object:nil];
    _paused = YES;
    _progressUpdateInterval = 250;
    _controls = NO;
  }

  return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - App lifecycle handlers

- (void)applicationWillResignActive:(NSNotification *)notification
{
  if (!_paused) {
    [self stopProgressTimer];
    [_player pause];
  }
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
  [self startProgressTimer];
  [self applyModifiers];
}

#pragma mark - Progress

- (void)sendProgressUpdate
{
   AVPlayerItem *video = [_player currentItem];
   if (video == nil || video.status != AVPlayerItemStatusReadyToPlay) {
     return;
   }

/*
  if (_prevProgressUpdateTime == nil ||
     (([_prevProgressUpdateTime timeIntervalSinceNow] * -1000.0) >= _progressUpdateInterval)) {
    [_eventDispatcher sendInputEventWithName:RNVideoEventProgress body:@{
      @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(video.currentTime)],
      @"playableDuration": [self calculatePlayableDuration],
      @"target": self.reactTag
    }];
*/
    [self sendBetterProgressUpdate];
}

/*!
 * Calculates and returns the playable duration of the current player item using its loaded time ranges.
 *
 * \returns The playable duration of the current player item in seconds.
 */
- (NSNumber *)calculatePlayableDuration {
  AVPlayerItem *video = _player.currentItem;
  if (video.status == AVPlayerItemStatusReadyToPlay) {
    __block CMTimeRange effectiveTimeRange;
    [video.loadedTimeRanges enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
      CMTimeRange timeRange = [obj CMTimeRangeValue];
      if (CMTimeRangeContainsTime(timeRange, video.currentTime)) {
        effectiveTimeRange = timeRange;
        *stop = YES;
      }
    }];
    Float64 playableDuration = CMTimeGetSeconds(CMTimeRangeGetEnd(effectiveTimeRange));
    if (playableDuration > 0) {
      return [NSNumber numberWithFloat:playableDuration];
    }
  }
  return [NSNumber numberWithInteger:0];
}

- (void)stopProgressTimer
{
    // [_progressUpdateTimer invalidate];
}

- (void)startProgressTimer
{
  _progressUpdateInterval = 250;
  //_prevProgressUpdateTime = nil;

  [self stopProgressTimer];

  //_progressUpdateTimer = [CADisplayLink displayLinkWithTarget:self selector:@selector(sendProgressUpdate)];
  //[_progressUpdateTimer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
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

- (void)setSrc:(NSDictionary *)source
{
  [self removePlayerObserver];
  [self removePlayerItemObserver];
  _playerItem = [self playerItemForSource:source];
  [self addPlayerItemObserver];

  [_player pause];
  [_playerLayer removeFromSuperlayer];
  _playerLayer = nil;
  [self removePlayerTimeObserver];

  _player = [AVPlayer playerWithPlayerItem:_playerItem];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
  [self addPlayerObserver];
  
  if( _playerViewController )
  {
    _playerViewController.player = _player;
    _playerViewController.view.frame = self.bounds;
  }
  const Float64 progressUpdateIntervalMS = _progressUpdateInterval / 1000;
  // CMTimeShow(CMTimeMakeWithSeconds(progressUpdateIntervalMS, NSEC_PER_SEC));
    
  // @see endScrubbing in AVPlayerDemoPlaybackViewController.m of https://developer.apple.com/library/ios/samplecode/AVPlayerDemo/Introduction/Intro.html
  __weak RCTVideo *weakSelf = self;
  _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(progressUpdateIntervalMS, NSEC_PER_SEC) queue:NULL usingBlock:
                     ^(CMTime time)
                     {
                         [weakSelf sendProgressUpdate];
                     }];
/*
  _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
  _playerLayer.frame = self.bounds;
  _playerLayer.needsDisplayOnBoundsChange = YES;

  [self applyModifiers];

  [self.layer addSublayer:_playerLayer];
  self.layer.needsDisplayOnBoundsChange = YES;

*/
  [_eventDispatcher sendInputEventWithName:RNVideoEventLoading body:@{
    @"src": @{
      @"uri": [source objectForKey:@"uri"],
      @"type": [source objectForKey:@"type"],
      @"isNetwork":[NSNumber numberWithBool:(bool)[source objectForKey:@"isNetwork"]]
    },
    @"target": self.reactTag
  }];
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
  if (object == _player) {
    // @see http://stackoverflow.com/questions/7575494/avplayer-notification-for-play-pause-state
    if ([keyPath isEqualToString:@"rate"] && _playerItem && _playerItem.status == AVPlayerItemStatusReadyToPlay) {
      
      // For some reason we allways get a play/pause at the begin of each movie.
      // Those need to be ignored.
      if( !_ignoreFirstPlay && !_ignoreFirstPause )
      {
        NSString *const videoEvent = [_player rate] ?  RNVideoEventPlay : RNVideoEventPause;
        CMTime currentTime = _player.currentTime;
        [_eventDispatcher sendInputEventWithName:videoEvent body:@{@"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(currentTime)],
                                                                   @"atValue": [NSNumber numberWithLongLong:currentTime.value],
                                                                   @"atTimescale": [NSNumber numberWithInt:currentTime.timescale],
                                                                   @"target": self.reactTag
                                                                   }];
      }
      else if( _ignoreFirstPlay )
      {
        _ignoreFirstPlay = ![_player rate];
      }
      else if( _ignoreFirstPause )
      {
        _ignoreFirstPause = [_player rate];
      }
    }
  }
  else if (object == _playerItem) {
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
        @"target": self.reactTag,
        @"atValue": [NSNumber numberWithLongLong:_playerItem.currentTime.value],
        @"atTimescale": [NSNumber numberWithInt:_playerItem.currentTime.timescale],
        @"mode": _resizeMode
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
  dispatch_async(dispatch_get_main_queue(), ^{
    // listen for end of file
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:[_player currentItem]];
  });
}

- (void)playerItemDidEnd:(NSNotification *)notification
{
  [_eventDispatcher sendInputEventWithName:RNVideoEventEnd body:@{
    @"target": self.reactTag
  }];
  if (_repeat) {
    AVPlayerItem *item = [notification object];
    [item seekToTime:kCMTimeZero];
    [self applyModifiers];
  }
}

#pragma mark - Prop setters

- (void)setResizeMode:(NSString*)mode
{
    if( _controls )
    {
        _playerViewController.videoGravity = mode;
    }
    else
    {
        _playerLayer.videoGravity = mode;
    }
  _resizeMode = mode;
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
  int timeScale = 10000;

  AVPlayerItem *item = _player.currentItem;
  if (item && item.status == AVPlayerItemStatusReadyToPlay) {
    // TODO check loadedTimeRanges

    CMTime cmSeekTime = CMTimeMakeWithSeconds(seekTime, timeScale);
    CMTime current = item.currentTime;
    // Picking 1/30s as the tolerance. That would give us 1 frame at 30 FPS.
      Float64 thirtyFPS = 1;
      thirtyFPS = thirtyFPS / 30 * timeScale;
    CMTime tolerance = CMTimeMake(thirtyFPS, timeScale);
    
    if (CMTimeCompare(current, cmSeekTime) != 0) {
      [_player seekToTime:cmSeekTime toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
        [_eventDispatcher sendInputEventWithName:RNVideoEventSeek body:@{
          @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(current)],
          @"atValue": [NSNumber numberWithLongLong:current.value],
          @"atTimescale": [NSNumber numberWithInt:current.timescale],
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
  if (_muted) {
    [_player setVolume:0];
    [_player setMuted:YES];
  } else {
    [_player setVolume:_volume];
    [_player setMuted:NO];
  }

  [self setResizeMode:_resizeMode];
  [self setRepeat:_repeat];
  [self setPaused:_paused];
  [_player setRate:_rate];
  [self setControls:_controls];
}

- (void)setRepeat:(BOOL)repeat {
  _repeat = repeat;
}

#pragma mark - React View Management

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
  // We are early in the game and somebody wants to set a subview.
  // That can only be in the context of playerViewController.
  if( !_controls && !_playerLayer && !_playerViewController )
  {
    [self setControls:true];
  }
  
  if( _controls )
  {
     view.frame = self.bounds;
     [_playerViewController.contentOverlayView insertSubview:view atIndex:atIndex];
  }
  else
  {
     RCTLogError(@"video cannot have any subviews");
  }
  return;
}

- (void)removeReactSubview:(UIView *)subview
{
  if( _controls )
  {
      [subview removeFromSuperview];
  }
  else
  {
    RCTLogError(@"video cannot have any subviews");
  }
  return;
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  if( _controls )
  {
    _playerViewController.view.frame = self.bounds;
  
    // also adjust all subviews of contentOverlayView
    for (UIView* subview in _playerViewController.contentOverlayView.subviews) {
      subview.frame = self.bounds;
    }
  }
  else
  {
    _playerLayer.frame = self.bounds;
  }
}

#pragma mark - Lifecycle

- (void)removeFromSuperview
{
  [self removePlayerTimeObserver];
  [self removePlayerObserver];
  [_playerViewController.view removeFromSuperview];
  _playerViewController = nil;

  [_player pause];
  _player = nil;

  [_playerLayer removeFromSuperlayer];
  _playerLayer = nil;

  [self removePlayerItemObserver];

  _eventDispatcher = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];

  [super removeFromSuperview];
}

- (AVPlayerViewController*)createPlayerViewController:(AVPlayer*)player withPlayerItem:(AVPlayerItem*)playerItem {
    AVPlayerViewController* playerLayer= [[AVPlayerViewController alloc] init];
    playerLayer.view.frame = self.bounds;
    playerLayer.player = _player;
    playerLayer.view.frame = self.bounds;
    return playerLayer;
}

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


/* Cancels the previously registered time observer. */
-(void)removePlayerTimeObserver
{
    if (_timeObserver)
    {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }
}

- (void)sendBetterProgressUpdate
{
    CMTime playerDuration = [self playerItemDuration];
    if (CMTIME_IS_INVALID(playerDuration))
    {
        return;
    }
    
    CMTime currentTime = _player.currentTime;
    const Float64 duration = CMTimeGetSeconds(playerDuration);
    const Float64 currentTimeSecs = CMTimeGetSeconds(currentTime);
    if( currentTimeSecs >= 0 && currentTimeSecs <= duration)
    {
        [_eventDispatcher sendInputEventWithName:RNVideoEventProgress body:@{
                                                                             @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(currentTime)],
                                                                             @"atValue": [NSNumber numberWithLongLong:currentTime.value],
                                                                             @"atTimescale": [NSNumber numberWithInt:currentTime.timescale],
                                                                             @"target": self.reactTag
                                                                             }];
    }
}


- (void)notifyEnd:(NSNotification *)notification
{
    [_eventDispatcher sendInputEventWithName:RNVideoEventEnd body:@{
                                                                    @"target": self.reactTag
                                                                    }];
}

- (void)addPlayerObserver
{
    // @see http://stackoverflow.com/questions/7575494/avplayer-notification-for-play-pause-state
    
    if (!_playerObserverSet) {
        _playerObserverSet = _ignoreFirstPlay = _ignoreFirstPause = YES;
        [_player addObserver:self forKeyPath:@"rate" options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew)  context:nil];
    }
}

- (void)removePlayerObserver
{
    if (_playerObserverSet) {
        _playerObserverSet = NO;
        [_player removeObserver:self forKeyPath:@"rate"];
    }
}

- (float)getCurrentTime
{
    return _playerItem != NULL ? CMTimeGetSeconds(_playerItem.currentTime) : 0;
}

- (void)setCurrentTime:(float)currentTime
{
    if( currentTime >= 0 )
    {
        [self setSeek: currentTime];
    }
}


- (void)usePlayerViewController
{
    if( _player )
    {
        _playerViewController = [self createPlayerViewController:_player withPlayerItem:_playerItem];
        [self addSubview:_playerViewController.view];
    }
}

- (void)usePlayerLayer
{
    if( _player )
    {
        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer.frame = self.bounds;
        _playerLayer.needsDisplayOnBoundsChange = YES;
        
        [self.layer addSublayer:_playerLayer];
        self.layer.needsDisplayOnBoundsChange = YES;
    }
}

- (void)setControls:(BOOL)controls
{
    if( _controls != controls || (!_playerLayer && !_playerViewController) )
    {
        _controls = controls;
        if( _controls )
        {
            [_playerLayer removeFromSuperlayer];
            _playerLayer = nil;
            [self usePlayerViewController];
        }
        else
        {
            [_playerViewController.view removeFromSuperview];
            _playerViewController = nil;
            [self usePlayerLayer];
        }
    }
}
@end
