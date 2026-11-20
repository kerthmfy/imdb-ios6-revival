// E5 tool (§13.4 step 3, extended per §15.2): can this iOS 6 device complete TLS to
// modern hosts with its own stack? Not the bundled OpenSSL 0.9.8 `curl`, which cannot
// do TLS 1.2 and gives a false negative. Built -marm for the §12.2 reason.
//
// §15.2 additions:
//   * the full NSError chain, plus the CFStream domain/code, so a failure says
//     whether it is a protocol problem (-9824/-9836/-9806) or a trust problem
//     (-9807/-9808/-9813) instead of a bare -1200;
//   * v3.sg.media-imdb.com, the newer suggestion endpoint, which would give live
//     search without a TLS client if iOS 6 can talk to it;
//   * which TLS tweak (if any) actually got loaded, because "no change" is
//     meaningless if DYLD_INSERT_LIBRARIES silently did nothing.
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>

static const char *NSS(NSString *s) { return s ? [s UTF8String] : "(null)"; }

// Names of the TLS-patching tweaks we care about that are mapped into this process.
static void PrintLoadedTweaks(void) {
    uint32_t total = _dyld_image_count();
    printf("tweaks:");
    int found = 0;
    for (uint32_t i = 0; i < total; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strcasestr(name, "tlsfix") || strcasestr(name, "sslpatch") ||
            strcasestr(name, "CydiaSubstrate")) {
            printf(" %s", name);
            found = 1;
        }
    }
    printf("%s\n", found ? "" : " (none)");
    fflush(stdout);
}

static void PrintError(NSError *err) {
    NSDictionary *ui = [err userInfo];
    printf("                   %s\n", NSS([err description]));
    if ([ui objectForKey:NSUnderlyingErrorKey]) {
        printf("                   underlying: %s\n",
               NSS([[ui objectForKey:NSUnderlyingErrorKey] description]));
    }
    id dom = [ui objectForKey:@"_kCFStreamErrorDomainKey"];
    id cod = [ui objectForKey:@"_kCFStreamErrorCodeKey"];
    if (dom || cod) {
        printf("                   cfstream: domain=%s code=%s\n",
               NSS([dom description]), NSS([cod description]));
    }
    printf("                   keys: %s\n", NSS([[ui allKeys] description]));
}

static void Probe(NSString *label, NSURLRequest *req) {
    NSHTTPURLResponse *resp = nil;
    NSError *err = nil;
    NSData *body = [NSURLConnection sendSynchronousRequest:req
                                         returningResponse:(NSURLResponse **)&resp
                                                     error:&err];
    if (err) {
        printf("%-18s FAIL domain=%s code=%ld %s\n", [label UTF8String],
               [[err domain] UTF8String], (long)[err code],
               [[err localizedDescription] UTF8String]);
        PrintError(err);
        fflush(stdout);
        return;
    }
    printf("%-18s HTTP %ld bytes=%lu type=%s\n", [label UTF8String],
           (long)[resp statusCode], (unsigned long)[body length],
           [[[resp allHeaderFields] objectForKey:@"Content-Type"] UTF8String] ?: "(none)");
    if ([body length] > 120) {
        NSString *s = [[[NSString alloc] initWithData:[body subdataWithRange:NSMakeRange(0,120)]
                                             encoding:NSUTF8StringEncoding] autorelease];
        printf("                   head=%s\n", [s UTF8String] ?: "(binary)");
    }
    fflush(stdout);
}

int main(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    printf("E5 start pid=%d\n", (int)getpid());
    printf("insert=%s\n", NSS(getenv("DYLD_INSERT_LIBRARIES") ? [NSString stringWithUTF8String:getenv("DYLD_INSERT_LIBRARIES")] : @"(unset)"));
    PrintLoadedTweaks();

    Probe(@"suggests", [NSURLRequest requestWithURL:
        [NSURL URLWithString:@"https://sg.media-imdb.com/suggests/t/the.json"]]);

    Probe(@"suggests-v3", [NSURLRequest requestWithURL:
        [NSURL URLWithString:@"https://v3.sg.media-imdb.com/suggestion/t/the.json"]]);

    Probe(@"poster", [NSURLRequest requestWithURL:
        [NSURL URLWithString:@"https://m.media-amazon.com/images/M/MV5BMjlhYTk3ZGQtNjdlYi00NDQyLTgxZTEtMzk0OTU5OTRhNGZhXkEyXkFqcGc@._V1._SX81_CR0,12,81,120.jpg"]]);

    NSMutableURLRequest *g = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://api.graphql.imdb.com/"]];
    [g setHTTPMethod:@"POST"];
    [g setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [g setHTTPBody:[@"{\"query\":\"{title(id:\\\"tt0133093\\\"){id titleText{text}}}\"}"
                    dataUsingEncoding:NSUTF8StringEncoding]];
    [g setTimeoutInterval:20];
    Probe(@"graphql", g);

    Probe(@"hello-tls", [NSURLRequest requestWithURL:
        [NSURL URLWithString:@"https://app.imdb.com/hello"]]);

    printf("E5 done\n");
    [pool release];
    return 0;
}
