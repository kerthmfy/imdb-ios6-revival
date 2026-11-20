// IMDBCapture v1.0 — marker + request hooks, logging to sandbox-safe paths.
//
// Earlier builds wrote to /var/mobile/Library/Logs, which an App Store sandbox
// may deny, making "no log" indistinguishable from "not injected". This writes
// to $HOME/Documents (the app's own container) and /tmp, both allowed.
#import <Foundation/Foundation.h>
#import <UIKit/UIWebView.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static const char *gPaths[2];

static void InitPaths(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    static char containerPath[512];
    const char *home = getenv("HOME");
    if (home) {
        snprintf(containerPath, sizeof(containerPath), "%s/Documents/imdb-capture.log", home);
        gPaths[0] = containerPath;
    }
    gPaths[1] = "/tmp/imdb-capture.log";
}

static void CLog(const char *fmt, ...) {
    InitPaths();
    for (int i = 0; i < 2; i++) {
        if (!gPaths[i]) continue;
        FILE *f = fopen(gPaths[i], "a");
        if (!f) continue;
        va_list ap;
        va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fputc('\n', f);
        fclose(f);
    }
}

__attribute__((constructor)) static void v10_marker(void) {
    CLog("=== v1.0 loaded, pid %d, HOME=%s ===", getpid(), getenv("HOME") ?: "(null)");
}

%hook NSURLConnection

- (id)initWithRequest:(NSURLRequest *)request delegate:(id)delegate {
    CLog("REQ[init] %s %s", (request.HTTPMethod ?: @"GET").UTF8String, request.URL.absoluteString.UTF8String);
    return %orig;
}

- (id)initWithRequest:(NSURLRequest *)request delegate:(id)delegate startImmediately:(BOOL)startImmediately {
    CLog("REQ[init-start] %s %s", (request.HTTPMethod ?: @"GET").UTF8String, request.URL.absoluteString.UTF8String);
    return %orig;
}

+ (NSURLConnection *)connectionWithRequest:(NSURLRequest *)request delegate:(id)delegate {
    CLog("REQ[connWith] %s %s", (request.HTTPMethod ?: @"GET").UTF8String, request.URL.absoluteString.UTF8String);
    return %orig;
}

+ (NSData *)sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error {
    CLog("REQ[sync] %s %s", (request.HTTPMethod ?: @"GET").UTF8String, request.URL.absoluteString.UTF8String);
    return %orig;
}

%end

%hook UIWebView

- (void)loadRequest:(NSURLRequest *)request {
    CLog("WEB[loadRequest] %s", request.URL.absoluteString.UTF8String);
    %orig;
}

%end
