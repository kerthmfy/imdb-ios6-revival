// IMDBCapture 2.0 — serving build (§13.4 step 2).
//
// The 1.x builds logged every IMDb request and then failed it with -1004. That
// proved the interception layer works, but it also stopped the app at its first
// call, so the rest of a title page's request chain was never made. This build
// serves app.imdb.com from on-device fixtures and lets every other host load
// normally, so a title tap runs to completion and each remaining route shows up
// in the log as something still to build.
//
// What it does:
//   * app.imdb.com      -> served from /Library/IMDbRevival/routes (protocol)
//   * every other host  -> handed back to the system loader untouched
//   * IMDb/Amazon hosts -> logged once per second per URL, as a cross-check
//
// Interception is above TLS: the protocol is handed the URLRequest before any
// socket exists, so https://app.imdb.com is answered with plain NSData and no
// certificate, CA profile, hosts entry or listening port is involved.
//
// Build sentinel: IMDB_NEEDS_ROUTES. deploy.sh greps the dylib for it and
// refuses to install unless the routes directory is present and non-empty,
// because this build renders empty pages without its fixtures.
//
// Log paths, in the order they are tried:
//   $HOME/Documents/imdb-probe.jsonl   (app container; survives reboots)
//   /tmp/imdb-probe.jsonl              (root-writable, cleared on reboot)

#import <Foundation/Foundation.h>
#import <UIKit/UIWebView.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

__attribute__((used)) static const char kBuild[] = "IMDB_SERVE_BUILD IMDB_NEEDS_ROUTES";

static NSString *gLogPaths[2] = { nil, nil };
static NSLock *gLogLock = nil;
static NSMutableSet *gSeen = nil;      // dedupe for pass-through logging
static NSString * const kRoutesDir = @"/Library/IMDbRevival/routes";

static void ProbeInit(void) {
    static int done = 0;
    if (done) return;
    done = 1;

    gLogLock = [[NSLock alloc] init];
    gSeen = [[NSMutableSet alloc] init];
    gLogPaths[1] = @"/tmp/imdb-probe.jsonl";

    const char *home = getenv("HOME");
    if (home) {
        gLogPaths[0] = [[NSString alloc] initWithFormat:@"%s/Documents/imdb-probe.jsonl", home];
    }
}

static void ProbeEmit(NSDictionary *fields) {
    ProbeInit();
    if (!fields) return;

    NSData *data = [NSJSONSerialization dataWithJSONObject:fields options:0 error:NULL];
    if (!data) return;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!line) return;

    [gLogLock lock];
    for (int i = 0; i < 2; i++) {
        if (!gLogPaths[i]) continue;
        FILE *f = fopen([gLogPaths[i] UTF8String], "a");
        if (!f) continue;
        fprintf(f, "%s\n", [line UTF8String]);
        fclose(f);
    }
    [gLogLock unlock];

    [line release];
}

static NSString *HexPrefix(NSData *data, NSUInteger max) {
    if (!data) return @"";
    const unsigned char *bytes = (const unsigned char *)[data bytes];
    NSUInteger n = [data length];
    if (n > max) n = max;

    NSMutableString *out = [NSMutableString stringWithCapacity:n * 2];
    for (NSUInteger i = 0; i < n; i++) {
        [out appendFormat:@"%02x", bytes[i]];
    }
    if ([data length] > max) [out appendString:@"..."];
    return out;
}

static NSString *ProbeISO8601(void) {
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char buf[32];
    strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &tmv);
    return [NSString stringWithUTF8String:buf];
}

// One JSON object per line describing a request. headers and body are what the
// 1.x build lacked; both are needed to rebuild a route faithfully.
static void ProbeLogRequest(NSURLRequest *request, NSString *src, NSDictionary *extra) {
    if (!request || !src) return;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"request" forKey:@"event"];
    [d setObject:src forKey:@"src"];
    [d setObject:ProbeISO8601() forKey:@"ts"];
    [d setObject:[NSNumber numberWithLongLong:(long long)time(NULL)] forKey:@"epoch"];
    [d setObject:[NSNumber numberWithInt:(int)getpid()] forKey:@"pid"];
    [d setObject:(request.HTTPMethod ? request.HTTPMethod : @"GET") forKey:@"method"];
    [d setObject:(request.URL.absoluteString ? request.URL.absoluteString : @"") forKey:@"url"];
    if (request.URL.host) [d setObject:request.URL.host forKey:@"host"];
    if (request.URL.path) [d setObject:request.URL.path forKey:@"path"];
    if (request.URL.query) [d setObject:request.URL.query forKey:@"query"];
    if (request.URL.scheme) [d setObject:[request.URL.scheme lowercaseString] forKey:@"scheme"];
    if (request.allHTTPHeaderFields.count) {
        [d setObject:request.allHTTPHeaderFields forKey:@"headers"];
    }
    if (request.HTTPBody) {
        [d setObject:[NSNumber numberWithUnsignedInteger:request.HTTPBody.length] forKey:@"body_len"];
        [d setObject:HexPrefix(request.HTTPBody, 2048) forKey:@"body_hex"];
    } else if (request.HTTPBodyStream) {
        [d setObject:@"stream" forKey:@"body_stream"];
    }
    [d setObject:[NSNumber numberWithBool:[NSThread isMainThread]] forKey:@"main"];
    if (extra) [d addEntriesFromDictionary:extra];

    ProbeEmit(d);
}

// IMDb's hosts, matched by suffix so app./sg./ia./www. and friends all match.
static BOOL IMDBHostMatches(NSString *host) {
    if (![host length]) return NO;
    NSString *h = [host lowercaseString];
    NSArray *domains = [NSArray arrayWithObjects:@"imdb.com", @"imdbws.com", @"media-imdb.com", nil];
    for (NSString *domain in domains) {
        if ([h isEqualToString:domain]) return YES;
        if ([h hasSuffix:[@"." stringByAppendingString:domain]]) return YES;
    }
    return NO;
}

// Requests that pass through the protocol registry are seen many times (once per
// canInit query). Collapse repeats of the same URL within one second, which keeps
// the log readable without hiding genuine retries.
static void LogPassThrough(NSURLRequest *request) {
    if (!request) return;
    NSString *method = request.HTTPMethod ? request.HTTPMethod : @"GET";
    NSString *key = [NSString stringWithFormat:@"%@|%@|%ld|%d",
                     method, request.URL.absoluteString, (long)time(NULL), (int)getpid()];

    BOOL fresh = NO;
    [gLogLock lock];
    if (![gSeen containsObject:key]) {
        [gSeen addObject:key];
        fresh = YES;
    }
    // Housekeeping: the set only needs to cover the last second or so.
    if ([gSeen count] > 4000) [gSeen removeAllObjects];
    [gLogLock unlock];

    if (fresh) ProbeLogRequest(request, @"passthrough", nil);
}

static void LogLoadContext(void) {
    const char *ins = getenv("DYLD_INSERT_LIBRARIES");
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"loadctx" forKey:@"event"];
    [d setObject:@"2.0-serve" forKey:@"build"];
    [d setObject:ProbeISO8601() forKey:@"ts"];
    [d setObject:[NSNumber numberWithInt:(int)getpid()] forKey:@"pid"];
    [d setObject:(ins ? [NSString stringWithUTF8String:ins] : @"(unset)") forKey:@"insert"];

    NSMutableArray *interesting = [NSMutableArray array];
    uint32_t total = _dyld_image_count();
    for (uint32_t i = 0; i < total; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "IMDBCapture") || strstr(name, "Substrate") ||
            strstr(name, "substrate") || strstr(name, "AppStoreFix") ||
            strstr(name, "SSLPatch") || strstr(name, "tlsfix") ||
            strstr(name, "MobileSafety")) {
            [interesting addObject:[NSString stringWithUTF8String:name]];
        }
    }
    [d setObject:[NSNumber numberWithUnsignedInt:total] forKey:@"image_count"];
    [d setObject:interesting forKey:@"images"];
    ProbeEmit(d);
}

#pragma mark - route table

// Redirect check. Requests the tweak will issue itself later (live fetches) must
// carry this property so they are not served in a loop; nothing issues them yet.
static NSString * const kServedKey = @"IMDBServedRequest";

// Search-as-you-type is what makes a title reachable at all. The app asks
// sg.media-imdb.com over http, upstream answers 301 to https, and this device's
// TLS cannot handshake with that host (E5: NSURLErrorDomain -1200), so the
// suggestion list comes back empty and there is nothing to tap. Serving
// /suggests here keeps the search path on the shim side of that wall.
static BOOL IsSuggestsRequest(NSURLRequest *request) {
    NSString *host = [request.URL.host lowercaseString];
    return [host isEqualToString:@"sg.media-imdb.com"] &&
           [request.URL.path hasPrefix:@"/suggests/"];
}

static BOOL IsDashRoute(NSString *path) {
    return ([path rangeOfString:@"maindetails"].location != NSNotFound);
}

// nil means "no fixture yet": the caller answers 404 and the log records it, so
// the missing routes are exactly the set listed in the capture.
static NSString *RouteNameForRequest(NSURLRequest *request) {
    NSString *path = request.URL.path;
    if (!path) return nil;

    if ([path isEqualToString:@"/hello"]) return @"hello.json";

    if ([path hasPrefix:@"/title/"] && IsDashRoute(path)) return @"md-2012.json";
    if ([path isEqualToString:@"/title/maindetails"]) return @"md-2012.json";

    return nil;
}

// /title/tt0133093/maindetails/ and ?tconst= are both legacy shapes; take
// whichever the app used.
static NSString *TconstForRequest(NSURLRequest *request) {
    NSString *path = request.URL.path;
    if ([path hasPrefix:@"/title/"]) {
        NSArray *parts = [path componentsSeparatedByString:@"/"];
        if ([parts count] > 2) {
            NSString *cand = [parts objectAtIndex:2];
            if ([cand length] == 9 && [cand hasPrefix:@"tt"]) return cand;
        }
    }
    NSString *q = request.URL.query;
    if (q) {
        NSArray *pairs = [q componentsSeparatedByString:@"&"];
        for (NSString *pair in pairs) {
            if ([pair hasPrefix:@"tconst="]) {
                return [pair substringFromIndex:7];
            }
        }
    }
    return nil;
}

static NSData *JSONErrorBody(NSString *message) {
    NSDictionary *d = [NSDictionary dictionaryWithObject:message forKey:@"error"];
    NSDictionary *wrap = [NSDictionary dictionaryWithObject:d forKey:@"data"];
    return [NSJSONSerialization dataWithJSONObject:wrap options:0 error:NULL];
}

// Fixtures are served as-is except for two live fields: `exp` must be in the
// future or the legacy client treats the payload as stale (§4.5), and tconst
// must match what was asked for or the page shows the wrong title's data.
static NSData *ServeRoute(NSURLRequest *request, NSInteger *statusOut, NSString **routeOut, NSString **ctypeOut) {
    if (ctypeOut) *ctypeOut = @"application/json";

    // Suggestions are JSONP-ish: imdb$<prefix>({...}). The callback name has to
    // match the prefix the app asked for or it is ignored.
    if (IsSuggestsRequest(request)) {
        if (routeOut) *routeOut = @"suggests.json";
        NSData *inner = [NSData dataWithContentsOfFile:
                         [kRoutesDir stringByAppendingPathComponent:@"suggests.json"]];
        if (!inner) {
            *statusOut = 503;
            return JSONErrorBody(@"IMDb revival: suggests.json missing");
        }
        NSString *leaf = [[request.URL.path lastPathComponent] stringByDeletingPathExtension];
        if (![leaf length]) leaf = @"x";
        NSString *payload = [[[NSString alloc] initWithData:inner encoding:NSUTF8StringEncoding] autorelease];
        NSString *text = [NSString stringWithFormat:@"imdb$%@(%@)", leaf, payload ? payload : @"{}"];
        if (ctypeOut) *ctypeOut = @"application/javascript";
        *statusOut = 200;
        return [text dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSString *name = RouteNameForRequest(request);
    if (routeOut) *routeOut = name ? name : @"(none)";
    if (!name) {
        *statusOut = 404;
        return JSONErrorBody(@"IMDb revival: route not built yet");
    }

    NSString *file = [kRoutesDir stringByAppendingPathComponent:name];
    NSData *raw = [NSData dataWithContentsOfFile:file];
    if (!raw) {
        *statusOut = 503;
        return JSONErrorBody([NSString stringWithFormat:@"IMDb revival: fixture %@ unreadable", name]);
    }
    if ([name isEqualToString:@"hello.json"]) {
        *statusOut = 200;
        return raw;
    }

    id obj = [NSJSONSerialization JSONObjectWithData:raw
                                             options:NSJSONReadingMutableContainers
                                               error:NULL];
    if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *d = (NSMutableDictionary *)obj;
        [d setObject:[NSNumber numberWithLongLong:(long long)time(NULL) + 3600] forKey:@"exp"];

        NSString *tconst = TconstForRequest(request);
        id data = [d objectForKey:@"data"];
        if (tconst && [data isKindOfClass:[NSMutableDictionary class]]) {
            [data setObject:tconst forKey:@"tconst"];
        }
        NSData *out = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
        if (out) {
            *statusOut = 200;
            return out;
        }
    }

    *statusOut = 200;
    return raw;
}

#pragma mark - protocol

@interface IMDBServeProtocol : NSURLProtocol
@end

@implementation IMDBServeProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request) return NO;

    // Never re-enter on our own sub-requests.
    if ([NSURLProtocol propertyForKey:kServedKey inRequest:request]) return NO;

    NSString *host = [[request URL].host lowercaseString];
    if ([host isEqualToString:@"app.imdb.com"]) return YES;
    if (IsSuggestsRequest(request)) return YES;

    // Everything else is the system's business, but IMDb/Amazon traffic is worth
    // recording: it is how the follow-up calls of a title page show up.
    if (IMDBHostMatches(host)) LogPassThrough(request);
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSURLRequest *request = [self request];

    NSInteger status = 200;
    NSString *route = nil;
    NSString *ctype = @"application/json";
    NSData *body = ServeRoute(request, &status, &route, &ctype);
    if (!body) body = [NSData data];

    ProbeLogRequest(request, @"serve",
                    [NSDictionary dictionaryWithObjectsAndKeys:
                     route, @"route",
                     [NSNumber numberWithInteger:status], @"served_status",
                     [NSNumber numberWithUnsignedInteger:[body length]], @"served_bytes",
                     nil]);

    if (!ctype) ctype = @"application/json";
    NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:
                             ctype, @"Content-Type",
                             [NSString stringWithFormat:@"%lu", (unsigned long)[body length]], @"Content-Length",
                             nil];

    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:[request URL]
                                                         statusCode:status
                                                        HTTPVersion:@"HTTP/1.1"
                                                       headerFields:headers];
    [[self client] URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if ([body length]) [[self client] URLProtocol:self didLoadData:body];
    [[self client] URLProtocolDidFinishLoading:self];
    [resp release];
}

- (void)stopLoading {
}

@end

%ctor {
    ProbeInit();
    [NSURLProtocol registerClass:[IMDBServeProtocol class]];
    LogLoadContext();

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"loaded" forKey:@"event"];
    [d setObject:@"2.1-serve" forKey:@"build"];
    [d setObject:ProbeISO8601() forKey:@"ts"];
    [d setObject:[NSNumber numberWithInt:(int)getpid()] forKey:@"pid"];
    [d setObject:(getenv("HOME") ? [NSString stringWithUTF8String:getenv("HOME")] : @"(null)")
           forKey:@"home"];
    [d setObject:@"IMDBServeProtocol" forKey:@"protocol"];
    [d setObject:kRoutesDir forKey:@"routes"];
    ProbeEmit(d);
}

%hook NSURLConnection

- (id)initWithRequest:(NSURLRequest *)request delegate:(id)delegate {
    if (IMDBHostMatches(request.URL.host)) ProbeLogRequest(request, @"NSURLConnection:init", nil);
    return %orig;
}

- (id)initWithRequest:(NSURLRequest *)request delegate:(id)delegate startImmediately:(BOOL)startImmediately {
    if (IMDBHostMatches(request.URL.host)) ProbeLogRequest(request, @"NSURLConnection:init-start", nil);
    return %orig;
}

+ (NSURLConnection *)connectionWithRequest:(NSURLRequest *)request delegate:(id)delegate {
    if (IMDBHostMatches(request.URL.host)) ProbeLogRequest(request, @"NSURLConnection:connectionWithRequest", nil);
    return %orig;
}

+ (NSData *)sendSynchronousRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error {
    if (IMDBHostMatches(request.URL.host)) ProbeLogRequest(request, @"NSURLConnection:sendSynchronousRequest", nil);
    return %orig;
}

%end

%hook UIWebView

- (void)loadRequest:(NSURLRequest *)request {
    if (IMDBHostMatches(request.URL.host)) ProbeLogRequest(request, @"UIWebView:loadRequest", nil);
    %orig;
}

%end
