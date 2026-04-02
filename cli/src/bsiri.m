// Minimal PoC: build an ephemeral Shortcuts workflow and run it via WorkflowKit
// Note: Uses private frameworks (WorkflowKit in dyld cache). Not App Store–safe.

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Intents/Intents.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <arpa/inet.h>
#import <objc/runtime.h>
#import <objc/message.h>

@protocol WFWorkflowRunnerClientDelegate <NSObject>
@optional
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithOutput:(id)output error:(NSError *)error cancelled:(BOOL)cancelled;
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithAllResults:(id)results error:(NSError *)error cancelled:(BOOL)cancelled;
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithError:(NSError *)error cancelled:(BOOL)cancelled;
@end

static void Log(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    fprintf(stderr, "%s\n", s.UTF8String);
}

static BOOL LoadPrivateFrameworks(void) {
    NSArray<NSString *> *paths = @[
        @"/System/Library/PrivateFrameworks/WorkflowKit.framework",
        @"/System/Library/PrivateFrameworks/ContentKit.framework"
    ];
    for (NSString *path in paths) {
        NSBundle *b = [NSBundle bundleWithPath:path];
        if (!b) { Log(@"Failed to get bundle at %@", path); return NO; }
        NSError *err = nil;
        if (![b loadAndReturnError:&err]) { Log(@"Failed to load %@: %@", path, err); return NO; }
    }
    return YES;
}

static NSDictionary *Action_OpenViaShell(NSString *appName) {
    // Use the Run Shell Script action to open an app without needing WFOpenApp parameter objects.
    // Identifier likely: is.workflow.actions.runshellscript
    NSDictionary *params = @{
        @"WFScript": [NSString stringWithFormat:@"open -a \"%@\"", appName ?: @""],
        @"WFShell": @"/bin/zsh",
        @"WFShowWhenRun": @NO
    };
    return @{ @"WFWorkflowActionIdentifier": @"is.workflow.actions.runshellscript",
              @"WFWorkflowActionParameters": params };
}

static NSDictionary *Action_CreateNote(NSString *title, NSString *body) {
    // Create a note in Apple Notes. Parameter keys may vary across OS versions.
    // Common keys seen historically: WFNoteTitle, WFNoteBody, WFNotePinned
    NSMutableDictionary *params = [NSMutableDictionary new];
    if (title) params[@"WFNoteTitle"] = title;
    if (body) params[@"WFNoteBody"] = body;
    return @{ @"WFWorkflowActionIdentifier": @"is.workflow.actions.createnote",
              @"WFWorkflowActionParameters": params };
}

static id GetSharedActionRegistry(void) {
    // Try to get a shared action registry instance
    Class WFActionRegistry = NSClassFromString(@"WFActionRegistry");
    if (!WFActionRegistry) return nil;

    // Try sharedRegistry or similar class methods
    SEL sharedSel = NSSelectorFromString(@"sharedRegistry");
    if ([WFActionRegistry respondsToSelector:sharedSel]) {
        return ((id(*)(id,SEL))objc_msgSend)(WFActionRegistry, sharedSel);
    }
    // Try alloc/init
    SEL initSel = NSSelectorFromString(@"init");
    if ([WFActionRegistry instancesRespondToSelector:initSel]) {
        return ((id(*)(id,SEL))objc_msgSend)([WFActionRegistry alloc], initSel);
    }
    return nil;
}

static id NewWorkflowFromActions(NSArray<NSDictionary *> *actions) {
    Class WFWorkflow = NSClassFromString(@"WFWorkflow");
    if (!WFWorkflow) return nil;

    id wf = ((id(*)(id,SEL))objc_msgSend)([WFWorkflow alloc], NSSelectorFromString(@"init"));
    if (!wf) return nil;

    id registry = GetSharedActionRegistry();

    for (NSDictionary *ad in actions ?: @[]) {
        NSString *identifier = ad[@"WFWorkflowActionIdentifier"] ?: @"action";
        NSDictionary *params = ad[@"WFWorkflowActionParameters"] ?: @{};
        id action = nil;

        if (registry) {
            SEL createSel = NSSelectorFromString(@"createActionWithIdentifier:serializedParameters:");
            if ([registry respondsToSelector:createSel]) {
                @try { action = ((id(*)(id,SEL,id,id))objc_msgSend)(registry, createSel, identifier, params); } @catch (NSException *e) {}
            }
        }
        if (!action) {
            Class WFAction = NSClassFromString(@"WFAction");
            SEL initSel = NSSelectorFromString(@"initWithDictionary:");
            if (WFAction && [WFAction instancesRespondToSelector:initSel]) {
                @try { action = ((id(*)(id,SEL,id))objc_msgSend)([WFAction alloc], initSel, ad); } @catch (NSException *e) {}
            }
        }
        if (action) {
            @try { ((void(*)(id,SEL,id))objc_msgSend)(wf, NSSelectorFromString(@"addAction:"), action); } @catch (NSException *e) {}
        }
    }

    NSArray *wfActions = ((id(*)(id,SEL))objc_msgSend)(wf, NSSelectorFromString(@"actions"));
    return wfActions.count > 0 ? wf : nil;
}

static id NewRunDescriptorForWorkflow(id wf) {
    id desc = nil;

    // Try WFWorkflowDataRunDescriptor
    Class WFWorkflowDataRunDescriptor = NSClassFromString(@"WFWorkflowDataRunDescriptor");
    if (WFWorkflowDataRunDescriptor) {
        SEL generateSel = NSSelectorFromString(@"generateStandaloneShortcutRepresentation:");
        if ([wf respondsToSelector:generateSel]) {
            NSError *err = nil; NSData *wfData = nil;
            @try { wfData = ((id(*)(id,SEL,id*))objc_msgSend)(wf, generateSel, &err); } @catch (NSException *e) {}
            if (wfData) {
                SEL initSel = NSSelectorFromString(@"initWithWorkflowData:");
                if ([WFWorkflowDataRunDescriptor instancesRespondToSelector:initSel]) {
                    @try { desc = ((id(*)(id,SEL,id))objc_msgSend)([WFWorkflowDataRunDescriptor alloc], initSel, wfData); } @catch (NSException *e) {}
                    if (desc) return desc;
                }
            }
        }
    }

    // Try WFINShortcutRunDescriptor
    Class WFINShortcutRunDescriptor = NSClassFromString(@"WFINShortcutRunDescriptor");
    Class INShortcutC = NSClassFromString(@"INShortcut");
    if (WFINShortcutRunDescriptor && INShortcutC) {
        SEL initWithWorkflowSel = NSSelectorFromString(@"initWithWorkflow:");
        id shortcut = nil;
        if ([INShortcutC instancesRespondToSelector:initWithWorkflowSel]) {
            @try { shortcut = ((id(*)(id,SEL,id))objc_msgSend)([INShortcutC alloc], initWithWorkflowSel, wf); } @catch (NSException *e) {}
        }
        if (shortcut) {
            SEL initDescSel = NSSelectorFromString(@"initWithShortcut:");
            if ([WFINShortcutRunDescriptor instancesRespondToSelector:initDescSel]) {
                @try { desc = ((id(*)(id,SEL,id))objc_msgSend)([WFINShortcutRunDescriptor alloc], initDescSel, shortcut); } @catch (NSException *e) {}
                if (desc) return desc;
            }
        }
    }

    return nil;
}

static id NewRunRequest(void) {
    Class WFWorkflowRunRequest = NSClassFromString(@"WFWorkflowRunRequest");
    if (!WFWorkflowRunRequest) { Log(@"WFWorkflowRunRequest class not found"); return nil; }
    id req = nil;
    SEL sel = NSSelectorFromString(@"initWithInput:presentationMode:");
    if ([WFWorkflowRunRequest instancesRespondToSelector:sel]) {
        // input:nil, presentationMode:0 (Default/Background)
        req = ((id(*)(id,SEL,id,NSInteger))objc_msgSend)([WFWorkflowRunRequest alloc], sel, nil, 0);
    } else {
        sel = NSSelectorFromString(@"init");
        if ([WFWorkflowRunRequest instancesRespondToSelector:sel]) {
            req = ((id(*)(id,SEL))objc_msgSend)([WFWorkflowRunRequest alloc], sel);
        }
    }
    if (!req) Log(@"Failed to construct WFWorkflowRunRequest");
    return req;
}

@interface WFWorkflowRunnerCapture : NSObject <WFWorkflowRunnerClientDelegate>
@property (atomic, strong) id output;
@property (atomic, strong) id allResults;
@property (atomic, strong) NSError *error;
@property (atomic, assign) BOOL cancelled;
@property (atomic, assign) BOOL finished;
@end

@implementation WFWorkflowRunnerCapture
- (void)markFinishedWithError:(NSError *)error cancelled:(BOOL)cancelled {
    self.error = error;
    self.cancelled = cancelled;
    self.finished = YES;
}
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithOutput:(id)output error:(NSError *)error cancelled:(BOOL)cancelled {
    self.output = output;
    [self markFinishedWithError:error cancelled:cancelled];
}
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithAllResults:(id)results error:(NSError *)error cancelled:(BOOL)cancelled {
    self.allResults = results;
    [self markFinishedWithError:error cancelled:cancelled];
}
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithError:(NSError *)error cancelled:(BOOL)cancelled {
    [self markFinishedWithError:error cancelled:cancelled];
}
@end

static BOOL RunWorkflowDirect(id wf, NSTimeInterval timeoutSeconds, id *outputOut, NSArray **allResultsOut);

static BOOL RunWorkflowInternal(id desc, id req, NSTimeInterval timeoutSeconds, id *outputOut, NSArray **allResultsOut) {
    Class WFWorkflowRunnerClient = NSClassFromString(@"WFWorkflowRunnerClient");
    if (!WFWorkflowRunnerClient) { Log(@"WFWorkflowRunnerClient class not found"); return NO; }
    SEL initSel = NSSelectorFromString(@"initWithDescriptor:runRequest:");
    id runner = nil;
    if ([WFWorkflowRunnerClient instancesRespondToSelector:initSel]) {
        runner = ((id(*)(id,SEL,id,id))objc_msgSend)([WFWorkflowRunnerClient alloc], initSel, desc, req);
    } else {
        // Try 3-arg initializer with delegateQueue if available
        initSel = NSSelectorFromString(@"initWithDescriptor:runRequest:delegateQueue:");
        if ([WFWorkflowRunnerClient instancesRespondToSelector:initSel]) {
            runner = ((id(*)(id,SEL,id,id,id))objc_msgSend)([WFWorkflowRunnerClient alloc], initSel, desc, req, nil);
        }
    }
    if (!runner) { Log(@"Failed to construct WFWorkflowRunnerClient"); return NO; }

    WFWorkflowRunnerCapture *capture = [WFWorkflowRunnerCapture new];
    SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
    if ([runner respondsToSelector:setDelegateSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(runner, setDelegateSel, capture);
    }
    // Ensure delegate callbacks happen on main thread
    SEL setDelegateQueueSel = NSSelectorFromString(@"setDelegateQueue:");
    if ([runner respondsToSelector:setDelegateQueueSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(runner, setDelegateQueueSel, dispatch_get_main_queue());
    }

    // Start run
    SEL startSel = NSSelectorFromString(@"start");
    if (![runner respondsToSelector:startSel]) { Log(@"Runner has no start"); return NO; }
    ((void(*)(id,SEL))objc_msgSend)(runner, startSel);

    // Spin runloop for a short window to let actions execute.
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds > 0 ? timeoutSeconds : 5.0];
    while ([until timeIntervalSinceNow] > 0 && !capture.finished) {
        @autoreleasepool { [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; }
    }
    if (!capture.finished) {
        Log(@"Workflow runner timed out before finishing");
        return NO;
    }
    if (outputOut) *outputOut = capture.output;
    if (allResultsOut) *allResultsOut = capture.allResults;
    if (capture.error) {
        Log(@"Workflow run error: %@", capture.error);
        return NO;
    }
    if (capture.cancelled) {
        Log(@"Workflow run cancelled");
        return NO;
    }
    return YES;
}

static BOOL RunWorkflow(id desc, id req, NSTimeInterval timeoutSeconds) {
    return RunWorkflowInternal(desc, req, timeoutSeconds, NULL, NULL);
}

static BOOL RunWorkflowCapture(id desc, id req, NSTimeInterval timeoutSeconds, id *outputOut, NSArray **allResultsOut) {
    return RunWorkflowInternal(desc, req, timeoutSeconds, outputOut, allResultsOut);
}

// Alternative: Run workflow directly via WFWorkflowController
@protocol WFWorkflowControllerDelegate <NSObject>
@optional
- (void)workflowController:(id)controller didFinishRunningWithError:(NSError *)error cancelled:(BOOL)cancelled;
- (void)workflowController:(id)controller didRunAction:(id)action error:(NSError *)error withCompletion:(void (^)(void))completion;
- (void)workflowController:(id)controller prepareToRunAction:(id)action withInput:(id)input completionHandler:(void (^)(void))handler;
@end

@interface WFWorkflowControllerCapture : NSObject <WFWorkflowControllerDelegate>
@property (atomic, strong) id output;
@property (atomic, strong) NSError *error;
@property (atomic, assign) BOOL cancelled;
@property (atomic, assign) BOOL finished;
@end

@implementation WFWorkflowControllerCapture
- (void)workflowController:(id)controller didFinishRunningWithError:(NSError *)error cancelled:(BOOL)cancelled {
    self.error = error;
    self.cancelled = cancelled;
    self.finished = YES;
    // Try to get output
    SEL outputSel = NSSelectorFromString(@"output");
    if ([controller respondsToSelector:outputSel]) {
        self.output = ((id(*)(id,SEL))objc_msgSend)(controller, outputSel);
    }
}
- (void)workflowController:(id)controller didRunAction:(id)action error:(NSError *)error withCompletion:(void (^)(void))completion {
    if (completion) completion();
}
- (void)workflowController:(id)controller prepareToRunAction:(id)action withInput:(id)input completionHandler:(void (^)(void))handler {
    if (handler) handler();
}
@end

static BOOL RunWorkflowDirect(id wf, NSTimeInterval timeoutSeconds, id *outputOut, NSArray **allResultsOut) {
    // Try WFShortcutsAppRunnerClient with workflow data
    Class WFShortcutsAppRunnerClient = NSClassFromString(@"WFShortcutsAppRunnerClient");
    if (WFShortcutsAppRunnerClient) {
        Log(@"Trying WFShortcutsAppRunnerClient...");
        SEL initSel = NSSelectorFromString(@"initWithWorkflowData:runSource:");
        if ([WFShortcutsAppRunnerClient instancesRespondToSelector:initSel]) {
            // Serialize workflow to data
            SEL generateSel = NSSelectorFromString(@"generateShortcutRepresentation:");
            NSData *wfData = nil;
            if ([wf respondsToSelector:generateSel]) {
                NSError *err = nil;
                @try {
                    wfData = ((id(*)(id,SEL,id*))objc_msgSend)(wf, generateSel, &err);
                } @catch (NSException *e) {
                    Log(@"Exception serializing workflow (generateShortcutRepresentation): %@", e);
                }
                if (err) Log(@"Error serializing workflow: %@", err);
            }
            // Fallback to generateStandaloneShortcutRepresentation
            if (!wfData) {
                generateSel = NSSelectorFromString(@"generateStandaloneShortcutRepresentation:");
                if ([wf respondsToSelector:generateSel]) {
                    NSError *err = nil;
                    @try {
                        wfData = ((id(*)(id,SEL,id*))objc_msgSend)(wf, generateSel, &err);
                    } @catch (NSException *e) {
                        Log(@"Exception serializing workflow (standalone): %@", e);
                    }
                    if (err) Log(@"Error serializing standalone: %@", err);
                }
            }
            if (wfData && wfData.length > 0) {
                Log(@"Serialized workflow to %lu bytes", (unsigned long)wfData.length);
                id runner = nil;
                @try {
                    runner = ((id(*)(id,SEL,id,id))objc_msgSend)([WFShortcutsAppRunnerClient alloc], initSel, wfData, @0);
                } @catch (NSException *e) {
                    Log(@"Exception creating WFShortcutsAppRunnerClient: %@", e);
                }
                if (runner) {
                    Log(@"Created WFShortcutsAppRunnerClient: %@", runner);
                    WFWorkflowRunnerCapture *capture = [WFWorkflowRunnerCapture new];
                    SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
                    if ([runner respondsToSelector:setDelegateSel]) {
                        ((void(*)(id,SEL,id))objc_msgSend)(runner, setDelegateSel, capture);
                    }
                    SEL startSel = NSSelectorFromString(@"start");
                    if ([runner respondsToSelector:startSel]) {
                        Log(@"Starting WFShortcutsAppRunnerClient...");
                        @try {
                            ((void(*)(id,SEL))objc_msgSend)(runner, startSel);
                        } @catch (NSException *e) {
                            Log(@"Exception starting runner: %@", e);
                        }
                        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds > 0 ? timeoutSeconds : 15.0];
                        while ([until timeIntervalSinceNow] > 0 && !capture.finished) {
                            @autoreleasepool { [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; }
                        }
                        if (capture.finished) {
                            Log(@"WFShortcutsAppRunnerClient: finished, error=%@, cancelled=%d", capture.error, capture.cancelled);
                            if (outputOut) *outputOut = capture.output;
                            return capture.error == nil && !capture.cancelled;
                        }
                        Log(@"WFShortcutsAppRunnerClient timed out");
                    }
                }
            }
        }
    }

    // Try WFWorkflowController as fallback
    Class WFWorkflowController = NSClassFromString(@"WFWorkflowController");
    if (!WFWorkflowController) { Log(@"WFWorkflowController class not found"); return NO; }

    Log(@"Trying WFWorkflowController...");
    id controller = ((id(*)(id,SEL))objc_msgSend)([WFWorkflowController alloc], NSSelectorFromString(@"init"));
    if (!controller) { Log(@"Failed to create WFWorkflowController"); return NO; }

    SEL setWorkflowSel = NSSelectorFromString(@"setWorkflow:");
    if (![controller respondsToSelector:setWorkflowSel]) { Log(@"WFWorkflowController has no setWorkflow:"); return NO; }
    @try {
        ((void(*)(id,SEL,id))objc_msgSend)(controller, setWorkflowSel, wf);
    } @catch (NSException *e) {
        Log(@"Exception setting workflow: %@", e);
        return NO;
    }

    WFWorkflowControllerCapture *capture = [WFWorkflowControllerCapture new];
    SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
    if ([controller respondsToSelector:setDelegateSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(controller, setDelegateSel, capture);
    }

    SEL runSel = NSSelectorFromString(@"run");
    if (![controller respondsToSelector:runSel]) { Log(@"WFWorkflowController has no run"); return NO; }
    @try {
        ((void(*)(id,SEL))objc_msgSend)(controller, runSel);
    } @catch (NSException *e) {
        Log(@"Exception running workflow: %@", e);
        return NO;
    }

    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds > 0 ? timeoutSeconds : 15.0];
    while ([until timeIntervalSinceNow] > 0 && !capture.finished) {
        @autoreleasepool { [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; }
    }

    if (!capture.finished) { Log(@"WFWorkflowController timed out"); return NO; }
    if (capture.error) { Log(@"WFWorkflowController error: %@", capture.error); return NO; }
    if (capture.cancelled) { Log(@"WFWorkflowController cancelled"); return NO; }
    if (outputOut) *outputOut = capture.output;
    return YES;
}

static NSDictionary *AppIntentActionDictionary(NSString *bundleID, NSString *intentIdentifier, NSString *displayName, NSDictionary *parameters) {
    if (!bundleID || !intentIdentifier) return nil;
    NSMutableDictionary *descriptor = [NSMutableDictionary new];
    descriptor[@"AppIntentIdentifier"] = intentIdentifier;
    descriptor[@"BundleIdentifier"] = bundleID;
    // Name is required - use app name from bundle ID if not provided
    if (displayName.length > 0) {
        descriptor[@"Name"] = displayName;
    } else {
        // Extract app name from bundle ID (e.g., "com.mitchellh.ghostty" -> "ghostty")
        NSArray *parts = [bundleID componentsSeparatedByString:@"."];
        descriptor[@"Name"] = [parts lastObject] ?: bundleID;
    }

    NSMutableDictionary *actionParams = [NSMutableDictionary new];
    actionParams[@"AppIntentDescriptor"] = descriptor;
    if (parameters.count > 0) {
        [actionParams addEntriesFromDictionary:parameters];
    }
    actionParams[@"UUID"] = [[NSUUID UUID] UUIDString];

    NSString *fqIdentifier = [NSString stringWithFormat:@"%@.%@", bundleID, intentIdentifier];
    return @{
        @"WFWorkflowActionIdentifier": fqIdentifier,
        @"WFWorkflowActionParameters": actionParams
    };
}

static NSData *BuildShortcutPlistData(NSArray<NSDictionary *> *actions) {
    NSDictionary *plist = @{
        @"WFWorkflowClientVersion": @"700",
        @"WFWorkflowClientRelease": @"2.0",
        @"WFWorkflowMinimumClientVersion": @900,
        @"WFWorkflowMinimumClientVersionString": @"900",
        @"WFWorkflowActions": actions ?: @[],
        @"WFWorkflowTypes": @[@"NCWidget", @"WatchKit"],
        @"WFWorkflowInputContentItemClasses": @[
            @"WFAppStoreAppContentItem",
            @"WFArticleContentItem",
            @"WFContactContentItem",
            @"WFDateContentItem",
            @"WFEmailAddressContentItem",
            @"WFGenericFileContentItem",
            @"WFImageContentItem",
            @"WFiTunesProductContentItem",
            @"WFLocationContentItem",
            @"WFDCMapsLinkContentItem",
            @"WFAVAssetContentItem",
            @"WFPDFContentItem",
            @"WFPhoneNumberContentItem",
            @"WFRichTextContentItem",
            @"WFSafariWebPageContentItem",
            @"WFStringContentItem",
            @"WFURLContentItem"
        ],
        @"WFWorkflowImportQuestions": @[],
        @"WFWorkflowIcon": @{
            @"WFWorkflowIconGlyphNumber": @59511,
            @"WFWorkflowIconImageData": [NSData data],
            @"WFWorkflowIconStartColor": @431817727
        }
    };
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];
    if (err) { Log(@"Error serializing plist: %@", err); }
    // Debug: dump the plist
    Log(@"Shortcut plist: %@", plist);
    return data;
}

// Get a properly configured WFLinkAction from WFAppIntentsMetadataProvider
static id GetLinkActionFromMetadataProvider(NSString *bundleID, NSString *intentID, NSDictionary *params) {
    Class WFAppIntentsMetadataProvider = NSClassFromString(@"WFAppIntentsMetadataProvider");
    if (!WFAppIntentsMetadataProvider) {
        Log(@"WFAppIntentsMetadataProvider not found");
        return nil;
    }

    // Get shared instance
    SEL sharedSel = NSSelectorFromString(@"sharedProvider");
    if (![WFAppIntentsMetadataProvider respondsToSelector:sharedSel]) {
        Log(@"sharedProvider selector not found");
        return nil;
    }
    id provider = ((id(*)(id,SEL))objc_msgSend)(WFAppIntentsMetadataProvider, sharedSel);
    if (!provider) {
        Log(@"sharedProvider returned nil");
        return nil;
    }
    Log(@"Got metadata provider: %@", provider);

    // Get action
    SEL actionSel = NSSelectorFromString(@"actionWithIdentifier:fromBundleIdentifier:");
    if (![provider respondsToSelector:actionSel]) {
        Log(@"actionWithIdentifier:fromBundleIdentifier: not found");
        return nil;
    }

    Log(@"Fetching action metadata: %@ from %@", intentID, bundleID);
    id metadata = ((id(*)(id,SEL,id,id))objc_msgSend)(provider, actionSel, intentID, bundleID);
    Log(@"Got action metadata: %@ (class: %@)", metadata, metadata ? NSStringFromClass([metadata class]) : @"nil");

    if (!metadata) return nil;

    // Build the fully qualified identifier
    NSString *fqid = [NSString stringWithFormat:@"%@.%@", bundleID, intentID];

    // Try to create a WFLinkAction using providedActionWithIdentifier:serializedParameters:
    Class WFLinkAction = NSClassFromString(@"WFLinkAction");
    if (WFLinkAction) {
        SEL createSel = NSSelectorFromString(@"providedActionWithIdentifier:serializedParameters:");
        if ([WFLinkAction respondsToSelector:createSel]) {
            Log(@"Creating WFLinkAction via providedActionWithIdentifier:serializedParameters:");
            NSMutableDictionary *serialized = [NSMutableDictionary new];
            serialized[@"AppIntentDescriptor"] = @{
                @"AppIntentIdentifier": intentID,
                @"BundleIdentifier": bundleID,
                @"Name": [bundleID componentsSeparatedByString:@"."].lastObject ?: bundleID
            };
            if (params.count > 0) {
                [serialized addEntriesFromDictionary:params];
            }
            id linkAction = ((id(*)(id,SEL,id,id))objc_msgSend)(WFLinkAction, createSel, fqid, serialized);
            Log(@"WFLinkAction from providedActionWithIdentifier: %@", linkAction);
            if (linkAction) return linkAction;
        }

        // Fallback: try initWithIdentifier:metadata:definition:serializedParameters:appIntentDescriptor:fullyQualifiedActionIdentifier:
        SEL initSel = NSSelectorFromString(@"initWithIdentifier:metadata:definition:serializedParameters:appIntentDescriptor:fullyQualifiedActionIdentifier:");
        if ([WFLinkAction instancesRespondToSelector:initSel]) {
            Log(@"Creating WFLinkAction via full init...");
            NSDictionary *descriptor = @{
                @"AppIntentIdentifier": intentID,
                @"BundleIdentifier": bundleID,
            };
            NSMutableDictionary *serialized = [NSMutableDictionary new];
            if (params.count > 0) {
                [serialized addEntriesFromDictionary:params];
            }
            id linkAction = ((id(*)(id,SEL,id,id,id,id,id,id))objc_msgSend)(
                [WFLinkAction alloc], initSel,
                intentID,      // identifier
                metadata,      // metadata
                nil,           // definition
                serialized,    // serializedParameters
                descriptor,    // appIntentDescriptor
                fqid           // fullyQualifiedActionIdentifier
            );
            Log(@"WFLinkAction from full init: %@", linkAction);
            if (linkAction) return linkAction;
        }
    }

    // If we can't create a WFLinkAction, return the metadata for potential use
    return metadata;
}

// Run via WFLinkActionRunDescriptor -> WFWorkflowRunnerClient
static BOOL RunLinkActionViaDescriptor(id linkAction, NSString *bundleID, NSString *intentID, NSTimeInterval timeout, id *outputOut) {
    Class WFLinkActionRunDescriptor = NSClassFromString(@"WFLinkActionRunDescriptor");
    if (!WFLinkActionRunDescriptor) return NO;

    // initWithIdentifier:action:metadata:
    SEL initSel = NSSelectorFromString(@"initWithIdentifier:action:metadata:");
    if (![WFLinkActionRunDescriptor instancesRespondToSelector:initSel]) return NO;

    NSString *fqid = [NSString stringWithFormat:@"%@.%@", bundleID, intentID];
    id descriptor = nil;
    @try {
        descriptor = ((id(*)(id,SEL,id,id,id))objc_msgSend)([WFLinkActionRunDescriptor alloc], initSel, fqid, linkAction, nil);
    } @catch (NSException *e) {
        Log(@"Exception creating WFLinkActionRunDescriptor: %@", e);
        return NO;
    }
    if (!descriptor) return NO;
    Log(@"Created WFLinkActionRunDescriptor: %@", descriptor);

    id req = NewRunRequest();
    if (!req) return NO;

    return RunWorkflowCapture(descriptor, req, timeout, outputOut, NULL);
}

// Run via WFLinkActionWorkflowRunnerClient
static BOOL RunLinkAction(id linkAction, NSString *bundleID, NSString *intentID, NSTimeInterval timeout, id *outputOut) {
    // Try WFLinkActionRunDescriptor first
    if (RunLinkActionViaDescriptor(linkAction, bundleID, intentID, timeout, outputOut)) {
        return YES;
    }

    Class WFLinkActionWorkflowRunnerClient = NSClassFromString(@"WFLinkActionWorkflowRunnerClient");
    if (!WFLinkActionWorkflowRunnerClient) return NO;

    SEL initSel = NSSelectorFromString(@"initWithLinkAction:bundleIdentifier:runSource:");
    if (![WFLinkActionWorkflowRunnerClient instancesRespondToSelector:initSel]) return NO;

    id runner = nil;
    @try {
        runner = ((id(*)(id,SEL,id,id,id))objc_msgSend)([WFLinkActionWorkflowRunnerClient alloc], initSel, linkAction, bundleID, @0);
    } @catch (NSException *e) {
        Log(@"Exception creating WFLinkActionWorkflowRunnerClient: %@", e);
        return NO;
    }
    if (!runner) return NO;
    Log(@"Created WFLinkActionWorkflowRunnerClient: %@", runner);

    WFWorkflowRunnerCapture *capture = [WFWorkflowRunnerCapture new];
    SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
    if ([runner respondsToSelector:setDelegateSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(runner, setDelegateSel, capture);
    }

    SEL startSel = NSSelectorFromString(@"start");
    if ([runner respondsToSelector:startSel]) {
        Log(@"Starting WFLinkActionWorkflowRunnerClient...");
        @try {
            ((void(*)(id,SEL))objc_msgSend)(runner, startSel);
        } @catch (NSException *e) {
            Log(@"Exception starting runner: %@", e);
            return NO;
        }

        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout > 0 ? timeout : 30.0];
        while ([until timeIntervalSinceNow] > 0 && !capture.finished) {
            @autoreleasepool { [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; }
        }

        if (capture.finished) {
            Log(@"WFLinkActionWorkflowRunnerClient: finished, error=%@, cancelled=%d", capture.error, capture.cancelled);
            if (outputOut) *outputOut = capture.output;
            return capture.error == nil && !capture.cancelled;
        }
        Log(@"WFLinkActionWorkflowRunnerClient timed out");
    }
    return NO;
}

static BOOL RunAppIntentActions(NSArray<NSDictionary *> *actions, NSTimeInterval timeoutSeconds, id *outputOut, NSArray **allResultsOut) {
    if (!LoadPrivateFrameworks()) return NO;

    // For single actions, try WFLinkActionWorkflowRunnerClient with properly loaded action
    if (actions.count == 1) {
        NSDictionary *actionDict = actions[0];
        NSDictionary *descriptor = actionDict[@"WFWorkflowActionParameters"][@"AppIntentDescriptor"];
        NSString *bundleID = descriptor[@"BundleIdentifier"];
        NSString *intentID = descriptor[@"AppIntentIdentifier"];
        NSDictionary *params = actionDict[@"WFWorkflowActionParameters"];

        if (bundleID && intentID) {
            id linkAction = GetLinkActionFromMetadataProvider(bundleID, intentID, params);
            if (linkAction) {
                BOOL ok = RunLinkAction(linkAction, bundleID, intentID, timeoutSeconds, outputOut);
                if (ok) return YES;
                Log(@"WFLinkActionWorkflowRunnerClient failed, falling back to plist approach...");
            }
        }
    }

    // Fallback: WFShortcutsAppRunnerClient with manually built plist data
    Class WFShortcutsAppRunnerClient = NSClassFromString(@"WFShortcutsAppRunnerClient");
    if (WFShortcutsAppRunnerClient) {
        SEL initSel = NSSelectorFromString(@"initWithWorkflowData:runSource:");
        if ([WFShortcutsAppRunnerClient instancesRespondToSelector:initSel]) {
            NSData *wfData = BuildShortcutPlistData(actions);
            if (wfData && wfData.length > 0) {
                Log(@"Built shortcut plist data: %lu bytes", (unsigned long)wfData.length);
                id runner = nil;
                @try {
                    runner = ((id(*)(id,SEL,id,id))objc_msgSend)([WFShortcutsAppRunnerClient alloc], initSel, wfData, @0);
                } @catch (NSException *e) {
                    Log(@"Exception creating WFShortcutsAppRunnerClient: %@", e);
                }
                if (runner) {
                    Log(@"Created WFShortcutsAppRunnerClient: %@", runner);
                    WFWorkflowRunnerCapture *capture = [WFWorkflowRunnerCapture new];
                    SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
                    if ([runner respondsToSelector:setDelegateSel]) {
                        ((void(*)(id,SEL,id))objc_msgSend)(runner, setDelegateSel, capture);
                    }
                    SEL startSel = NSSelectorFromString(@"start");
                    if ([runner respondsToSelector:startSel]) {
                        Log(@"Starting WFShortcutsAppRunnerClient...");
                        @try {
                            ((void(*)(id,SEL))objc_msgSend)(runner, startSel);
                        } @catch (NSException *e) {
                            Log(@"Exception starting runner: %@", e);
                        }
                        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds > 0 ? timeoutSeconds : 30.0];
                        while ([until timeIntervalSinceNow] > 0 && !capture.finished) {
                            @autoreleasepool { [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; }
                        }
                        if (capture.finished) {
                            Log(@"WFShortcutsAppRunnerClient: finished, error=%@, cancelled=%d", capture.error, capture.cancelled);
                            if (outputOut) *outputOut = capture.output ?: capture.allResults;
                            return capture.error == nil && !capture.cancelled;
                        }
                        Log(@"WFShortcutsAppRunnerClient timed out");
                    }
                }
            }
        }
    }

    return NO;
}

static BOOL RunAppIntentAction(NSString *bundleID, NSString *intentIdentifier, NSString *displayName, NSDictionary *parameters, NSTimeInterval timeoutSeconds, id *outputOut) {
    NSDictionary *action = AppIntentActionDictionary(bundleID, intentIdentifier, displayName, parameters);
    if (!action) { Log(@"Failed to create App Intent action dictionary for %@.%@", bundleID, intentIdentifier); return NO; }
    return RunAppIntentActions(@[action], timeoutSeconds, outputOut, NULL);
}

static void CreateNoteWithBody(NSString *title, NSString *body);
static NSString *PickRandomTailscaleIPv4FromStatusJSON(NSData *jsonData);

static BOOL RunNotesCreateNoteIntent(NSString *title, NSString *body) {
    NSMutableDictionary *params = [NSMutableDictionary new];
    if (title) params[@"title"] = title;
    if (body) params[@"body"] = body;
    if (RunAppIntentAction(@"com.apple.Notes", @"CreateNoteIntent", @"Create Note", params, 10.0, NULL)) {
        return YES;
    }
    Log(@"Unable to construct Notes CreateNoteIntent action via private APIs; falling back to AppleScript");
    CreateNoteWithBody(title ?: @"", body ?: @"");
    return YES;
}

static BOOL RunTailscaleGetStatusIntent(id *outputOut) {
    return RunAppIntentAction(@"com.tailscale.ipn.macos", @"GetStatusIntent", @"Get Status", nil, 15.0, outputOut);
}

static id WFJSONObjectFromAppIntentObject(id obj);

static NSArray<NSString *> *CollectIPv4StringsFromObject(id obj) {
    NSMutableArray<NSString *> *results = [NSMutableArray new];
    NSMutableArray *stack = [NSMutableArray array];
    if (obj) [stack addObject:obj];
    NSCharacterSet *dotSet = [NSCharacterSet characterSetWithCharactersInString:@"."];

    while (stack.count > 0) {
        id current = [stack lastObject];
        [stack removeLastObject];
        if (!current || current == [NSNull null]) continue;
        if ([current isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)current;
            if ([s rangeOfCharacterFromSet:dotSet].location != NSNotFound) {
                struct in_addr addr;
                if (inet_pton(AF_INET, s.UTF8String, &addr) == 1) {
                    [results addObject:s];
                }
            }
            continue;
        }
        if ([current isKindOfClass:[NSNumber class]]) continue;
        if ([current isKindOfClass:[NSDictionary class]]) {
            for (id value in [(NSDictionary *)current allValues]) {
                if (value) [stack addObject:value];
            }
            continue;
        }
        if ([current isKindOfClass:[NSArray class]]) {
            for (id value in (NSArray *)current) {
                if (value) [stack addObject:value];
            }
            continue;
        }
        // Try to obtain serialized representation
        SEL wfSel = NSSelectorFromString(@"wfSerializedRepresentation");
        if ([current respondsToSelector:wfSel]) {
            id rep = ((id(*)(id,SEL))objc_msgSend)(current, wfSel);
            if (rep) { [stack addObject:rep]; continue; }
        }
        SEL dictSel = NSSelectorFromString(@"dictionaryRepresentation");
        if ([current respondsToSelector:dictSel]) {
            id rep = ((id(*)(id,SEL))objc_msgSend)(current, dictSel);
            if (rep) { [stack addObject:rep]; continue; }
        }
        SEL jsonSel = NSSelectorFromString(@"jsonObject");
        if ([current respondsToSelector:jsonSel]) {
            id rep = ((id(*)(id,SEL))objc_msgSend)(current, jsonSel);
            if (rep) { [stack addObject:rep]; continue; }
        }
        SEL valueSel = NSSelectorFromString(@"value");
        if ([current respondsToSelector:valueSel]) {
            id rep = ((id(*)(id,SEL))objc_msgSend)(current, valueSel);
            if (rep) { [stack addObject:rep]; continue; }
        }
        SEL itemSel = NSSelectorFromString(@"item");
        if ([current respondsToSelector:itemSel]) {
            id rep = ((id(*)(id,SEL))objc_msgSend)(current, itemSel);
            if (rep) { [stack addObject:rep]; continue; }
        }
        SEL allObjectsSel = NSSelectorFromString(@"allObjects");
        if ([current respondsToSelector:allObjectsSel]) {
            id rep = ((id(*)(id,SEL))objc_msgSend)(current, allObjectsSel);
            if (rep) { [stack addObject:rep]; continue; }
        }
        SEL contentSel = NSSelectorFromString(@"content");
        if ([current respondsToSelector:contentSel]) {
            id rep = ((id(*)(id,SEL))objc_msgSend)(current, contentSel);
            if (rep) { [stack addObject:rep]; continue; }
        }
    }
    return results;
}

static id WFJSONObjectFromAppIntentObject(id obj) {
    if (!obj || obj == [NSNull null]) return nil;
    if ([obj isKindOfClass:[NSDictionary class]] ||
        [obj isKindOfClass:[NSArray class]] ||
        [obj isKindOfClass:[NSString class]] ||
        [obj isKindOfClass:[NSNumber class]]) {
        return obj;
    }
    if ([obj isKindOfClass:[NSData class]]) {
        NSError *err = nil;
        id json = [NSJSONSerialization JSONObjectWithData:obj options:0 error:&err];
        if (json) return json;
        return nil;
    }
    SEL wfSel = NSSelectorFromString(@"wfSerializedRepresentation");
    if ([obj respondsToSelector:wfSel]) {
        id rep = ((id(*)(id,SEL))objc_msgSend)(obj, wfSel);
        if (rep) return WFJSONObjectFromAppIntentObject(rep);
    }
    SEL dictSel = NSSelectorFromString(@"dictionaryRepresentation");
    if ([obj respondsToSelector:dictSel]) {
        id rep = ((id(*)(id,SEL))objc_msgSend)(obj, dictSel);
        if (rep) return WFJSONObjectFromAppIntentObject(rep);
    }
    SEL jsonSel = NSSelectorFromString(@"jsonObject");
    if ([obj respondsToSelector:jsonSel]) {
        id rep = ((id(*)(id,SEL))objc_msgSend)(obj, jsonSel);
        if (rep) return WFJSONObjectFromAppIntentObject(rep);
    }
    SEL valueSel = NSSelectorFromString(@"value");
    if ([obj respondsToSelector:valueSel]) {
        id rep = ((id(*)(id,SEL))objc_msgSend)(obj, valueSel);
        if (rep) return WFJSONObjectFromAppIntentObject(rep);
    }
    SEL itemSel = NSSelectorFromString(@"item");
    if ([obj respondsToSelector:itemSel]) {
        id rep = ((id(*)(id,SEL))objc_msgSend)(obj, itemSel);
        if (rep) return WFJSONObjectFromAppIntentObject(rep);
    }
    SEL contentSel = NSSelectorFromString(@"content");
    if ([obj respondsToSelector:contentSel]) {
        id rep = ((id(*)(id,SEL))objc_msgSend)(obj, contentSel);
        if (rep) return WFJSONObjectFromAppIntentObject(rep);
    }
    SEL allObjectsSel = NSSelectorFromString(@"allObjects");
    if ([obj respondsToSelector:allObjectsSel]) {
        id rep = ((id(*)(id,SEL))objc_msgSend)(obj, allObjectsSel);
        if (rep) return WFJSONObjectFromAppIntentObject(rep);
    }
    if ([obj respondsToSelector:@selector(count)] && [obj respondsToSelector:@selector(objectAtIndex:)]) {
        NSUInteger count = ((NSUInteger (*)(id,SEL))objc_msgSend)(obj, @selector(count));
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger idx = 0; idx < count; idx++) {
            id element = ((id(*)(id,SEL,NSUInteger))objc_msgSend)(obj, @selector(objectAtIndex:), idx);
            id jsonEl = WFJSONObjectFromAppIntentObject(element);
            if (jsonEl) [arr addObject:jsonEl];
        }
        return arr;
    }
    return nil;
}

static NSString *PickIPv4FromAppIntentOutput(id output) {
    id jsonObj = WFJSONObjectFromAppIntentObject(output);
    if (jsonObj) {
        if ([NSJSONSerialization isValidJSONObject:jsonObj]) {
            NSError *err = nil;
            NSData *data = [NSJSONSerialization dataWithJSONObject:jsonObj options:0 error:&err];
            if (data) {
                NSString *ip = PickRandomTailscaleIPv4FromStatusJSON(data);
                if (ip) return ip;
            }
        }
        NSArray<NSString *> *ips = CollectIPv4StringsFromObject(jsonObj);
        if (ips.count > 0) {
            return ips[arc4random_uniform((uint32_t)ips.count)];
        }
    } else {
        NSArray<NSString *> *ips = CollectIPv4StringsFromObject(output);
        if (ips.count > 0) {
            return ips[arc4random_uniform((uint32_t)ips.count)];
        }
    }
    return nil;
}


// Helpers: run processes and integrate with Notes for native demo
static NSData *RunCapture(NSArray<NSString *> *argv, int *statusOut) {
    if (argv.count == 0) return nil;
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/env";
    task.arguments = argv;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try { [task launch]; [task waitUntilExit]; } @catch (NSException *e) {
        Log(@"Failed to run %@: %@", [argv componentsJoinedByString:@" "], e);
        return nil;
    }
    if (statusOut) *statusOut = task.terminationStatus;
    return [[pipe fileHandleForReading] readDataToEndOfFile];
}

static NSString *PickRandomTailscaleIPv4FromStatusJSON(NSData *jsonData) {
    if (!jsonData) return nil;
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&err];
    if (!obj || ![obj isKindOfClass:[NSDictionary class]]) { Log(@"Invalid Tailscale JSON: %@", err); return nil; }
    NSDictionary *dict = (NSDictionary *)obj;
    NSMutableArray<NSDictionary *> *devices = [NSMutableArray new];
    id selfDev = dict[@"Self"];
    if ([selfDev isKindOfClass:[NSDictionary class]]) [devices addObject:selfDev];
    id peers = dict[@"Peer"] ?: dict[@"Peers"]; // different versions
    if ([peers isKindOfClass:[NSDictionary class]]) {
        [devices addObjectsFromArray:[(NSDictionary *)peers allValues]];
    } else if ([peers isKindOfClass:[NSArray class]]) {
        [devices addObjectsFromArray:(NSArray *)peers];
    }
    NSMutableArray<NSString *> *ips = [NSMutableArray new];
    for (NSDictionary *d in devices) {
        id arr = d[@"TailscaleIPs"] ?: d[@"Addresses"] ?: d[@"TailscaleIP"];
        if ([arr isKindOfClass:[NSArray class]]) {
            for (id ip in (NSArray *)arr) {
                if (![ip isKindOfClass:[NSString class]]) continue;
                NSString *s = (NSString *)ip;
                if ([s rangeOfString:@":"].location == NSNotFound) { [ips addObject:s]; }
            }
        } else if ([arr isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)arr;
            if ([s rangeOfString:@":"].location == NSNotFound) [ips addObject:s];
        }
    }
    if (ips.count == 0) return nil;
    u_int32_t idx = arc4random_uniform((u_int32_t)ips.count);
    return ips[idx];
}

static void CreateNoteWithBody(NSString *title, NSString *body) {
    NSString *escT = [title stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""] ?: @"";
    NSString *escB = [body stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""] ?: @"";
    NSString *script = [NSString stringWithFormat:@"tell application \"Notes\"\nmake new note with properties {name:\"%@\", body:\"%@\"}\nend tell", escT, escB];
    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
    NSDictionary *errInfo = nil; [as executeAndReturnError:&errInfo];
    if (errInfo) Log(@"AppleScript error: %@", errInfo);
}

// --- LNActionExecutor path for Entity-typed outputs ---

@interface LNRunDelegate : NSObject
@property (nonatomic, copy) void (^done)(id result, NSError *error);
@end

@implementation LNRunDelegate {
    BOOL _finished;
}
- (void)_finishOnceWithResult:(id)result error:(NSError *)error {
    if (_finished) return;
    _finished = YES;
    if (self.done) self.done(result, error);
}
- (void)executor:(id)executor didPerformActionWithResult:(id)result error:(NSError *)error {
    [self _finishOnceWithResult:result error:error];
}
- (void)executor:(id)executor didFinishWithResult:(id)result error:(NSError *)error {
    [self _finishOnceWithResult:result error:error];
}
- (void)executor:(id)executor didCompleteExecutionWithResult:(id)result error:(NSError *)error {
    [self _finishOnceWithResult:result error:error];
}
@end

static int RunLNActionExecutorCommand(NSString *bundleID, NSString *intentID, NSTimeInterval timeout) {
    Log(@"ln-run-intent: %@.%@ timeout=%.0f", bundleID, intentID, timeout);

    // Load LinkServices
    Log(@"Loading LinkServices...");
    NSBundle *ls = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/LinkServices.framework"];
    if (ls) {
        NSError *e = nil;
        BOOL ok = [ls loadAndReturnError:&e];
        Log(@"LinkServices loaded: %d (error=%@)", ok, e);
    } else {
        Log(@"LinkServices bundle not found");
    }

    if (!LoadPrivateFrameworks()) return 1;
    Log(@"Private frameworks loaded");

    Class providerCls = NSClassFromString(@"WFAppIntentsMetadataProvider");
    id provider = nil;
    if (providerCls) {
        SEL s = NSSelectorFromString(@"sharedProvider");
        if ([providerCls respondsToSelector:s]) provider = ((id(*)(id,SEL))objc_msgSend)(providerCls, s);
        if (!provider) {
            s = NSSelectorFromString(@"daemonProvider");
            if ([providerCls respondsToSelector:s]) provider = ((id(*)(id,SEL))objc_msgSend)(providerCls, s);
        }
    }
    if (!provider) { Log(@"Metadata provider unavailable"); return 1; }
    Log(@"Got provider: %@", provider);

    SEL metaSel = NSSelectorFromString(@"actionWithIdentifier:fromBundleIdentifier:");
    Log(@"Fetching metadata for %@.%@", bundleID, intentID);
    id meta = [provider respondsToSelector:metaSel]
        ? ((id(*)(id,SEL,id,id))objc_msgSend)(provider, metaSel, intentID, bundleID) : nil;
    if (!meta) { Log(@"No metadata for %@.%@", bundleID, intentID); return 1; }
    Log(@"Got metadata: %@ (%@)", [meta class], meta);

    // Create LNAction
    Class lnActionCls = NSClassFromString(@"LNAction");
    Log(@"LNAction class: %@", lnActionCls);
    id action = nil;
    if (lnActionCls) {
        SEL initSel = NSSelectorFromString(@"initWithMetadata:bundleIdentifier:parameters:");
        if ([lnActionCls instancesRespondToSelector:initSel]) {
            Log(@"Creating LNAction via initWithMetadata:bundleIdentifier:parameters:");
            action = ((id(*)(id,SEL,id,id,id))objc_msgSend)([lnActionCls alloc], initSel, meta, bundleID, @{});
        }
    }
    if (!action) { Log(@"Failed to create LNAction"); return 1; }
    Log(@"Created LNAction: %@", action);

    // Create LNConnection
    Log(@"Creating LNConnection...");
    Class connCls = NSClassFromString(@"LNConnection");
    if (!connCls) { Log(@"LNConnection class not found"); return 1; }

    // Introspect init methods
    unsigned int mc = 0; Method *ml = class_copyMethodList(connCls, &mc);
    for (unsigned int j = 0; j < mc; j++) {
        const char *name = sel_getName(method_getName(ml[j]));
        if (strncmp(name, "init", 4) == 0) Log(@"LNConnection.%s", name);
    }
    if (ml) free(ml);

    id conn = nil;

    // Extract effectiveBundleIdentifiers from metadata — these are LNBundleIdentifier objects
    id effectiveBundleIds = nil;
    SEL ebSel = NSSelectorFromString(@"effectiveBundleIdentifiers");
    if ([meta respondsToSelector:ebSel]) {
        effectiveBundleIds = ((id(*)(id,SEL))objc_msgSend)(meta, ebSel);
        Log(@"effectiveBundleIdentifiers: %@ (class=%@)", effectiveBundleIds, [effectiveBundleIds class]);
    }

    // Use the first effective bundle ID object (it's an LNBundleIdentifier, not a string)
    id bundleIdObj = nil;
    if ([effectiveBundleIds isKindOfClass:[NSOrderedSet class]] && [(NSOrderedSet *)effectiveBundleIds count] > 0) {
        bundleIdObj = [(NSOrderedSet *)effectiveBundleIds firstObject];
    } else if ([effectiveBundleIds isKindOfClass:[NSArray class]] && [(NSArray *)effectiveBundleIds count] > 0) {
        bundleIdObj = [(NSArray *)effectiveBundleIds firstObject];
    } else if ([effectiveBundleIds isKindOfClass:[NSSet class]] && [(NSSet *)effectiveBundleIds count] > 0) {
        bundleIdObj = [(NSSet *)effectiveBundleIds anyObject];
    }
    if (bundleIdObj) {
        Log(@"Using bundle ID object: %@ (class=%@)", bundleIdObj, [bundleIdObj class]);
    }

    // Try initWithBundleIdentifier: with the proper LNBundleIdentifier object
    if (bundleIdObj) {
        SEL initSel = NSSelectorFromString(@"initWithBundleIdentifier:");
        if ([connCls instancesRespondToSelector:initSel]) {
            Log(@"Trying initWithBundleIdentifier: (LNBundleIdentifier object)");
            @try {
                conn = ((id(*)(id,SEL,id))objc_msgSend)([connCls alloc], initSel, bundleIdObj);
            } @catch (NSException *e) {
                Log(@"LNConnection init exception: %@", e);
            }
        }
    }

    // Fallback: try initWithEffectiveBundleIdentifier with proper objects
    if (!conn && bundleIdObj) {
        SEL initEffSel = NSSelectorFromString(@"initWithEffectiveBundleIdentifier:appBundleIdentifier:processInstanceIdentifier:appIntentsEnabledOnly:userIdentity:error:");
        if ([connCls instancesRespondToSelector:initEffSel]) {
            Log(@"Trying initWithEffectiveBundleIdentifier: with LNBundleIdentifier");
            NSError *connErr = nil;
            @try {
                conn = ((id(*)(id,SEL,id,id,id,BOOL,id,NSError**))objc_msgSend)(
                    [connCls alloc], initEffSel,
                    bundleIdObj, bundleIdObj, nil, YES, nil, &connErr
                );
            } @catch (NSException *e) {
                Log(@"LNConnection initEff exception: %@", e);
            }
            if (connErr) Log(@"LNConnection init error: %@", connErr);
        }
    }

    if (!conn) { Log(@"Failed to create LNConnection"); return 1; }
    Log(@"Created LNConnection: %@", conn);

    // Connect with background options
    SEL connectSel = NSSelectorFromString(@"connectWithOptions:");
    if ([conn respondsToSelector:connectSel]) {
        id opts = nil;
        Class macOptsCls = NSClassFromString(@"LNMacApplicationConnectionOptions");
        if (macOptsCls) {
            opts = [macOptsCls new];
            SEL setBgSel = NSSelectorFromString(@"setBackground:");
            if ([opts respondsToSelector:setBgSel])
                ((void(*)(id,SEL,BOOL))objc_msgSend)(opts, setBgSel, YES);
        }
        dispatch_queue_t cq = nil;
        SEL qSel = NSSelectorFromString(@"queue");
        if ([conn respondsToSelector:qSel]) cq = ((dispatch_queue_t(*)(id,SEL))objc_msgSend)(conn, qSel);
        void (^doConn)(void) = ^{ ((void(*)(id,SEL,id))objc_msgSend)(conn, connectSel, opts); };
        if (cq) dispatch_sync(cq, doConn); else doConn();
    }

    // Create executor with options
    Class execOptsCls = NSClassFromString(@"LNActionExecutorOptions");
    id execOpts = execOptsCls ? [execOptsCls new] : nil;
    if (execOpts) {
        SEL labelSel = NSSelectorFromString(@"setClientLabel:");
        if ([execOpts respondsToSelector:labelSel])
            ((void(*)(id,SEL,id))objc_msgSend)(execOpts, labelSel, @"bsiri");
        SEL toSel = NSSelectorFromString(@"setConnectionOperationTimeout:");
        if ([execOpts respondsToSelector:toSel])
            ((void(*)(id,SEL,double))objc_msgSend)(execOpts, toSel, timeout);
    }

    Class execCls = NSClassFromString(@"LNActionExecutor");
    id executor = nil;
    if (execCls) {
        SEL initSel = NSSelectorFromString(@"initWithAction:connection:options:");
        if ([execCls instancesRespondToSelector:initSel])
            executor = ((id(*)(id,SEL,id,id,id))objc_msgSend)([execCls alloc], initSel, action, conn, execOpts);
    }
    if (!executor) { Log(@"Failed to create LNActionExecutor"); return 1; }

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    __block BOOL completed = NO;
    __block id result = nil;
    __block NSError *execErr = nil;

    LNRunDelegate *delegate = [LNRunDelegate new];
    delegate.done = ^(id out, NSError *error) {
        completed = YES; result = out; execErr = error;
        CFRunLoopStop(runLoop);
    };
    SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
    if ([executor respondsToSelector:setDelegateSel])
        ((void(*)(id,SEL,id))objc_msgSend)(executor, setDelegateSel, delegate);

    SEL performSel = NSSelectorFromString(@"perform");
    if (![executor respondsToSelector:performSel]) { Log(@"LNActionExecutor.perform unavailable"); return 1; }

    Log(@"Starting LNActionExecutor for %@.%@...", bundleID, intentID);
    ((void(*)(id,SEL))objc_msgSend)(executor, performSel);

    if (!completed) CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout, false);

    if (!completed) { Log(@"LNActionExecutor timeout after %.0fs", timeout); return 2; }
    if (execErr) { Log(@"LNActionExecutor error: %@", execErr); return 3; }
    if (!result) { Log(@"LNActionExecutor returned no result"); return 4; }

    // Unwrap LNActionOutput.value
    id value = result;
    @try {
        if ([value respondsToSelector:NSSelectorFromString(@"value")]) {
            id inner = ((id(*)(id,SEL))objc_msgSend)(value, NSSelectorFromString(@"value"));
            if (inner) value = inner;
        }
    } @catch (NSException *e) {}

    // Try JSON output
    id jsonObj = WFJSONObjectFromAppIntentObject(value);
    if (jsonObj && [NSJSONSerialization isValidJSONObject:jsonObj]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:jsonObj options:NSJSONWritingPrettyPrinted error:nil];
        if (data) { printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String); return 0; }
    }

    // Fallback: description
    printf("%s\n", [[value description] UTF8String]);
    return 0;
}

static void PrintUsage(FILE *f) {
    fprintf(f,
            "Usage: bsiri [commands]\n"
            "\n"
            "Commands:\n"
            "  open-app <AppName>           Open app (default: native engine)\n"
            "  create-note <Title> <Body>   Create a new note in Apple Notes (native)\n"
            "  wk-create-note-intent <T> <B> Create note via INCreateNoteIntent + WorkflowKit (private engine)\n"
            "  wk-find-devices-note         Run Tailscale GetStatus via WorkflowKit; append IP to note (experimental)\n"
            "  tailscale-note               Pick random Tailscale device IP and create a note\n"
            "  demo-tailscale               Open Tailscale app\n"
            "  demo-notes                   Open Notes and create a sample note\n"
            "  wk-list-actions <BundleID>   List App Intent action identifiers (private)\n"
            "  wk-create-note-private <Title> <Body>  Create note via private WorkflowKit App Intent\n"
            "  wk-run-file <path.shortcut>  Run a .shortcut plist as a single workflow via WorkflowKit\n"
            "  ln-run-intent <bundle> <intent> [timeout]  Run App Intent via LNActionExecutor (handles Entity outputs)\n"
            "  debug-introspect             List method names for key classes\n");
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) { PrintUsage(stderr); return 2; }
        // Fast-path a couple of private commands to avoid parser collisions while iterating
        if (argc >= 2 && strcmp(argv[1], "wk-list-actions") == 0) {
            if (argc < 3) { Log(@"wk-list-actions requires <BundleID>"); return 2; }
            NSString *bundle = [NSString stringWithUTF8String:argv[2]];
            Class Shim = NSClassFromString(@"WFAppIntentsProviderShim");
            if (!Shim) { Log(@"Shim not found"); return 1; }
            NSArray *ids = ((id(*)(id,SEL,id))objc_msgSend)(Shim, NSSelectorFromString(@"listActions:"), bundle);
            Log(@"Found %lu actions for %@", (unsigned long)ids.count, bundle);
            for (id s in ids) { Log(@"- %@", s); }
            return 0;
        }
        if (argc >= 4 && strcmp(argv[1], "wk-create-note-private") == 0) {
            NSString *title = [NSString stringWithUTF8String:argv[2]];
            NSString *body  = [NSString stringWithUTF8String:argv[3]];
            BOOL ok = RunNotesCreateNoteIntent(title, body);
            return ok ? 0 : 1;
        }
        if (argc >= 4 && strcmp(argv[1], "wk-create-note-intent") == 0) {
            if (!LoadPrivateFrameworks()) return 1;
            NSString *title = [NSString stringWithUTF8String:argv[2]];
            NSString *body  = [NSString stringWithUTF8String:argv[3]];
            Class INSpeakableStringC = NSClassFromString(@"INSpeakableString");
            Class INTextNoteContentC = NSClassFromString(@"INTextNoteContent");
            Class INCreateNoteIntentC = NSClassFromString(@"INCreateNoteIntent");
            if (!INSpeakableStringC || !INTextNoteContentC || !INCreateNoteIntentC) { Log(@"Intents classes not available"); return 1; }
            id titleSpeak = ((id(*)(id,SEL,id))objc_msgSend)([INSpeakableStringC alloc], NSSelectorFromString(@"initWithSpokenPhrase:"), title);
            id textContent = ((id(*)(id,SEL,id))objc_msgSend)([INTextNoteContentC alloc], NSSelectorFromString(@"initWithText:"), body);
            id intent = ((id(*)(id,SEL,id,id,id))objc_msgSend)([INCreateNoteIntentC alloc], NSSelectorFromString(@"initWithTitle:content:groupName:"), titleSpeak, textContent, nil);
            if (!intent) { Log(@"Failed to construct INCreateNoteIntent"); return 1; }
            Class INShortcutC = NSClassFromString(@"INShortcut");
            id shortcut = ((id(*)(id,SEL,id))objc_msgSend)([INShortcutC alloc], NSSelectorFromString(@"initWithIntent:"), intent);
            if (!shortcut) { Log(@"Failed to build INShortcut"); return 1; }
            Class WFWorkflow = NSClassFromString(@"WFWorkflow");
            SEL initWithShortcutSel = NSSelectorFromString(@"initWithShortcut:error:");
            id wf = nil;
            if ([WFWorkflow instancesRespondToSelector:initWithShortcutSel]) {
                wf = ((id(*)(id,SEL,id,id))objc_msgSend)([WFWorkflow alloc], initWithShortcutSel, shortcut, (id)nil);
            }
            if (!wf) { Log(@"WFWorkflow initWithShortcut:error: failed"); return 1; }
            id desc = NewRunDescriptorForWorkflow(wf); if (!desc) return 1;
            id req  = NewRunRequest(); if (!req) return 1;
            BOOL ok = RunWorkflow(desc, req, 8.0);
            return ok?0:1;
        }
        // ln-run-intent: run a single App Intent via LNActionExecutor (handles Entity outputs)
        if (argc >= 4 && strcmp(argv[1], "ln-run-intent") == 0) {
            NSString *bundle = [NSString stringWithUTF8String:argv[2]];
            NSString *intent = [NSString stringWithUTF8String:argv[3]];
            double timeout = 20.0;
            if (argc >= 5) timeout = atof(argv[4]);
            if (timeout <= 0) timeout = 20.0;
            return RunLNActionExecutorCommand(bundle, intent, timeout);
        }

        // wk-run-file: read a .shortcut plist and run it as a unified workflow
        // Uses WFShortcutsAppRunnerClient (the same path as RunAppIntentActions)
        // so that variables and action chaining work correctly.
        if (argc >= 3 && strcmp(argv[1], "wk-run-file") == 0) {
            NSString *path = [NSString stringWithUTF8String:argv[2]];
            NSData *fileData = [NSData dataWithContentsOfFile:path];
            if (!fileData) { Log(@"Cannot read file: %@", path); return 1; }
            NSError *plistErr = nil;
            NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:fileData
                                                                           options:NSPropertyListImmutable
                                                                            format:NULL error:&plistErr];
            if (!plist || plistErr) { Log(@"Failed to parse plist: %@", plistErr); return 1; }
            NSArray *wfActions = plist[@"WFWorkflowActions"];
            if (!wfActions || wfActions.count == 0) { Log(@"No actions in shortcut file"); return 1; }

            // Parse optional timeout from argv[3]
            double timeout = 15.0;
            if (argc >= 4) timeout = atof(argv[3]);
            if (timeout <= 0) timeout = 15.0;

            Log(@"Running %lu action(s) from %@ (timeout=%.1fs)", (unsigned long)wfActions.count, path.lastPathComponent, timeout);

            // Use RunAppIntentActions which goes through WFShortcutsAppRunnerClient,
            // preserving variable context and action chaining within one workflow run.
            id output = nil;
            BOOL ok = RunAppIntentActions(wfActions, timeout, &output, NULL);
            if (output) {
                id jsonObj = WFJSONObjectFromAppIntentObject(output);
                if (jsonObj && [NSJSONSerialization isValidJSONObject:jsonObj]) {
                    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonObj options:NSJSONWritingPrettyPrinted error:nil];
                    if (jsonData) printf("%s\n", [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding].UTF8String);
                } else {
                    Log(@"Output: %@", output);
                }
            }
            return ok ? 0 : 1;
        }

        NSMutableArray<NSDictionary *> *actions = [NSMutableArray new];
        BOOL useNativeEngine = YES; // default to native; set to NO to attempt WorkflowKit

        // Parse simple subcommands
        int i = 1;
        while (i < argc) {
            NSString *cmd = [NSString stringWithUTF8String:argv[i++]];
            if ([cmd isEqualToString:@"--engine"]) {
                if (i >= argc) { Log(@"--engine requires native|wk"); return 2; }
                NSString *eng = [NSString stringWithUTF8String:argv[i++]];
                useNativeEngine = ![eng.lowercaseString isEqualToString:@"wk"];
                continue;
            }
            if ([cmd isEqualToString:@"open-app"]) {
                if (i >= argc) { Log(@"open-app requires <AppName>"); return 2; }
                NSString *app = [NSString stringWithUTF8String:argv[i++]];
                if (useNativeEngine) {
                    // Native path: NSWorkspace
                    [[NSWorkspace sharedWorkspace] launchApplication:app];
                } else {
                    [actions addObject:Action_OpenViaShell(app)];
                }
            } else if ([cmd isEqualToString:@"create-note"]) {
                if (i+1 >= argc) { Log(@"create-note requires <Title> <Body>"); return 2; }
                NSString *title = [NSString stringWithUTF8String:argv[i++]];
                NSString *body  = [NSString stringWithUTF8String:argv[i++]];
                if (useNativeEngine) {
                    // Native path: AppleScript
                    NSString *script = [NSString stringWithFormat:@"tell application \"Notes\"\nmake new note with properties {name:\"%@\", body:\"%@\"}\nend tell", [title stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""], [body stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
                    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
                    NSDictionary *errInfo = nil; [as executeAndReturnError:&errInfo];
                    if (errInfo) Log(@"AppleScript error: %@", errInfo);
                } else {
                    [actions addObject:Action_CreateNote(title, body)];
                }
            } else if ([cmd isEqualToString:@"demo-tailscale"]) {
                if (useNativeEngine) {
                    [[NSWorkspace sharedWorkspace] launchApplication:@"Tailscale"];
                } else {
                    [actions addObject:Action_OpenViaShell(@"Tailscale")];
                }
            } else if ([cmd isEqualToString:@"demo-notes"]) {
                if (useNativeEngine) {
                    [[NSWorkspace sharedWorkspace] launchApplication:@"Notes"];
                    NSString *script = @"tell application \"Notes\"\nmake new note with properties {name:\"Hello from bsiri\", body:\"This note was created by bsiri (native engine).\"}\nend tell";
                    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
                    NSDictionary *errInfo = nil; [as executeAndReturnError:&errInfo];
                    if (errInfo) Log(@"AppleScript error: %@", errInfo);
                } else {
                    [actions addObject:Action_OpenViaShell(@"Notes")];
                    [actions addObject:Action_CreateNote(@"Hello from WorkflowKit", @"This note was created by a private WorkflowKit runner.")];
                }
            } else if ([cmd isEqualToString:@"wk-list-actions"]) {
                if (i >= argc) { Log(@"wk-list-actions requires <bundleID>"); return 2; }
                NSString *bundle = [NSString stringWithUTF8String:argv[i++]];
                Class Shim = NSClassFromString(@"WFAppIntentsProviderShim");
                if (!Shim) { Log(@"Shim not found"); return 1; }
                NSArray *ids = ((id(*)(id,SEL,id))objc_msgSend)(Shim, NSSelectorFromString(@"listActions:"), bundle);
                Log(@"Found %lu actions for %@", (unsigned long)ids.count, bundle);
                for (id s in ids) { Log(@"- %@", s); }
            } else if ([cmd isEqualToString:@"wk-create-note-private"]) {
                if (i+1 >= argc) { Log(@"wk-create-note-private requires <Title> <Body>"); return 2; }
                NSString *title = [NSString stringWithUTF8String:argv[i++]];
                NSString *body  = [NSString stringWithUTF8String:argv[i++]];
                BOOL ok = RunNotesCreateNoteIntent(title, body);
                return ok ? 0 : 1;
            } else if ([cmd isEqualToString:@"wk-create-note-intent"]) {
                if (i+1 >= argc) { Log(@"wk-create-note-intent requires <Title> <Body>"); return 2; }
                NSString *title = [NSString stringWithUTF8String:argv[i++]];
                NSString *body  = [NSString stringWithUTF8String:argv[i++]];
                if (!LoadPrivateFrameworks()) return 1;
                // Build INCreateNoteIntent
                Class INSpeakableStringC = NSClassFromString(@"INSpeakableString");
                Class INTextNoteContentC = NSClassFromString(@"INTextNoteContent");
                Class INCreateNoteIntentC = NSClassFromString(@"INCreateNoteIntent");
                if (!INSpeakableStringC || !INTextNoteContentC || !INCreateNoteIntentC) { Log(@"Intents classes not available"); return 1; }
                id titleSpeak = ((id(*)(id,SEL,id))objc_msgSend)(INSpeakableStringC, NSSelectorFromString(@"speakableStringWithSpokenPhrase:"), title);
                id textContent = ((id(*)(id,SEL,id))objc_msgSend)([INTextNoteContentC alloc], NSSelectorFromString(@"initWithText:"), body);
                id intent = ((id(*)(id,SEL,id,id,id))objc_msgSend)([INCreateNoteIntentC alloc], NSSelectorFromString(@"initWithTitle:content:groupName:"), titleSpeak, textContent, nil);
                if (!intent) { Log(@"Failed to construct INCreateNoteIntent"); return 1; }
                // Wrap in INShortcut
                Class INShortcutC = NSClassFromString(@"INShortcut");
                id shortcut = ((id(*)(id,SEL,id))objc_msgSend)([INShortcutC alloc], NSSelectorFromString(@"initWithIntent:"), intent);
                if (!shortcut) { Log(@"Failed to build INShortcut"); return 1; }
                // Create WFWorkflow from INShortcut
                Class WFWorkflow = NSClassFromString(@"WFWorkflow");
                SEL initWithShortcutSel = NSSelectorFromString(@"initWithShortcut:error:");
                id wf = nil;
                if ([WFWorkflow instancesRespondToSelector:initWithShortcutSel]) {
                    wf = ((id(*)(id,SEL,id,id))objc_msgSend)([WFWorkflow alloc], initWithShortcutSel, shortcut, (id)nil);
                }
                if (!wf) { Log(@"WFWorkflow initWithShortcut:error: failed"); return 1; }
                id desc = NewRunDescriptorForWorkflow(wf); if (!desc) return 1;
                id req  = NewRunRequest(); if (!req) return 1;
                BOOL ok = RunWorkflow(desc, req, 8.0);
                return ok?0:1;
            } else if ([cmd isEqualToString:@"wk-find-devices-note"]) {
                id statusOutput = nil;
                if (!RunTailscaleGetStatusIntent(&statusOutput)) {
                    Log(@"Failed to execute Tailscale GetStatus App Intent; falling back to tailscale CLI JSON");
                    int st = 0;
                    NSData *out = RunCapture(@[@"tailscale", @"status", @"--json"], &st);
                    if (st != 0 || !out.length) { Log(@"Failed to get tailscale status --json (exit %d)", st); return 1; }
                    NSString *ip = PickRandomTailscaleIPv4FromStatusJSON(out);
                    if (!ip) { Log(@"No IPv4 address found in Tailscale status"); return 1; }
                    NSString *title = @"Random Tailscale device IP";
                    NSString *body  = [NSString stringWithFormat:@"Random Tailscale device IP: %@", ip];
                    CreateNoteWithBody(title, body);
                    return 0;
                }
                NSString *ip = PickIPv4FromAppIntentOutput(statusOutput);
                if (!ip) {
                    Log(@"Unable to locate IPv4 address in Tailscale intent output (class %@)", statusOutput ? NSStringFromClass([statusOutput class]) : @"nil");
                    return 1;
                }
                NSString *title = @"Random Tailscale device IP";
                NSString *body  = [NSString stringWithFormat:@"Random Tailscale device IP: %@", ip];
                if (!RunNotesCreateNoteIntent(title, body)) {
                    Log(@"Failed to create note via Notes CreateNote App Intent");
                    return 1;
                }
                Log(@"Created note with Tailscale IPv4 %@ via private App Intents workflow", ip);
                return 0;
            } else if ([cmd isEqualToString:@"tailscale-note"]) {
            } else if ([cmd isEqualToString:@"wk-run-appintent"]) {
                if (i+1 >= argc) { Log(@"wk-run-appintent requires <bundleID> <intentIdentifier> [key=value ...]"); return 2; }
                NSString *bundle = [NSString stringWithUTF8String:argv[i++]];
                NSString *intentId = [NSString stringWithUTF8String:argv[i++]];

                // Parse optional key=value parameters
                NSMutableDictionary *params = [NSMutableDictionary new];
                while (i < argc) {
                    NSString *arg = [NSString stringWithUTF8String:argv[i]];
                    if ([arg hasPrefix:@"-"]) break; // Next flag
                    NSRange eq = [arg rangeOfString:@"="];
                    if (eq.location != NSNotFound) {
                        NSString *key = [arg substringToIndex:eq.location];
                        NSString *val = [arg substringFromIndex:eq.location + 1];
                        // Try to parse as JSON for complex types
                        NSData *jsonData = [val dataUsingEncoding:NSUTF8StringEncoding];
                        id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
                        params[key] = parsed ?: val;
                    }
                    i++;
                }

                Log(@"Running App Intent: %@.%@", bundle, intentId);
                if (params.count > 0) Log(@"Parameters: %@", params);

                id output = nil;
                BOOL ok = RunAppIntentAction(bundle, intentId, nil, params.count > 0 ? params : nil, 15.0, &output);

                if (!ok) {
                    Log(@"Failed to execute App Intent via WorkflowKit");
                    return 1;
                }

                if (output) {
                    id jsonObj = WFJSONObjectFromAppIntentObject(output);
                    if (jsonObj && [NSJSONSerialization isValidJSONObject:jsonObj]) {
                        NSData *data = [NSJSONSerialization dataWithJSONObject:jsonObj options:NSJSONWritingPrettyPrinted error:nil];
                        if (data) {
                            printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
                        }
                    } else {
                        Log(@"Output: %@", output);
                    }
                }
                return 0;
            } else if ([cmd isEqualToString:@"debug-introspect"]) {
                if (!LoadPrivateFrameworks()) return 1;
                NSArray *classes = @[ @"WFWorkflow", @"WFAction", @"WFActionDefinition", @"WFActionDefinitionRegistry", @"WFActionRegistry", @"WFRunShellScriptAction", @"WFCreateNoteAction", @"WFOpenAppAction", @"WFAppIntent", @"WFAppIntentArchiver", @"WFAppIntentsMetadataProvider", @"WFAppIntentExecutionAction", @"WFConfiguredSystemWorkflowAction", @"WFConfiguredAction", @"WFAppIntentDescriptor", @"WFActionMetadata", @"WFWorkflowRunDescriptor", @"WFWorkflowRunRequest", @"WFWorkflowRunnerClient" ];
                for (NSString *cn in classes) {
                    Class C = NSClassFromString(cn);
                    if (!C) { Log(@"Class %@ not found", cn); continue; }
                    unsigned int mcount=0; Method *mlist = class_copyMethodList(C, &mcount);
                    Log(@"%@ methods (%u):", cn, mcount);
                    for (unsigned int j=0;j<mcount;j++) {
                        SEL name = method_getName(mlist[j]);
                        Log(@"  - %s", sel_getName(name));
                    }
                    if (mlist) free(mlist);
                }
                return 0;
            } else if ([cmd isEqualToString:@"debug-scan-wfapp"]) {
                if (!LoadPrivateFrameworks()) return 1;
                int num = objc_getClassList(NULL, 0);
                Class *classes = (Class *)calloc(num, sizeof(Class));
                objc_getClassList(classes, num);
                for (int ix = 0; ix < num; ix++) {
                    const char *cn = class_getName(classes[ix]);
                    if (!cn) continue;
                    if (strncmp(cn, "WFApp", 5) == 0) {
                        Log(@"Class: %s", cn);
                        unsigned int mcount=0; Method *mlist = class_copyMethodList(classes[ix], &mcount);
                        for (unsigned int j=0;j<mcount;j++) {
                            Log(@"  - %s", sel_getName(method_getName(mlist[j])));
                        }
                        if (mlist) free(mlist);
                    }
                }
                free(classes);
                return 0;
            } else if ([cmd isEqualToString:@"wk-list-actions"]) {
                if (i >= argc) { Log(@"wk-list-actions requires <bundleID>"); return 2; }
                NSString *bundle = [NSString stringWithUTF8String:argv[i++]];
                if (!LoadPrivateFrameworks()) return 1;
                Class Provider = NSClassFromString(@"WFAppIntentsMetadataProvider");
                if (!Provider) Provider = NSClassFromString(@"VoiceShortcutClient_Private.WFAppIntentsMetadataProvider");
                if (!Provider) Provider = NSClassFromString(@"WorkflowKit.WFAppIntentsMetadataProvider");
                if (!Provider) { Log(@"WFAppIntentsMetadataProvider class not found"); return 1; }
                // Try to construct with AppIntentsServices.CachedLinkMetadataProvider
                NSBundle *ais = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AppIntentsServices.framework"]; NSError *err=nil; [ais loadAndReturnError:&err];
                Class CachedLinkMetadataProvider = NSClassFromString(@"AppIntentsServices.CachedLinkMetadataProvider");
                id metaProv = nil;
                if (CachedLinkMetadataProvider) {
                    SEL initSel = NSSelectorFromString(@"init");
                    if ([CachedLinkMetadataProvider instancesRespondToSelector:initSel]) metaProv = ((id(*)(id,SEL))objc_msgSend)([CachedLinkMetadataProvider alloc], initSel);
                }
                id provider = nil;
                SEL initMP = NSSelectorFromString(@"initWithMetadataProvider:");
                SEL initMPC = NSSelectorFromString(@"initWithMetadataProvider:cacheLifetime:");
                if ([Provider instancesRespondToSelector:initMPC] && metaProv) {
                    provider = ((id(*)(id,SEL,id,NSInteger))objc_msgSend)([Provider alloc], initMPC, metaProv, (NSInteger)300);
                } else if ([Provider instancesRespondToSelector:initMP] && metaProv) {
                    provider = ((id(*)(id,SEL,id))objc_msgSend)([Provider alloc], initMP, metaProv);
                } else if ([Provider instancesRespondToSelector:NSSelectorFromString(@"init")]) {
                    provider = ((id(*)(id,SEL))objc_msgSend)([Provider alloc], NSSelectorFromString(@"init"));
                }
                SEL sel = NSSelectorFromString(@"actionsForBundleIdentifier:");
                if (![provider respondsToSelector:sel]) { Log(@"Provider missing actionsForBundleIdentifier:"); return 1; }
                NSArray *actions = ((id(*)(id,SEL,id))objc_msgSend)(provider, sel, bundle);
                Log(@"Found %lu actions for %@", (unsigned long)actions.count, bundle);
                for (id a in actions) {
                    const char *cn = object_getClassName(a);
                    Log(@"- %@ (%s)", [a description], cn);
                    // Try common selectors
                    NSArray *cands = @[ @"identifier", @"bundleIdentifier", @"fullyQualifiedIdentifier", @"name", @"title", @"subtitle", @"parameters", @"definition", @"intentIdentifier", @"appIntentDescriptor", @"actionIdentifier" ];
                    for (NSString *nm in cands) {
                        SEL s = NSSelectorFromString(nm);
                        if ([a respondsToSelector:s]) {
                            id v = ((id(*)(id,SEL))objc_msgSend)(a, s);
                            Log(@"    %@ => %@", nm, v);
                        }
                    }
                }
                return 0;
            } else if ([cmd isEqualToString:@"debug-scan-ais"]) {
                NSBundle *ais = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AppIntentsServices.framework"]; NSError *err=nil; [ais loadAndReturnError:&err];
                int num = objc_getClassList(NULL, 0);
                Class *classes = (Class *)calloc(num, sizeof(Class));
                objc_getClassList(classes, num);
                for (int ix = 0; ix < num; ix++) {
                    const char *cn = class_getName(classes[ix]);
                    if (!cn) continue;
                    if (strstr(cn, "AppIntentsServices.")) {
                        Log(@"Class: %s", cn);
                        unsigned int mcount=0; Method *mlist = class_copyMethodList(classes[ix], &mcount);
                        for (unsigned int j=0;j<mcount;j++) {
                            Log(@"  - %s", sel_getName(method_getName(mlist[j])));
                        }
                        if (mlist) free(mlist);
                    }
                }
                free(classes);
                return 0;
            } else if ([cmd isEqualToString:@"--help"]) {
                PrintUsage(stdout); return 0;
            } else {
                Log(@"Unknown command: %@", cmd); PrintUsage(stderr); return 2;
            }
        }

        if (useNativeEngine) {
            // Native engine executed synchronously above
            return 0;
        }
        if (actions.count == 0) { Log(@"No actions for WorkflowKit"); return 2; }
        if (!LoadPrivateFrameworks()) return 1;

        id wf = NewWorkflowFromActions(actions);
        if (!wf) return 1;
        id desc = NewRunDescriptorForWorkflow(wf);
        if (!desc) return 1;
        id req = NewRunRequest();
        if (!req) return 1;
        BOOL ok = RunWorkflow(desc, req, 5.0);
        return ok ? 0 : 1;
    }
}
