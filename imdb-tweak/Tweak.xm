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
#include <dlfcn.h>
#include <objc/runtime.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void InstallDataWrapperAccessorHooks(void);

__attribute__((used)) static const char kBuild[] = "IMDB_SERVE_BUILD IMDB_NEEDS_ROUTES";

static NSString *gLogPaths[2] = { nil, nil };
static NSLock *gLogLock = nil;
static NSMutableSet *gSeen = nil;      // dedupe for pass-through logging
static NSMutableDictionary *gImageCache = nil;   // relayed photos, by live URL
static NSLock *gImageCacheLock = nil;
static NSString * const kRoutesDir = @"/Library/IMDbRevival/routes";

static void ProbeInit(void) {
    static int done = 0;
    if (done) return;
    done = 1;

    gLogLock = [[NSLock alloc] init];
    gSeen = [[NSMutableSet alloc] init];
    gImageCache = [[NSMutableDictionary alloc] init];
    gImageCacheLock = [[NSLock alloc] init];
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

// Every answer this tweak hands back is for the page that is open right now, so
// none of it may be stored: a cached body is how the same URL kept showing the
// old title after the data behind it changed.
static NSDictionary *ResponseHeaders(NSString *ctype, NSUInteger length) {
    return [NSDictionary dictionaryWithObjectsAndKeys:
            (ctype ? ctype : @"application/json"), @"Content-Type",
            [NSString stringWithFormat:@"%lu", (unsigned long)length], @"Content-Length",
            @"no-store, no-cache, must-revalidate", @"Cache-Control",
            @"no-cache", @"Pragma",
            @"0", @"Expires",
            nil];
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
    [d setObject:@"4.2-omdb" forKey:@"build"];
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

#pragma mark - live data (TLSFix)

// Marks a request as one the tweak issued itself, so canInitWithRequest: lets it
// through instead of serving it again (recursion guard). Declared here because
// both the live fetch and its probe need it before the route table.
static NSString * const kServedKey = @"IMDBServedRequest";

// §17: the stock stack cannot handshake with sg.media-imdb.com or
// api.graphql.imdb.com. The failure is errSSLPeerHandshakeFail (-9824), a
// protocol mismatch, not trust. tlsfix.dylib patches CFNetwork and fixes it —
// but Substrate injects into no new process here (§14.2), so nothing loads it
// by itself. Load it ourselves, before the app's first request.
static NSString * const kTLSFixPath = @"/Library/MobileSubstrate/DynamicLibraries/tlsfix.dylib";
// Presence of this file turns on the live-fetch probe. It is a diagnostic, not a
// feature: without the file nothing extra happens at launch.
static NSString * const kLiveTestMark = @"/Library/IMDbRevival/livetest";

static BOOL TLSFixImageLoaded(void) {
    uint32_t total = _dyld_image_count();
    for (uint32_t i = 0; i < total; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "tlsfix")) return YES;
    }
    return NO;
}
// Returns nil on success, or the reason it could not be loaded.
static NSString *LoadTLSFix(void) {
    if (TLSFixImageLoaded()) return nil;
    if (access([kTLSFixPath UTF8String], R_OK) != 0) return @"missing";
    void *h = dlopen([kTLSFixPath UTF8String], RTLD_NOW | RTLD_GLOBAL);
    if (h) return nil;
    const char *e = dlerror();
    return [NSString stringWithFormat:@"dlopen: %s", e ? e : "unknown error"];
}

// One synchronous fetch, logged as a `livetest` line. Runs on a background
// thread so a dead host cannot stall the launch.
static NSDictionary *FetchTitleInfo(NSString *tconst, NSInteger *statusOut, NSString **errOut);
static NSArray *FetchTmdbCast(NSString *tconst, NSString **errOut);
static NSString *TitleInfoSource(void);
static NSData *ServeRoute(NSURLRequest *request, NSDictionary *titleInfo,
                          NSInteger *statusOut, NSString **routeOut, NSString **ctypeOut);
static NSString *FirstWidgetTitleIn(id node);

@interface IMDBLiveTest : NSObject
- (void)run:(id)ignored;
@end

@implementation IMDBLiveTest

- (void)probeURL:(NSString *)url label:(NSString *)label bypassTweak:(BOOL)bypass {
    [self probeURL:url label:label bypassTweak:bypass method:@"GET" body:nil ctype:nil timeout:20];
}

// One probe, one `livetest` line.
//
// For a host matrix the decisive field is not `status` but whether an NSError
// came back at all. -9824 (errSSLPeerHandshakeFail) and -1200 are the TLS wall:
// the handshake never completed, so no HTTP status exists. Any status — 200,
// 403, 400 from a GraphQL POST — means TLS succeeded and the host is reachable
// for live data. `error_code` nil + `status` present is the pass condition.
- (void)probeURL:(NSString *)url label:(NSString *)label bypassTweak:(BOOL)bypass
          method:(NSString *)method body:(NSData *)body ctype:(NSString *)ctype
         timeout:(NSTimeInterval)timeout {
    [self probeURL:url label:label bypassTweak:bypass method:method body:body ctype:ctype
           timeout:timeout headers:nil];
}

// `headers` overrides the default UA and adds Origin/Referer/Accept. Called with
// nil by every legacy probe, so only the header experiment changes behaviour.
- (void)probeURL:(NSString *)url label:(NSString *)label bypassTweak:(BOOL)bypass
          method:(NSString *)method body:(NSData *)body ctype:(NSString *)ctype
         timeout:(NSTimeInterval)timeout headers:(NSDictionary *)headers {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setTimeoutInterval:timeout];
    // Without this a cached body makes a broken TLS path look healthy: the first
    // no-tlsfix run reported 200/3,170 B from cache while the fetch was failing.
    [req setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
    // A real UA matters: api.graphql.imdb.com answered 403 to a bare POST in E5.
    [req setValue:@"IMDb/3.4.2 (iPad; iPhone OS 6.1.3)" forHTTPHeaderField:@"User-Agent"];
    for (NSString *k in headers) {
        [req setValue:[headers objectForKey:k] forHTTPHeaderField:k];
    }
    if (method) [req setHTTPMethod:method];
    if (body) {
        [req setHTTPBody:body];
        [req setValue:(ctype ? ctype : @"application/json") forHTTPHeaderField:@"Content-Type"];
    }
    // IsSuggestsRequest matches https too, so without this the "raw" probe is
    // answered by our own protocol and its bytes say nothing about TLS.
    if (bypass) {
        [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:kServedKey inRequest:req];
    }

    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    // Elapsed time separates "refused/failed fast" from "handshake hung until
    // the timeout", which the error code alone does not.
    NSDate *started = [NSDate date];
    NSData *bodyIn = [NSURLConnection sendSynchronousRequest:req
                                           returningResponse:(NSURLResponse **)&resp
                                                       error:&err];
    NSTimeInterval elapsed = -[started timeIntervalSinceNow];

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"livetest" forKey:@"event"];
    [d setObject:label forKey:@"target"];
    [d setObject:url forKey:@"url"];
    [d setObject:ProbeISO8601() forKey:@"ts"];
    [d setObject:[NSNumber numberWithInt:(int)getpid()] forKey:@"pid"];
    [d setObject:[NSNumber numberWithBool:TLSFixImageLoaded()] forKey:@"tlsfix"];
    [d setObject:[NSNumber numberWithInt:(int)(elapsed * 1000)] forKey:@"ms"];

    if (err) {
        [d setObject:[NSNumber numberWithInteger:[err code]] forKey:@"error_code"];
        [d setObject:[[err userInfo] description] forKey:@"error"];
        // -1012 is not a handshake failure: the connection completed and the
        // host answered 401, so the host is reachable and only a key is missing
        // (confirmed from the Mac: OMDb and TMDB both answer 401 JSON).
        [d setObject:([err code] == -1012 ? @"reachable-auth" : @"tls-wall")
               forKey:@"verdict"];
    } else {
        [d setObject:[NSNumber numberWithInteger:[resp statusCode]] forKey:@"status"];
        [d setObject:[NSNumber numberWithUnsignedInteger:[bodyIn length]] forKey:@"bytes"];
        NSString *ct = [[resp allHeaderFields] objectForKey:@"Content-Type"];
        if (ct) [d setObject:ct forKey:@"ctype"];
        // A status means the handshake completed. 200 with a body means usable.
        [d setObject:([resp statusCode] == 200 && [bodyIn length] > 0) ? @"usable" : @"reachable"
               forKey:@"verdict"];
        if ([bodyIn length]) {
            NSUInteger n = [bodyIn length] < 160 ? [bodyIn length] : 160;
            NSString *head = [[[NSString alloc] initWithData:[bodyIn subdataWithRange:NSMakeRange(0, n)]
                                                    encoding:NSUTF8StringEncoding] autorelease];
            if (head) [d setObject:head forKey:@"head"];
        }
    }
    ProbeEmit(d);
}

- (void)run:(id)ignored {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    // Raw TLS: the tweak is told to keep its hands off these two.
    [self probeURL:@"https://sg.media-imdb.com/suggests/t/the.json" label:@"sg-raw" bypassTweak:YES];
    [self probeURL:@"https://v3.sg.media-imdb.com/suggestion/t/the.json" label:@"v3-raw" bypassTweak:YES];
    // Same request the app makes, so it goes through IMDBServeProtocol: canInit,
    // worker thread, live fetch, delivery back to this client. Proves the route,
    // not just the network.
    [self probeURL:@"http://sg.media-imdb.com/suggests/t/the.json" label:@"sg-protocol" bypassTweak:NO];
    // A prefix upstream has nothing for: must end up on the fixture, not an
    // empty page. The serve line says which side answered.
    [self probeURL:@"http://sg.media-imdb.com/suggests/z/zzzqqqx.json" label:@"sg-fallback" bypassTweak:NO];

    // --- host matrix (3.7-reach) -------------------------------------------------
    // The question this answers: can live per-title data be assembled ON the
    // device, or does it need a relay on the Mac? Each label is one candidate
    // source of title data, probed with the UA the app itself sends.

    // Known-good asset: the poster path the fixture already renders, so a
    // failure here is TLS and not a typo'd URL.
    [self probeURL:@"https://m.media-amazon.com/images/M/MV5BN2NmN2VhMTQtMDNiOS00NDlhLTliMjgtODE2ZTY0ODQyNDRhXkEyXkFqcGc@._V1_.jpg"
             label:@"amazon-image" bypassTweak:YES method:@"GET" body:nil ctype:nil timeout:12];

    // The current IMDb web page: modern pages embed __NEXT_DATA__ / JSON-LD, so
    // if this returns HTML at all, per-title data is one parse away.
    [self probeURL:@"https://www.imdb.com/title/tt0133093/"
             label:@"www-title" bypassTweak:YES method:@"GET" body:nil ctype:nil timeout:12];
    [self probeURL:@"https://m.imdb.com/title/tt0133093/"
             label:@"m-title" bypassTweak:YES method:@"GET" body:nil ctype:nil timeout:12];

    // GraphQL. A 400/403 is still a pass for reachability; only an NSError is
    // the wall. Both hosts are probed because the app and the modern web client
    // use different ones.
    NSData *gql = [[@"{\"query\":\"query { title(id: \\\"tt0133093\\\") { id titleText { text } } }\"}"
                    dataUsingEncoding:NSUTF8StringEncoding] retain];
    [self probeURL:@"https://api.graphql.imdb.com/" label:@"graphql-api" bypassTweak:YES
            method:@"POST" body:gql ctype:@"application/json" timeout:12];

    // The two third-party APIs that could fill the rest of the title page. No
    // key is sent on purpose: what matters here is whether the handshake works
    // at all, and a 401/403 with a JSON body is a pass (status, no NSError).
    [self probeURL:@"https://www.omdbapi.com/?i=tt0133093&plot=short" label:@"omdb-nokey" bypassTweak:YES
            method:@"GET" body:nil ctype:nil timeout:12];
    [self probeURL:@"https://api.themoviedb.org/3/find/tt0133093?external_source=imdb_id" label:@"tmdb-nokey" bypassTweak:YES
            method:@"GET" body:nil ctype:nil timeout:12];
    [self probeURL:@"https://caching.graphql.imdb.com/" label:@"graphql-cache" bypassTweak:YES
            method:@"POST" body:gql ctype:@"application/json" timeout:12];

    // Phase 2: the same three, dressed as a browser. This separates the two
    // explanations for 202/0-byte and 403: "nobody told us we were a browser"
    // (fixable in-request) vs "there is an auth/challenge gate" (needs a relay).
    NSDictionary *browser = [NSDictionary dictionaryWithObjectsAndKeys:
        @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        @"(KHTML, like Gecko) Chrome/120.0 Safari/537.36", @"User-Agent",
        @"https://www.imdb.com", @"Origin",
        @"https://www.imdb.com/title/tt0133093/", @"Referer",
        @"text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8", @"Accept",
        @"en-US,en;q=0.9", @"Accept-Language",
        nil];
    [self probeURL:@"https://www.imdb.com/title/tt0133093/" label:@"www-browser" bypassTweak:YES
            method:@"GET" body:nil ctype:nil timeout:12 headers:browser];
    [self probeURL:@"https://m.imdb.com/title/tt0133093/" label:@"m-browser" bypassTweak:YES
            method:@"GET" body:nil ctype:nil timeout:12 headers:browser];
    [self probeURL:@"https://api.graphql.imdb.com/" label:@"graphql-browser" bypassTweak:YES
            method:@"POST" body:gql ctype:@"application/json" timeout:12 headers:browser];
    [gql release];

    // --- per-title path (3.8) -------------------------------------------------
    // Resolve a few tconsts exactly the way a title page does, then build the
    // body the app would receive. Logged as `titleinfo` and `titlebody` so the
    // payload can be checked without tapping through the UI.
    NSArray *ids = [NSArray arrayWithObjects:@"tt0133093", @"tt0068646", @"tt0111161",
                    @"tt9999999", nil];
    for (NSString *tid in ids) {
        NSInteger st = 0;
        NSString *e = nil;
        NSDictionary *info = FetchTitleInfo(tid, &st, &e);
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        [d setObject:@"titleinfo" forKey:@"event"];
        [d setObject:tid forKey:@"tconst"];
        [d setObject:ProbeISO8601() forKey:@"ts"];
        [d setObject:[NSNumber numberWithInteger:st] forKey:@"status"];
        // The real provenance, not "we have data": cache/disk vs live is the
        // difference this probe exists to show.
        [d setObject:(info ? TitleInfoSource() : @"none") forKey:@"source"];
        if (info) {
            // Every one of these is optional now: an id with no entry has only a
            // tconst, and setObject:nil raises rather than logging nothing.
            if ([info objectForKey:@"title"]) [d setObject:[info objectForKey:@"title"] forKey:@"title"];
            if ([info objectForKey:@"year"]) [d setObject:[info objectForKey:@"year"] forKey:@"year"];
            id starList = [info objectForKey:@"stars"];
            if ([starList isKindOfClass:[NSArray class]] && [starList count]) {
                [d setObject:[starList componentsJoinedByString:@" | "] forKey:@"stars"];
            }
            if ([info objectForKey:@"poster"]) [d setObject:[info objectForKey:@"poster"] forKey:@"poster"];
            // What OMDb added, so the log shows it without dumping the text.
            id plot = [info objectForKey:@"plot"];
            if ([plot isKindOfClass:[NSString class]]) {
                [d setObject:[NSNumber numberWithUnsignedInteger:[plot length]] forKey:@"plot_len"];
            }
            for (NSString *fk in [NSArray arrayWithObjects:@"rating", @"votes", @"runtime", nil]) {
                if ([info objectForKey:fk]) [d setObject:[info objectForKey:fk] forKey:fk];
            }
            id genres = [info objectForKey:@"genres"];
            if ([genres isKindOfClass:[NSArray class]]) {
                [d setObject:[genres componentsJoinedByString:@","] forKey:@"genres"];
            }
            if ([info objectForKey:@"omdbError"]) {
                [d setObject:[info objectForKey:@"omdbError"] forKey:@"omdb_error"];
            }
        } else if (e) {
            [d setObject:e forKey:@"error"];
        }
        ProbeEmit(d);

        // The bytes the page actually gets, parsed back.
        NSURLRequest *fake = [NSURLRequest requestWithURL:
                              [NSURL URLWithString:[NSString stringWithFormat:
                                                    @"http://app.imdb.com/title/%@/maindetails", tid]]];
        NSInteger bs = 0;
        NSString *broute = nil;
        NSString *bctype = nil;
        NSData *bbody = ServeRoute(fake, info, &bs, &broute, &bctype);
        NSMutableDictionary *b = [NSMutableDictionary dictionary];
        [b setObject:@"titlebody" forKey:@"event"];
        [b setObject:tid forKey:@"tconst"];
        [b setObject:(broute ? broute : @"(none)") forKey:@"route"];
        [b setObject:[NSNumber numberWithUnsignedInteger:[bbody length]] forKey:@"bytes"];
        [b setObject:ProbeISO8601() forKey:@"ts"];
        id root = [NSJSONSerialization JSONObjectWithData:bbody options:0 error:NULL];
        id data = [root isKindOfClass:[NSDictionary class]] ? [root objectForKey:@"data"] : nil;
        if ([data isKindOfClass:[NSDictionary class]]) {
            if ([data objectForKey:@"title"]) [b setObject:[data objectForKey:@"title"] forKey:@"title"];
            if ([data objectForKey:@"year"]) [b setObject:[data objectForKey:@"year"] forKey:@"year"];
            id cast = [data objectForKey:@"cast_summary"];
            if ([cast isKindOfClass:[NSArray class]]) {
                [b setObject:[NSNumber numberWithUnsignedInteger:[cast count]] forKey:@"cast"];
                if ([cast count]) {
                    id p = [cast objectAtIndex:0];
                    id nm = [p isKindOfClass:[NSDictionary class]] ? [p objectForKey:@"name"] : nil;
                    id n = [nm isKindOfClass:[NSDictionary class]] ? [nm objectForKey:@"name"] : nil;
                    if ([n isKindOfClass:[NSString class]]) [b setObject:n forKey:@"cast0"];
                }
            }
            id img = [data objectForKey:@"image"];
            if ([img isKindOfClass:[NSDictionary class]]) {
                id u = [img objectForKey:@"url"];
                if ([u isKindOfClass:[NSString class]]) [b setObject:u forKey:@"image_url"];
            }
            id plot = [data objectForKey:@"plot"];
            if ([plot isKindOfClass:[NSDictionary class]]) {
                id outline = [plot objectForKey:@"outline"];
                [b setObject:[NSNumber numberWithUnsignedInteger:
                              ([outline isKindOfClass:[NSString class]] ? [outline length] : 0)]
                      forKey:@"plot_len"];
            }
        }
        ProbeEmit(b);

        // The page itself is driven by the auxiliary layout, so build that body
        // too: widgets map, layout `data` copies and the top-level `data` block.
        NSURLRequest *auxReq = [NSURLRequest requestWithURL:
                                [NSURL URLWithString:[NSString stringWithFormat:
                                @"http://api.imdbws.com/template/imdb-ios-writable/ipad-title-auxiliary-v5b.jstl/render?tconst=%@", tid]]];
        NSInteger as = 0;
        NSString *aroute = nil;
        NSString *actype = nil;
        NSData *abody = ServeRoute(auxReq, info, &as, &aroute, &actype);
        id aroot = abody ? [NSJSONSerialization JSONObjectWithData:abody options:0 error:NULL] : nil;
        NSMutableDictionary *a = [NSMutableDictionary dictionary];
        [a setObject:@"titleaux" forKey:@"event"];
        [a setObject:tid forKey:@"tconst"];
        [a setObject:(aroute ? aroute : @"(none)") forKey:@"route"];
        [a setObject:[NSNumber numberWithUnsignedInteger:[abody length]] forKey:@"bytes"];
        [a setObject:[NSNumber numberWithBool:(aroot != nil)] forKey:@"json_ok"];
        [a setObject:ProbeISO8601() forKey:@"ts"];
        if ([aroot isKindOfClass:[NSDictionary class]]) {
            id widgets = [aroot objectForKey:@"widgets"];
            if ([widgets isKindOfClass:[NSDictionary class]]) {
                [a setObject:[NSNumber numberWithUnsignedInteger:[widgets count]] forKey:@"widgets"];
                id hero = [widgets objectForKey:@"hero"];
                if ([hero isKindOfClass:[NSDictionary class]]) {
                    if ([hero objectForKey:@"title"]) [a setObject:[hero objectForKey:@"title"] forKey:@"hero_title"];
                    if ([hero objectForKey:@"year"]) [a setObject:[hero objectForKey:@"year"] forKey:@"hero_year"];
                }
                id pw = [widgets objectForKey:@"pstr"];
                if ([pw isKindOfClass:[NSDictionary class]]) {
                    id iu = [pw objectForKey:@"imageURL"];
                    if ([iu isKindOfClass:[NSString class]]) [a setObject:iu forKey:@"pstr_imageURL"];
                }
                id cw = [widgets objectForKey:@"cast"];
                if ([cw isKindOfClass:[NSDictionary class]]) {
                    id people = [cw objectForKey:@"people"];
                    [a setObject:[NSNumber numberWithUnsignedInteger:
                                  ([people isKindOfClass:[NSArray class]] ? [people count] : 0)]
                          forKey:@"cast_people"];
                }
            }
            id adata = [aroot objectForKey:@"data"];
            if ([adata isKindOfClass:[NSDictionary class]] && [adata objectForKey:@"title"]) {
                [a setObject:[adata objectForKey:@"title"] forKey:@"data_title"];
            }
            NSString *layoutTitle = FirstWidgetTitleIn([aroot objectForKey:@"sections"]);
            if (layoutTitle) [a setObject:layoutTitle forKey:@"layout_title"];
        }
        ProbeEmit(a);

        // Full cast: the same route the "full cast" button hits, built the way
        // the app would get it, so a per-title header can be checked against it.
        NSURLRequest *fcReq = [NSURLRequest requestWithURL:
                               [NSURL URLWithString:[NSString stringWithFormat:
                               @"http://app.imdb.com/title/fullcredits?tconst=%@", tid]]];
        NSInteger fs = 0;
        NSString *froute = nil;
        NSString *fctype = nil;
        NSData *fbody = ServeRoute(fcReq, info, &fs, &froute, &fctype);
        id froot = fbody ? [NSJSONSerialization JSONObjectWithData:fbody options:0 error:NULL] : nil;
        NSMutableDictionary *f = [NSMutableDictionary dictionary];
        [f setObject:@"titlecredits" forKey:@"event"];
        [f setObject:tid forKey:@"tconst"];
        [f setObject:(froute ? froute : @"(none)") forKey:@"route"];
        [f setObject:[NSNumber numberWithUnsignedInteger:[fbody length]] forKey:@"bytes"];
        [f setObject:[NSNumber numberWithBool:(froot != nil)] forKey:@"json_ok"];
        [f setObject:ProbeISO8601() forKey:@"ts"];
        id fdata = [froot isKindOfClass:[NSDictionary class]] ? [froot objectForKey:@"data"] : nil;
        if ([fdata isKindOfClass:[NSDictionary class]]) {
            if ([fdata objectForKey:@"title"]) [f setObject:[fdata objectForKey:@"title"] forKey:@"title"];
            id fgroups = [fdata objectForKey:@"groups"];
            if ([fgroups isKindOfClass:[NSArray class]]) {
                [f setObject:[NSNumber numberWithUnsignedInteger:[fgroups count]] forKey:@"groups"];
                if ([fgroups count]) {
                    id g0 = [fgroups objectAtIndex:0];
                    id gc = [g0 isKindOfClass:[NSDictionary class]] ? [g0 objectForKey:@"credits"] : nil;
                    if ([gc isKindOfClass:[NSArray class]]) {
                        [f setObject:[NSNumber numberWithUnsignedInteger:[gc count]] forKey:@"cast"];
                        NSMutableArray *names = [NSMutableArray array];
                        for (id c in gc) {
                            id nm = [c isKindOfClass:[NSDictionary class]] ? [c objectForKey:@"name"] : nil;
                            id n = [nm isKindOfClass:[NSDictionary class]] ? [nm objectForKey:@"name"] : nil;
                            if ([n isKindOfClass:[NSString class]]) [names addObject:n];
                        }
                        [f setObject:[names componentsJoinedByString:@" | "] forKey:@"names"];
                    }
                }
            }
        }
        ProbeEmit(f);
    }

    // TMDB on its own: two requests (find, credits), logged separately from the
    // title cache so a failure says which hop broke.
    {
        NSString *tmdbErr = nil;
        NSArray *tmdbCast = FetchTmdbCast(@"tt0133093", &tmdbErr);
        NSMutableDictionary *t = [NSMutableDictionary dictionary];
        [t setObject:@"tmdbprobe" forKey:@"event"];
        [t setObject:[NSNumber numberWithUnsignedInteger:[tmdbCast count]] forKey:@"cast"];
        [t setObject:ProbeISO8601() forKey:@"ts"];
        if ([tmdbCast count]) {
            NSDictionary *first = [tmdbCast objectAtIndex:0];
            [t setObject:[first objectForKey:@"name"] forKey:@"first"];
            if ([first objectForKey:@"character"]) [t setObject:[first objectForKey:@"character"] forKey:@"first_char"];
            if ([first objectForKey:@"image"]) [t setObject:[first objectForKey:@"image"] forKey:@"first_image"];
        } else if (tmdbErr) {
            [t setObject:tmdbErr forKey:@"error"];
        }
        ProbeEmit(t);
    }

    [pool release];
}

@end

#pragma mark - per-title data (live suggestion)

// The title routes have always answered from md-2012.json, so every film showed
// Fight Club's name, year, cast and poster with only the tconst corrected. The
// suggestion API fixes that from the device itself: it is the same host the
// app's search already talks to, it was measured reachable with tlsfix
// (3.7-reach: 200/2,146 B), and it accepts a bare tconst as the query —
//
//   https://v3.sg.media-imdb.com/suggestion/t/tt0133093.json
//   {"d":[{"i":{"imageUrl":"https://m.media-amazon.com/...","width":2100,
//               "height":3156},
//          "id":"tt0133093","l":"The Matrix","q":"feature","rank":349,
//          "s":"Keanu Reeves, Laurence Fishburne","y":1999}]}
//
// — so a page opened from a chart or a link needs no search text, and a page
// opened from search costs no second request: every search the app runs passes
// through this tweak and its entries are kept by tconst.
static NSMutableDictionary *gTitleInfo = nil;
static NSLock *gTitleInfoLock = nil;
static NSRecursiveLock *gTitleFetchLock = nil;

// The cache lives in the app's own container so it survives a relaunch: the
// first fetch after a cold start is exactly where a title tap used to time out
// and fall through to the archived film.
static NSString *TitleCachePath(void) {
    const char *home = getenv("HOME");
    if (!home) return nil;
    return [NSString stringWithFormat:@"%s/Library/Caches/imdb-titleinfo.plist", home];
}

static void LoadTitleCacheFromDisk(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"titlecache" forKey:@"event"];
    [d setObject:@"load" forKey:@"op"];
    [d setObject:ProbeISO8601() forKey:@"ts"];

    NSString *path = TitleCachePath();
    [d setObject:(path ? path : @"(no home)") forKey:@"path"];
    if (!path) { ProbeEmit(d); return; }

    NSData *raw = [NSData dataWithContentsOfFile:path];
    [d setObject:[NSNumber numberWithUnsignedInteger:[raw length]] forKey:@"bytes"];
    if (![raw length]) {
        [d setObject:@"missing" forKey:@"reason"];
        ProbeEmit(d);
        return;
    }

    NSError *err = nil;
    id root = [NSPropertyListSerialization propertyListWithData:raw
                                                        options:0
                                                         format:NULL
                                                          error:&err];
    if (![root isKindOfClass:[NSDictionary class]]) {
        [d setObject:(err ? [err description] : @"not a dictionary") forKey:@"reason"];
        ProbeEmit(d);
        return;
    }

    NSUInteger loaded = 0;
    [gTitleInfoLock lock];
    for (id key in (NSDictionary *)root) {
        id v = [(NSDictionary *)root objectForKey:key];
        if ([key isKindOfClass:[NSString class]] && [v isKindOfClass:[NSDictionary class]]) {
            [gTitleInfo setObject:v forKey:key];
            loaded++;
        }
    }
    [gTitleInfoLock unlock];

    [d setObject:[NSNumber numberWithUnsignedInteger:loaded] forKey:@"loaded"];
    ProbeEmit(d);
}

// A failed write must never cost a page, so every failure here is silent.
// Writes are rate-limited: search-as-you-type would otherwise rewrite the whole
// plist on every keystroke.
static NSTimeInterval gTitleCacheSavedAt = 0;

static void SaveTitleCacheToDisk(BOOL force) {
    NSString *path = TitleCachePath();
    if (!path) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!force && gTitleCacheSavedAt > 0 && (now - gTitleCacheSavedAt) < 10.0) return;

    [gTitleInfoLock lock];
    if ([gTitleInfo count] > 300) {
        // Keep it small: the newest entries matter, and this is a shortcut for
        // titles that are about to be opened, not a library.
        NSArray *keys = [gTitleInfo allKeys];
        for (NSUInteger i = 0; i + 200 < [keys count]; i++) {
            [gTitleInfo removeObjectForKey:[keys objectAtIndex:i]];
        }
    }
    NSDictionary *snapshot = [NSDictionary dictionaryWithDictionary:gTitleInfo];
    [gTitleInfoLock unlock];
    if (![snapshot count]) return;

    NSData *data = [NSPropertyListSerialization dataFromPropertyList:snapshot
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                   errorDescription:NULL];
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"titlecache" forKey:@"event"];
    [d setObject:@"save" forKey:@"op"];
    [d setObject:ProbeISO8601() forKey:@"ts"];
    [d setObject:[NSNumber numberWithUnsignedInteger:[snapshot count]] forKey:@"entries"];
    [d setObject:[NSNumber numberWithUnsignedInteger:[data length]] forKey:@"bytes"];
    if (!data) {
        [d setObject:@"plist encode failed" forKey:@"reason"];
        ProbeEmit(d);
        return;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    BOOL ok = [data writeToFile:path atomically:YES];
    if (ok) gTitleCacheSavedAt = now;
    if (!ok) [d setObject:@"write failed" forKey:@"reason"];
    ProbeEmit(d);
}

// A title route with nothing live must still answer for the page that is open.
// `tconst` is all that is certainly known; every other field stays missing.
static NSDictionary *BlankTitleInfo(NSString *tconst) {
    return [NSDictionary dictionaryWithObject:(tconst ? tconst : @"") forKey:@"tconst"];
}

static void TitleInfoInit(void) {
    if (gTitleInfo) return;
    gTitleInfo = [[NSMutableDictionary alloc] init];
    gTitleInfoLock = [[NSLock alloc] init];
    gTitleFetchLock = [[NSRecursiveLock alloc] init];
    LoadTitleCacheFromDisk();
}

// The last title route answered, but only while it is still the page being
// opened. A stale one would attach another film's cast to this header.
static NSString *LastTitleTconstIfFresh(void);


static NSString *SuggestionString(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return nil;
}

// The API hands out the original poster (2100x3156, 3.7 MB measured on this
// device). The 2012 layout wants 336x500, so ask the same object for the
// `_SX400` variant instead. Any other URL shape is returned untouched.
static NSString *PosterThumbURL(NSString *url) {
    if (![url hasSuffix:@"_V1_.jpg"]) return url;
    return [url stringByReplacingOccurrencesOfString:@"_V1_.jpg"
                                          withString:@"_V1_SX400.jpg"
                                             options:NSBackwardsSearch
                                               range:NSMakeRange(0, [url length])];
}

// One suggestion entry -> the fields a title page needs.
static NSMutableDictionary *TitleInfoFromEntry(NSDictionary *e) {
    if (![e isKindOfClass:[NSDictionary class]]) return nil;
    NSString *tid = SuggestionString([e objectForKey:@"id"]);
    NSString *name = SuggestionString([e objectForKey:@"l"]);
    if (![tid hasPrefix:@"tt"] || ![name length]) return nil;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    [info setObject:tid forKey:@"tconst"];
    [info setObject:name forKey:@"title"];

    NSString *year = SuggestionString([e objectForKey:@"y"]);
    if (![year length]) year = SuggestionString([e objectForKey:@"tl"]);
    if ([year length]) [info setObject:year forKey:@"year"];

    NSString *type = SuggestionString([e objectForKey:@"q"]);
    if ([type length]) [info setObject:type forKey:@"type"];

    // `s` is the principal cast, comma separated: "Keanu Reeves, Laurence
    // Fishburne". Two names is what the API returns for most titles.
    NSMutableArray *stars = [NSMutableArray array];
    NSString *cast = SuggestionString([e objectForKey:@"s"]);
    if ([cast length]) {
        for (NSString *raw in [cast componentsSeparatedByString:@","]) {
            NSString *n = [raw stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([n length]) [stars addObject:n];
        }
    }
    [info setObject:stars forKey:@"stars"];

    id img = [e objectForKey:@"i"];
    if ([img isKindOfClass:[NSDictionary class]]) {
        NSString *u = SuggestionString([img objectForKey:@"imageUrl"]);
        if (![u length]) u = SuggestionString([img objectForKey:@"url"]);
        if ([u length]) {
            [info setObject:PosterThumbURL(u) forKey:@"poster"];
            id w = [img objectForKey:@"width"];
            id h = [img objectForKey:@"height"];
            if ([w isKindOfClass:[NSNumber class]]) [info setObject:w forKey:@"width"];
            if ([h isKindOfClass:[NSNumber class]]) [info setObject:h forKey:@"height"];
        }
    }
    return info;
}

// Keeps the entries of any suggestion answer the app itself receives. Bounded:
// a search session is a handful of results, and the map is only a shortcut for
// titles that are about to be opened.
static void CacheSuggestionBody(NSData *body) {
    if (![body length]) return;
    NSData *json = body;
    // The old sg host answers JSONP: imdb$prefix({...}). Only unwrap when the
    // body is not already JSON — a suggestion set can legitimately contain a
    // "(" ("Michael Douglas (I)"), and cutting at the first one corrupts it.
    NSString *text = [[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] autorelease];
    if (text && ![text hasPrefix:@"{"] && ![text hasPrefix:@"["] &&
        [text rangeOfString:@"imdb$"].location != NSNotFound) {
        NSRange open = [text rangeOfString:@"("];
        NSRange close = [text rangeOfString:@")" options:NSBackwardsSearch];
        if (open.location != NSNotFound && close.location != NSNotFound &&
            close.location > open.location) {
            json = [[text substringWithRange:NSMakeRange(open.location + 1,
                                                         close.location - open.location - 1)]
                    dataUsingEncoding:NSUTF8StringEncoding];
        }
    }

    id root = [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    NSArray *entries = nil;
    if ([root isKindOfClass:[NSDictionary class]]) entries = [root objectForKey:@"d"];
    else if ([root isKindOfClass:[NSArray class]]) entries = root;
    if (![entries isKindOfClass:[NSArray class]]) return;

    TitleInfoInit();
    [gTitleInfoLock lock];
    if ([gTitleInfo count] > 400) [gTitleInfo removeAllObjects];
    for (id e in entries) {
        NSMutableDictionary *info = TitleInfoFromEntry(e);
        if (info) [gTitleInfo setObject:info forKey:[info objectForKey:@"tconst"]];
    }
    [gTitleInfoLock unlock];
}

// 30 days. Long enough that a normal viewer never pays twice, short enough that
// a bad or outdated answer cannot stick for the life of the install.
static const long long kTitleInfoTTL = 30 * 24 * 3600;

static NSDictionary *CachedTitleInfo(NSString *tconst) {
    if (![tconst length]) return nil;
    TitleInfoInit();

    NSDictionary *hit = nil;
    BOOL expired = NO;
    [gTitleInfoLock lock];
    NSDictionary *raw = [[gTitleInfo objectForKey:tconst] retain];
    if (raw) {
        id stamp = [raw objectForKey:@"fetched"];
        if ([stamp respondsToSelector:@selector(longLongValue)] &&
            (long long)time(NULL) - [stamp longLongValue] > kTitleInfoTTL) {
            expired = YES;
            [gTitleInfo removeObjectForKey:tconst];
        } else {
            hit = [raw retain];
        }
    }
    [gTitleInfoLock unlock];

    if (expired) {
        ProbeEmit([NSDictionary dictionaryWithObjectsAndKeys:
                   @"titlecache", @"event", @"expire", @"op",
                   tconst, @"tconst", ProbeISO8601(), @"ts", nil]);
        SaveTitleCacheToDisk(YES);
    }
    if (raw) [raw release];
    return [hit autorelease];
}

static NSMutableDictionary *PosterImageFromInfo(NSDictionary *info) {
    NSString *poster = [info objectForKey:@"poster"];
    if (![poster length]) return nil;
    NSMutableDictionary *img = [NSMutableDictionary dictionary];
    [img setObject:poster forKey:@"url"];
    id w = [info objectForKey:@"width"];
    id h = [info objectForKey:@"height"];
    [img setObject:(w ? w : [NSNumber numberWithInt:336]) forKey:@"width"];
    [img setObject:(h ? h : [NSNumber numberWithInt:500]) forKey:@"height"];
    return img;
}

// The 2012 person shape: { name: { name, image? } }. `nconst` is unknown here
// and is left out rather than guessed.
static NSMutableArray *PeopleFromStars(NSArray *stars) {
    NSMutableArray *out = [NSMutableArray array];
    for (id n in stars) {
        if (![n isKindOfClass:[NSString class]]) continue;
        [out addObject:[NSDictionary dictionaryWithObject:
                        [NSDictionary dictionaryWithObject:n forKey:@"name"]
                                                   forKey:@"name"]];
    }
    return out;
}

// The suggestion API knows five things: name, year, type, principal cast and
// poster. Everything else in the fixture would be Fight Club's plot, quote and
// reviews under another film's name, so those keys are emptied rather than
// kept. `has` gates whole widgets, so it is emptied with them.
static void ApplyTitleInfoToTitleData(NSMutableDictionary *d, NSDictionary *info) {
    if (!d || !info) return;
    // Written unconditionally: when the page is answered for its tconst alone,
    // these must be empty rather than keep the fixture's film.
    [d setObject:([info objectForKey:@"tconst"] ? [info objectForKey:@"tconst"] : @"") forKey:@"tconst"];
    [d setObject:([info objectForKey:@"title"] ? [info objectForKey:@"title"] : @"") forKey:@"title"];
    [d setObject:([info objectForKey:@"year"] ? [info objectForKey:@"year"] : @"") forKey:@"year"];
    [d setObject:([info objectForKey:@"type"] ? [info objectForKey:@"type"] : @"") forKey:@"type"];

    NSMutableDictionary *img = PosterImageFromInfo(info);
    if (img) {
        [d setObject:img forKey:@"image"];
        [d setObject:[NSArray arrayWithObject:
                      [NSDictionary dictionaryWithObject:img forKey:@"image"]]
              forKey:@"photos"];
    } else {
        [d removeObjectForKey:@"image"];
        [d setObject:[NSArray array] forKey:@"photos"];
    }

    NSArray *stars = [info objectForKey:@"stars"];
    [d setObject:PeopleFromStars([stars isKindOfClass:[NSArray class]] ? stars : [NSArray array])
          forKey:@"cast_summary"];

    for (NSString *k in [NSArray arrayWithObjects:@"directors_summary", @"writers_summary",
                         @"genres", @"has", nil]) {
        [d setObject:[NSArray array] forKey:k];
    }
    for (NSString *k in [NSArray arrayWithObjects:@"plot", @"best_plot", @"quote", @"trivium",
                         @"goof", @"news", nil]) {
        [d setObject:[NSDictionary dictionary] forKey:k];
    }
    for (NSString *k in [NSArray arrayWithObjects:@"rating", @"num_votes", @"certificate",
                         @"release_date", @"runtime", @"tagline", @"user_comment", @"trailer",
                         @"metascore", nil]) {
        [d removeObjectForKey:k];
    }

    // --- what OMDb did confirm -------------------------------------------------
    NSString *plot = [info objectForKey:@"plot"];
    if ([plot isKindOfClass:[NSString class]] && [plot length]) {
        [d setObject:[NSDictionary dictionaryWithObjectsAndKeys:
                      plot, @"outline", @"", @"more", nil] forKey:@"plot"];
        [d setObject:[NSDictionary dictionaryWithObjectsAndKeys:
                      plot, @"outline", [NSNumber numberWithInt:0], @"total_summaries", nil]
              forKey:@"best_plot"];
    }
    if ([info objectForKey:@"rating"]) [d setObject:[info objectForKey:@"rating"] forKey:@"rating"];
    if ([info objectForKey:@"votes"]) [d setObject:[info objectForKey:@"votes"] forKey:@"num_votes"];

    NSArray *genres = [info objectForKey:@"genres"];
    if ([genres isKindOfClass:[NSArray class]] && [genres count]) {
        NSMutableArray *g = [NSMutableArray array];
        for (id s in genres) {
            if ([s isKindOfClass:[NSString class]]) {
                [g addObject:[NSDictionary dictionaryWithObject:s forKey:@"str"]];
            }
        }
        if ([g count]) [d setObject:g forKey:@"genres"];
    }

    if ([info objectForKey:@"runtime"]) {
        [d setObject:[NSDictionary dictionaryWithObject:[info objectForKey:@"runtime"]
                                                 forKey:@"time"]
              forKey:@"runtime"];
    }
    NSString *cert = [info objectForKey:@"certificate"];
    if ([cert isKindOfClass:[NSString class]] && [cert length]) {
        [d setObject:[NSDictionary dictionaryWithObjectsAndKeys:
                      cert, @"certificate", @"", @"attr", nil] forKey:@"certificate"];
    }
    NSString *released = [info objectForKey:@"released"];
    if ([released isKindOfClass:[NSString class]] && [released length]) {
        [d setObject:[NSDictionary dictionaryWithObject:released forKey:@"normal"]
              forKey:@"release_date"];
    }

    NSArray *dirs = [info objectForKey:@"directors"];
    if ([dirs isKindOfClass:[NSArray class]] && [dirs count]) {
        [d setObject:PeopleFromStars(dirs) forKey:@"directors_summary"];
    }
    NSArray *writers = [info objectForKey:@"writers"];
    if ([writers isKindOfClass:[NSArray class]] && [writers count]) {
        [d setObject:PeopleFromStars(writers) forKey:@"writers_summary"];
    }
}

// The same values in the shape the config layout reads: one block per widget
// name. Widgets whose content the API cannot confirm stay empty on purpose.
static NSMutableDictionary *TitleWidgetsFromInfo(NSDictionary *info) {
    NSArray *names = [NSArray arrayWithObjects:
                      @"hero", @"titl", @"pstr", @"arate", @"urate", @"meta", @"oplot", @"plotd",
                      @"drct", @"wrt", @"cast", @"phtos", @"plytlr", @"tAwrd", @"t250", @"pulq",
                      @"triv", @"quot", @"goof", @"crzy", @"sndt", @"tgln", @"gnrs", @"rdat",
                      @"lang", @"altt", @"loctn", @"runt", @"altv", @"sims", @"conns", @"imdbWS",
                      @"crev", @"ocrev", nil];
    NSMutableDictionary *widgets = [NSMutableDictionary dictionary];
    for (NSString *n in names) [widgets setObject:[NSDictionary dictionary] forKey:n];

    NSString *title = [info objectForKey:@"title"];
    NSString *year = [info objectForKey:@"year"];
    NSString *type = [info objectForKey:@"type"];
    NSString *poster = [info objectForKey:@"poster"];
    NSMutableDictionary *img = PosterImageFromInfo(info);
    NSArray *stars = [info objectForKey:@"stars"];
    if (![stars isKindOfClass:[NSArray class]]) stars = [NSArray array];

    NSMutableDictionary *hero = [NSMutableDictionary dictionary];
    if (title) [hero setObject:title forKey:@"title"];
    if (year) [hero setObject:year forKey:@"year"];
    if (type) [hero setObject:type forKey:@"type"];
    [hero setObject:[info objectForKey:@"tconst"] forKey:@"tconst"];
    [hero setObject:[NSArray array] forKey:@"genres"];
    if (img) {
        [hero setObject:img forKey:@"image"];
        [hero setObject:img forKey:@"poster"];
        [hero setObject:poster forKey:@"imageURL"];
    }
    [widgets setObject:hero forKey:@"hero"];

    NSMutableDictionary *titl = [NSMutableDictionary dictionary];
    if (title) [titl setObject:title forKey:@"title"];
    if (year) [titl setObject:year forKey:@"year"];
    if (type) [titl setObject:type forKey:@"type"];
    [widgets setObject:titl forKey:@"titl"];

    // The poster widget exposes image / imageURL / posterURL as properties and
    // was never handed data before; carry all three spellings again.
    NSMutableDictionary *pstr = [NSMutableDictionary dictionary];
    if (img) {
        [pstr setObject:img forKey:@"image"];
        [pstr setObject:img forKey:@"poster"];
        [pstr setObject:poster forKey:@"imageURL"];
        [pstr setObject:poster forKey:@"posterURL"];
        [pstr setObject:poster forKey:@"url"];
    }
    [widgets setObject:pstr forKey:@"pstr"];

    [widgets setObject:[NSDictionary dictionaryWithObject:PeopleFromStars(stars) forKey:@"people"]
                forKey:@"cast"];

    NSMutableDictionary *photos = [NSMutableDictionary dictionary];
    [photos setObject:(img ? [NSArray arrayWithObject:
                              [NSDictionary dictionaryWithObject:img forKey:@"image"]]
                           : [NSArray array])
               forKey:@"photos"];
    [widgets setObject:photos forKey:@"phtos"];

    // Plot and genres come from OMDb; an absent value stays empty rather than
    // borrowing the archived film's.
    NSString *plot = [info objectForKey:@"plot"];
    NSDictionary *plotWidget = [NSDictionary dictionaryWithObjectsAndKeys:
                                (([plot isKindOfClass:[NSString class]]) ? plot : @""), @"plot",
                                [NSNumber numberWithBool:NO], @"has_more", nil];
    [widgets setObject:plotWidget forKey:@"oplot"];
    [widgets setObject:plotWidget forKey:@"plotd"];

    NSMutableArray *genreDicts = [NSMutableArray array];
    NSArray *genres = [info objectForKey:@"genres"];
    if ([genres isKindOfClass:[NSArray class]]) {
        for (id g in genres) {
            if ([g isKindOfClass:[NSString class]]) {
                [genreDicts addObject:[NSDictionary dictionaryWithObject:g forKey:@"str"]];
            }
        }
    }
    [widgets setObject:[NSDictionary dictionaryWithObject:genreDicts forKey:@"genres"]
                forKey:@"gnrs"];
    [hero setObject:genreDicts forKey:@"genres"];
    for (NSString *hk in [NSArray arrayWithObjects:@"certificate", @"rating", @"votes", nil]) {
        id hv = [info objectForKey:hk];
        if (!hv) continue;
        [hero setObject:hv forKey:([hk isEqualToString:@"votes"] ? @"num_votes" : hk)];
    }

    NSMutableDictionary *arate = [NSMutableDictionary dictionary];
    if ([info objectForKey:@"rating"]) [arate setObject:[info objectForKey:@"rating"] forKey:@"rating"];
    if ([info objectForKey:@"votes"]) [arate setObject:[info objectForKey:@"votes"] forKey:@"num_votes"];
    [widgets setObject:arate forKey:@"arate"];

    NSArray *dirs = [info objectForKey:@"directors"];
    if ([dirs isKindOfClass:[NSArray class]] && [dirs count]) {
        [widgets setObject:[NSDictionary dictionaryWithObject:PeopleFromStars(dirs) forKey:@"people"]
                    forKey:@"drct"];
    }
    NSArray *writers = [info objectForKey:@"writers"];
    if ([writers isKindOfClass:[NSArray class]] && [writers count]) {
        [widgets setObject:[NSDictionary dictionaryWithObject:PeopleFromStars(writers) forKey:@"people"]
                    forKey:@"wrt"];
    }
    if ([info objectForKey:@"runtime"]) {
        [widgets setObject:[NSDictionary dictionaryWithObject:[info objectForKey:@"runtime"]
                                                       forKey:@"time"]
                    forKey:@"runt"];
    }
    NSString *released = [info objectForKey:@"released"];
    if ([released isKindOfClass:[NSString class]] && [released length]) {
        [widgets setObject:[NSDictionary dictionaryWithObjectsAndKeys:
                            [NSDictionary dictionaryWithObject:released forKey:@"normal"], @"release_date",
                            released, @"date", nil]
                    forKey:@"rdat"];
    }

    [widgets setObject:[NSDictionary dictionaryWithObject:[info objectForKey:@"tconst"]
                                                   forKey:@"tconst"]
                forKey:@"imdbWS"];
    return widgets;
}

// /title/fullcredits is asked for in parallel with maindetails and should agree
// with the header. It is usually sent with ?tconst=; when it is not, the last
// title route this process answered is the page being opened.
static NSString *gLastTitleTconst = nil;
static NSTimeInterval gLastTitleAt = 0;

static void SetLastTitleTconst(NSString *tconst) {
    if (![tconst length]) return;
    TitleInfoInit();
    [gTitleInfoLock lock];
    [gLastTitleTconst release];
    gLastTitleTconst = [tconst copy];
    gLastTitleAt = [NSDate timeIntervalSinceReferenceDate];
    [gTitleInfoLock unlock];
}

// 5 s: long enough for the three routes of one page to arrive, short enough
// that a stale id can never reach a different page's full cast.
static NSString *LastTitleTconstIfFresh(void) {
    TitleInfoInit();
    [gTitleInfoLock lock];
    BOOL fresh = (gLastTitleTconst &&
                  ([NSDate timeIntervalSinceReferenceDate] - gLastTitleAt) < 5.0);
    NSString *t = fresh ? [gLastTitleTconst retain] : nil;
    [gTitleInfoLock unlock];
    return [t autorelease];
}

// One credit, in the shape shim/build-fullcredits.py emits: IMCredit reads
// `name`, `char`, `characters`, `job`, `as`. The API knows the names only, so
// there is no character, job or portrait to claim.
static NSDictionary *CreditForName(NSString *name) {
    return [NSDictionary dictionaryWithObjectsAndKeys:
            [NSDictionary dictionaryWithObject:name forKey:@"name"], @"name",
            @"", @"char",
            @"", @"character",
            [NSArray array], @"characters",
            [NSNumber numberWithBool:NO], @"hasCharacter",
            @"", @"job",
            @"", @"as",
            @"", @"attribution",
            nil];
}

// A credit with the character and portrait TMDB knows. `char`/`characters` are
// what IMCredit reads; `image` is the headshot URL the list will request.
static NSDictionary *CreditForPerson(NSString *name, NSString *character, NSString *imageURL) {
    NSMutableDictionary *person = [NSMutableDictionary dictionaryWithObject:(name ? name : @"")
                                                                    forKey:@"name"];
    NSDictionary *image = nil;
    if ([imageURL isKindOfClass:[NSString class]] && [imageURL length]) {
        image = [NSDictionary dictionaryWithObjectsAndKeys:
                 imageURL, @"url",
                 [NSNumber numberWithInt:185], @"width",
                 [NSNumber numberWithInt:278], @"height", nil];
        [person setObject:image forKey:@"image"];
    }
    NSMutableDictionary *c = [NSMutableDictionary dictionary];
    [c setObject:person forKey:@"name"];
    [c setObject:(character ? character : @"") forKey:@"char"];
    [c setObject:(character ? character : @"") forKey:@"character"];
    [c setObject:((character && [character length]) ? [NSArray arrayWithObject:character] : [NSArray array])
          forKey:@"characters"];
    [c setObject:[NSNumber numberWithBool:(character && [character length])] forKey:@"hasCharacter"];
    [c setObject:@"" forKey:@"job"];
    [c setObject:@"" forKey:@"as"];
    [c setObject:@"" forKey:@"attribution"];
    if (image) [c setObject:image forKey:@"image"];
    return c;
}

// Same envelope and the same repeated payload keys as the fixture, so the app
// parses this exactly like the archived body: one group, its credits under
// `credits`/`groups`/`list`, and the cast and groups again at top level.
static NSData *FullCreditsForInfo(NSDictionary *info) {
    if (!info) return nil;
    NSString *title = [info objectForKey:@"title"];
    NSString *tconst = [info objectForKey:@"tconst"];
    NSArray *stars = [info objectForKey:@"stars"];
    if (![stars isKindOfClass:[NSArray class]]) stars = [NSArray array];

    NSMutableArray *cast = [NSMutableArray array];
    NSArray *tmdb = [info objectForKey:@"tmdbCast"];
    if ([tmdb isKindOfClass:[NSArray class]] && [tmdb count]) {
        // Real cast with characters and headshots, in billing order.
        for (id p in tmdb) {
            if (![p isKindOfClass:[NSDictionary class]]) continue;
            [cast addObject:CreditForPerson([p objectForKey:@"name"],
                                            [p objectForKey:@"character"],
                                            [p objectForKey:@"image"])];
        }
    } else {
        // No TMDB: the billed names only. Nothing invented.
        for (NSString *n in stars) {
            if ([n isKindOfClass:[NSString class]]) [cast addObject:CreditForName(n)];
        }
    }

    NSMutableArray *groups = [NSMutableArray array];
    if ([cast count]) {
        [groups addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                           @"Cast", @"name",
                           @"Cast", @"title",
                           @"cast", @"category",
                           [NSNumber numberWithUnsignedInteger:[cast count]], @"totalCreditsCount",
                           cast, @"credits",
                           cast, @"groups",
                           cast, @"list",
                           nil]];
    }

    // OMDb knows the director for this film, so the section can be real instead
    // of the archived crew.
    NSArray *dirs = [info objectForKey:@"directors"];
    if ([dirs isKindOfClass:[NSArray class]] && [dirs count]) {
        NSMutableArray *dc = [NSMutableArray array];
        for (NSString *n in dirs) {
            if ([n isKindOfClass:[NSString class]]) [dc addObject:CreditForName(n)];
        }
        [groups addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                           @"Directed by", @"name",
                           @"Directed by", @"title",
                           @"directed by", @"category",
                           [NSNumber numberWithUnsignedInteger:[dc count]], @"totalCreditsCount",
                           dc, @"credits", dc, @"groups", dc, @"list", nil]];
    }

    NSDictionary *data = [NSDictionary dictionaryWithObjectsAndKeys:
                          (tconst ? tconst : @""), @"tconst",
                          (title ? title : @""), @"title",
                          groups, @"groups",
                          groups, @"credits",
                          cast, @"cast",
                          [NSNumber numberWithUnsignedInteger:[cast count]], @"totalCreditsCount",
                          nil];
    NSDictionary *meta = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSNumber numberWithInt:21], @"serverTimeMs",
                          @"imdb-revival-local", @"requestId",
                          nil];
    NSDictionary *root = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSNumber numberWithLongLong:(long long)time(NULL) + 3600], @"exp",
                          meta, @"@meta",
                          data, @"data",
                          nil];
    return [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
}

// First widget node in the layout that carries a title — used by the launch
// probe to prove the layout copies were patched, not just the widgets map.
static NSString *FirstWidgetTitleIn(id node) {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id n in (NSArray *)node) {
            NSString *t = FirstWidgetTitleIn(n);
            if (t) return t;
        }
        return nil;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *n = (NSDictionary *)node;
    if ([[n objectForKey:@"type"] isEqualToString:@"widget"]) {
        id d = [n objectForKey:@"data"];
        if ([d isKindOfClass:[NSDictionary class]]) {
            id t = [d objectForKey:@"title"];
            if ([t isKindOfClass:[NSString class]]) return t;
        }
    }
    for (NSString *k in [n allKeys]) {
        id v = [n objectForKey:k];
        if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSDictionary class]]) {
            NSString *t = FirstWidgetTitleIn(v);
            if (t) return t;
        }
    }
    return nil;
}

// The layout carries a `data` copy on every widget node; patch those too so a
// widget reads its own title no matter which lookup path it uses.
static void PatchWidgetNodes(id node, NSDictionary *widgets) {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id n in (NSArray *)node) PatchWidgetNodes(n, widgets);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *n = (NSMutableDictionary *)node;
    NSString *type = [n objectForKey:@"type"];
    NSString *name = [n objectForKey:@"name"];
    if ([type isEqualToString:@"widget"] && [name isKindOfClass:[NSString class]]) {
        id w = [widgets objectForKey:name];
        [n setObject:(w ? w : [NSDictionary dictionary]) forKey:@"data"];
    }
    for (NSString *k in [n allKeys]) {
        id v = [n objectForKey:k];
        if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSDictionary class]]) {
            PatchWidgetNodes(v, widgets);
        }
    }
}

#pragma mark - route table

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

// The home page is not an app.imdb.com route: the app asks the template engine on
// api.imdbws.com for a server-rendered layout. The host is alive but rejects the
// app's 2011 AWS3 signature with 403, so the response has to come from here.
static BOOL IsHomepageRequest(NSURLRequest *request) {
    NSString *host = [request.URL.host lowercaseString];
    if (![host isEqualToString:@"api.imdbws.com"]) return NO;
    NSString *path = request.URL.path ? request.URL.path : @"";
    return ([path rangeOfString:@"/template/imdb-ios-writable/"].location != NSNotFound &&
            [path rangeOfString:@"homepage" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

// The title page is rendered by the same template engine as the home page: the
// app asks for title-auxiliary-v5b.jstl/render with tconst/region/today and
// expects the layout from data.title_page.sections, filled per widget.
static BOOL IsTitleAuxRequest(NSURLRequest *request) {
    NSString *host = [request.URL.host lowercaseString];
    if (![host isEqualToString:@"api.imdbws.com"]) return NO;
    NSString *path = request.URL.path ? request.URL.path : @"";
    return ([path rangeOfString:@"/template/imdb-ios-writable/"].location != NSNotFound &&
            [path rangeOfString:@"title-auxiliary" options:NSCaseInsensitiveSearch].location != NSNotFound);
}

// Actor thumbnails and posters. The app composes these URLs itself as
// http://ia.media-imdb.com/images/... regardless of the host in the fixture, and
// that origin now answers plain http with 403, so every photo stays blank. The
// same path over https on m.media-amazon.com still returns the JPEG (§19).
static BOOL IsImageRequest(NSURLRequest *request) {
    NSString *host = [request.URL.host lowercaseString];
    if (![host isEqualToString:@"ia.media-imdb.com"]) return NO;
    return [request.URL.path hasPrefix:@"/images/"];
}

static NSURL *LiveImageURL(NSURLRequest *request) {
    NSString *path = request.URL.path ? request.URL.path : @"/images/";
    NSString *query = request.URL.query;
    NSString *s = [NSString stringWithFormat:@"https://m.media-amazon.com%@%@", path,
                   [query length] ? [@"?" stringByAppendingString:query] : @""];
    return [NSURL URLWithString:s];
}

static BOOL IsDashRoute(NSString *path) {
    return ([path rangeOfString:@"maindetails"].location != NSNotFound);
}

// nil means "no fixture yet": the caller answers 404 and the log records it, so
// the missing routes are exactly the set listed in the capture.
static NSString *RouteNameForRequest(NSURLRequest *request) {
    NSString *path = request.URL.path;
    if (!path) return nil;

    if (IsHomepageRequest(request)) return @"homepage.json";
    if (IsTitleAuxRequest(request)) return @"title-auxiliary.json";

    if ([path isEqualToString:@"/hello"]) return @"hello.json";
    // The title page's cast list (and the actor photos) comes from this route,
    // asked in parallel with maindetails; without it the section stays empty.
    if ([path isEqualToString:@"/title/fullcredits"]) return @"fullcredits.json";

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

static NSData *JSONErrorBody(NSString *message);

// Offline answer for a suggestions request: the archived capture, re-wrapped in
// the JSONP form the app expects. This is the fallback whenever the live fetch
// fails, so search keeps working with no network and no tlsfix.
static NSData *FixtureSuggests(NSURLRequest *request, NSInteger *statusOut,
                               NSString **ctypeOut, NSString **routeOut) {
    if (routeOut) *routeOut = @"suggests.json";
    if (ctypeOut) *ctypeOut = @"application/javascript";

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
    *statusOut = 200;
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *JSONErrorBody(NSString *message) {
    NSDictionary *d = [NSDictionary dictionaryWithObject:message forKey:@"error"];
    NSDictionary *wrap = [NSDictionary dictionaryWithObject:d forKey:@"data"];
    return [NSJSONSerialization dataWithJSONObject:wrap options:0 error:NULL];
}

// Fixtures are served as-is except for two live fields: `exp` must be in the
// future or the legacy client treats the payload as stale (§4.5), and tconst
// must match what was asked for or the page shows the wrong title's data.
// `titleInfo` is the live suggestion answer for this tconst, or nil when there is
// none: nil means the fixture answers and the page still renders its old title.
static NSData *ServeRoute(NSURLRequest *request, NSDictionary *titleInfo,
                          NSInteger *statusOut, NSString **routeOut, NSString **ctypeOut) {
    if (ctypeOut) *ctypeOut = @"application/json";

    // Suggestions are JSONP-ish: imdb$<prefix>({...}). The callback name has to
    // match the prefix the app asked for or it is ignored.
    if (IsSuggestsRequest(request)) {
        return FixtureSuggests(request, statusOut, ctypeOut, routeOut);
    }

    NSString *name = RouteNameForRequest(request);
    if (routeOut) *routeOut = name ? name : @"(none)";
    if (!name) {
        *statusOut = 404;
        return JSONErrorBody(@"IMDb revival: route not built yet");
    }

    // A title route never serves the archived film. If nothing live is known it
    // answers for this tconst with every other field missing: another film's
    // name, cast and plot under the right title is the worst possible outcome.
    if (!titleInfo &&
        ([name isEqualToString:@"md-2012.json"] ||
         [name isEqualToString:@"title-auxiliary.json"] ||
         [name isEqualToString:@"fullcredits.json"])) {
        NSString *tid = TconstForRequest(request);
        if (!tid) tid = LastTitleTconstIfFresh();
        titleInfo = BlankTitleInfo(tid);
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

    // Full cast follows the header: the billed names of the open title, not the
    // archived film's whole call sheet.
    if ([name isEqualToString:@"fullcredits.json"] && titleInfo) {
        NSData *fc = FullCreditsForInfo(titleInfo);
        if (fc) {
            *statusOut = 200;
            return fc;
        }
    }

    // The homepage payload is not the app.imdb.com envelope: it carries
    // @jstlMeta instead of exp, and a stale timestamp is the same kind of trap
    // that exp is on maindetails.
    if ([name isEqualToString:@"homepage.json"] ||
        [name isEqualToString:@"title-auxiliary.json"]) {
        id hobj = [NSJSONSerialization JSONObjectWithData:raw
                                                  options:NSJSONReadingMutableContainers
                                                    error:NULL];
        if ([hobj isKindOfClass:[NSMutableDictionary class]]) {
            NSMutableDictionary *hd = (NSMutableDictionary *)hobj;
            id meta = [hd objectForKey:@"@jstlMeta"];
            if ([meta isKindOfClass:[NSMutableDictionary class]]) {
                [(NSMutableDictionary *)meta setObject:[NSNumber numberWithLongLong:(long long)time(NULL)]
                                                forKey:@"timestamp"];
                [(NSMutableDictionary *)meta setObject:[NSNumber numberWithInt:12]
                                                forKey:@"serverTimeMs"];
            }
            // The template is per title; the fixture is one title's data.
            NSString *jtconst = TconstForRequest(request);
            if (jtconst) [hd setObject:jtconst forKey:@"tconst"];
            NSMutableDictionary *jdata = [hd objectForKey:@"data"];
            if (jtconst && [jdata isKindOfClass:[NSMutableDictionary class]]) {
                [(NSMutableDictionary *)jdata setObject:jtconst forKey:@"tconst"];
            }
            // Per-title: the layout, its widget data and the `data` block all
            // move to the film that was asked for.
            if ([name isEqualToString:@"title-auxiliary.json"] && titleInfo) {
                if ([jdata isKindOfClass:[NSMutableDictionary class]]) {
                    ApplyTitleInfoToTitleData((NSMutableDictionary *)jdata, titleInfo);
                }
                NSMutableDictionary *widgets = TitleWidgetsFromInfo(titleInfo);
                [hd setObject:widgets forKey:@"widgets"];
                if ([titleInfo objectForKey:@"title"]) {
                    [hd setObject:[titleInfo objectForKey:@"title"] forKey:@"title"];
                }
                PatchWidgetNodes([hd objectForKey:@"sections"], widgets);
            }
            NSData *hout = [NSJSONSerialization dataWithJSONObject:hd options:0 error:NULL];
            if (hout) {
                *statusOut = 200;
                return hout;
            }
        }
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
        if (titleInfo && [data isKindOfClass:[NSMutableDictionary class]]) {
            ApplyTitleInfoToTitleData((NSMutableDictionary *)data, titleInfo);
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

#pragma mark - live suggestions

// The app asks for `http://sg.media-imdb.com/suggests/…`; upstream answers 301 to
// https, and without tlsfix that hop dies at -9824 (§17). With tlsfix loaded
// (§18) the same path over https returns live JSONP — the exact envelope the app
// parses — so the live response can be relayed as-is, no reshaping.
static NSURL *LiveSuggestsURL(NSURLRequest *request) {
    NSString *path = request.URL.path ? request.URL.path : @"/suggests/";
    NSString *query = request.URL.query;
    NSString *s = [NSString stringWithFormat:@"https://sg.media-imdb.com%@%@", path,
                   [query length] ? [@"?" stringByAppendingString:query] : @""];
    return [NSURL URLWithString:s];
}

// Returns the live body, or nil when it is not usable (no tlsfix, no network,
// non-200, empty, or not the JSONP the client expects) — every nil becomes the
// fixture. Runs on a worker thread, so a 6 s timeout cannot stall the UI.
// One live fetch for both relays (suggestions and images). They differ only in
// timeout, in what counts as a usable body, and in caching, so the request
// plumbing lives here once instead of twice.
static NSData *FetchHTTPS(NSURL *url, NSTimeInterval timeout, NSInteger *statusOut,
                          NSString **ctypeOut, NSString **errOut) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setTimeoutInterval:timeout];
    // Live means live: a cached copy would hide a broken TLS path and make the
    // fixture fallback unreachable (§18.3).
    [req setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
    [req setValue:@"IMDb/3.4.2 (iPad; iPhone OS 6.1.3)" forHTTPHeaderField:@"User-Agent"];
    // Must not be re-intercepted: this request is the tweak talking to the world.
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:kServedKey inRequest:req];

    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *body = [NSURLConnection sendSynchronousRequest:req
                                         returningResponse:(NSURLResponse **)&resp
                                                     error:&err];
    if (statusOut) *statusOut = resp ? [resp statusCode] : 0;
    if (ctypeOut) *ctypeOut = resp ? [[resp allHeaderFields] objectForKey:@"Content-Type"] : nil;

    if (err) {
        if (errOut) *errOut = [NSString stringWithFormat:@"%@ %ld", [err domain], (long)[err code]];
        return nil;
    }
    if (!resp || [resp statusCode] != 200 || ![body length]) {
        if (errOut) *errOut = [NSString stringWithFormat:@"status %ld, %lu bytes",
                               (long)(resp ? [resp statusCode] : 0), (unsigned long)[body length]];
        return nil;
    }
    return body;
}

static NSData *FetchLiveSuggests(NSURL *url, NSInteger *statusOut, NSString **errOut) {
    NSData *body = FetchHTTPS(url, 6.0, statusOut, NULL, errOut);
    if (!body) return nil;
    // Guard the contract, not the content: a non-JSONP body would be silently
    // ignored by the app, which looks exactly like an empty result list.
    NSRange r = [body rangeOfData:[@"imdb$" dataUsingEncoding:NSUTF8StringEncoding]
                          options:0 range:NSMakeRange(0, MIN((NSUInteger)16, [body length]))];
    if (r.location == NSNotFound) {
        if (errOut) *errOut = @"body is not JSONP";
        return nil;
    }
    return body;
}

#pragma mark - live per-title lookup

// A tconst is a valid suggestion query, so a title opened from a chart or a link
// needs no search text. The first path segment is the query's first character;
// the upsream accepts any of them for an id query, and this keeps the URL in the
// shape the endpoint documents.
static NSURL *SuggestionURLForQuery(NSString *query) {
    NSString *prefix = @"t";
    if ([query length]) prefix = [[query substringToIndex:1] lowercaseString];
    NSString *escaped = [query stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    return [NSURL URLWithString:[NSString stringWithFormat:
                                @"https://v3.sg.media-imdb.com/suggestion/%@/%@.json",
                                prefix, escaped]];
}

#pragma mark - user-supplied API keys

// Keys are never compiled in and never committed. This is a tweak, so whoever
// installs it brings their own: put them in /Library/IMDbRevival/keys.plist as
// { OMDbAPIKey, TMDBAPIKey }, or in the com.imdbrevival.settings preference
// domain, which is where a settings pane would write them. A missing key simply
// disables that source; the page degrades to what the suggestion API knows.
static NSString * const kKeysPath = @"/Library/IMDbRevival/keys.plist";
static NSMutableDictionary *gKeys = nil;

static NSString *APIKey(NSString *name) {
    if (!gKeys) {
        gKeys = [[NSMutableDictionary alloc] init];
        NSData *raw = [NSData dataWithContentsOfFile:kKeysPath];
        if ([raw length]) {
            id root = [NSPropertyListSerialization propertyListWithData:raw
                                                                 options:0
                                                                  format:NULL
                                                                   error:NULL];
            if ([root isKindOfClass:[NSDictionary class]]) [gKeys addEntriesFromDictionary:root];
        }
    }
    id v = [gKeys objectForKey:name];
    if (![v isKindOfClass:[NSString class]] || ![v length]) {
        v = [[NSUserDefaults standardUserDefaults] stringForKey:name];
    }
    if (![v isKindOfClass:[NSString class]] || ![v length]) return nil;
    return v;
}

#pragma mark - OMDb / TMDB (fills what the suggestion API cannot)

// "Keanu Reeves, Laurence Fishburne" -> two strings. OMDb uses the same shape.
static NSMutableArray *SplitNames(NSString *s) {
    NSMutableArray *out = [NSMutableArray array];
    if (![s isKindOfClass:[NSString class]]) return out;
    for (NSString *raw in [s componentsSeparatedByString:@","]) {
        NSString *n = [raw stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([n length]) [out addObject:n];
    }
    return out;
}

static NSString *NotAvailable(id v) {
    if (![v isKindOfClass:[NSString class]]) return nil;
    NSString *s = [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![s length] || [s isEqualToString:@"N/A"]) return nil;
    return s;
}

// "139 min" -> 8340 seconds; the 2012 runtime field is seconds.
static NSNumber *RuntimeSeconds(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
        else if ([digits length]) break;
    }
    if (![digits length]) return nil;
    return [NSNumber numberWithInt:[digits intValue] * 60];
}

// "2,323,146" -> 2323146
static NSNumber *DigitNumber(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
    }
    if (![digits length]) return nil;
    return [NSNumber numberWithLongLong:[digits longLongValue]];
}

// "31 Mar 1999" -> "1999-03-31"; anything else is left out rather than guessed.
static NSString *ISO8601Date(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || ![s length]) return nil;
    NSDateFormatter *f = [[[NSDateFormatter alloc] init] autorelease];
    [f setDateFormat:@"d MMM yyyy"];
    [f setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
    NSDate *d = [f dateFromString:s];
    if (!d) return nil;
    [f setDateFormat:@"yyyy-MM-dd"];
    return [f stringFromDate:d];
}

// OMDb answers by IMDb id alone, so it also rescues an id the suggestion API
// does not know. Returns nil when there is no key, no network, or no record.
static NSMutableDictionary *FetchOmdbInfo(NSString *tconst, NSString **errOut) {
    NSString *key = APIKey(@"OMDbAPIKey");
    if (!key) {
        if (errOut) *errOut = @"no OMDb key";
        return nil;
    }
    NSString *u = [NSString stringWithFormat:
                   @"https://www.omdbapi.com/?i=%@&plot=short&apikey=%@", tconst, key];
    NSData *body = FetchHTTPS([NSURL URLWithString:u], 8.0, NULL, NULL, errOut);
    if (!body) return nil;

    id root = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    if (![root isKindOfClass:[NSDictionary class]]) {
        if (errOut) *errOut = @"omdb: not json";
        return nil;
    }
    if (![[root objectForKey:@"Response"] isEqualToString:@"True"]) {
        if (errOut) *errOut = [NSString stringWithFormat:@"omdb: %@",
                               [root objectForKey:@"Error"] ? [root objectForKey:@"Error"] : @"not found"];
        return nil;
    }

    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:tconst forKey:@"tconst"];
    NSString *v = nil;
    if ((v = NotAvailable([root objectForKey:@"Title"]))) [info setObject:v forKey:@"title"];
    if ((v = NotAvailable([root objectForKey:@"Year"]))) {
        [info setObject:([v length] > 4 ? [v substringToIndex:4] : v) forKey:@"year"];
    }
    if ((v = NotAvailable([root objectForKey:@"Type"]))) [info setObject:v forKey:@"type"];
    if ((v = NotAvailable([root objectForKey:@"Rated"]))) [info setObject:v forKey:@"certificate"];
    if ((v = NotAvailable([root objectForKey:@"Plot"]))) [info setObject:v forKey:@"plot"];
    if ((v = NotAvailable([root objectForKey:@"Poster"]))) [info setObject:v forKey:@"poster"];

    if ((v = NotAvailable([root objectForKey:@"Genre"]))) [info setObject:SplitNames(v) forKey:@"genres"];
    if ((v = NotAvailable([root objectForKey:@"Director"]))) [info setObject:SplitNames(v) forKey:@"directors"];
    if ((v = NotAvailable([root objectForKey:@"Writer"]))) [info setObject:SplitNames(v) forKey:@"writers"];
    if ((v = NotAvailable([root objectForKey:@"Actors"]))) [info setObject:SplitNames(v) forKey:@"stars"];
    if ((v = NotAvailable([root objectForKey:@"Released"]))) {
        NSString *iso = ISO8601Date(v);
        if (iso) [info setObject:iso forKey:@"released"];
    }
    if ((v = NotAvailable([root objectForKey:@"Runtime"]))) {
        NSNumber *secs = RuntimeSeconds(v);
        if (secs) [info setObject:secs forKey:@"runtime"];
    }
    if ((v = NotAvailable([root objectForKey:@"imdbVotes"]))) {
        NSNumber *n = DigitNumber(v);
        if (n) [info setObject:n forKey:@"votes"];
    }
    if ((v = NotAvailable([root objectForKey:@"imdbRating"]))) {
        [info setObject:[NSNumber numberWithDouble:[v doubleValue]] forKey:@"rating"];
    }
    return info;
}

// Two requests, only on the full-credits route: find the movie from the IMDb id,
// then its credits. Returns [{name, character, profile}] or nil.
static NSArray *FetchTmdbCast(NSString *tconst, NSString **errOut) {
    NSString *key = APIKey(@"TMDBAPIKey");
    if (!key) {
        if (errOut) *errOut = @"no TMDB key";
        return nil;
    }
    NSString *find = [NSString stringWithFormat:
                      @"https://api.themoviedb.org/3/find/%@?external_source=imdb_id&api_key=%@",
                      tconst, key];
    NSData *body = FetchHTTPS([NSURL URLWithString:find], 8.0, NULL, NULL, errOut);
    if (!body) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    id results = [root isKindOfClass:[NSDictionary class]] ? [root objectForKey:@"movie_results"] : nil;
    if (![results isKindOfClass:[NSArray class]] || ![results count]) {
        if (errOut) *errOut = @"tmdb: no movie_result";
        return nil;
    }
    id movieId = [[results objectAtIndex:0] objectForKey:@"id"];
    if (![movieId respondsToSelector:@selector(stringValue)]) return nil;

    NSString *credits = [NSString stringWithFormat:
                         @"https://api.themoviedb.org/3/movie/%@/credits?api_key=%@",
                         [movieId stringValue], key];
    NSData *cbody = FetchHTTPS([NSURL URLWithString:credits], 8.0, NULL, NULL, errOut);
    if (!cbody) return nil;
    id croot = [NSJSONSerialization JSONObjectWithData:cbody options:0 error:NULL];
    id cast = [croot isKindOfClass:[NSDictionary class]] ? [croot objectForKey:@"cast"] : nil;
    if (![cast isKindOfClass:[NSArray class]]) {
        if (errOut) *errOut = @"tmdb: no cast";
        return nil;
    }

    NSMutableArray *out = [NSMutableArray array];
    for (id p in cast) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = SuggestionString([p objectForKey:@"name"]);
        if (![name length]) continue;
        NSString *character = SuggestionString([p objectForKey:@"character"]);
        NSString *profile = SuggestionString([p objectForKey:@"profile_path"]);
        NSMutableDictionary *e = [NSMutableDictionary dictionary];
        [e setObject:name forKey:@"name"];
        if ([character length]) [e setObject:character forKey:@"character"];
        // TMDB serves headshots; the app asks for whatever URL the payload
        // carries, and this one is https like the Amazon posters it already
        // loads.
        if ([profile length]) {
            [e setObject:[NSString stringWithFormat:@"https://image.tmdb.org/t/p/w185%@", profile]
                  forKey:@"image"];
        }
        [out addObject:e];
    }
    return out;
}

// Copies whatever OMDb could confirm over the suggestion answer.
static void MergeInfo(NSMutableDictionary *into, NSDictionary *from) {
    if (!into || !from) return;
    for (NSString *k in [NSArray arrayWithObjects:@"title", @"year", @"type", @"certificate",
                         @"plot", @"genres", @"directors", @"writers", @"stars", @"released",
                         @"runtime", @"votes", @"rating", nil]) {
        id v = [from objectForKey:k];
        if (!v) continue;
        // An empty string or array is a missing value, not a better one.
        if ([v isKindOfClass:[NSString class]] && ![v length]) continue;
        if ([v isKindOfClass:[NSArray class]] && ![v count]) continue;
        [into setObject:v forKey:k];
    }
    if (![[into objectForKey:@"poster"] length] && [[from objectForKey:@"poster"] length]) {
        [into setObject:[from objectForKey:@"poster"] forKey:@"poster"];
    }
}

// Where the answer came from, for the log: "disk" on a cold start is the
// difference between a cache that persisted and one that never did.
static NSString *gTitleInfoSource = nil;

static void SetTitleInfoSource(NSString *s) {
    TitleInfoInit();
    [gTitleInfoLock lock];
    [gTitleInfoSource release];
    gTitleInfoSource = [s copy];
    [gTitleInfoLock unlock];
}

static NSString *TitleInfoSource(void) {
    TitleInfoInit();
    [gTitleInfoLock lock];
    NSString *s = [gTitleInfoSource retain];
    [gTitleInfoLock unlock];
    return [s autorelease];
}

// nil means "nothing live": the caller answers for the tconst alone and never
// serves the archived film's content in its place.
static NSDictionary *FetchTitleInfo(NSString *tconst, NSInteger *statusOut, NSString **errOut) {
    if (![tconst length]) return nil;
    NSDictionary *hit = CachedTitleInfo(tconst);
    if (hit) {
        SetTitleInfoSource(@"cache");
        return hit;
    }

    TitleInfoInit();
    // maindetails and title-auxiliary are asked for in parallel for the same
    // page; serialise the miss so only one of them goes to the network.
    [gTitleFetchLock lock];
    hit = CachedTitleInfo(tconst);
    if (hit) {
        SetTitleInfoSource(@"cache");
    } else {
        NSData *body = FetchHTTPS(SuggestionURLForQuery(tconst), 8.0, statusOut, NULL, errOut);
        if (!body) {
            // One retry. The first request after launch is where the -1001 race
            // lives, and a real tap must not pay for it with the fixture.
            usleep(1000 * 1000);
            body = FetchHTTPS(SuggestionURLForQuery(tconst), 8.0, statusOut, NULL, errOut);
        }
        NSString *src = nil;
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        [info setObject:tconst forKey:@"tconst"];

        if (body) {
            CacheSuggestionBody(body);
            NSDictionary *sugg = CachedTitleInfo(tconst);
            if (sugg) {
                [info addEntriesFromDictionary:sugg];
                src = @"live";
            } else if (errOut) {
                // The body head is the difference between "the API does not know
                // this id" and "we could not read the answer".
                NSUInteger n = [body length] < 120 ? [body length] : 120;
                NSString *head = [[[NSString alloc] initWithData:[body subdataWithRange:NSMakeRange(0, n)]
                                                        encoding:NSUTF8StringEncoding] autorelease];
                *errOut = [NSString stringWithFormat:@"no entry for this tconst: %@",
                           head ? head : @"(non-utf8)"];
            }
        }

        // OMDb answers by id alone, so this is also what rescues an id the
        // suggestion endpoint has never heard of — a blank page becomes a page.
        NSString *omdbErr = nil;
        NSMutableDictionary *omdb = FetchOmdbInfo(tconst, &omdbErr);
        if (omdb) {
            MergeInfo(info, omdb);
            src = [src length] ? @"live+omdb" : @"omdb";
        } else {
            // Keep the reason with the entry. A key the app cannot read, and an
            // id OMDb has nothing for, look identical in the payload otherwise.
            [info setObject:(omdbErr ? omdbErr : @"no omdb") forKey:@"omdbError"];
            if (![src length] && errOut) {
                NSString *have = (*errOut ? *errOut : @"no suggestion entry");
                *errOut = [NSString stringWithFormat:@"%@ / %@", have, omdbErr ? omdbErr : @"no omdb"];
            }
        }

        // Stamped so the disk entry can expire: a wrong answer must not live
        // forever just because it was written once.
        [info setObject:[NSNumber numberWithLongLong:(long long)time(NULL)] forKey:@"fetched"];
        [gTitleInfoLock lock];
        [gTitleInfo setObject:info forKey:tconst];
        [gTitleInfoLock unlock];
        hit = info;
        SetTitleInfoSource(src ? src : @"none");
        SaveTitleCacheToDisk(YES);
    }
    [gTitleFetchLock unlock];
    return hit;
}

#pragma mark - protocol

@interface IMDBServeProtocol : NSURLProtocol
{
    BOOL _cancelled;
}
@end

@implementation IMDBServeProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request) return NO;

    // Never re-enter on our own sub-requests.
    if ([NSURLProtocol propertyForKey:kServedKey inRequest:request]) return NO;

    NSString *host = [[request URL].host lowercaseString];
    BOOL claimsApp = [host isEqualToString:@"app.imdb.com"];
    BOOL claimsSuggests = IsSuggestsRequest(request);
    // Template engine routes: the homepage answers from a fixture, every other
    // template path falls through to a logged 404 so the missing routes are
    // exactly the ones the app asks for.
    BOOL claimsTemplate = [host isEqualToString:@"api.imdbws.com"] &&
                          [[request URL].path hasPrefix:@"/template/"];
    BOOL claimsImage = IsImageRequest(request);

    if (claimsApp || claimsSuggests || claimsTemplate || claimsImage) {
        // Recorded at claim time as well as at serve time: a request that is
        // claimed and then cancelled by the app never reaches startLoading, and
        // its absence would read as "the app never asked for it".
        NSString *match = claimsTemplate ? @"api.imdbws.com/template"
                                         : (claimsImage ? @"ia.media-imdb.com/images"
                                                        : (claimsApp ? @"app.imdb.com" : @"suggests"));
        ProbeLogRequest(request, @"claim",
                        [NSDictionary dictionaryWithObject:match forKey:@"claim"]);
        return YES;
    }

    // Everything else is the system's business, but IMDb/Amazon traffic is worth
    // recording: it is how the follow-up calls of a title page show up.
    if (IMDBHostMatches(host)) LogPassThrough(request);
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

// Both title routes carry per-title data now, and resolving that is a network
// call: answered on a worker thread, like search.
static BOOL IsTitleDataRoute(NSURLRequest *request) {
    NSString *name = RouteNameForRequest(request);
    return ([name isEqualToString:@"title-auxiliary.json"] ||
            [name isEqualToString:@"md-2012.json"] ||
            [name isEqualToString:@"fullcredits.json"]);
}

- (void)startLoading {
    NSURLRequest *request = [self request];

    // Search is the one route whose live answer is worth waiting for; handled
    // off the caller's thread so search-as-you-type does not block on it.
    if (IsSuggestsRequest(request)) {
        [NSThread detachNewThreadSelector:@selector(runLiveSuggests)
                                 toTarget:self
                               withObject:nil];
        return;
    }

    // Photos are binary and slow: relay them on their own thread too.
    if (IsImageRequest(request)) {
        [NSThread detachNewThreadSelector:@selector(runImage)
                                 toTarget:self
                               withObject:nil];
        return;
    }

    // Title data: may need one live request before it can answer.
    if (IsTitleDataRoute(request)) {
        [NSThread detachNewThreadSelector:@selector(runTitleRoute)
                                 toTarget:self
                               withObject:nil];
        return;
    }

    NSInteger status = 200;
    NSString *route = nil;
    NSString *ctype = @"application/json";
    NSData *body = ServeRoute(request, nil, &status, &route, &ctype);
    if (!body) body = [NSData data];

    ProbeLogRequest(request, @"serve",
                    [NSDictionary dictionaryWithObjectsAndKeys:
                     route, @"route",
                     [NSNumber numberWithInteger:status], @"served_status",
                     [NSNumber numberWithUnsignedInteger:[body length]], @"served_bytes",
                     nil]);

    if (!ctype) ctype = @"application/json";
    NSDictionary *headers = ResponseHeaders(ctype, [body length]);

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
    _cancelled = YES;
}

// Worker thread: relay a photo from the https origin that still serves it.
- (void)runImage {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSURLRequest *request = [[self request] retain];

    NSURL *live = LiveImageURL(request);
    NSString *key = [live absoluteString];
    NSString *source = @"image-live";
    NSString *err = nil;
    NSInteger status = 0;
    NSData *body = nil;
    NSString *ctype = nil;

    // The same portraits are asked for on every open, and each is a few KB, so
    // keep them in memory instead of re-fetching per request. Bounded.
    [gImageCacheLock lock];
    NSDictionary *hit = [[gImageCache objectForKey:key] retain];
    [gImageCacheLock unlock];

    if (hit) {
        body = [[hit objectForKey:@"body"] retain];
        ctype = [[hit objectForKey:@"ctype"] retain];
        status = 200;
        source = @"image-cache";
    } else {
        body = [FetchHTTPS(live, 8.0, &status, &ctype, &err) retain];
        if (body && [body length] <= 512 * 1024) {
            [gImageCacheLock lock];
            if ([gImageCache count] < 64) {
                [gImageCache setObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                        body, @"body", (ctype ? ctype : @"image/jpeg"), @"ctype", nil]
                                forKey:key];
            }
            [gImageCacheLock unlock];
        }
    }
    if (!ctype) ctype = @"image/jpeg";
    BOOL ok = (status == 200 && [body length] > 0);

    NSString *route = ok ? source
                         : [NSString stringWithFormat:@"image-fail(%@)", err ? err : @"no body"];
    ProbeLogRequest(request, @"serve",
                    [NSDictionary dictionaryWithObjectsAndKeys:
                     route, @"route",
                     [NSNumber numberWithInteger:ok ? 200 : 404], @"served_status",
                     [NSNumber numberWithUnsignedInteger:[body length]], @"served_bytes",
                     [live absoluteString], @"live_url",
                     nil]);

    if (!_cancelled) {
        // The client must be driven on its own run loop (the main one); calling
        // it from this worker thread is a data race the app can crash on.
        NSData *outBody = [body retain];
        NSString *outCtype = [ctype retain];
        NSInteger outStatus = ok ? 200 : 404;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!_cancelled) {
                NSDictionary *headers = ResponseHeaders(outCtype, [outBody length]);
                NSHTTPURLResponse *out = [[NSHTTPURLResponse alloc] initWithURL:[request URL]
                                                                    statusCode:outStatus
                                                                   HTTPVersion:@"HTTP/1.1"
                                                                  headerFields:headers];
                [[self client] URLProtocol:self didReceiveResponse:out cacheStoragePolicy:NSURLCacheStorageAllowed];
                if ([outBody length]) [[self client] URLProtocol:self didLoadData:outBody];
                [[self client] URLProtocolDidFinishLoading:self];
                [out release];
            }
            [outBody release];
            [outCtype release];
        });
    }

    [hit release];
    [body release];
    [ctype release];
    [request release];
    [pool release];
}

// Worker thread: try the live host, log which side answered, deliver either way.
- (void)runLiveSuggests {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSURLRequest *request = [[self request] retain];

    NSInteger status = 0;
    NSString *err = nil;
    NSURL *live = LiveSuggestsURL(request);
    NSData *body = FetchLiveSuggests(live, &status, &err);
    // Every search result the app shows is kept by tconst, so opening one of
    // them needs no further request.
    if (body) {
        CacheSuggestionBody(body);
        // Tapping one of these results must not depend on the network, and the
        // entries should still be there after a relaunch.
        SaveTitleCacheToDisk(NO);
    }
    NSString *source = @"suggests-live";
    NSString *ctype = @"application/javascript";

    if (!body) {
        // Fallback. Reset status so a failed live attempt cannot leak its 0/403
        // into the response the client sees.
        NSInteger fstatus = 0;
        NSString *fctype = nil;
        NSString *froute = nil;
        body = FixtureSuggests(request, &fstatus, &fctype, &froute);
        status = fstatus;
        ctype = fctype ? fctype : @"application/javascript";
        source = [NSString stringWithFormat:@"suggests-fixture(%@)", err ? err : @"no body"];
    }

    NSDictionary *extra = [NSDictionary dictionaryWithObjectsAndKeys:
                           source, @"route",
                           [NSNumber numberWithInteger:status], @"served_status",
                           [NSNumber numberWithUnsignedInteger:[body length]], @"served_bytes",
                           [live absoluteString], @"live_url",
                           nil];
    ProbeLogRequest(request, @"serve", extra);

    if (!_cancelled) {
        NSDictionary *headers = ResponseHeaders(ctype, [body length]);
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:[request URL]
                                                             statusCode:status
                                                            HTTPVersion:@"HTTP/1.1"
                                                           headerFields:headers];
        [[self client] URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        if ([body length]) [[self client] URLProtocol:self didLoadData:body];
        [[self client] URLProtocolDidFinishLoading:self];
        [resp release];
    }

    [request release];
    [pool release];
}

// Worker thread: answer maindetails / title-auxiliary with the film that was
// asked for, not the fixture's. One live suggestion request per new tconst; the
// answer is cached, so the second route of the same page is free and a title
// already seen in search costs no request at all.
- (void)runTitleRoute {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSURLRequest *request = [[self request] retain];
    NSString *tconst = TconstForRequest(request);
    // fullcredits is often sent without the id; the page being opened is the
    // one the previous title route answered.
    BOOL fromRequest = ([tconst length] > 0);
    if (!tconst) tconst = LastTitleTconstIfFresh();

    NSInteger liveStatus = 0;
    NSString *liveErr = nil;
    NSDictionary *info = tconst ? FetchTitleInfo(tconst, &liveStatus, &liveErr) : nil;
    if (tconst) SetLastTitleTconst(tconst);
    // An empty string here means the page is answered for its tconst alone —
    // never for the archived film.
    NSString *source = info ? TitleInfoSource() : @"blank";

    // Full cast is the only route that wants the real credit list, and TMDB is
    // the only source for characters and headshots: fetched here, once, and
    // kept with the rest of the entry so a second open is free.
    NSString *routeName = RouteNameForRequest(request);
    if (info && [routeName isEqualToString:@"fullcredits.json"] &&
        ![[info objectForKey:@"tmdbCast"] isKindOfClass:[NSArray class]]) {
        NSString *tmdbErr = nil;
        NSArray *tmdbCast = FetchTmdbCast(tconst, &tmdbErr);
        if ([tmdbCast count]) {
            NSMutableDictionary *merged = [[info mutableCopy] autorelease];
            [merged setObject:tmdbCast forKey:@"tmdbCast"];
            info = merged;
            [gTitleInfoLock lock];
            [gTitleInfo setObject:merged forKey:tconst];
            [gTitleInfoLock unlock];
            SaveTitleCacheToDisk(YES);
        } else if (tmdbErr) {
            liveErr = tmdbErr;
        }
    }

    NSInteger status = 200;
    NSString *route = nil;
    NSString *ctype = nil;
    NSData *body = ServeRoute(request, info, &status, &route, &ctype);
    if (!body) body = [NSData data];

    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    [extra setObject:(route ? route : @"(none)") forKey:@"route"];
    [extra setObject:[NSNumber numberWithInteger:status] forKey:@"served_status"];
    [extra setObject:[NSNumber numberWithUnsignedInteger:[body length]] forKey:@"served_bytes"];
    [extra setObject:(source ? source : @"blank") forKey:@"title_source"];
    [extra setObject:(fromRequest ? @"request" : (tconst ? @"last" : @"none")) forKey:@"tconst_source"];
    if (tconst) [extra setObject:tconst forKey:@"tconst"];
    if (info) {
        if ([info objectForKey:@"title"]) [extra setObject:[info objectForKey:@"title"] forKey:@"title"];
        id stars = [info objectForKey:@"stars"];
        [extra setObject:[NSNumber numberWithUnsignedInteger:
                          ([stars isKindOfClass:[NSArray class]] ? [stars count] : 0)]
                  forKey:@"stars"];
        if ([info objectForKey:@"poster"]) [extra setObject:[info objectForKey:@"poster"] forKey:@"poster"];
    }
    if (liveErr) [extra setObject:liveErr forKey:@"live_error"];
    ProbeLogRequest(request, @"serve", extra);

    if (!_cancelled) {
        NSData *outBody = [body retain];
        NSString *outCtype = [(ctype ? ctype : @"application/json") retain];
        NSInteger outStatus = status;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!_cancelled) {
                NSDictionary *headers = ResponseHeaders(outCtype, [outBody length]);
                NSHTTPURLResponse *out = [[NSHTTPURLResponse alloc] initWithURL:[request URL]
                                                                    statusCode:outStatus
                                                                   HTTPVersion:@"HTTP/1.1"
                                                                  headerFields:headers];
                [[self client] URLProtocol:self didReceiveResponse:out cacheStoragePolicy:NSURLCacheStorageNotAllowed];
                if ([outBody length]) [[self client] URLProtocol:self didLoadData:outBody];
                [[self client] URLProtocolDidFinishLoading:self];
                [out release];
            }
            [outBody release];
            [outCtype release];
        });
    }

    [request release];
    [pool release];
}

@end

%ctor {
    ProbeInit();
    InstallDataWrapperAccessorHooks();
    [NSURLProtocol registerClass:[IMDBServeProtocol class]];
    LogLoadContext();

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"loaded" forKey:@"event"];
    [d setObject:@"4.2-omdb" forKey:@"build"];
    [d setObject:ProbeISO8601() forKey:@"ts"];
    [d setObject:[NSNumber numberWithInt:(int)getpid()] forKey:@"pid"];
    [d setObject:(getenv("HOME") ? [NSString stringWithUTF8String:getenv("HOME")] : @"(null)")
           forKey:@"home"];
    [d setObject:@"IMDBServeProtocol" forKey:@"protocol"];
    [d setObject:kRoutesDir forKey:@"routes"];
    ProbeEmit(d);

    // Live data: without this, sg.media-imdb.com and GraphQL fail -9824 inside
    // the app exactly as they do in E5 (§17). Loading it here is what makes
    // live search and live titles possible without repairing Substrate.
    NSString *tlsFail = LoadTLSFix();
    NSMutableDictionary *t = [NSMutableDictionary dictionary];
    [t setObject:@"tlsfix" forKey:@"event"];
    [t setObject:ProbeISO8601() forKey:@"ts"];
    [t setObject:[NSNumber numberWithInt:(int)getpid()] forKey:@"pid"];
    [t setObject:(tlsFail ? @"failed" : @"loaded") forKey:@"result"];
    if (tlsFail) [t setObject:tlsFail forKey:@"reason"];
    [t setObject:[NSNumber numberWithBool:TLSFixImageLoaded()] forKey:@"image"];
    ProbeEmit(t);

    if (access([kLiveTestMark UTF8String], F_OK) == 0) {
        [[[[IMDBLiveTest alloc] init] autorelease] performSelectorInBackground:@selector(run:)
                                                                   withObject:nil];
    }
}

// Parser-side recording (§17): log the payload the auxiliary and homepage
// controllers actually receive, and what `pstr` resolves to. Hooks live in the
// app's own classes, so Foundation is never touched.
static NSString *DescribeValue(id v) {
    if (!v) return @"nil";
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSArray *keys = [(NSDictionary *)v allKeys];
        NSArray *head = [keys count] > 12 ? [keys subarrayWithRange:NSMakeRange(0, 12)] : keys;
        return [NSString stringWithFormat:@"dict(%@)%@",
                [head componentsJoinedByString:@","],
                [keys count] > 12 ? @",..." : @""];
    }
    if ([v isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"array(%lu)", (unsigned long)[(NSArray *)v count]];
    }
    if ([v isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"string(%@)", v];
    return NSStringFromClass([v class]);
}

static void LogPayload(id obj, NSString *where) {
    if (!obj) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"payload" forKey:@"event"];
    [d setObject:where forKey:@"where"];
    [d setObject:ProbeISO8601() forKey:@"ts"];
    [d setObject:[NSNumber numberWithInt:(int)getpid()] forKey:@"pid"];
    [d setObject:NSStringFromClass([obj class]) forKey:@"class"];
    [d setObject:[NSNumber numberWithBool:[obj isKindOfClass:[NSDictionary class]]] forKey:@"is_dict"];

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        NSArray *keys = [dict allKeys];
        [d setObject:[NSNumber numberWithUnsignedInteger:[keys count]] forKey:@"key_count"];
        [d setObject:[keys componentsJoinedByString:@","] forKey:@"keys"];
        id pstr = [dict objectForKey:@"pstr"];
        [d setObject:DescribeValue(pstr) forKey:@"pstr"];
        if ([pstr isKindOfClass:[NSDictionary class]]) {
            id img = [(NSDictionary *)pstr objectForKey:@"image"];
            if ([img isKindOfClass:[NSDictionary class]]) {
                id u = [(NSDictionary *)img objectForKey:@"url"];
                if ([u isKindOfClass:[NSString class]]) [d setObject:u forKey:@"pstr_image"];
            }
        }
        [d setObject:DescribeValue([dict objectForKey:@"sections"]) forKey:@"sections"];
        [d setObject:DescribeValue([dict objectForKey:@"widgets"]) forKey:@"widgets"];
        [d setObject:DescribeValue([dict objectForKey:@"data"]) forKey:@"data"];
    }
    ProbeEmit(d);
}

// IMDataWrapper is the parser's data path: it wraps a dictionary and serves
// objectForKey:/dictionaryForKey:/arrayForKey:/stringForKey:. Hooking it records
// what the layout asks for, per widget, without touching Foundation.
static NSMutableSet *gWrapSeen = nil;
static NSLock *gWrapLock = nil;

static void LogWrap(NSString *op, NSString *key, id value) {
    if (!key || ![key isKindOfClass:[NSString class]]) return;
    if (!gWrapSeen) {
        gWrapSeen = [[NSMutableSet alloc] init];
        gWrapLock = [[NSLock alloc] init];
    }
    NSString *sig = [NSString stringWithFormat:@"%@|%@", op, key];
    BOOL seen = NO;
    [gWrapLock lock];
    seen = [gWrapSeen containsObject:sig];
    if (!seen && [gWrapSeen count] < 600) [gWrapSeen addObject:sig];
    [gWrapLock unlock];
    if (seen) return;

    ProbeEmit([NSDictionary dictionaryWithObjectsAndKeys:
               @"lookup", @"event",
               op, @"op",
               key, @"key",
               DescribeValue(value), @"value",
               ProbeISO8601(), @"ts",
               [NSNumber numberWithInt:(int)getpid()], @"pid",
               nil]);
}

// IMDataWrapper's own accessors are never called (subclasses override them),
// so hook every subclass's no-argument object getters (type encoding
// "@16@0:8") with one shared logger. The original IMP is preserved per method.
static NSMutableDictionary *gOrigIMPs = nil;

static void InstallDataWrapperAccessorHooks(void) {
    Class base = objc_getClass("IMDataWrapper");
    if (!base) { ProbeEmit([NSDictionary dictionaryWithObject:@"no IMDataWrapper class" forKey:@"event"]); return; }
    gOrigIMPs = [[NSMutableDictionary alloc] init];

    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)total);
    total = objc_getClassList(classes, total);
    int hooked = 0;

    for (int i = 0; i < total; i++) {
        Class c = classes[i];
        BOOL isSub = NO;
        for (Class k = class_getSuperclass(c); k; k = class_getSuperclass(k)) {
            if (k == base) { isSub = YES; break; }
        }
        if (!isSub) continue;

        unsigned int mc = 0;
        Method *methods = class_copyMethodList(c, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            Method m = methods[j];
            const char *enc = method_getTypeEncoding(m);
            if (!enc || strcmp(enc, "@16@0:8") != 0) continue;
            SEL sel = method_getName(m);
            NSString *key = [NSString stringWithFormat:@"%s|%s", class_getName(c), sel_getName(sel)];
            if ([gOrigIMPs objectForKey:key]) continue;
            IMP orig = method_getImplementation(m);
            [gOrigIMPs setObject:[NSValue valueWithPointer:(const void *)orig] forKey:key];
            NSString *op = [NSString stringWithFormat:@"%s.%s", class_getName(c), sel_getName(sel)];
            __block IMP origBlock = orig;
            __block SEL selBlock = sel;
            IMP repl = imp_implementationWithBlock(^id(id obj) {
                id v = ((id (*)(id, SEL))origBlock)(obj, selBlock);
                LogWrap(op, op, v);
                return v;
            });
            if (repl) { method_setImplementation(m, repl); hooked++; }
        }
        if (methods) free(methods);
    }
    if (classes) free(classes);
    ProbeEmit([NSDictionary dictionaryWithObjectsAndKeys:
               @"accessor-hooks", @"event",
               [NSNumber numberWithInt:hooked], @"hooked",
               ProbeISO8601(), @"ts",
               nil]);
}

%hook IMDataWrapper

- (id)initWithDictionary:(id)dict {
    if ([dict isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        [d setObject:@"wrap" forKey:@"event"];
        [d setObject:[[(NSDictionary *)dict allKeys] componentsJoinedByString:@","] forKey:@"keys"];
        [d setObject:[NSNumber numberWithUnsignedInteger:[(NSDictionary *)dict count]] forKey:@"key_count"];
        [d setObject:ProbeISO8601() forKey:@"ts"];
        [d setObject:[NSNumber numberWithInt:(int)getpid()] forKey:@"pid"];
        // What `pstr` actually resolves to, whenever it is present.
        id pstr = [(NSDictionary *)dict objectForKey:@"pstr"];
        if (pstr) {
            [d setObject:DescribeValue(pstr) forKey:@"pstr"];
            if ([pstr isKindOfClass:[NSDictionary class]]) {
                id img = [(NSDictionary *)pstr objectForKey:@"image"];
                if ([img isKindOfClass:[NSDictionary class]]) {
                    id u = [(NSDictionary *)img objectForKey:@"url"];
                    if ([u isKindOfClass:[NSString class]]) [d setObject:u forKey:@"pstr_image"];
                }
            }
        }
        ProbeEmit(d);
    }
    return %orig;
}

- (id)objectForKey:(id)key {
    id v = %orig;
    LogWrap(@"objectForKey", key, v);
    return v;
}

- (id)dictionaryForKey:(id)key {
    id v = %orig;
    LogWrap(@"dictionaryForKey", key, v);
    return v;
}

- (id)arrayForKey:(id)key {
    id v = %orig;
    LogWrap(@"arrayForKey", key, v);
    return v;
}

- (id)stringForKey:(id)key {
    id v = %orig;
    LogWrap(@"stringForKey", key, v);
    return v;
}

%end

%hook IMTabletConstPageAuxillaryViewController

- (void)setData:(id)data {
    LogPayload(data, @"aux-setData");
    %orig;
}

%end

%hook IMTabletTitlePageAuxillaryViewController

- (void)handleResponse:(id)response {
    LogPayload(response, @"aux-handleResponse");
    %orig;
}

%end

%hook IMTabletFrontPageViewController

- (void)setDataSource:(id)source {
    LogPayload(source, @"frontpage-setDataSource");
    %orig;
}

%end

// The poster widget never requests its image, so log what it is actually handed:
// an empty/nil data object means the response never reached it, a populated one
// means the widget is gated on something else.
%hook IMTitlePagePosterWidget

- (void)setWidgetData:(id)data {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"widgetdata" forKey:@"event"];
    [d setObject:@"IMTitlePagePosterWidget" forKey:@"class"];
    [d setObject:ProbeISO8601() forKey:@"ts"];
    [d setObject:[NSNumber numberWithInt:(int)getpid()] forKey:@"pid"];
    if ([data isKindOfClass:[NSDictionary class]]) {
        [d setObject:[NSArray arrayWithArray:[(NSDictionary *)data allKeys]] forKey:@"keys"];
        id img = [(NSDictionary *)data objectForKey:@"image"];
        if ([img isKindOfClass:[NSDictionary class]]) {
            id u = [(NSDictionary *)img objectForKey:@"url"];
            if ([u isKindOfClass:[NSString class]]) [d setObject:u forKey:@"image_url"];
        }
    } else if (data) {
        [d setObject:NSStringFromClass([data class]) forKey:@"data_class"];
    } else {
        [d setObject:@"nil" forKey:@"data_class"];
    }
    ProbeEmit(d);
    %orig;
}

%end

// Which screens actually appear is the only reliable "does it render" signal:
// there is no screenshot tool on this device, and a page can load its data while
// still being replaced by an error view.
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    NSString *cls = NSStringFromClass([self class]);
    if (cls) {
        ProbeEmit([NSDictionary dictionaryWithObjectsAndKeys:
                   @"screen", @"event",
                   cls, @"class",
                   ProbeISO8601(), @"ts",
                   [NSNumber numberWithInt:(int)getpid()], @"pid",
                   [NSNumber numberWithBool:animated], @"animated",
                   nil]);
    }
    %orig;
}

%end

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
