import CryptoKit
import Foundation

enum HistoryCryptoError: Error, Equatable {
    case corrupted
    case decryptionFailed
}

/// Authenticated encryption for on-disk clipboard history using `ChaChaPoly`.
///
/// The serialized format is CryptoKit's standard `combined` layout:
/// `[12-byte nonce][ciphertext][16-byte tag]`. This keeps things simple and
/// avoids any custom framing; round-tripping through `ChaChaPoly.SealedBox`
/// is enough to detect tampering or corruption.
struct HistoryCrypto {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try ChaChaPoly.seal(plaintext, using: key)
        return sealed.combined
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: ciphertext)
        } catch {
            throw HistoryCryptoError.corrupted
        }
        do {
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw HistoryCryptoError.decryptionFailed
        }
    }
}
