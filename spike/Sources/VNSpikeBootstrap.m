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
                    // One argument-free literal per outcome, rather than a single
                    // NSLog carrying %d.
                    //
                    // MEASURED (docs/IOS-BUILD.md): neither USB relay this project
                    // debugs through -- os_trace_relay nor syslog_relay, via
                    // idevicesyslog -- delivers the argument payload of a third-party
                    // binary's os_log entries. Only the literal format string arrives.
                    // A line reading "rc=%d" therefore shows up as nothing readable at
                    // all, which is precisely the case where we most need to read it.
                    // The previous version of this file logged exactly that, and the
                    // first device run could not distinguish "installed but invisible"
                    // from "never installed".
                    int rc = vnspike_install_overlay();
                    switch (rc) {
                        case 1:
                            NSLog(@"[vnspike] overlay installed");
                            break;
                        case 2:
                            NSLog(@"[vnspike] overlay already installed");
                            break;
                        case -1:
                            NSLog(@"[vnspike] overlay FAILED not main thread");
                            break;
                        case -2:
                            NSLog(@"[vnspike] overlay FAILED no window scene");
                            break;
                        case -3:
                            NSLog(@"[vnspike] overlay FAILED zero-size window");
                            break;
                        default:
                            NSLog(@"[vnspike] overlay FAILED unrecognised return code");
                            break;
                    }
                }];
    NSLog(@"[vnspike] bootstrap registered");
}

@end
