import Foundation

@objc(WFAppIntentsProviderShim)
class WFAppIntentsProviderShim: NSObject {
    private static func loadPrivateFrameworks() {
        _ = Bundle(path: "/System/Library/PrivateFrameworks/AppIntentsServices.framework")?.load()
        _ = Bundle(path: "/System/Library/PrivateFrameworks/WorkflowKit.framework")?.load()
        _ = Bundle(path: "/System/Library/PrivateFrameworks/ContentKit.framework")?.load()
    }

    @objc static func makeProvider() -> AnyObject? {
        loadPrivateFrameworks()
        // Unable to build provider generically on this OS build without private Swift symbols.
        return nil
    }

    @objc static func listActions(_ bundleID: String) -> [String] {
        guard let provider = makeProvider() as? NSObject else { return [] }
        var result: [String] = []
        if provider.responds(to: Selector(("actionsForBundleIdentifier:"))) {
            if let arr = provider.perform(Selector(("actionsForBundleIdentifier:")), with: bundleID)?.takeUnretainedValue() as? [NSObject] {
                for a in arr {
                    var ident: String? = nil
                    if a.responds(to: Selector(("identifier"))) {
                        ident = a.perform(Selector(("identifier")))?.takeUnretainedValue() as? String
                    }
                    if ident == nil, a.responds(to: Selector(("actionIdentifier"))) {
                        ident = a.perform(Selector(("actionIdentifier")))?.takeUnretainedValue() as? String
                    }
                    if let s = ident { result.append(s) }
                }
            }
        }
        return result
    }

    private static func value(for obj: NSObject, keys: [String]) -> AnyObject? {
        for k in keys {
            let sel = Selector(k)
            if obj.responds(to: sel) {
                if let v = obj.perform(sel)?.takeUnretainedValue() { return v as AnyObject }
            }
            if let v = obj.value(forKey: k) as AnyObject? { return v }
        }
        return nil
    }

    @objc static func makeExecutionAction(bundleID: String, intentIdentifier: String, parameters: [String: Any]? = nil) -> AnyObject? {
        loadPrivateFrameworks()
        guard let provider = makeProvider() as? NSObject else { return nil }
        let actionSel = Selector(("actionWithIdentifier:fromBundleIdentifier:"))
        guard provider.responds(to: actionSel) else { return nil }
        guard let actionMeta = provider.perform(actionSel, with: intentIdentifier, with: bundleID)?.takeUnretainedValue() as? NSObject else { return nil }

        // Extract components from metadata object via dynamic selectors/KVC
        let metadata   = value(for: actionMeta, keys: ["metadata"]) as AnyObject?
        let definition = value(for: actionMeta, keys: ["definition"]) as AnyObject?
        let appDesc    = value(for: actionMeta, keys: ["appIntentDescriptor","appDescriptor","intentDescriptor"]) as AnyObject?
        let identifier = (value(for: actionMeta, keys: ["identifier","actionIdentifier","intentIdentifier"]) as? String)
            ?? intentIdentifier
        let fqid       = (value(for: actionMeta, keys: ["fullyQualifiedActionIdentifier","fullyQualifiedLinkActionIdentifier"]) as? String)
            ?? (bundleID + "." + intentIdentifier)

        guard let ActionCls = NSClassFromString("WFAppIntentExecutionAction") as? NSObject.Type else { return nil }
        let action = ActionCls.init()
        // Set bundle preference
        if action.responds(to: Selector(("setPreferredExtensionBundleIdentifier:"))) {
            _ = action.perform(Selector(("setPreferredExtensionBundleIdentifier:")), with: bundleID)
        }
        // Set core pieces via KVC where possible
        if let m = metadata { action.setValue(m, forKey: "metadata") }
        if let d = definition { action.setValue(d, forKey: "definition") }
        if let a = appDesc { action.setValue(a, forKey: "appIntentDescriptor") }
        action.setValue(identifier, forKey: "identifier")
        // Some builds use 'fullyQualifiedLinkActionIdentifier'
        if action.value(forKey: "fullyQualifiedLinkActionIdentifier") != nil {
            action.setValue(fqid, forKey: "fullyQualifiedLinkActionIdentifier")
        } else {
            action.setValue(fqid, forKey: "fullyQualifiedActionIdentifier")
        }
        if let params = parameters { action.setValue(params, forKey: "serializedParameters") }
        return action
    }

    @objc static func makeNotesCreateNoteAction(title: String, body: String) -> AnyObject? {
        // Attempt to find a create-note-like action id by scanning bundle actions
        let bundle = "com.apple.Notes"
        let ids = listActions(bundle)
        let cand = ids.first { $0.lowercased().contains("createnote") || $0.lowercased().contains("create_note") } ?? "CreateNoteIntent"
        return makeExecutionAction(bundleID: bundle, intentIdentifier: cand, parameters: ["title": title, "body": body])
    }
}
