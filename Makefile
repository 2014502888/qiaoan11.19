ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Joolink

# Dopamine 是无根越狱，必须 rootless 打包
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = JoolinkProbe
JoolinkProbe_FILES = Tweak.xm
JoolinkProbe_CFLAGS = -fobjc-arc
JoolinkProbe_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
