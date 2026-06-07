import Foundation

// Simple heap box for semaphore-bridged callback code.
final class UnsafeMutableTransfer<T>: @unchecked Sendable {
    var value: T

    init(_ value: T) {
        self.value = value
    }
}
