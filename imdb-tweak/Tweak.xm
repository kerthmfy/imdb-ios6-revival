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
    [d setObject:@"3.6-accessors" forKey:@"build"];
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
@interface IMDBLiveTest : NSObject
- (void)run:(id)ignored;
@end

@implementation IMDBLiveTest

- (void)probeURL:(NSString *)url label:(NSString *)label bypassTweak:(BOOL)bypass {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setTimeoutInterval:20];
    // Without this a cached body makes a broken TLS path look healthy: the first
    // no-tlsfix run reported 200/3,170 B from cache while the fetch was failing.
    [req setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
    // A real UA matters: api.graphql.imdb.com answered 403 to a bare POST in E5.
    [req setValue:@"IMDb/3.4.2 (iPad; iPhone OS 6.1.3)" forHTTPHeaderField:@"User-Agent"];
    // IsSuggestsRequest matches https too, so without this the "raw" probe is
    // answered by our own protocol and its bytes say nothing about TLS.
    if (bypass) {
        [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:kServedKey inRequest:req];
    }

    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *body = [NSURLConnection sendSynchronousRequest:req
                                         returningResponse:(NSURLResponse **)&resp
                                                     error:&err];

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"livetest" forKey:@"event"];
    [d setObject:label forKey:@"target"];
    [d setObject:url forKey:@"url"];
    [d setObject:ProbeISO8601() forKey:@"ts"];
    [d setObject:[NSNumber numberWithInt:(int)getpid()] forKey:@"pid"];
    [d setObject:[NSNumber numberWithBool:TLSFixImageLoaded()] forKey:@"tlsfix"];

    if (err) {
        [d setObject:[NSNumber numberWithInteger:[err code]] forKey:@"error_code"];
        [d setObject:[[err userInfo] description] forKey:@"error"];
    } else {
        [d setObject:[NSNumber numberWithInteger:[resp statusCode]] forKey:@"status"];
        [d setObject:[NSNumber numberWithUnsignedInteger:[body length]] forKey:@"bytes"];
        if ([body length]) {
            NSUInteger n = [body length] < 160 ? [body length] : 160;
            NSString *head = [[[NSString alloc] initWithData:[body subdataWithRange:NSMakeRange(0, n)]
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
    [pool release];
}

@end

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
static NSData *ServeRoute(NSURLRequest *request, NSInteger *statusOut, NSString **routeOut, NSString **ctypeOut) {
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

- (void)startLoading {
    NSURLRequest *request = [self request];

    // Live first, fixture as the fallback: this is the only route with a real
    // upstream left. Handled off the caller's thread so search-as-you-type does
    // not block on it.
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
                NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:
                                         outCtype, @"Content-Type",
                                         [NSString stringWithFormat:@"%lu", (unsigned long)[outBody length]], @"Content-Length",
                                         nil];
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
    [d setObject:@"3.6-accessors" forKey:@"build"];
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
