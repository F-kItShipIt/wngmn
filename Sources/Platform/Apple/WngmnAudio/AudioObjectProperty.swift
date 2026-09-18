import CoreAudio
import Foundation
import Synchronization

/// Thin, typed wrappers over the HAL's property interface, plus a property-listener
/// registry that can actually be unregistered.
public enum AudioProperty {
    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let selector: AudioObjectPropertySelector
        public let status: OSStatus
        public var description: String {
            "\(fourCC(selector)) failed: \(statusDescription(status))"
        }
    }

    /// Reads a fixed-size value (`UInt32`, `AudioObjectID`, `AudioStreamBasicDescription`…).
    public static func value<T>(
        _ type: T.Type, from object: AudioObjectID, _ addr: AudioObjectPropertyAddress
    ) throws -> T {
        var addr = addr
        var size = UInt32(MemoryLayout<T>.size)
        let out = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment
        )
        defer { out.deallocate() }
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, out)
        guard status == noErr else { throw Failure(selector: addr.mSelector, status: status) }
        return out.assumingMemoryBound(to: T.self).pointee
    }

    /// Reads a variable-length array property.
    public static func array<T>(
        _ type: T.Type, from object: AudioObjectID, _ addr: AudioObjectPropertyAddress
    ) throws -> [T] {
        var addr = addr
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard status == noErr else { throw Failure(selector: addr.mSelector, status: status) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }

        var out = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        status = out.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { throw Failure(selector: addr.mSelector, status: status) }
        return Array(out.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads a `CFString` property. The HAL hands back a +1 reference and the `as String`
    /// bridge takes ownership, so there is no manual release here.
    public static func string(
        from object: AudioObjectID, _ addr: AudioObjectPropertyAddress
    ) throws -> String {
        var addr = addr
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString?
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { throw Failure(selector: addr.mSelector, status: status) }
        return (cf as String?) ?? ""
    }

    /// Non-throwing variant for diagnostics, where a missing property is not an error.
    public static func optionalString(
        from object: AudioObjectID, _ addr: AudioObjectPropertyAddress
    ) -> String? {
        try? string(from: object, addr)
    }

    /// A device the HAL no longer knows fails the *read* with `kAudioHardwareBadObjectError`
    /// rather than returning zero, so a failed read is the death signal.
    public static func isAlive(_ device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        guard let alive = try? value(
            UInt32.self, from: device, address(kAudioDevicePropertyDeviceIsAlive)
        ) else { return false }
        return alive != 0
    }

    public static func fourCC(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        let text = String(decoding: bytes, as: UTF8.self)
        return text.allSatisfy { $0.isASCII && !$0.isNewline } ? "'\(text)'" : "\(code)"
    }

    public static func statusDescription(_ status: OSStatus) -> String {
        switch status {
        case noErr: return "noErr"
        case kAudioHardwareBadObjectError: return "badObject ('!obj') — the object is gone"
        case kAudioHardwareUnknownPropertyError: return "unknownProperty ('who?')"
        case kAudioHardwareIllegalOperationError: return "illegalOperation ('nope')"
        case kAudioHardwareNotRunningError: return "notRunning ('stop')"
        case kAudioHardwareUnsupportedOperationError: return "unsupported ('unop')"
        default: return "\(fourCC(UInt32(bitPattern: status))) (\(status))"
        }
    }
}

// MARK: - Property listeners

/// Registration handle. Removing a listener requires the *exact same* four-tuple of
/// (object, address, proc, clientData), so the token carries all of it.
public struct AudioPropertyListenerToken: Sendable {
    fileprivate let object: AudioObjectID
    fileprivate let address: AudioObjectPropertyAddress
    fileprivate let token: UInt
}

/// Property-change notifications from the HAL.
///
/// Deliberately built on `AudioObjectAddPropertyListener` (the C function-pointer API)
/// rather than the more convenient `…ListenerBlock` variant, because the block variant
/// **cannot be unregistered from Swift**: `AudioObjectRemovePropertyListenerBlock` returns
/// `noErr` and the listener keeps firing. Measured — callbacks stayed at 2 after a
/// "successful" removal, and registrations accumulated across add/remove cycles. The cause
/// is that Swift re-thunks a fresh ObjC block at each call boundary, so the reference the
/// HAL copied never matches the one passed to remove. A listener that cannot be removed
/// keeps firing into a torn-down capture graph, which is exactly the crash this design
/// cannot afford mid-call.
///
/// Handlers are keyed by an integer token that is only ever compared, never dereferenced,
/// so a callback still in flight during teardown becomes a failed lookup rather than a
/// use-after-free.
public enum AudioPropertyListener {
    public typealias Handler = @Sendable (AudioObjectID, [AudioObjectPropertySelector]) -> Void

    private static let registry = Mutex<[UInt: Handler]>([:])
    private static let nextToken = Atomic<UInt>(1)

    /// Callbacks arrive on a HAL-internal thread ("HALC_ShellObject_Listener Queue"), not on
    /// any queue of ours — the C API has no queue parameter. Handlers must hop themselves.
    nonisolated(unsafe) private static let proc: AudioObjectPropertyListenerProc = {
        objectID, count, addresses, clientData in
        guard let clientData else { return noErr }
        let token = UInt(bitPattern: clientData)
        guard let handler = registry.withLock({ $0[token] }) else { return noErr }
        var selectors: [AudioObjectPropertySelector] = []
        selectors.reserveCapacity(Int(count))
        for i in 0..<Int(count) { selectors.append(addresses[i].mSelector) }
        handler(objectID, selectors)
        return noErr
    }

    /// Every logical listener gets its own token: the HAL rejects a duplicate registration
    /// of an identical four-tuple with `kAudioHardwareIllegalOperationError`.
    public static func add(
        to object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        handler: @escaping Handler
    ) throws -> AudioPropertyListenerToken {
        let token = nextToken.wrappingAdd(1, ordering: .relaxed).newValue
        registry.withLock { $0[token] = handler }

        var addr = address
        let status = AudioObjectAddPropertyListener(
            object, &addr, proc, UnsafeMutableRawPointer(bitPattern: token)
        )
        guard status == noErr else {
            registry.withLock { $0[token] = nil }
            throw AudioProperty.Failure(selector: address.mSelector, status: status)
        }
        return AudioPropertyListenerToken(object: object, address: address, token: token)
    }

    /// Removal is best-effort by design: every removal path in this API returns `noErr` even
    /// when it removed nothing, so the registry entry is dropped first. That way a listener
    /// the HAL refuses to forget still stops calling into us.
    public static func remove(_ token: AudioPropertyListenerToken) {
        registry.withLock { $0[token.token] = nil }
        var addr = token.address
        _ = AudioObjectRemovePropertyListener(
            token.object, &addr, proc, UnsafeMutableRawPointer(bitPattern: token.token)
        )
    }
}
