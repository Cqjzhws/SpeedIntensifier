TARGET := iphone:clang:14.5:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = GeraniumRootHelper

GeraniumRootHelper_FILES = $(wildcard *.m)
GeraniumRootHelper_CFLAGS = -fobjc-arc
GeraniumRootHelper_CODESIGN_FLAGS = -Sentitlements.plist
GeraniumRootHelper_INSTALL_PATH = /usr/local/bin
GeraniumRootHelper_PRIVATE_FRAMEWORKS = SpringBoardServices BackBoardServices MobileCoreServices

include $(THEOS_MAKE_PATH)/tool.mk
