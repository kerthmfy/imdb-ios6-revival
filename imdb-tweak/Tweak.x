// v0.9 marker: pure C, compiled as .x (not ObjC++) so the dylib has no
// libc++ static initialisers at all. If this writes, injection works.
//
// Writes to $HOME/Documents (the app's own container), because an App Store
// sandbox may deny /var/mobile/Library/Logs — that denial is indistinguishable
// from "the tweak never loaded", which cost us a debugging round. /tmp is the
// second copy, same as Tweak.xm.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void v09_marker(void) {
    const char *home = getenv("HOME");
    char path[512];

    for (int i = 0; i < 2; i++) {
        if (i == 0) {
            if (!home) continue;
            snprintf(path, sizeof(path), "%s/Documents/imdb-capture.log", home);
        } else {
            snprintf(path, sizeof(path), "/tmp/imdb-capture.log");
        }

        FILE *f = fopen(path, "a");
        if (!f) continue;
        fprintf(f, "=== v0.9 pure-C ctor ran in pid %d (%s) ===\n", getpid(), path);
        fclose(f);
    }
}
