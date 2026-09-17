//
//  main.m
//  videostabilization
//
//  Created by PixSmart on 2025/2/13.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#include <stdio.h>

int main(int argc, char * argv[]) {
    NSString * appDelegateClassName;
    
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = NSStringFromClass([AppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
