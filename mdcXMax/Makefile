# mdcX Max — 本地 Theos 构建（iOS App，非 tweak）
# 用法：cd mdcXMax && make package
# 产物：.deb（Theos 打包）。若要 .ipa，把 .deb 解压后的 mdcXMax.app 放进 Payload/ 再 zip。
TARGET := iphone:clang:latest:14.0
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = mdcXMax
mdcXMax_FILES = App/main.m App/exploit.c
mdcXMax_FRAMEWORKS = UIKit Foundation CoreGraphics
mdcXMax_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
mdcXMax_CODESIGN_FLAGS = -Sentitlements.plist

# Theos 自动使用工程根目录的 Info.plist；本仓库的在 App/ 下，构建前复制过来
before-mdcXMax-stage::
	$(ECHO_NOTHING)cp $(THEOS_PROJECT_DIR)/App/Info.plist $(THEOS_PROJECT_DIR)/Info.plist$(ECHO_END)

include $(THEOS_MAKE_PATH)/application.mk
