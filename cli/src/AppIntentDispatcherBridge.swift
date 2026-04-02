import Foundation

private func loadFrameworks() {
    let path = "/System/Library/PrivateFrameworks/AppIntentsServices.framework"
    if let bundle = Bundle(path: path) {
        _ = try? bundle.loadAndReturnError()
    }
}

@_cdecl("GetInProcessDispatcherMetadata")
public func GetInProcessDispatcherMetadata() -> UnsafeRawPointer? {
    loadFrameworks()
    guard let type = _typeByName("AppIntentsServices.InProcessDispatcher") else { return nil }
    return unsafeBitCast(type, to: UnsafeRawPointer.self)
}

@objc(AppIntentDispatcherFactory)
public final class AppIntentDispatcherFactory: NSObject {
    @objc public static func makeDispatcher() -> AnyObject? {
        loadFrameworks()
        guard let type = _typeByName("AppIntentsServices.InProcessDispatcher") as? AnyObject.Type else {
            return nil
        }
        return type.init()
    }
}
