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
    [d setObject:@"2.3-claimlog" forKey:@"build"];
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

static BOOL IsDashRoute(NSString *path) {
    return ([path rangeOfString:@"maindetails"].location != NSNotFound);
}

// nil means "no fixture yet": the caller answers 404 and the log records it, so
// the missing routes are exactly the set listed in the capture.
static NSString *RouteNameForRequest(NSURLRequest *request) {
    NSString *path = request.URL.path;
    if (!path) return nil;

    if (IsHomepageRequest(request)) return @"homepage.json";

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
    if ([name isEqualToString:@"homepage.json"]) {
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
static NSData *FetchLiveSuggests(NSURL *url, NSInteger *statusOut, NSString **errOut) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setTimeoutInterval:6.0];
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

    if (err) {
        if (errOut) *errOut = [NSString stringWithFormat:@"%@ %ld", [err domain], (long)[err code]];
        return nil;
    }
    if (!resp || [resp statusCode] != 200 || ![body length]) {
        if (errOut) *errOut = [NSString stringWithFormat:@"status %ld, %lu bytes",
                               (long)(resp ? [resp statusCode] : 0), (unsigned long)[body length]];
        return nil;
    }
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

    if (claimsApp || claimsSuggests || claimsTemplate) {
        // Recorded at claim time as well as at serve time: a request that is
        // claimed and then cancelled by the app never reaches startLoading, and
        // its absence would read as "the app never asked for it".
        NSString *match = claimsTemplate ? @"api.imdbws.com/template"
                                         : (claimsApp ? @"app.imdb.com" : @"suggests");
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
    [NSURLProtocol registerClass:[IMDBServeProtocol class]];
    LogLoadContext();

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"loaded" forKey:@"event"];
    [d setObject:@"2.3-claimlog" forKey:@"build"];
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
