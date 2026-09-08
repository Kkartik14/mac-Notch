import Foundation

// Swift-friendly bridge to the private MediaRemote framework.
// Provides just the symbols we need: register, get info, send command.
// All calls fail gracefully (no-ops) if the framework is unavailable.
enum MediaRemote {
    static func registerForNotifications(_ queue: DispatchQueue, handler: @escaping () -> Void) {
        guard let fn = mrRegister else { return }
        fn(queue, handler)
    }

    static func getNowPlayingInfo(_ queue: DispatchQueue, handler: @escaping ([AnyHashable: Any]?) -> Void) {
        guard let fn = mrGetInfo else { return }
        fn(queue, handler)
    }

    static func sendCommand(_ command: Command, _ options: Any? = nil) {
        guard let fn = mrSendCommand else { return }
        _ = fn(command.rawValue, options)
    }

    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }
}

private let mrHandle: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

private func mrSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    guard let h = mrHandle else { return nil }
    return dlsym(h, name)
}

// The MediaRemote framework uses a C API taking block callbacks.
// The functions themselves are C functions (@convention(c)); only the
// completion handlers are blocks (@convention(block)).
private let mrRegister: (@convention(c) (DispatchQueue, @escaping @convention(block) () -> Void) -> Void)? = {
    guard let sym = mrSymbol("MRMediaRemoteRegisterForNowPlayingNotifications") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (DispatchQueue, @escaping @convention(block) () -> Void) -> Void).self)
}()

private let mrGetInfo: (@convention(c) (DispatchQueue, @escaping @convention(block) ([AnyHashable: Any]?) -> Void) -> Void)? = {
    guard let sym = mrSymbol("MRMediaRemoteGetNowPlayingInfo") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (DispatchQueue, @escaping @convention(block) ([AnyHashable: Any]?) -> Void) -> Void).self)
}()

private let mrSendCommand: (@convention(c) (Int, Any?) -> Bool)? = {
    guard let sym = mrSymbol("MRMediaRemoteSendCommand") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Int, Any?) -> Bool).self)
}()
