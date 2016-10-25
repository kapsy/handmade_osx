# TODO: (Kapsy) Need a way of eventually distinguishing between separate platforms,
# either through the same Makefile, or completly different Platforms using the same
# shared Game repo.

# TODO: (Kapsy) No matter which of these optimization swiches I set, the disassembly always produces:
# 0x105ef34f2 <+18>: callq  0x105ef3570               ; symbol stub for: floorf
HANDMADE_OPTIMIZATION_SWITCHES = #-fno-builtin -O2 -ffast-math -ftrapping-math
HANDMADE_CODE_PATH = code
HANDMADE_BUILD_PATH = build
HANDMADE_ASSETS_PATH = data

HANDMADE_IGNORE_WARNING_FLAGS = -Wno-unused-function -Wno-unused-variable -Wno-missing-braces -Wno-c++11-compat-deprecated-writable-strings

OSX_DEPENDENCIES = -framework Cocoa -framework IOKit -framework CoreAudio -framework AudioToolbox

default: handmade handmade.dylib

# TODO: (Kapsy) Implement a clean command which cleans everything if it gets out of whack.
# TODO: (Kapsy) Need to be able to include Info.plist.
# rm -rf $(HANDMADE_BUILD_PATH)/Handmade.app
# NOTE: (Kapsy) Just overwriting for now, however there might be a better way to do this.
handmade:
	mkdir -p $(HANDMADE_BUILD_PATH)/Handmade.app/Contents/MacOS
	mkdir -p $(HANDMADE_BUILD_PATH)/Handmade.app/Contents/Resources
	mkdir -p $(HANDMADE_BUILD_PATH)/Handmade.app/Contents/code
	clang -g $(HANDMADE_OPTIMIZATION_SWITCHES) -Wall $(HANDMADE_IGNORE_WARNING_FLAGS) $(OSX_DEPENDENCIES) -lstdc++ -DHANDMADE_SLOW -DHANDMADE_INTERNAL $(HANDMADE_CODE_PATH)/osx_handmade.mm -o $(HANDMADE_BUILD_PATH)/Handmade.app/Contents/MacOS/$@
	rsync -a -r -v --ignore-existing $(HANDMADE_ASSETS_PATH)/* $(HANDMADE_BUILD_PATH)/Handmade.app/Contents/Resources

handmade.dylib:
	clang -g $(HANDMADE_OPTIMIZATION_SWITCHES) -Wall $(HANDMADE_IGNORE_WARNING_FLAGS) $(OSX_DEPENDENCIES) -lstdc++ -dynamiclib -DHANDMADE_SLOW -DHANDMADE_INTERNAL $(HANDMADE_CODE_PATH)/handmade.cpp -o $(HANDMADE_BUILD_PATH)/Handmade.app/Contents/MacOS/$@
