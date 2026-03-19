import Foundation

extension Data {
    /// Reads a little-endian integer of type `T` starting at `offset`.
    func readLE<T: FixedWidthInteger>(offset: Int) -> T {
        let size = MemoryLayout<T>.size
        return subdata(in: offset ..< offset + size).withUnsafeBytes { ptr in
            T(littleEndian: ptr.loadUnaligned(as: T.self))
        }
    }
}
