// Copyright (c) 2012 The Chromium Authors. All rights reserved.
// Copyright (c) 2013 Adam Roben <adam@roben.org>. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE-CHROMIUM file.

#include "shell/browser/ui/inspectable_web_contents_view_mac.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#include <vector>

#include "base/strings/sys_string_conversions.h"
#import "shell/browser/ui/cocoa/electron_inspectable_web_contents_view.h"
#include "shell/browser/ui/drag_util.h"
#include "shell/browser/ui/inspectable_web_contents.h"
#include "shell/browser/ui/inspectable_web_contents_view_delegate.h"
#include "ui/gfx/geometry/rect.h"

@interface DragRegionView : NSView

@property(assign) NSPoint initialLocation;

@end

@interface NSWindow ()
- (void)performWindowDragWithEvent:(NSEvent*)event;
@end

@implementation DragRegionView

@synthesize initialLocation;

+ (void)load {
  if (getenv("ELECTRON_DEBUG_DRAG_REGIONS")) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      SEL originalSelector = @selector(drawRect:);
      SEL swizzledSelector = @selector(drawDebugRect:);

      Method originalMethod =
          class_getInstanceMethod([self class], originalSelector);
      Method swizzledMethod =
          class_getInstanceMethod([self class], swizzledSelector);
      BOOL didAddMethod =
          class_addMethod([self class], originalSelector,
                          method_getImplementation(swizzledMethod),
                          method_getTypeEncoding(swizzledMethod));

      if (didAddMethod) {
        class_replaceMethod([self class], swizzledSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
      } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
      }
    });
  }
}

- (BOOL)mouseDownCanMoveWindow {
  return
      [self.window respondsToSelector:@selector(performWindowDragWithEvent:)];
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
  return YES;
}

- (BOOL)shouldIgnoreMouseEvent {
  NSEventType type = [[NSApp currentEvent] type];
  return type != NSEventTypeLeftMouseDragged &&
         type != NSEventTypeLeftMouseDown;
}

- (NSView*)hitTest:(NSPoint)point {
  // Pass-through events that hit one of the exclusion zones
  for (NSView* exclusion_zones in [self subviews]) {
    if ([exclusion_zones hitTest:point])
      return nil;
  }

  return self;
}

- (void)mouseDown:(NSEvent*)event {
  [super mouseDown:event];

  if ([self.window respondsToSelector:@selector(performWindowDragWithEvent:)]) {
    // According to Google, using performWindowDragWithEvent:
    // does not generate a NSWindowWillMoveNotification. Hence post one.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:NSWindowWillMoveNotification
                      object:self];

    [self.window performWindowDragWithEvent:event];

    return;
  }

  if (self.window.styleMask & NSWindowStyleMaskFullScreen) {
    return;
  }

  self.initialLocation = [event locationInWindow];
}

- (void)mouseDragged:(NSEvent*)event {
  if ([self.window respondsToSelector:@selector(performWindowDragWithEvent:)]) {
    return;
  }

  if (self.window.styleMask & NSWindowStyleMaskFullScreen) {
    return;
  }

  NSPoint currentLocation = [NSEvent mouseLocation];
  NSPoint newOrigin;

  NSRect screenFrame = [[NSScreen mainScreen] frame];
  NSSize screenSize = screenFrame.size;
  NSRect windowFrame = [self.window frame];
  NSSize windowSize = windowFrame.size;

  newOrigin.x = currentLocation.x - self.initialLocation.x;
  newOrigin.y = currentLocation.y - self.initialLocation.y;

  BOOL inMenuBar = (newOrigin.y + windowSize.height) >
                   (screenFrame.origin.y + screenSize.height);
  BOOL screenAboveMainScreen = false;

  if (inMenuBar) {
    for (NSScreen* screen in [NSScreen screens]) {
      NSRect currentScreenFrame = [screen frame];
      BOOL isHigher = currentScreenFrame.origin.y > screenFrame.origin.y;

      // If there's another screen that is generally above the current screen,
      // we'll draw a new rectangle that is just above the current screen. If
      // the "higher" screen intersects with this rectangle, we'll allow drawing
      // above the menubar.
      if (isHigher) {
        NSRect aboveScreenRect =
            NSMakeRect(screenFrame.origin.x,
                       screenFrame.origin.y + screenFrame.size.height - 10,
                       screenFrame.size.width, 200);

        BOOL screenAboveIntersects =
            NSIntersectsRect(currentScreenFrame, aboveScreenRect);

        if (screenAboveIntersects) {
          screenAboveMainScreen = true;
          break;
        }
      }
    }
  }

  // Don't let window get dragged up under the menu bar
  if (inMenuBar && !screenAboveMainScreen) {
    newOrigin.y = screenFrame.origin.y +
                  (screenFrame.size.height - windowFrame.size.height);
  }

  // Move the window to the new location
  [self.window setFrameOrigin:newOrigin];
}

// For debugging purposes only.
- (void)drawDebugRect:(NSRect)aRect {
  [[[NSColor greenColor] colorWithAlphaComponent:0.5] set];
  NSRectFill([self bounds]);
}

@end

@interface ExcludeDragRegionView : NSView
@end

@implementation ExcludeDragRegionView

+ (void)load {
  if (getenv("ELECTRON_DEBUG_DRAG_REGIONS")) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      SEL originalSelector = @selector(drawRect:);
      SEL swizzledSelector = @selector(drawDebugRect:);

      Method originalMethod =
          class_getInstanceMethod([self class], originalSelector);
      Method swizzledMethod =
          class_getInstanceMethod([self class], swizzledSelector);
      BOOL didAddMethod =
          class_addMethod([self class], originalSelector,
                          method_getImplementation(swizzledMethod),
                          method_getTypeEncoding(swizzledMethod));

      if (didAddMethod) {
        class_replaceMethod([self class], swizzledSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
      } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
      }
    });
  }
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

// For debugging purposes only.
- (void)drawDebugRect:(NSRect)aRect {
  [[[NSColor redColor] colorWithAlphaComponent:0.5] set];
  NSRectFill([self bounds]);
}

@end

namespace electron {

InspectableWebContentsView* CreateInspectableContentsView(
    InspectableWebContents* inspectable_web_contents) {
  return new InspectableWebContentsViewMac(inspectable_web_contents);
}

InspectableWebContentsViewMac::InspectableWebContentsViewMac(
    InspectableWebContents* inspectable_web_contents)
    : InspectableWebContentsView(inspectable_web_contents),
      view_([[ElectronInspectableWebContentsView alloc]
          initWithInspectableWebContentsViewMac:this]) {}

InspectableWebContentsViewMac::~InspectableWebContentsViewMac() {
  CloseDevTools();
}

gfx::NativeView InspectableWebContentsViewMac::GetNativeView() const {
  return view_.get();
}

void InspectableWebContentsViewMac::ShowDevTools(bool activate) {
  [view_ setDevToolsVisible:YES activate:activate];
}

void InspectableWebContentsViewMac::CloseDevTools() {
  [view_ setDevToolsVisible:NO activate:NO];
}

bool InspectableWebContentsViewMac::IsDevToolsViewShowing() {
  return [view_ isDevToolsVisible];
}

bool InspectableWebContentsViewMac::IsDevToolsViewFocused() {
  return [view_ isDevToolsFocused];
}

void InspectableWebContentsViewMac::SetIsDocked(bool docked, bool activate) {
  [view_ setIsDocked:docked activate:activate];
}

void InspectableWebContentsViewMac::SetContentsResizingStrategy(
    const DevToolsContentsResizingStrategy& strategy) {
  [view_ setContentsResizingStrategy:strategy];
}

void InspectableWebContentsViewMac::SetTitle(const std::u16string& title) {
  [view_ setTitle:base::SysUTF16ToNSString(title)];
}

}  // namespace electron
