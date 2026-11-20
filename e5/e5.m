// E5 tool (§13.4 step 3): can this iOS 6 device complete TLS to modern hosts
// with its own stack? Not the bundled OpenSSL 0.9.8 `curl`, which cannot do
// TLS 1.2 and gives a false negative. Built -marm for the §12.2 reason.
#import <Foundation/Foundation.h>
#include <stdio.h>

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
    printf("E5 start pid=%d\n", (int)getpid()); fflush(stdout);

    Probe(@"suggests", [NSURLRequest requestWithURL:
        [NSURL URLWithString:@"https://sg.media-imdb.com/suggests/t/the.json"]]);

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
