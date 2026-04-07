// injector.m - Dylib that executes App Intents when injected into shortcuts process
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

// Read command from environment variables
// BSIRI_BUNDLE_ID - bundle identifier (e.g., com.mitchellh.ghostty)
// BSIRI_INTENT_ID - intent identifier (e.g., QuickTerminalIntent)
// BSIRI_PARAMS_JSON - optional JSON params

@interface WFWorkflowRunnerCapture : NSObject
@property (atomic, strong) id output;
@property (atomic, strong) id allResults;
@property (atomic, strong) NSError *error;
@property (atomic, assign) BOOL cancelled;
@property (atomic, assign) BOOL finished;
@end

@implementation WFWorkflowRunnerCapture
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithOutput:(id)output error:(NSError *)error cancelled:(BOOL)cancelled {
    self.output = output;
    self.error = error;
    self.cancelled = cancelled;
    self.finished = YES;
}
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithAllResults:(id)results error:(NSError *)error cancelled:(BOOL)cancelled {
    self.allResults = results;
    self.error = error;
    self.cancelled = cancelled;
    self.finished = YES;
}
- (void)workflowRunnerClient:(id)client didFinishRunningWorkflowWithError:(NSError *)error cancelled:(BOOL)cancelled {
    self.error = error;
    self.cancelled = cancelled;
    self.finished = YES;
}
@end

static void RunAppIntent(NSString *bundleID, NSString *intentID, NSDictionary *params);
static id SafeValueForKey(id obj, NSString *key);
static void DumpResultObject(NSString *label, id obj);

// LNRunDelegate: delegate for LNActionExecutor — handles entity-typed outputs
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

static BOOL RunViaLNActionExecutor(NSString *bundleID, NSString *intentID, NSTimeInterval timeout, id *outputOut) {
    // Load LinkServices framework if not already loaded (needed for LNConnection, LNActionExecutor)
    NSBundle *ls = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/LinkServices.framework"];
    if (ls) { NSError *lsErr = nil; [ls loadAndReturnError:&lsErr]; }

    @try {

    Class providerCls = NSClassFromString(@"WFAppIntentsMetadataProvider");
    id provider = nil;
    if (providerCls) {
        SEL sharedSel = NSSelectorFromString(@"sharedProvider");
        if ([providerCls respondsToSelector:sharedSel])
            provider = ((id(*)(id,SEL))objc_msgSend)(providerCls, sharedSel);
        if (!provider) {
            SEL daemonSel = NSSelectorFromString(@"daemonProvider");
            if ([providerCls respondsToSelector:daemonSel])
                provider = ((id(*)(id,SEL))objc_msgSend)(providerCls, daemonSel);
        }
    }
    if (!provider) { NSLog(@"[BSIRI] LN: metadata provider unavailable"); return NO; }

    NSLog(@"[BSIRI] LN: got provider: %@", provider);

    SEL metaSel = NSSelectorFromString(@"actionWithIdentifier:fromBundleIdentifier:");
    id meta = [provider respondsToSelector:metaSel]
        ? ((id(*)(id,SEL,id,id))objc_msgSend)(provider, metaSel, intentID, bundleID) : nil;
    if (!meta) { NSLog(@"[BSIRI] LN: no metadata for %@.%@", bundleID, intentID); return NO; }
    NSLog(@"[BSIRI] LN: got metadata: %@", [meta class]);

    // Create LNAction — try various init selectors
    Class lnActionCls = NSClassFromString(@"LNAction");
    NSLog(@"[BSIRI] LN: meta class=%@, isLNAction=%d", [meta class], lnActionCls ? [meta isKindOfClass:lnActionCls] : -1);

    id action = nil;
    if (lnActionCls) {
        // List available init methods
        unsigned int mc = 0; Method *ml = class_copyMethodList(lnActionCls, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            const char *name = sel_getName(method_getName(ml[j]));
            if (strncmp(name, "init", 4) == 0) NSLog(@"[BSIRI] LN: LNAction.%s", name);
        }
        if (ml) free(ml);

        // Try initWithMetadata:bundleIdentifier:parameters:
        SEL initMBPSel = NSSelectorFromString(@"initWithMetadata:bundleIdentifier:parameters:");
        if (!action && [lnActionCls instancesRespondToSelector:initMBPSel]) {
            action = ((id(*)(id,SEL,id,id,id))objc_msgSend)([lnActionCls alloc], initMBPSel, meta, bundleID, @{});
            if (action) NSLog(@"[BSIRI] LN: created via initWithMetadata:bundleIdentifier:parameters:");
        }
        // Try initWithIdentifier:
        SEL initIdSel = NSSelectorFromString(@"initWithIdentifier:");
        if (!action && [lnActionCls instancesRespondToSelector:initIdSel]) {
            NSString *actionID = [NSString stringWithFormat:@"%@.%@", bundleID, intentID];
            action = ((id(*)(id,SEL,id))objc_msgSend)([lnActionCls alloc], initIdSel, actionID);
            if (action) NSLog(@"[BSIRI] LN: created via initWithIdentifier:");
        }
    }
    if (!action) {
        NSLog(@"[BSIRI] LN: failed to create LNAction, using metadata directly");
        action = meta;
    }

    NSLog(@"[BSIRI] LN: created action: %@", [action class]);

    // Create LNConnection
    Class connCls = NSClassFromString(@"LNConnection");
    if (!connCls) { NSLog(@"[BSIRI] LN: LNConnection class not found"); return NO; }
    NSLog(@"[BSIRI] LN: creating LNConnection for %@", bundleID);
    id conn = nil;
    SEL initConnSel = NSSelectorFromString(@"initWithBundleIdentifier:");
    if ([connCls instancesRespondToSelector:initConnSel])
        conn = ((id(*)(id,SEL,id))objc_msgSend)([connCls alloc], initConnSel, bundleID);
    if (!conn) { NSLog(@"[BSIRI] LN: failed to create LNConnection"); return NO; }
    NSLog(@"[BSIRI] LN: created connection: %@", conn);

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
        dispatch_queue_t connQueue = nil;
        SEL queueSel = NSSelectorFromString(@"queue");
        if ([conn respondsToSelector:queueSel])
            connQueue = ((dispatch_queue_t(*)(id,SEL))objc_msgSend)(conn, queueSel);
        void (^doConnect)(void) = ^{ ((void(*)(id,SEL,id))objc_msgSend)(conn, connectSel, opts); };
        if (connQueue) dispatch_sync(connQueue, doConnect); else doConnect();
    }

    // Create executor
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
        SEL initExecSel = NSSelectorFromString(@"initWithAction:connection:options:");
        if ([execCls instancesRespondToSelector:initExecSel])
            executor = ((id(*)(id,SEL,id,id,id))objc_msgSend)([execCls alloc], initExecSel, action, conn, execOpts);
    }
    if (!executor) { NSLog(@"[BSIRI] LN: failed to create LNActionExecutor"); return NO; }

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
    if (![executor respondsToSelector:performSel]) { NSLog(@"[BSIRI] LN: perform unavailable"); return NO; }

    NSLog(@"[BSIRI] LN: starting LNActionExecutor for %@.%@...", bundleID, intentID);
    ((void(*)(id,SEL))objc_msgSend)(executor, performSel);

    if (!completed) CFRunLoopRunInMode(kCFRunLoopDefaultMode, timeout, false);

    if (!completed) { NSLog(@"[BSIRI] LN: timeout after %.0fs", timeout); return NO; }
    if (execErr) { NSLog(@"[BSIRI] LN: error: %@", execErr); return NO; }
    if (!result) { NSLog(@"[BSIRI] LN: no result"); return NO; }

    // Unwrap LNActionOutput.value if present
    id value = result;
    if ([value respondsToSelector:@selector(value)]) {
        id inner = SafeValueForKey(value, @"value");
        if (inner) value = inner;
    }
    NSLog(@"[BSIRI] LN: success (%@): %@", NSStringFromClass([result class]), [value description]);
    DumpResultObject(@"LNActionExecutor.result", value);
    if (outputOut) *outputOut = value;
    return YES;

    } @catch (NSException *e) {
        NSLog(@"[BSIRI] LN: exception: %@ — %@", e.name, e.reason);
        return NO;
    }
}

static BOOL EnvIsTruthy(const char *value) {
    if (!value) return NO;
    return strcmp(value, "1") == 0 || strcasecmp(value, "true") == 0 || strcasecmp(value, "yes") == 0;
}

static id SafeValueForKey(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *JSONStringIfPossible(id obj) {
    if (!obj) return nil;

    id candidate = obj;
    if ([candidate respondsToSelector:@selector(dictionaryRepresentation)]) {
        @try {
            id dict = ((id(*)(id,SEL))objc_msgSend)(candidate, NSSelectorFromString(@"dictionaryRepresentation"));
            if (dict) candidate = dict;
        } @catch (__unused NSException *e) {}
    }

    if (![NSJSONSerialization isValidJSONObject:candidate]) return nil;

    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:candidate options:NSJSONWritingPrettyPrinted error:&err];
    if (!data || err) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *OutputFilePathFromEnv(void) {
    const char *raw = getenv("BSIRI_OUTPUT_FILE");
    if (!raw || !raw[0]) return nil;
    return [NSString stringWithUTF8String:raw];
}

static void AppendOutputFileLine(NSString *line) {
    if (!line.length) return;

    NSString *path = OutputFilePathFromEnv();
    if (!path.length) return;

    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [data writeToFile:path atomically:YES];
        return;
    }

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *e) {
    }
    [handle closeFile];
}

static void DumpResultObject(NSString *label, id obj) {
    if (!obj) {
        NSLog(@"[BSIRI] %@: (nil)", label);
        AppendOutputFileLine([NSString stringWithFormat:@"%@: (nil)", label]);
        return;
    }

    NSLog(@"[BSIRI] %@ class=%@", label, NSStringFromClass([obj class]));
    AppendOutputFileLine([NSString stringWithFormat:@"%@ class=%@", label, NSStringFromClass([obj class])]);

    NSString *json = JSONStringIfPossible(obj);
    if (json.length > 0) {
        NSLog(@"[BSIRI] %@ json:\n%@", label, json);
        AppendOutputFileLine([NSString stringWithFormat:@"%@ json=%@", label, json]);
    } else {
        NSLog(@"[BSIRI] %@ description=%@", label, obj);
        AppendOutputFileLine([NSString stringWithFormat:@"%@ description=%@", label, obj]);
    }
}

static NSTimeInterval TimeoutFromEnv(NSTimeInterval fallbackSeconds) {
    const char *raw = getenv("BSIRI_TIMEOUT");
    if (!raw || !raw[0]) return fallbackSeconds;

    double parsed = strtod(raw, NULL);
    if (parsed > 0.1 && parsed < 300.0) return parsed;
    return fallbackSeconds;
}

static id RunSourceObjectFromEnv(void) {
    const char *raw = getenv("BSIRI_RUN_SOURCE_OBJ");
    if (!raw || !raw[0]) return nil;

    NSString *value = [NSString stringWithUTF8String:raw];
    if (value.length == 0) return nil;

    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([value rangeOfCharacterFromSet:nonDigits].location == NSNotFound) {
        return @([value longLongValue]);
    }
    return value;
}

static BOOL ShouldRequireOutput(void) {
    return EnvIsTruthy(getenv("BSIRI_REQUIRE_OUTPUT"));
}

static BOOL ShouldKeepProcessAlive(void) {
    return EnvIsTruthy(getenv("BSIRI_NO_EXIT"));
}

static BOOL ShouldDeferToAppLaunch(void) {
    return EnvIsTruthy(getenv("BSIRI_DEFER_LAUNCH"));
}

static BOOL ShouldAsyncStart(void) {
    return EnvIsTruthy(getenv("BSIRI_ASYNC_START"));
}

static BOOL ShouldTryVCLegacyWorkflow(void) {
    return EnvIsTruthy(getenv("BSIRI_TRY_VC_LEGACY"));
}

static BOOL ShouldTryVCSerializedExecutor(void) {
    return EnvIsTruthy(getenv("BSIRI_TRY_VC_SERIALIZED_EXECUTOR"));
}

static BOOL ShouldTryRunCompletionPath(void) {
    return EnvIsTruthy(getenv("BSIRI_TRY_RUN_COMPLETION"));
}

static NSTimeInterval StartupDelayFromEnv(void) {
    const char *raw = getenv("BSIRI_DELAY");
    if (!raw || !raw[0]) return 0.0;
    double seconds = strtod(raw, NULL);
    if (seconds < 0.0) return 0.0;
    if (seconds > 120.0) return 120.0;
    return seconds;
}

static void ExecuteConfiguredIntent(void) {
    @autoreleasepool {
        const char *bundleID = getenv("BSIRI_BUNDLE_ID");
        const char *intentID = getenv("BSIRI_INTENT_ID");
        const char *paramsJSON = getenv("BSIRI_PARAMS_JSON");

        if (!bundleID || !intentID) {
            NSLog(@"[BSIRI] Injector loaded but no BSIRI_BUNDLE_ID/BSIRI_INTENT_ID set");
            return;
        }

        NSString *bundle = [NSString stringWithUTF8String:bundleID];
        NSString *intent = [NSString stringWithUTF8String:intentID];
        NSDictionary *params = nil;

        if (paramsJSON) {
            NSData *jsonData = [[NSString stringWithUTF8String:paramsJSON] dataUsingEncoding:NSUTF8StringEncoding];
            params = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
        }

        NSTimeInterval startupDelay = StartupDelayFromEnv();
        if (startupDelay > 0.0) {
            NSLog(@"[BSIRI] Delaying run by %.2fs", startupDelay);
            [NSThread sleepForTimeInterval:startupDelay];
        }

        RunAppIntent(bundle, intent, params);

        if (ShouldKeepProcessAlive()) {
            NSLog(@"[BSIRI] BSIRI_NO_EXIT=1, keeping process alive");
            return;
        }

        exit(0);
    }
}

static void ScheduleConfiguredIntentOnMainQueue(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ExecuteConfiguredIntent();
    });
}

static unsigned long long OutputBehaviorFromEnv(void) {
    const char *raw = getenv("BSIRI_OUTPUT_BEHAVIOR");
    if (!raw || !raw[0]) {
        // WFWorkflowRunRequest output behavior:
        // 0 = default, 1 = ignore, 2 = implicit(last), 3 = all action outputs
        return 2;
    }

    unsigned long long value = strtoull(raw, NULL, 10);
    return value;
}

static BOOL WaitForCapture(WFWorkflowRunnerCapture *capture, NSTimeInterval timeoutSeconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while ([until timeIntervalSinceNow] > 0 && !capture.finished) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }
    return capture.finished;
}

static NSDictionary *BuildActionDict(NSString *bundleID, NSString *intentID, NSDictionary *params) {
    NSMutableDictionary *descriptor = [NSMutableDictionary new];
    descriptor[@"AppIntentIdentifier"] = intentID;
    descriptor[@"BundleIdentifier"] = bundleID;
    descriptor[@"Name"] = [bundleID componentsSeparatedByString:@"."].lastObject ?: bundleID;

    NSMutableDictionary *actionParams = [NSMutableDictionary new];
    actionParams[@"AppIntentDescriptor"] = descriptor;
    actionParams[@"UUID"] = [[NSUUID UUID] UUIDString];
    if (params.count > 0) {
        [actionParams addEntriesFromDictionary:params];  // caller's UUID wins if provided
    }

    NSString *fqIdentifier = [NSString stringWithFormat:@"%@.%@", bundleID, intentID];
    return @{
        @"WFWorkflowActionIdentifier": fqIdentifier,
        @"WFWorkflowActionParameters": actionParams
    };
}

static NSArray<NSString *> *AppendActionIDsFromEnv(void) {
    const char *raw = getenv("BSIRI_APPEND_ACTION_IDS");
    if (!raw || !raw[0]) return @[];

    NSString *csv = [NSString stringWithUTF8String:raw];
    NSArray<NSString *> *parts = [csv componentsSeparatedByString:@","];
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    for (NSString *part in parts) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            [ids addObject:trimmed];
        }
    }
    return ids;
}

static NSDictionary *BuildSimpleAction(NSString *identifier) {
    if (identifier.length == 0) return nil;
    return @{
        @"WFWorkflowActionIdentifier": identifier,
        @"WFWorkflowActionParameters": @{ @"UUID": [[NSUUID UUID] UUIDString] }
    };
}


static NSArray<NSDictionary *> *AppendActionsFromJSONEnv(void) {
    const char *raw = getenv("BSIRI_APPEND_ACTIONS_JSON");
    if (!raw || !raw[0]) return @[];

    NSString *jsonString = [NSString stringWithUTF8String:raw];
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @[];

    NSError *err = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![parsed isKindOfClass:[NSArray class]]) {
        NSLog(@"[BSIRI] Failed to parse BSIRI_APPEND_ACTIONS_JSON: %@", err);
        return @[];
    }

    NSMutableArray<NSDictionary *> *actions = [NSMutableArray new];
    for (id entry in (NSArray *)parsed) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *dict = (NSDictionary *)entry;

        NSString *identifier = dict[@"WFWorkflowActionIdentifier"];
        if (identifier.length == 0) identifier = dict[@"id"];
        if (identifier.length == 0) continue;

        id rawParams = dict[@"WFWorkflowActionParameters"] ?: dict[@"params"];
        NSMutableDictionary *params = [NSMutableDictionary new];
        if ([rawParams isKindOfClass:[NSDictionary class]]) {
            [params addEntriesFromDictionary:(NSDictionary *)rawParams];
        }
        if (!params[@"UUID"]) {
            params[@"UUID"] = [[NSUUID UUID] UUIDString];
        }

        [actions addObject:@{
            @"WFWorkflowActionIdentifier": identifier,
            @"WFWorkflowActionParameters": params
        }];
    }

    return actions;
}

static id BuildRunRequest(NSString *bundleID) {
    Class ReqCls = NSClassFromString(@"WFWorkflowRunRequest");
    if (!ReqCls) return nil;

    SEL initSel = NSSelectorFromString(@"initWithInput:presentationMode:");
    if (![ReqCls instancesRespondToSelector:initSel]) return nil;

    id req = ((id(*)(id,SEL,id,long long))objc_msgSend)([ReqCls alloc], initSel, nil, 0);
    if (!req) return nil;

    if ([req respondsToSelector:@selector(setOutputBehavior:)]) {
        unsigned long long outputBehavior = OutputBehaviorFromEnv();
        ((void(*)(id,SEL,unsigned long long))objc_msgSend)(req, @selector(setOutputBehavior:), outputBehavior);
    }
    if ([req respondsToSelector:@selector(setHandlesDialogRequests:)]) {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(req, @selector(setHandlesDialogRequests:), YES);
    }
    if ([req respondsToSelector:@selector(setHandlesSiriActionRequests:)]) {
        ((void(*)(id,SEL,BOOL))objc_msgSend)(req, @selector(setHandlesSiriActionRequests:), YES);
    }
    NSString *parentBundle = @"com.apple.shortcuts.ShortcutsCommandLine";
    const char *parentRaw = getenv("BSIRI_PARENT_BUNDLE");
    if (parentRaw && parentRaw[0]) {
        parentBundle = [NSString stringWithUTF8String:parentRaw];
    } else if (bundleID.length > 0) {
        parentBundle = bundleID;
    }

    if ([req respondsToSelector:@selector(setParentBundleIdentifier:)]) {
        ((void(*)(id,SEL,id))objc_msgSend)(req, @selector(setParentBundleIdentifier:), parentBundle);
    }
    if ([req respondsToSelector:@selector(setRunSource:)]) {
        id runSourceObj = RunSourceObjectFromEnv();
        if (runSourceObj) {
            ((void(*)(id,SEL,id))objc_msgSend)(req, @selector(setRunSource:), runSourceObj);
        }
    }

    NSLog(@"[BSIRI] Built run request: %@", req);
    return req;
}

static BOOL RunWithWorkflowDescriptor(id descriptor, NSString *bundleID, NSTimeInterval timeoutSeconds, NSString *pathLabel, id *outputOut) {
    if (!descriptor) {
        NSLog(@"[BSIRI] %@ descriptor is nil", pathLabel);
        return NO;
    }

    id request = BuildRunRequest(bundleID);
    if (!request) {
        NSLog(@"[BSIRI] %@ failed to create WFWorkflowRunRequest", pathLabel);
        return NO;
    }

    Class ClientCls = NSClassFromString(@"WFWorkflowRunnerClient");
    if (!ClientCls) {
        NSLog(@"[BSIRI] %@ WFWorkflowRunnerClient class not found", pathLabel);
        return NO;
    }

    SEL initClientSel = NSSelectorFromString(@"initWithDescriptor:runRequest:");
    if (![ClientCls instancesRespondToSelector:initClientSel]) {
        NSLog(@"[BSIRI] %@ WFWorkflowRunnerClient initWithDescriptor:runRequest: unavailable", pathLabel);
        return NO;
    }

    id client = ((id(*)(id,SEL,id,id))objc_msgSend)([ClientCls alloc], initClientSel, descriptor, request);
    if (!client) {
        NSLog(@"[BSIRI] %@ failed to create WFWorkflowRunnerClient", pathLabel);
        return NO;
    }

    WFWorkflowRunnerCapture *capture = [WFWorkflowRunnerCapture new];
    SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
    if ([client respondsToSelector:setDelegateSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(client, setDelegateSel, capture);
    }
    SEL setDelegateQueueSel = NSSelectorFromString(@"setDelegateQueue:");
    if ([client respondsToSelector:setDelegateQueueSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(client, setDelegateQueueSel, dispatch_get_main_queue());
    }

    SEL startSel = NSSelectorFromString(@"start");
    if (![client respondsToSelector:startSel]) {
        NSLog(@"[BSIRI] %@ WFWorkflowRunnerClient.start unavailable", pathLabel);
        return NO;
    }

    NSLog(@"[BSIRI] Starting %@ via WFWorkflowRunnerClient...", pathLabel);
    ((void(*)(id,SEL))objc_msgSend)(client, startSel);

    if (!WaitForCapture(capture, timeoutSeconds)) {
        NSLog(@"[BSIRI] %@ timed out after %.1fs", pathLabel, timeoutSeconds);
        DumpResultObject([NSString stringWithFormat:@"%@.state.output", pathLabel], SafeValueForKey(client, @"output"));
        DumpResultObject([NSString stringWithFormat:@"%@.state.result", pathLabel], SafeValueForKey(client, @"result"));
        DumpResultObject([NSString stringWithFormat:@"%@.state.allResults", pathLabel], SafeValueForKey(client, @"allResults"));
        DumpResultObject([NSString stringWithFormat:@"%@.state.error", pathLabel], SafeValueForKey(client, @"error"));
        return NO;
    }

    if (capture.error) {
        NSLog(@"[BSIRI] %@ error: %@", pathLabel, capture.error);
        return NO;
    }
    if (capture.cancelled) {
        NSLog(@"[BSIRI] %@ cancelled", pathLabel);
        return NO;
    }

    id result = capture.output ?: capture.allResults;
    if (!result) {
        result = SafeValueForKey(client, @"result") ?: SafeValueForKey(client, @"output") ?: SafeValueForKey(client, @"allResults");
    }

    DumpResultObject([NSString stringWithFormat:@"%@.result", pathLabel], result);
    if (outputOut) *outputOut = result;

    if (!result && ShouldRequireOutput()) {
        NSLog(@"[BSIRI] %@ produced nil output and BSIRI_REQUIRE_OUTPUT=1", pathLabel);
        return NO;
    }
    return YES;
}

static BOOL RunViaWorkflowRunnerClient(NSData *workflowData, NSString *bundleID, NSTimeInterval timeoutSeconds, id *outputOut) {
    Class DescCls = NSClassFromString(@"WFWorkflowDataRunDescriptor");
    if (!DescCls) {
        NSLog(@"[BSIRI] WFWorkflowDataRunDescriptor class not found");
        return NO;
    }

    SEL initDescSel = NSSelectorFromString(@"initWithWorkflowData:");
    if (![DescCls instancesRespondToSelector:initDescSel]) {
        NSLog(@"[BSIRI] WFWorkflowDataRunDescriptor initWithWorkflowData: unavailable");
        return NO;
    }

    id descriptor = ((id(*)(id,SEL,id))objc_msgSend)([DescCls alloc], initDescSel, workflowData);
    if (!descriptor) {
        NSLog(@"[BSIRI] Failed to create WFWorkflowDataRunDescriptor");
        return NO;
    }

    return RunWithWorkflowDescriptor(descriptor, bundleID, timeoutSeconds, @"WFWorkflowRunnerClient", outputOut);
}

static BOOL RunViaRunCompletion(id runner, NSString *bundleID, NSTimeInterval timeoutSeconds, id *outputOut) {
    if (!runner || !ShouldTryRunCompletionPath()) return NO;

    SEL runSel = NSSelectorFromString(@"runWorkflowWithRequest:descriptor:completion:");
    if (![runner respondsToSelector:runSel]) {
        NSLog(@"[BSIRI] runWorkflowWithRequest:descriptor:completion: unavailable on runner");
        return NO;
    }

    id request = BuildRunRequest(bundleID);
    __block BOOL done = NO;
    __block id resultOut = nil;
    __block NSError *errorOut = nil;

    void (^completion)(id, NSError *) = ^(id result, NSError *error) {
        resultOut = result;
        errorOut = error;
        done = YES;
    };

    NSLog(@"[BSIRI] Trying runWorkflowWithRequest:descriptor:completion: path");
    ((id(*)(id,SEL,id,id,id))objc_msgSend)(runner, runSel, request, nil, completion);

    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while ([until timeIntervalSinceNow] > 0 && !done) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }

    if (!done) {
        NSLog(@"[BSIRI] runWorkflowWithRequest completion timed out after %.1fs", timeoutSeconds);
        return NO;
    }
    if (errorOut) {
        NSLog(@"[BSIRI] runWorkflowWithRequest completion error: %@", errorOut);
        return NO;
    }

    DumpResultObject(@"Runner.completion.result", resultOut);
    if (outputOut) *outputOut = resultOut;
    if (!resultOut && ShouldRequireOutput()) {
        NSLog(@"[BSIRI] completion path produced nil output and BSIRI_REQUIRE_OUTPUT=1");
        return NO;
    }
    return YES;
}

static id StandardVCVoiceShortcutClient(void) {
    Class VCVoiceShortcutClient = NSClassFromString(@"VCVoiceShortcutClient");
    if (!VCVoiceShortcutClient) {
        NSLog(@"[BSIRI] VCVoiceShortcutClient class not found");
        return nil;
    }
    SEL standardClientSel = NSSelectorFromString(@"standardClient");
    if (![VCVoiceShortcutClient respondsToSelector:standardClientSel]) {
        NSLog(@"[BSIRI] VCVoiceShortcutClient.standardClient unavailable");
        return nil;
    }
    id client = ((id(*)(id,SEL))objc_msgSend)(VCVoiceShortcutClient, standardClientSel);
    if (!client) {
        NSLog(@"[BSIRI] VCVoiceShortcutClient.standardClient returned nil");
    }
    return client;
}

static id VCLinkActionForIntent(id client, NSString *bundleID, NSString *intentID, NSDictionary *params) {
    SEL linkSel = NSSelectorFromString(@"linkActionWithAppBundleIdentifier:appIntentIdentifier:serializedParameterStates:error:");
    if (!client || ![client respondsToSelector:linkSel]) {
        NSLog(@"[BSIRI] VCVoiceShortcutClient.linkActionWithAppBundleIdentifier:... unavailable");
        return nil;
    }

    NSError *err = nil;
    id serializedStates = params.count > 0 ? params : nil;
    id action = ((id(*)(id,SEL,id,id,id,NSError **))objc_msgSend)(client, linkSel, bundleID, intentID, serializedStates, &err);
    if (!action && serializedStates) {
        err = nil;
        action = ((id(*)(id,SEL,id,id,id,NSError **))objc_msgSend)(client, linkSel, bundleID, intentID, nil, &err);
    }
    if (err) {
        NSLog(@"[BSIRI] VC linkAction error: %@", err);
    }
    if (action) {
        DumpResultObject(@"VC.linkAction", action);
    }
    return action;
}

static id VCGetValueForDescriptor(id client, id descriptor, NSString *label) {
    if (!client || !descriptor) return nil;

    SEL getValueSel = NSSelectorFromString(@"getValueForDescriptor:resultClass:error:");
    if (![client respondsToSelector:getValueSel]) {
        NSLog(@"[BSIRI] VCVoiceShortcutClient.getValueForDescriptor:resultClass:error: unavailable");
        return nil;
    }

    Class classCandidates[] = {
        Nil,
        [NSObject class],
        [NSDictionary class],
        [NSArray class],
        NSClassFromString(@"LNQueryOutput"),
        NSClassFromString(@"LNActionOutput"),
        NSClassFromString(@"LNAction"),
        NSClassFromString(@"LNQueryRequest")
    };
    NSUInteger classCount = sizeof(classCandidates) / sizeof(classCandidates[0]);

    for (NSUInteger i = 0; i < classCount; i++) {
        Class resultClass = classCandidates[i];
        NSError *err = nil;
        id value = ((id(*)(id,SEL,id,id,NSError **))objc_msgSend)(client, getValueSel, descriptor, resultClass, &err);
        NSString *resultClassName = resultClass ? NSStringFromClass(resultClass) : @"(nil)";

        if (err) {
            NSLog(@"[BSIRI] %@ getValue error (resultClass=%@): %@", label, resultClassName, err);
        }
        if (value) {
            DumpResultObject([NSString stringWithFormat:@"%@.%@", label, resultClassName], value);
            return value;
        }
    }

    return nil;
}

static BOOL RunWithWFLinkActionExecutor(id wfLinkAction, NSString *bundleID, NSTimeInterval timeoutSeconds, NSString *label, id *outputOut) {
    if (!wfLinkAction) return NO;

    Class WFLinkActionExecutor = NSClassFromString(@"WFLinkActionExecutor");
    if (!WFLinkActionExecutor) {
        NSLog(@"[BSIRI] %@ WFLinkActionExecutor class not found", label);
        return NO;
    }

    SEL execInitSel = NSSelectorFromString(@"initWithLinkAction:appBundleIdentifier:extensionBundleIdentifier:authenticationPolicy:error:");
    if (![WFLinkActionExecutor instancesRespondToSelector:execInitSel]) {
        NSLog(@"[BSIRI] %@ WFLinkActionExecutor init unavailable", label);
        return NO;
    }

    NSError *initError = nil;
    id executor = ((id(*)(id,SEL,id,id,id,id,NSError **))objc_msgSend)([WFLinkActionExecutor alloc], execInitSel, wfLinkAction, bundleID, nil, nil, &initError);
    if (initError) {
        NSLog(@"[BSIRI] %@ executor init error: %@", label, initError);
        return NO;
    }
    if (!executor) {
        NSLog(@"[BSIRI] %@ executor init returned nil", label);
        return NO;
    }

    __block BOOL done = NO;
    __block id resultOut = nil;
    __block NSError *errorOut = nil;

    void (^completion)(id, NSError *) = ^(id result, NSError *error) {
        resultOut = result;
        errorOut = error;
        done = YES;
    };

    SEL performSel = NSSelectorFromString(@"performWithCompletionHandler:");
    if (![executor respondsToSelector:performSel]) {
        NSLog(@"[BSIRI] %@ performWithCompletionHandler unavailable", label);
        return NO;
    }

    NSLog(@"[BSIRI] Starting %@ executor...", label);
    ((void(*)(id,SEL,id))objc_msgSend)(executor, performSel, completion);

    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while ([until timeIntervalSinceNow] > 0 && !done) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }

    if (!done) {
        NSLog(@"[BSIRI] %@ executor timed out after %.1fs", label, timeoutSeconds);
        return NO;
    }

    if (errorOut) {
        NSLog(@"[BSIRI] %@ executor error: %@", label, errorOut);
        return NO;
    }

    DumpResultObject([NSString stringWithFormat:@"%@.result", label], resultOut);
    if (outputOut) *outputOut = resultOut;
    if (!resultOut && ShouldRequireOutput()) {
        NSLog(@"[BSIRI] %@ executor produced nil output and BSIRI_REQUIRE_OUTPUT=1", label);
        return NO;
    }
    return YES;
}

static BOOL RunViaVCSerializedWFLinkAction(id client, NSString *bundleID, NSString *intentID, id linkAction, NSTimeInterval timeoutSeconds, id *outputOut) {
    if (!ShouldTryVCSerializedExecutor()) {
        NSLog(@"[BSIRI] Skipping VC serialized WFLinkAction executor (set BSIRI_TRY_VC_SERIALIZED_EXECUTOR=1 to enable)");
        return NO;
    }

    if (!client || !linkAction) return NO;

    id actionMetadata = SafeValueForKey(linkAction, @"metadata");
    SEL serializeSel = NSSelectorFromString(@"serializedParametersForLinkAction:actionMetadata:error:");
    if (![client respondsToSelector:serializeSel]) {
        NSLog(@"[BSIRI] VC serializedParametersForLinkAction unavailable");
        return NO;
    }

    NSError *serErr = nil;
    id serialized = ((id(*)(id,SEL,id,id,NSError **))objc_msgSend)(client, serializeSel, linkAction, actionMetadata, &serErr);
    if (serErr) {
        NSLog(@"[BSIRI] VC serializedParametersForLinkAction error: %@", serErr);
    }
    if (!serialized) {
        return NO;
    }

    DumpResultObject(@"VC.serializedParameters", serialized);

    Class WFLinkAction = NSClassFromString(@"WFLinkAction");
    SEL providedSel = NSSelectorFromString(@"providedActionWithIdentifier:serializedParameters:");
    if (!WFLinkAction || ![WFLinkAction respondsToSelector:providedSel]) {
        NSLog(@"[BSIRI] WFLinkAction.providedActionWithIdentifier unavailable");
        return NO;
    }

    NSString *fqid = [NSString stringWithFormat:@"%@.%@", bundleID, intentID];
    id wfLinkAction = ((id(*)(id,SEL,id,id))objc_msgSend)(WFLinkAction, providedSel, fqid, serialized);
    if (!wfLinkAction) {
        NSLog(@"[BSIRI] VC serialized WFLinkAction creation failed");
        return NO;
    }

    DumpResultObject(@"VC.serializedWFLinkAction", wfLinkAction);
    return RunWithWFLinkActionExecutor(wfLinkAction, bundleID, timeoutSeconds, @"VCSerializedWFLinkAction", outputOut);
}

static id VCTryHarvestValue(id client, NSString *bundleID, NSString *intentID, id linkAction, id wfDescriptor) {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray new];

    if (wfDescriptor) {
        [candidates addObject:@{ @"label": @"VC.getValue.wfDescriptor", @"descriptor": wfDescriptor }];
    }
    if (linkAction) {
        [candidates addObject:@{ @"label": @"VC.getValue.linkAction", @"descriptor": linkAction }];
    }

    id linkMetadata = SafeValueForKey(linkAction, @"metadata");
    if (linkMetadata) {
        [candidates addObject:@{ @"label": @"VC.getValue.linkMetadata", @"descriptor": linkMetadata }];
    }

    Class LNMetadataProvider = NSClassFromString(@"LNMetadataProvider");
    if (LNMetadataProvider) {
        id provider = ((id(*)(id,SEL))objc_msgSend)([LNMetadataProvider alloc], NSSelectorFromString(@"init"));
        SEL actionSel = NSSelectorFromString(@"actionForBundleIdentifier:andActionIdentifier:error:");
        if (provider && [provider respondsToSelector:actionSel]) {
            NSError *metaErr = nil;
            id actionMeta = ((id(*)(id,SEL,id,id,NSError **))objc_msgSend)(provider, actionSel, bundleID, intentID, &metaErr);
            if (metaErr) {
                NSLog(@"[BSIRI] LNMetadataProvider action metadata error: %@", metaErr);
            }
            if (actionMeta) {
                [candidates addObject:@{ @"label": @"VC.getValue.actionMetadata", @"descriptor": actionMeta }];
            }
        }
    }

    for (NSDictionary *entry in candidates) {
        NSString *label = entry[@"label"];
        id descriptor = entry[@"descriptor"];
        id value = VCGetValueForDescriptor(client, descriptor, label);
        if (value) {
            return value;
        }
    }

    return nil;
}

static id BuildLinkActionRunDescriptor(id linkAction, NSString *bundleID, NSString *intentID) {
    Class DescriptorCls = NSClassFromString(@"WFLinkActionRunDescriptor");
    if (!DescriptorCls) {
        NSLog(@"[BSIRI] WFLinkActionRunDescriptor class not found");
        return nil;
    }

    id metadata = SafeValueForKey(linkAction, @"metadata");
    NSString *runID = [[NSUUID UUID] UUIDString];
    NSString *name = SafeValueForKey(metadata, @"name") ?: intentID;

    SEL initWithNameSel = NSSelectorFromString(@"initWithIdentifier:name:action:metadata:isAutoShortcut:");
    if ([DescriptorCls instancesRespondToSelector:initWithNameSel]) {
        @try {
            id descriptor = ((id(*)(id,SEL,id,id,id,id,BOOL))objc_msgSend)([DescriptorCls alloc], initWithNameSel, runID, name, linkAction, metadata, NO);
            if (descriptor) return descriptor;
        } @catch (NSException *e) {
            NSLog(@"[BSIRI] WFLinkActionRunDescriptor initWithIdentifier:name:... exception: %@", e);
        }
    }

    SEL initAutoSel = NSSelectorFromString(@"initWithIdentifier:action:metadata:isAutoShortcut:");
    if ([DescriptorCls instancesRespondToSelector:initAutoSel]) {
        @try {
            id descriptor = ((id(*)(id,SEL,id,id,id,BOOL))objc_msgSend)([DescriptorCls alloc], initAutoSel, runID, linkAction, metadata, NO);
            if (descriptor) return descriptor;
        } @catch (NSException *e) {
            NSLog(@"[BSIRI] WFLinkActionRunDescriptor initWithIdentifier:action:...isAutoShortcut exception: %@", e);
        }
    }

    SEL initSel = NSSelectorFromString(@"initWithIdentifier:action:metadata:");
    if ([DescriptorCls instancesRespondToSelector:initSel]) {
        @try {
            NSString *fqid = [NSString stringWithFormat:@"%@.%@", bundleID, intentID];
            id descriptor = ((id(*)(id,SEL,id,id,id))objc_msgSend)([DescriptorCls alloc], initSel, fqid, linkAction, metadata);
            if (descriptor) return descriptor;
        } @catch (NSException *e) {
            NSLog(@"[BSIRI] WFLinkActionRunDescriptor initWithIdentifier:action:metadata: exception: %@", e);
        }
    }

    return nil;
}

static BOOL RunViaVCLinkActionRunner(NSString *bundleID, NSString *intentID, NSDictionary *params, NSTimeInterval timeoutSeconds, id *outputOut) {
    id client = StandardVCVoiceShortcutClient();
    if (!client) return NO;

    id linkAction = VCLinkActionForIntent(client, bundleID, intentID, params);
    if (!linkAction) {
        NSLog(@"[BSIRI] VC linkAction path returned nil action");
        return NO;
    }

    if (RunViaVCSerializedWFLinkAction(client, bundleID, intentID, linkAction, timeoutSeconds, outputOut)) {
        return YES;
    }

    id descriptor = BuildLinkActionRunDescriptor(linkAction, bundleID, intentID);
    if (!descriptor) {
        NSLog(@"[BSIRI] Failed to create WFLinkActionRunDescriptor from VC action");
        return NO;
    }

    DumpResultObject(@"VC.linkActionDescriptor", descriptor);

    if (RunWithWorkflowDescriptor(descriptor, bundleID, timeoutSeconds, @"VCLinkActionRunner", outputOut)) {
        return YES;
    }

    id harvested = VCTryHarvestValue(client, bundleID, intentID, linkAction, descriptor);
    if (harvested) {
        if (outputOut) *outputOut = harvested;
        return YES;
    }

    Class AppRunnerCls = NSClassFromString(@"WFShortcutsAppRunnerClient");
    SEL initSel = NSSelectorFromString(@"initWithIdentifier:name:action:metadata:runSource:remoteDialogPresenterEndpoint:");
    if (!AppRunnerCls || ![AppRunnerCls instancesRespondToSelector:initSel]) {
        return NO;
    }

    id metadata = SafeValueForKey(linkAction, @"metadata");
    NSString *name = SafeValueForKey(metadata, @"name") ?: intentID;
    NSString *runIdentifier = [NSString stringWithFormat:@"%@.%@", bundleID, intentID];
    id runSourceObj = RunSourceObjectFromEnv() ?: @"spotlight";

    id runner = nil;
    @try {
        runner = ((id(*)(id,SEL,id,id,id,id,id,id))objc_msgSend)([AppRunnerCls alloc], initSel, runIdentifier, name, linkAction, metadata, runSourceObj, nil);
    } @catch (NSException *e) {
        NSLog(@"[BSIRI] VC app-runner init exception: %@", e);
        return NO;
    }
    if (!runner) {
        NSLog(@"[BSIRI] VC app-runner init returned nil");
        return NO;
    }

    WFWorkflowRunnerCapture *capture = [WFWorkflowRunnerCapture new];
    SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
    if ([runner respondsToSelector:setDelegateSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(runner, setDelegateSel, capture);
    }
    SEL setDelegateQueueSel = NSSelectorFromString(@"setDelegateQueue:");
    if ([runner respondsToSelector:setDelegateQueueSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(runner, setDelegateQueueSel, dispatch_get_main_queue());
    }

    SEL startSel = NSSelectorFromString(@"start");
    if (![runner respondsToSelector:startSel]) {
        NSLog(@"[BSIRI] VC app-runner has no start selector");
        return NO;
    }

    NSLog(@"[BSIRI] Starting VC app-runner fallback...");
    ((void(*)(id,SEL))objc_msgSend)(runner, startSel);

    if (!WaitForCapture(capture, timeoutSeconds)) {
        NSLog(@"[BSIRI] VC app-runner timed out after %.1fs", timeoutSeconds);
        return NO;
    }
    if (capture.error) {
        NSLog(@"[BSIRI] VC app-runner error: %@", capture.error);
        return NO;
    }
    if (capture.cancelled) {
        NSLog(@"[BSIRI] VC app-runner cancelled");
        return NO;
    }

    id result = capture.output ?: capture.allResults;
    if (!result) {
        result = SafeValueForKey(runner, @"result") ?: SafeValueForKey(runner, @"output") ?: SafeValueForKey(runner, @"allResults");
    }
    DumpResultObject(@"VCAppRunner.result", result);
    if (outputOut) *outputOut = result;

    if (!result) {
        id harvested = VCTryHarvestValue(client, bundleID, intentID, linkAction, descriptor);
        if (harvested) {
            if (outputOut) *outputOut = harvested;
            return YES;
        }
    }

    if (!result && ShouldRequireOutput()) {
        NSLog(@"[BSIRI] VC app-runner produced nil output and BSIRI_REQUIRE_OUTPUT=1");
        return NO;
    }
    return YES;
}

static BOOL RunViaVCVoiceShortcutClient(NSString *bundleID, NSString *intentID, NSDictionary *params, NSTimeInterval timeoutSeconds, id *outputOut) {
    if (RunViaVCLinkActionRunner(bundleID, intentID, params, timeoutSeconds, outputOut)) {
        return YES;
    }

    if (!ShouldTryVCLegacyWorkflow()) {
        NSLog(@"[BSIRI] Skipping legacy VC workflow path (set BSIRI_TRY_VC_LEGACY=1 to enable)");
        return NO;
    }

    Class INAppIntent = NSClassFromString(@"INAppIntent");
    if (!INAppIntent) {
        NSLog(@"[BSIRI] INAppIntent class not found");
        return NO;
    }

    SEL initAppIntentSel = NSSelectorFromString(@"initWithAppBundleIdentifier:appIntentIdentifier:serializedParameters:");
    if (![INAppIntent instancesRespondToSelector:initAppIntentSel]) {
        NSLog(@"[BSIRI] INAppIntent initWithAppBundleIdentifier:appIntentIdentifier:serializedParameters: unavailable");
        return NO;
    }

    id appIntent = ((id(*)(id,SEL,id,id,id))objc_msgSend)([INAppIntent alloc], initAppIntentSel, bundleID, intentID, params ?: @{});
    if (!appIntent) {
        NSLog(@"[BSIRI] Failed to create INAppIntent");
        return NO;
    }

    Class INShortcut = NSClassFromString(@"INShortcut");
    if (!INShortcut) {
        NSLog(@"[BSIRI] INShortcut class not found");
        return NO;
    }
    SEL initShortcutSel = NSSelectorFromString(@"initWithIntent:");
    if (![INShortcut instancesRespondToSelector:initShortcutSel]) {
        NSLog(@"[BSIRI] INShortcut initWithIntent: unavailable");
        return NO;
    }

    id shortcut = ((id(*)(id,SEL,id))objc_msgSend)([INShortcut alloc], initShortcutSel, appIntent);
    if (!shortcut) {
        NSLog(@"[BSIRI] Failed to create INShortcut");
        return NO;
    }

    Class WFWorkflow = NSClassFromString(@"WFWorkflow");
    if (!WFWorkflow) {
        NSLog(@"[BSIRI] WFWorkflow class not found");
        return NO;
    }
    SEL initWorkflowSel = NSSelectorFromString(@"initWithShortcut:error:");
    if (![WFWorkflow instancesRespondToSelector:initWorkflowSel]) {
        NSLog(@"[BSIRI] WFWorkflow initWithShortcut:error: unavailable");
        return NO;
    }

    NSError *wfError = nil;
    id workflow = ((id(*)(id,SEL,id,NSError **))objc_msgSend)([WFWorkflow alloc], initWorkflowSel, shortcut, &wfError);
    if (!workflow || wfError) {
        NSLog(@"[BSIRI] Failed to create WFWorkflow from INShortcut: %@", wfError);
        return NO;
    }

    id client = StandardVCVoiceShortcutClient();
    if (!client) {
        return NO;
    }

    SEL runSel = NSSelectorFromString(@"runShortcutIntentForWorkflow:error:");
    if (![client respondsToSelector:runSel]) {
        NSLog(@"[BSIRI] VCVoiceShortcutClient.runShortcutIntentForWorkflow:error: unavailable");
        return NO;
    }

    NSError *runError = nil;
    id result = nil;
    @try {
        result = ((id(*)(id,SEL,id,NSError **))objc_msgSend)(client, runSel, workflow, &runError);
    } @catch (NSException *e) {
        NSLog(@"[BSIRI] VCVoiceShortcutClient legacy run exception: %@", e);
        return NO;
    }
    if (runError) {
        NSLog(@"[BSIRI] VCVoiceShortcutClient run error: %@", runError);
        return NO;
    }

    if (outputOut) *outputOut = result;
    DumpResultObject(@"VCVoiceShortcutClient.result", result);
    return result != nil;
}

static NSData *BuildShortcutPlist(NSDictionary *action) {
    NSMutableArray *actions = [NSMutableArray arrayWithObject:action];

    for (NSString *actionID in AppendActionIDsFromEnv()) {
        NSDictionary *extra = BuildSimpleAction(actionID);
        if (extra) {
            [actions addObject:extra];
            NSLog(@"[BSIRI] Appended custom action id=%@", actionID);
        }
    }

    for (NSDictionary *extra in AppendActionsFromJSONEnv()) {
        [actions addObject:extra];
        NSLog(@"[BSIRI] Appended custom action from JSON id=%@", extra[@"WFWorkflowActionIdentifier"]);
    }

    if (EnvIsTruthy(getenv("BSIRI_APPEND_OUTPUT_ACTION"))) {
        NSDictionary *outputAction = @{
            @"WFWorkflowActionIdentifier": @"is.workflow.actions.output",
            @"WFWorkflowActionParameters": @{}
        };
        [actions addObject:outputAction];
        NSLog(@"[BSIRI] Appended Stop and Output action");
    }

    if (EnvIsTruthy(getenv("BSIRI_APPEND_SHOWRESULT_ACTION"))) {
        NSDictionary *showAction = @{
            @"WFWorkflowActionIdentifier": @"is.workflow.actions.showresult",
            @"WFWorkflowActionParameters": @{}
        };
        [actions addObject:showAction];
        NSLog(@"[BSIRI] Appended Show Content action");
    }

    NSDictionary *plist = @{
        @"WFWorkflowClientVersion": @"700",
        @"WFWorkflowClientRelease": @"2.0",
        @"WFWorkflowMinimumClientVersion": @900,
        @"WFWorkflowMinimumClientVersionString": @"900",
        @"WFWorkflowActions": actions,
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
    return [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

static void RunAppIntent(NSString *bundleID, NSString *intentID, NSDictionary *params) {
    NSLog(@"[BSIRI] Running App Intent: %@.%@", bundleID, intentID);
    NSString *fqid = [NSString stringWithFormat:@"%@.%@", bundleID, intentID];
    NSTimeInterval timeoutSeconds = TimeoutFromEnv(45.0);
    BOOL tryLinkExecutor = EnvIsTruthy(getenv("BSIRI_TRY_LINK_EXECUTOR"));
    BOOL tryLNExecutor = EnvIsTruthy(getenv("BSIRI_TRY_LN_EXECUTOR"));
    BOOL attachRunRequest = EnvIsTruthy(getenv("BSIRI_ATTACH_RUNREQUEST"));
    BOOL tryVCClient = EnvIsTruthy(getenv("BSIRI_TRY_VC_CLIENT"));
    BOOL tryWorkflowRunner = EnvIsTruthy(getenv("BSIRI_TRY_WORKFLOW_RUNNER"));

    // Try LNActionExecutor first — it handles Entity<T> outputs that hang other runners
    if (tryLNExecutor) {
        NSLog(@"[BSIRI] Trying LNActionExecutor path...");
        id lnOut = nil;
        if (RunViaLNActionExecutor(bundleID, intentID, timeoutSeconds, &lnOut)) {
            NSLog(@"[BSIRI] LNActionExecutor path succeeded");
            return;
        }
        NSLog(@"[BSIRI] LNActionExecutor path failed, continuing...");
    }

    BOOL vcThenPlist = EnvIsTruthy(getenv("BSIRI_VC_THEN_PLIST"));

    if (tryVCClient) {
        NSLog(@"[BSIRI] Trying VCVoiceShortcutClient path...");
        id vcOut = nil;
        if (RunViaVCVoiceShortcutClient(bundleID, intentID, params, timeoutSeconds, &vcOut)) {
            NSLog(@"[BSIRI] VCVoiceShortcutClient path succeeded (output=%@)", vcOut ?: @"nil");

            // If VC_THEN_PLIST mode: fire primary via VC, then run appended actions separately
            if (vcThenPlist) {
                NSArray<NSDictionary *> *extraActions = AppendActionsFromJSONEnv();
                if (extraActions.count > 0) {
                    NSLog(@"[BSIRI] VC_THEN_PLIST: running %lu appended actions via plist runner...", (unsigned long)extraActions.count);
                    NSData *extraPlist = [NSPropertyListSerialization dataWithPropertyList:@{
                        @"WFWorkflowClientVersion": @"900",
                        @"WFWorkflowClientRelease": @"2.0",
                        @"WFWorkflowMinimumClientVersion": @900,
                        @"WFWorkflowMinimumClientVersionString": @"900",
                        @"WFWorkflowActions": extraActions,
                        @"WFWorkflowTypes": @[@"NCWidget", @"WatchKit"],
                        @"WFWorkflowInputContentItemClasses": @[],
                        @"WFWorkflowImportQuestions": @[],
                        @"WFWorkflowIcon": @{
                            @"WFWorkflowIconGlyphNumber": @59511,
                            @"WFWorkflowIconImageData": [NSData data],
                            @"WFWorkflowIconStartColor": @431817727
                        }
                    } format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];

                    Class WFShortcutsAppRunnerClient = NSClassFromString(@"WFShortcutsAppRunnerClient");
                    SEL initSel = NSSelectorFromString(@"initWithWorkflowData:runSource:");
                    id runner = ((id(*)(id,SEL,id,id))objc_msgSend)([WFShortcutsAppRunnerClient alloc], initSel, extraPlist, @0);
                    if (runner) {
                        WFWorkflowRunnerCapture *cap = [WFWorkflowRunnerCapture new];
                        ((void(*)(id,SEL,id))objc_msgSend)(runner, NSSelectorFromString(@"setDelegate:"), cap);

                        id req = BuildRunRequest(bundleID);
                        if (req && [runner respondsToSelector:NSSelectorFromString(@"setRunRequest:")]) {
                            ((void(*)(id,SEL,id))objc_msgSend)(runner, NSSelectorFromString(@"setRunRequest:"), req);
                        }

                        NSLog(@"[BSIRI] VC_THEN_PLIST: starting plist runner...");
                        ((void(*)(id,SEL))objc_msgSend)(runner, NSSelectorFromString(@"start"));

                        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
                        while ([until timeIntervalSinceNow] > 0 && !cap.finished) {
                            @autoreleasepool {
                                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                            }
                        }
                        if (cap.finished) {
                            NSLog(@"[BSIRI] VC_THEN_PLIST: plist runner finished, error=%@", cap.error);
                        } else {
                            NSLog(@"[BSIRI] VC_THEN_PLIST: plist runner timed out");
                        }
                    }
                }
            }
            return;
        }
        NSLog(@"[BSIRI] VCVoiceShortcutClient path failed, continuing");
    }

    // Approach 0: Use WFLinkActionExecutor with metadata (best when inside shortcuts process)
    Class WFAppIntentsMetadataProvider = NSClassFromString(@"WFAppIntentsMetadataProvider");
    if (tryLinkExecutor && WFAppIntentsMetadataProvider) {
        SEL sharedSel = NSSelectorFromString(@"sharedProvider");
        id provider = ((id(*)(id,SEL))objc_msgSend)(WFAppIntentsMetadataProvider, sharedSel);

        SEL actionSel = NSSelectorFromString(@"actionWithIdentifier:fromBundleIdentifier:");
        id metadata = ((id(*)(id,SEL,id,id))objc_msgSend)(provider, actionSel, intentID, bundleID);
        NSLog(@"[BSIRI] Got action metadata: %@", metadata ? @"Yes" : @"No");

        if (metadata) {
            // Create WFLinkAction with proper init that includes metadata
            Class WFLinkAction = NSClassFromString(@"WFLinkAction");
            SEL linkInitSel = NSSelectorFromString(@"initWithIdentifier:metadata:definition:serializedParameters:appIntentDescriptor:fullyQualifiedActionIdentifier:");

            if ([WFLinkAction instancesRespondToSelector:linkInitSel]) {
                NSDictionary *descriptor = @{
                    @"AppIntentIdentifier": intentID,
                    @"BundleIdentifier": bundleID,
                    @"Name": [bundleID componentsSeparatedByString:@"."].lastObject ?: bundleID
                };

                NSMutableDictionary *serialized = [NSMutableDictionary new];
                if (params.count > 0) {
                    [serialized addEntriesFromDictionary:params];
                }

                @try {
                    id linkAction = ((id(*)(id,SEL,id,id,id,id,id,id))objc_msgSend)(
                        [WFLinkAction alloc], linkInitSel,
                        intentID,        // identifier (just intentID, not FQ)
                        metadata,        // metadata from provider
                        nil,             // definition
                        serialized,      // serializedParameters
                        descriptor,      // appIntentDescriptor
                        fqid             // fullyQualifiedActionIdentifier
                    );
                    NSLog(@"[BSIRI] Created WFLinkAction with metadata: %@", linkAction);

                    if (linkAction) {
                        // Use WFLinkActionExecutor
                        Class WFLinkActionExecutor = NSClassFromString(@"WFLinkActionExecutor");
                        SEL execInitSel = NSSelectorFromString(@"initWithLinkAction:appBundleIdentifier:extensionBundleIdentifier:authenticationPolicy:error:");

                        if ([WFLinkActionExecutor instancesRespondToSelector:execInitSel]) {
                            NSError *initError = nil;
                            id executor = ((id(*)(id,SEL,id,id,id,id,id*))objc_msgSend)(
                                [WFLinkActionExecutor alloc], execInitSel,
                                linkAction, bundleID, nil, nil, &initError
                            );

                            if (initError) {
                                NSLog(@"[BSIRI] WFLinkActionExecutor init error: %@", initError);
                            } else if (executor) {
                                NSLog(@"[BSIRI] Created WFLinkActionExecutor: %@", executor);

                                __block BOOL done = NO;
                                __block id resultOut = nil;
                                __block NSError *errorOut = nil;

                                void (^completion)(id, NSError *) = ^(id result, NSError *error) {
                                    NSLog(@"[BSIRI] WFLinkActionExecutor completed: result=%@, error=%@", result, error);
                                    resultOut = result;
                                    errorOut = error;
                                    done = YES;
                                };

                                SEL performSel = NSSelectorFromString(@"performWithCompletionHandler:");
                                NSLog(@"[BSIRI] Starting WFLinkActionExecutor...");
                                ((void(*)(id,SEL,id))objc_msgSend)(executor, performSel, completion);

                                NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
                                while ([until timeIntervalSinceNow] > 0 && !done) {
                                    @autoreleasepool {
                                        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                                    }
                                }

                                if (done) {
                                    if (errorOut) {
                                        NSLog(@"[BSIRI] WFLinkActionExecutor error: %@", errorOut);
                                    } else {
                                        NSLog(@"[BSIRI] WFLinkActionExecutor success");
                                        DumpResultObject(@"WFLinkActionExecutor.result", resultOut);
                                        return;
                                    }
                                } else {
                                    NSLog(@"[BSIRI] WFLinkActionExecutor timeout");
                                }
                            }
                        }
                    }
                } @catch (NSException *e) {
                    NSLog(@"[BSIRI] WFLinkActionExecutor exception: %@", e);
                }
            }
        }
    }

    if (!tryLinkExecutor) {
        NSLog(@"[BSIRI] Skipping WFLinkActionExecutor (set BSIRI_TRY_LINK_EXECUTOR=1 to enable)");
    }

    NSLog(@"[BSIRI] WFLinkActionExecutor failed, falling back to plist approach...");

    NSDictionary *action = BuildActionDict(bundleID, intentID, params);
    NSData *plistData = BuildShortcutPlist(action);

    if (!plistData) {
        NSLog(@"[BSIRI] Failed to build plist");
        return;
    }
    NSLog(@"[BSIRI] Built plist: %lu bytes", (unsigned long)plistData.length);

    if (tryWorkflowRunner) {
        id wfRunnerOut = nil;
        if (RunViaWorkflowRunnerClient(plistData, bundleID, timeoutSeconds, &wfRunnerOut)) {
            NSLog(@"[BSIRI] WFWorkflowRunnerClient path succeeded");
            return;
        }
        NSLog(@"[BSIRI] WFWorkflowRunnerClient path failed; trying WFShortcutsAppRunnerClient...");
    }

    Class WFShortcutsAppRunnerClient = NSClassFromString(@"WFShortcutsAppRunnerClient");
    if (!WFShortcutsAppRunnerClient) {
        NSLog(@"[BSIRI] WFShortcutsAppRunnerClient not found");
        return;
    }

    long long runSource = 0;
    const char *runSourceRaw = getenv("BSIRI_RUN_SOURCE");
    if (runSourceRaw && runSourceRaw[0]) {
        runSource = strtoll(runSourceRaw, NULL, 10);
    }

    SEL initSel = NSSelectorFromString(@"initWithWorkflowData:runSource:");
    id runner = ((id(*)(id,SEL,id,id))objc_msgSend)([WFShortcutsAppRunnerClient alloc], initSel, plistData, @(runSource));
    if (!runner) {
        NSLog(@"[BSIRI] Failed to create runner");
        return;
    }
    NSLog(@"[BSIRI] Created runner: %@ (runSource=%lld)", runner, runSource);

    WFWorkflowRunnerCapture *capture = [WFWorkflowRunnerCapture new];
    SEL setDelegateSel = NSSelectorFromString(@"setDelegate:");
    if ([runner respondsToSelector:setDelegateSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(runner, setDelegateSel, capture);
    }
    SEL setDelegateQueueSel = NSSelectorFromString(@"setDelegateQueue:");
    if ([runner respondsToSelector:setDelegateQueueSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(runner, setDelegateQueueSel, dispatch_get_main_queue());
    }

    if (attachRunRequest) {
        id request = BuildRunRequest(bundleID);
        if (request && [runner respondsToSelector:NSSelectorFromString(@"setRunRequest:")]) {
            ((void(*)(id,SEL,id))objc_msgSend)(runner, NSSelectorFromString(@"setRunRequest:"), request);
            NSLog(@"[BSIRI] Attached WFWorkflowRunRequest with outputBehavior=1");
        } else {
            NSLog(@"[BSIRI] Unable to attach WFWorkflowRunRequest");
        }
    } else {
        NSLog(@"[BSIRI] Running with default request (set BSIRI_ATTACH_RUNREQUEST=1 to override)");
    }

    id completionOut = nil;
    if (RunViaRunCompletion(runner, bundleID, timeoutSeconds, &completionOut)) {
        NSLog(@"[BSIRI] runWorkflowWithRequest completion path succeeded");
        return;
    }

    SEL startSel = NSSelectorFromString(@"start");
    NSLog(@"[BSIRI] Starting runner...");
    ((void(*)(id,SEL))objc_msgSend)(runner, startSel);

    // Wait for completion
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds];
    while ([until timeIntervalSinceNow] > 0 && !capture.finished) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }

    if (capture.finished) {
        if (capture.error) {
            NSLog(@"[BSIRI] Error: %@", capture.error);
        } else if (capture.cancelled) {
            NSLog(@"[BSIRI] Cancelled");
        } else {
            NSLog(@"[BSIRI] Runner success");
            DumpResultObject(@"Runner.output", capture.output);
            DumpResultObject(@"Runner.allResults", capture.allResults);
            DumpResultObject(@"Runner.state.output", SafeValueForKey(runner, @"output"));
            DumpResultObject(@"Runner.state.result", SafeValueForKey(runner, @"result"));
            DumpResultObject(@"Runner.state.allResults", SafeValueForKey(runner, @"allResults"));
            DumpResultObject(@"Runner.state.error", SafeValueForKey(runner, @"error"));
        }
    } else {
        NSLog(@"[BSIRI] Timeout after %.1fs", timeoutSeconds);
        DumpResultObject(@"Runner.state.output", SafeValueForKey(runner, @"output"));
        DumpResultObject(@"Runner.state.result", SafeValueForKey(runner, @"result"));
        DumpResultObject(@"Runner.state.allResults", SafeValueForKey(runner, @"allResults"));
        DumpResultObject(@"Runner.state.error", SafeValueForKey(runner, @"error"));
    }
}

static void RunEntityQuery(void) {
    const char *rawSearch = getenv("BSIRI_ENTITY_SEARCH");
    const char *rawMangled = getenv("BSIRI_ENTITY_MANGLED_TYPE");
    const char *rawBundleID = getenv("BSIRI_ENTITY_BUNDLE_ID");
    if (!rawSearch || !rawSearch[0] || !rawMangled || !rawMangled[0]) return;

    NSString *searchTerm = [NSString stringWithUTF8String:rawSearch];
    NSString *mangledType = [NSString stringWithUTF8String:rawMangled];
    NSString *bundleID = rawBundleID ? [NSString stringWithUTF8String:rawBundleID] : nil;
    NSTimeInterval timeout = TimeoutFromEnv(10.0);

    NSLog(@"[BSIRI] Entity query: search='%@' type='%@' bundle='%@'", searchTerm, mangledType, bundleID ?: @"(nil)");

    // Load LinkServices
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/LinkServices.framework"] loadAndReturnError:nil];

    // Create query request
    Class LNQueryRequest = NSClassFromString(@"LNQueryRequest");
    SEL initStrSel = NSSelectorFromString(@"initWithString:entityMangledTypeName:");
    id query = ((id(*)(id,SEL,id,id))objc_msgSend)([LNQueryRequest alloc], initStrSel, searchTerm, mangledType);
    if (!query) { NSLog(@"[BSIRI] Failed to create LNQueryRequest"); exit(1); }

    // Get metadata provider
    NSLog(@"[BSIRI] Getting metadata provider...");
    Class providerCls = NSClassFromString(@"WFAppIntentsMetadataProvider");
    id provider = nil;
    if (providerCls) {
        SEL sharedSel = NSSelectorFromString(@"sharedProvider");
        if ([providerCls respondsToSelector:sharedSel]) {
            @try {
                provider = ((id(*)(id,SEL))objc_msgSend)(providerCls, sharedSel);
            } @catch (NSException *e) {
                NSLog(@"[BSIRI] Provider exception: %@", e);
            }
        }
    }
    NSLog(@"[BSIRI] Provider: %@", provider ?: @"nil");

    // Try to perform query through the provider or its internal connection manager
    // Dump provider methods to find query-related ones
    NSLog(@"[BSIRI] Provider methods with 'query' or 'entity' or 'connection':");
    unsigned int mc = 0;
    Method *ml = class_copyMethodList([provider class], &mc);
    for (unsigned int j = 0; j < mc; j++) {
        const char *sel = sel_getName(method_getName(ml[j]));
        if (strstr(sel, "uery") || strstr(sel, "ntit") || strstr(sel, "onnect") || strstr(sel, "earch"))
            NSLog(@"  - %s", sel);
    }
    if (ml) free(ml);

    // Try performQuery directly on the provider
    SEL performQuerySel = NSSelectorFromString(@"performQuery:forBundleIdentifier:completionHandler:");
    if ([provider respondsToSelector:performQuerySel]) {
        NSLog(@"[BSIRI] Using provider.performQuery:forBundleIdentifier:");
    }

    // Try entity resolution through a different path
    // Check if there's a resolveEntity or fetchOptions method
    SEL fetchOptsSel = NSSelectorFromString(@"fetchOptionsForAction:actionMetadata:parameterMetadata:searchTerm:localeIdentifier:completionHandler:");

    // LNConnection crashes consistently when created manually.
    // Entity queries need a different approach — possibly through WFPerformQueryDialogRequest
    // or by building a shortcut that uses the entity parameter picker.
    NSLog(@"[BSIRI] Entity query not yet supported — LNConnection cannot be created in this context");
    printf("[]\n");
    exit(1);
}

static void RunWorkflowFromPlistFile(void) {
    const char *plistPath = getenv("BSIRI_WORKFLOW_PLIST");
    if (!plistPath || !plistPath[0]) return;

    NSString *path = [NSString stringWithUTF8String:plistPath];
    NSData *fileData = [NSData dataWithContentsOfFile:path];
    if (!fileData) { NSLog(@"[BSIRI] Cannot read plist: %@", path); exit(1); }

    NSTimeInterval timeout = TimeoutFromEnv(30.0);
    NSLog(@"[BSIRI] Running workflow from plist: %@ (timeout=%.0fs)", path.lastPathComponent, timeout);

    Class WFShortcutsAppRunnerClient = NSClassFromString(@"WFShortcutsAppRunnerClient");
    if (!WFShortcutsAppRunnerClient) { NSLog(@"[BSIRI] WFShortcutsAppRunnerClient not found"); exit(1); }

    SEL initSel = NSSelectorFromString(@"initWithWorkflowData:runSource:");
    id runner = ((id(*)(id,SEL,id,id))objc_msgSend)([WFShortcutsAppRunnerClient alloc], initSel, fileData, @0);
    if (!runner) { NSLog(@"[BSIRI] Failed to create runner"); exit(1); }

    WFWorkflowRunnerCapture *capture = [WFWorkflowRunnerCapture new];
    ((void(*)(id,SEL,id))objc_msgSend)(runner, NSSelectorFromString(@"setDelegate:"), capture);

    id request = BuildRunRequest(nil);
    // Override output behavior from env if set
    unsigned long long outBehavior = OutputBehaviorFromEnv();
    if (request) {
        SEL setOutSel = NSSelectorFromString(@"setOutputBehavior:");
        if ([request respondsToSelector:setOutSel]) {
            ((void(*)(id,SEL,unsigned long long))objc_msgSend)(request, setOutSel, outBehavior);
        }
    }
    if (request && [runner respondsToSelector:NSSelectorFromString(@"setRunRequest:")]) {
        ((void(*)(id,SEL,id))objc_msgSend)(runner, NSSelectorFromString(@"setRunRequest:"), request);
    }

    NSLog(@"[BSIRI] Starting workflow runner...");
    ((void(*)(id,SEL))objc_msgSend)(runner, NSSelectorFromString(@"start"));

    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([until timeIntervalSinceNow] > 0 && !capture.finished) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }

    if (capture.finished) {
        if (capture.error) {
            NSLog(@"[BSIRI] Error: %@", capture.error);
        } else {
            NSLog(@"[BSIRI] Workflow completed successfully");
            DumpResultObject(@"Output", capture.output);
        }
    } else {
        NSLog(@"[BSIRI] Timeout after %.0fs", timeout);
    }

    exit(capture.finished && !capture.error && !capture.cancelled ? 0 : 1);
}

__attribute__((constructor))
void bsiri_injector_init(void) {
    @autoreleasepool {
        // Fast path: entity query
        if (getenv("BSIRI_ENTITY_SEARCH") && getenv("BSIRI_ENTITY_SEARCH")[0]) {
            RunEntityQuery();
            return;  // exit called inside
        }

        // Fast path: run a complete plist workflow directly
        const char *plistPath = getenv("BSIRI_WORKFLOW_PLIST");
        if (plistPath && plistPath[0]) {
            RunWorkflowFromPlistFile();
            return;  // exit(0/1) called inside
        }

        const char *bundleID = getenv("BSIRI_BUNDLE_ID");
        const char *intentID = getenv("BSIRI_INTENT_ID");
        if (!bundleID || !intentID) {
            NSLog(@"[BSIRI] Injector loaded but no BSIRI_BUNDLE_ID/BSIRI_INTENT_ID or BSIRI_WORKFLOW_PLIST set");
            return;
        }

        if (ShouldDeferToAppLaunch()) {
            NSLog(@"[BSIRI] Deferring execution until NSApplicationDidFinishLaunchingNotification");
            [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(__unused NSNotification *note) {
                NSLog(@"[BSIRI] Received NSApplicationDidFinishLaunchingNotification");
                ScheduleConfiguredIntentOnMainQueue();
            }];
            return;
        }

        if (ShouldAsyncStart()) {
            NSLog(@"[BSIRI] Scheduling async start on main queue");
            ScheduleConfiguredIntentOnMainQueue();
            return;
        }

        ExecuteConfiguredIntent();
    }
}
