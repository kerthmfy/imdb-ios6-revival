// v0.9 marker: pure C, compiled as .x (not ObjC++) so the dylib has no
// libc++ static initialisers at all. If this writes, injection works.
#include <stdio.h>
#include <unistd.h>

__attribute__((constructor)) static void v09_marker(void) {
    FILE *f = fopen("/var/mobile/Library/Logs/imdb-capture.log", "a");
    if (f) {
        fprintf(f, "=== v0.9 pure-C ctor ran in pid %d ===\n", getpid());
        fclose(f);
    }
}
