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

// HTML5 compatible events, @see http://www.w3schools.com/tags/ref_av_dom.asp
NSString *const RNVideoEventPlay = @"videoPlay";    // http://www.w3schools.com/tags/av_event_play.asp
NSString *const RNVideoEventPause = @"videoPause"; // http://www.w3schools.com/tags/av_event_pause.asp


static NSString *const statusKeyPath = @"status";

@implementation RCTVideo
{
  AVPlayer *_player;
  AVPlayerItem *_playerItem;
  BOOL _playerItemObserverSet;
  BOOL _playerObserverSet;
  BOOL _ignoreFirstPlay;
  BOOL _ignoreFirstPause;
  AVPlayerLayer *_playerLayer;
  AVPlayerViewController *_playerViewController;
  NSURL *_videoURL;

  /* Required to publish events */
  RCTEventDispatcher *_eventDispatcher;

  bool _pendingSeek;
  float _pendingSeekTime;
  float _lastSeekTime;

  /* For sending videoProgress events */
  Float64 _progressUpdateInterval;
    
  /* Keep track of any modifiers, need to be applied after each play */
  float _volume;
  float _rate;
  BOOL _muted;
  BOOL _paused;
  BOOL _controls;
  id _timeObserver;
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
  if ((self = [super init])) {
    _eventDispatcher = eventDispatcher;
    _rate = 1.0;
    _volume = 1.0;
    
    _pendingSeek = false;
    _pendingSeekTime = 0.0f;
    _lastSeekTime = 0.0f;
    _paused = YES;
    _progressUpdateInterval = 250;
    _controls = NO;
  }

  return self;
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

#pragma mark - Progress

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
    
  // [self setControls:_controls];

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
      CMTime currentTime = _playerItem.currentTime;
      
      if (isnan(duration)) {
        duration = 0.0;
      }
      

      NSString *mode;
      if(_controls){
        mode = _playerViewController.videoGravity;
      }else{
        mode = _playerLayer.videoGravity;
      }
      
      [_eventDispatcher sendInputEventWithName:RNVideoEventLoaded body:@{
        @"duration": [NSNumber numberWithFloat:duration],
        @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(currentTime)],
        @"canPlayReverse": [NSNumber numberWithBool:_playerItem.canPlayReverse],
        @"canPlayFastForward": [NSNumber numberWithBool:_playerItem.canPlayFastForward],
        @"canPlaySlowForward": [NSNumber numberWithBool:_playerItem.canPlaySlowForward],
        @"canPlaySlowReverse": [NSNumber numberWithBool:_playerItem.canPlaySlowReverse],
        @"canStepBackward": [NSNumber numberWithBool:_playerItem.canStepBackward],
        @"canStepForward": [NSNumber numberWithBool:_playerItem.canStepForward],
        @"atValue": [NSNumber numberWithLongLong:currentTime.value],
        @"atTimescale": [NSNumber numberWithInt:currentTime.timescale],
        @"target": self.reactTag,
        @"mode": mode
      }];

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
  if( _controls )
  {
    _playerViewController.videoGravity = mode;
  }
  else
  {
    _playerLayer.videoGravity = mode;
  }
}

- (void)setPaused:(BOOL)paused
{
  if (paused) {
    [_player pause];
  } else {
    [_player play];
  }
  
  _paused = paused;
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

- (void)setSeek:(float)seekTime
{
  const int timeScale = 10000;
  Float64 thirtyFPS = 1;
  thirtyFPS = thirtyFPS / 30 * timeScale;
  
  AVPlayerItem *item = _player.currentItem;
  if (item && item.status == AVPlayerItemStatusReadyToPlay) {
    // TODO check loadedTimeRanges

    CMTime cmSeekTime = CMTimeMakeWithSeconds(seekTime, timeScale);
    CMTime current = item.currentTime;
    // Picking 1/30s as the tolerance. That would give us 1 frame at 30 FPS.
    CMTime tolerance = CMTimeMake(thirtyFPS, timeScale);
    
    if (CMTimeCompare(current, cmSeekTime) != 0) {
      [_player seekToTime:cmSeekTime toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
        [_eventDispatcher sendInputEventWithName:RNVideoEventSeek body:@{
          @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(current)],
          @"seekTime": [NSNumber numberWithFloat:seekTime],
          @"atValue": [NSNumber numberWithLongLong:current.value],
          @"atTimescale": [NSNumber numberWithInt:current.timescale],
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
  [self setControls:_controls];
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
  [self removePlayerItemObserver];
  [self removePlayerObserver];

  [_player pause];
  _player = nil;

  [_playerLayer removeFromSuperlayer];
  _playerLayer = nil;
  
  [_playerViewController.view removeFromSuperview];
  _playerViewController = nil;


  _eventDispatcher = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
