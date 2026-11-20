TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

THEOS ?= $(HOME)/theos
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = IMDBCapture
IMDBCapture_FILES = Tweak.xm
IMDBCapture_FRAMEWORKS = Foundation UIKit
IMDBCapture_CFLAGS = -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 IMDb 2>/dev/null; killall -9 SpringBoard 2>/dev/null; true"
