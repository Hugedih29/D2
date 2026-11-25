TARGET := iphone:clang:latest:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := roothide
INSTALL_TARGET_PROCESSES := SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := DepthLayer
DepthLayer_FILES := Tweak.xm
DepthLayer_CFLAGS := -fobjc-arc
DepthLayer_FRAMEWORKS := UIKit Foundation Vision CoreImage CoreVideo QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME := DepthLayerPrefs
DepthLayerPrefs_FILES := DLRootListController.m
DepthLayerPrefs_FRAMEWORKS := UIKit
# Preferences.framework ships on-device but has no linkable stub in this SDK.
# Settings loads it before the pane, so resolve its Objective-C classes at runtime.
DepthLayerPrefs_LDFLAGS := -undefined dynamic_lookup
DepthLayerPrefs_INSTALL_PATH := /Library/PreferenceBundles
DepthLayerPrefs_BUNDLE_RESOURCE_DIRS := Resources
DepthLayerPrefs_CFLAGS := -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp PreferenceEntry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DepthLayerPrefs.plist$(ECHO_END)
