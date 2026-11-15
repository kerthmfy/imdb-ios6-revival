// IMDBCapture v0.8 — marker plus every plausible request entry point.
#import <Foundation/Foundation.h>
#import <UIKit/UIWebView.h>
#include <stdio.h>
#include <unistd.h>

#define LOG_PATH "/var/mobile/Library/Logs/imdb-capture.log"

static void CLog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    FILE *f = fopen(LOG_PATH, "a");
    if (f) {
        vfprintf(f, fmt, ap);
        fputc('\n', f);
        fclose(f);
    }
    va_end(ap);
}

__attribute__((constructor)) static void v08_marker(void) {
    CLog("=== v0.8 loaded in pid %d ===", getpid());
}

%hook NSURLConnection

- (id)initWithRequest:(NSURLRequest *)request delegate:(id)delegate {
    CLog("REQ[init] %s", request.URL.absoluteString.UTF8String);
    return %orig;
}

- (id)initWithRequest:(NSURLRequest *)request delegate:(id)delegate startImmediately:(BOOL)startImmediately {
    CLog("REQ[init-start] %s", request.URL.absoluteString.UTF8String);
    return %orig;
}

+ (NSURLConnection *)connectionWithRequest:(NSURLRequest *)request delegate:(id)delegate {
    CLog("REQ[connWith] %s", request.URL.absoluteString.UTF8String);
    return %orig;
}

+ (NSData *)sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error {
    CLog("REQ[sync] %s", request.URL.absoluteString.UTF8String);
    return %orig;
}

%end

%hook UIWebView

- (void)loadRequest:(NSURLRequest *)request {
    CLog("WEB[loadRequest] %s", request.URL.absoluteString.UTF8String);
    %orig;
}

- (void)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    CLog("WEB[loadHTML] base=%s", baseURL.absoluteString.UTF8String);
    %orig;
}

- (void)loadData:(NSData *)data MIMEType:(NSString *)mimeType textEncodingName:(NSString *)encodingName baseURL:(NSURL *)baseURL {
    CLog("WEB[loadData] base=%s", baseURL.absoluteString.UTF8String);
    %orig;
}

%end

%hook NSMutableURLRequest

- (void)setURL:(NSURL *)URL {
    CLog("SETURL %s", URL.absoluteString.UTF8String);
    %orig;
}

%end
