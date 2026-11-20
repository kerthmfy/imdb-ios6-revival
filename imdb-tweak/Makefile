TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

THEOS ?= $(HOME)/theos
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IMDBCapture
IMDBCapture_FILES = Tweak.xm
IMDBCapture_FRAMEWORKS = Foundation UIKit
# -marm is REQUIRED, not an optimisation choice.
#
# With the modern Xcode toolchain, a plain armv7 dylib is compiled Thumb-2 but
# ld writes EVEN pointers into __DATA,__mod_init_func. iOS 6's dyld calls those
# pointers as ARM code, decodes the Thumb stream as garbage and the process dies
# with SIGILL ("Illegal instruction: 4") before main() -- which looks exactly
# like "the tweak never loaded" / "Substrate is broken". Verified 2026-11-20:
#   same source, -mthumb -> rc=132 (SIGILL), -marm -> rc=0 (ctor runs).
# Never drop this flag.
IMDBCapture_CFLAGS = -Wno-deprecated-declarations -marm

include $(THEOS_MAKE_PATH)/tweak.mk

# Never hard-kill SpringBoard on this device (boot-loop risk on a 2011 iPad).
# sbreload is graceful; SIGHUP is the fallback.
# Theos' own signing step produced an unsigned dylib here (no LC_CODE_SIGNATURE),
# and iOS 6 traps an unsigned injected dylib with SIGILL. Sign explicitly.
after-all::
	ldid -S $(THEOS_OBJ_DIR)/IMDBCapture.dylib
	otool -l $(THEOS_OBJ_DIR)/IMDBCapture.dylib | grep -q LC_CODE_SIGNATURE

after-install::
	install.exec "killall -9 IMDb 2>/dev/null; (sbreload || killall -HUP SpringBoard) >/dev/null 2>&1; true"
