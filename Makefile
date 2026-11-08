TARGET   := iphone:clang:latest:15.5
ARCHS    := arm64
GO_EASY_ON_ME := 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := AutoDodge
AutoDodge_FILES     := AutoDodge.mm
AutoDodge_CFLAGS    := -fobjc-arc -std=c++17 -O2
AutoDodge_FRAMEWORKS := UIKit Foundation CoreGraphics
AutoDodge_FILTER_BUNDLES := com.supercell.laser

include $(THEOS)/makefiles/tweak.mk
