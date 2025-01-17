// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterDisplayLink.h"
#import "flutter/shell/platform/darwin/macos/framework/Source/FlutterVSyncWaiter.h"

#import "flutter/testing/testing.h"

@interface TestDisplayLink : FlutterDisplayLink {
}

@property(nonatomic) CFTimeInterval nominalOutputRefreshPeriod;

@end

@implementation TestDisplayLink

@synthesize nominalOutputRefreshPeriod = _nominalOutputRefreshPeriod;
@synthesize delegate = _delegate;
@synthesize paused = _paused;

- (instancetype)init {
  if (self = [super init]) {
    _paused = YES;
  }
  return self;
}

- (void)tickWithTimestamp:(CFTimeInterval)timestamp
          targetTimestamp:(CFTimeInterval)targetTimestamp {
  [_delegate onDisplayLink:timestamp targetTimestamp:targetTimestamp];
}

- (void)invalidate {
}

@end

TEST(FlutterVSyncWaiterTest, RequestsInitialVSync) {
  TestDisplayLink* displayLink = [[TestDisplayLink alloc] init];
  EXPECT_TRUE(displayLink.paused);
  // When created waiter requests a reference vsync to determine vsync phase.
  FlutterVSyncWaiter* waiter = [[FlutterVSyncWaiter alloc]
      initWithDisplayLink:displayLink
                    block:^(CFTimeInterval timestamp, CFTimeInterval targetTimestamp,
                            uintptr_t baton){
                    }];
  (void)waiter;
  EXPECT_FALSE(displayLink.paused);
  [displayLink tickWithTimestamp:CACurrentMediaTime()
                 targetTimestamp:CACurrentMediaTime() + 1.0 / 60.0];
  EXPECT_TRUE(displayLink.paused);
}

static void BusyWait(CFTimeInterval duration) {
  CFTimeInterval start = CACurrentMediaTime();
  while (CACurrentMediaTime() < start + duration) {
  }
}

// See FlutterVSyncWaiter.mm for the original definition.
static const CFTimeInterval kTimerLatencyCompensation = 0.001;

TEST(FlutterVSyncWaiterTest, FirstVSyncIsSynthesized) {
  TestDisplayLink* displayLink = [[TestDisplayLink alloc] init];
  displayLink.nominalOutputRefreshPeriod = 1.0 / 60.0;

  auto test = [&](CFTimeInterval waitDuration, CFTimeInterval expectedDelay) {
    __block CFTimeInterval timestamp = 0;
    __block CFTimeInterval targetTimestamp = 0;
    __block size_t baton = 0;
    FlutterVSyncWaiter* waiter = [[FlutterVSyncWaiter alloc]
        initWithDisplayLink:displayLink
                      block:^(CFTimeInterval _timestamp, CFTimeInterval _targetTimestamp,
                              uintptr_t _baton) {
                        timestamp = _timestamp;
                        targetTimestamp = _targetTimestamp;
                        baton = _baton;
                        EXPECT_TRUE(CACurrentMediaTime() >= _timestamp - kTimerLatencyCompensation);
                        CFRunLoopStop(CFRunLoopGetCurrent());
                      }];
    // Reference vsync to setup phase.
    CFTimeInterval now = CACurrentMediaTime();
    // CVDisplayLink callback is called one and a half frame before the target.
    [displayLink tickWithTimestamp:now + 0.5 * displayLink.nominalOutputRefreshPeriod
                   targetTimestamp:now + 2 * displayLink.nominalOutputRefreshPeriod];
    EXPECT_EQ(displayLink.paused, YES);
    // Vsync was not requested yet, block should not have been called.
    EXPECT_EQ(timestamp, 0);

    BusyWait(waitDuration);

    // Synthesized vsync should come in 1/60th of a second after the first.
    CFTimeInterval expectedTimestamp = now + expectedDelay;
    [waiter waitForVSync:1];

    CFRunLoopRun();

    EXPECT_DOUBLE_EQ(timestamp, expectedTimestamp);
    EXPECT_DOUBLE_EQ(targetTimestamp, expectedTimestamp + displayLink.nominalOutputRefreshPeriod);
    EXPECT_EQ(baton, size_t(1));
  };

  // First argument if the wait duration after reference vsync.
  // Second argument is the expected delay between reference vsync and synthesized vsync.
  test(0.005, displayLink.nominalOutputRefreshPeriod);
  test(0.025, 2 * displayLink.nominalOutputRefreshPeriod);
  test(0.040, 3 * displayLink.nominalOutputRefreshPeriod);
}

TEST(FlutterVSyncWaiterTest, VSyncWorks) {
  TestDisplayLink* displayLink = [[TestDisplayLink alloc] init];
  displayLink.nominalOutputRefreshPeriod = 1.0 / 60.0;

  struct Entry {
    CFTimeInterval timestamp;
    CFTimeInterval targetTimestamp;
    size_t baton;
  };
  __block std::vector<Entry> entries;

  FlutterVSyncWaiter* waiter = [[FlutterVSyncWaiter alloc]
      initWithDisplayLink:displayLink
                    block:^(CFTimeInterval timestamp, CFTimeInterval targetTimestamp,
                            uintptr_t baton) {
                      entries.push_back({timestamp, targetTimestamp, baton});
                      EXPECT_TRUE(CACurrentMediaTime() >= timestamp - kTimerLatencyCompensation);
                      CFRunLoopStop(CFRunLoopGetCurrent());
                    }];

  // Reference vsync to setup phase.
  CFTimeInterval now = CACurrentMediaTime();
  // CVDisplayLink callback is called one and a half frame before the target.
  [displayLink tickWithTimestamp:now + 0.5 * displayLink.nominalOutputRefreshPeriod
                 targetTimestamp:now + 2 * displayLink.nominalOutputRefreshPeriod];
  EXPECT_EQ(displayLink.paused, YES);

  [waiter waitForVSync:1];
  CFRunLoopRun();

  [waiter waitForVSync:2];
  [displayLink tickWithTimestamp:now + 1.5 * displayLink.nominalOutputRefreshPeriod
                 targetTimestamp:now + 3 * displayLink.nominalOutputRefreshPeriod];
  CFRunLoopRun();

  [waiter waitForVSync:3];
  [displayLink tickWithTimestamp:now + 2.5 * displayLink.nominalOutputRefreshPeriod
                 targetTimestamp:now + 4 * displayLink.nominalOutputRefreshPeriod];
  CFRunLoopRun();

  EXPECT_FALSE(displayLink.paused);
  // Vsync without baton should pause the display link.
  [displayLink tickWithTimestamp:now + 3.5 * displayLink.nominalOutputRefreshPeriod
                 targetTimestamp:now + 5 * displayLink.nominalOutputRefreshPeriod];
  // Make sure to run the timer scheduled in display link callback.
  CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, NO);
  ASSERT_TRUE(displayLink.paused);

  EXPECT_EQ(entries.size(), size_t(3));
  EXPECT_DOUBLE_EQ(entries[0].timestamp, now + displayLink.nominalOutputRefreshPeriod);
  EXPECT_DOUBLE_EQ(entries[0].targetTimestamp, now + 2 * displayLink.nominalOutputRefreshPeriod);
  EXPECT_EQ(entries[0].baton, size_t(1));
  EXPECT_DOUBLE_EQ(entries[1].timestamp, now + 2 * displayLink.nominalOutputRefreshPeriod);
  EXPECT_DOUBLE_EQ(entries[1].targetTimestamp, now + 3 * displayLink.nominalOutputRefreshPeriod);
  EXPECT_EQ(entries[1].baton, size_t(2));
  EXPECT_DOUBLE_EQ(entries[2].timestamp, now + 3 * displayLink.nominalOutputRefreshPeriod);
  EXPECT_DOUBLE_EQ(entries[2].targetTimestamp, now + 4 * displayLink.nominalOutputRefreshPeriod);
  EXPECT_EQ(entries[2].baton, size_t(3));
}
