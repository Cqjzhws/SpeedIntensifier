# theos 工程（可选）：编译 SpeedIntensifier dylib
# 云端构建走 .github/workflows/build.yml（纯 clang，不依赖 theos）
TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SpeedIntensifier
SpeedIntensifier_FILES = Tweak/Tweak.m
SpeedIntensifier_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
