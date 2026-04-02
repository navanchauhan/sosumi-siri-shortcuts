APP:=bsiri
OBJC_SRC:=src/bsiri.m
INJECTOR_SRC:=src/injector.m
BUILD:=build
INJECTOR:=bsiri_injector.dylib
INJECTOR_ARM64E:=bsiri_injector_arm64e.dylib

all: $(APP) $(INJECTOR) $(INJECTOR_ARM64E)

$(BUILD):
	mkdir -p $(BUILD)

PRIVATE_FW:=/System/Library/PrivateFrameworks
FWFLAGS:=-F $(PRIVATE_FW) -framework WorkflowKit -framework ContentKit

$(APP): $(BUILD) $(OBJC_SRC)
	clang -fobjc-arc -Wno-deprecated-declarations -o $@ $(OBJC_SRC) -framework Foundation -framework AppKit -framework Intents $(FWFLAGS) -F $(PRIVATE_FW) -framework LinkServices

$(INJECTOR): $(BUILD) $(INJECTOR_SRC)
	clang -dynamiclib -fobjc-arc -Wno-deprecated-declarations -arch arm64 -o $@ $(INJECTOR_SRC) -framework Foundation -framework AppKit -framework Intents $(FWFLAGS) -F $(PRIVATE_FW) -framework LinkServices

$(INJECTOR_ARM64E): $(BUILD) $(INJECTOR_SRC)
	clang -dynamiclib -fobjc-arc -Wno-deprecated-declarations -arch arm64e -o $@ $(INJECTOR_SRC) -framework Foundation -framework AppKit -framework Intents $(FWFLAGS)

.PHONY: clean
clean:
	rm -f $(APP) $(INJECTOR) $(INJECTOR_ARM64E) $(BUILD)/*.o
