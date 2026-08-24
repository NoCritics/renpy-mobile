// THROWAWAY SPIKE CODE — not the eventual design.
//
// Installs the SwiftUI overlay without Python's involvement.
//
// The previous iteration installed it from Python via ctypes, which the device proved
// impossible: ctypes.CDLL(None) cannot resolve any symbol in this binary, not even
// libpython's own. So the overlay has to bootstrap itself natively.
//
// +load runs before UIKit exists, so it cannot create a window directly. It registers
// for the notification instead, and installs on the first activation.

@import Foundation;
@import UIKit;

// Implemented in Swift with @_cdecl. ObjC needs only the C declaration.
extern int vnspike_install_overlay(void);

@interface VNSpikeBootstrap : NSObject
@end

@implementation VNSpikeBootstrap

+ (void)load {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    int rc = vnspike_install_overlay();
                    NSLog(@"[vnspike] install_overlay rc=%d", rc);
                }];
    NSLog(@"[vnspike] bootstrap registered");
}

@end
