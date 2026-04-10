@testable import Clipped
import CryptoKit
import Foundation
import Testing

struct HistoryCryptoTests {
    @Test("Encrypt → decrypt round-trips the plaintext")
    func roundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let crypto = HistoryCrypto(key: key)
        let plaintext = Data("the quick brown fox".utf8)

        let ciphertext = try crypto.encrypt(plaintext)
        #expect(ciphertext != plaintext)

        let decrypted = try crypto.decrypt(ciphertext)
        #expect(decrypted == plaintext)
    }

    @Test("A different key cannot decrypt the ciphertext")
    func wrongKeyFails() throws {
        let crypto1 = HistoryCrypto(key: SymmetricKey(size: .bits256))
        let crypto2 = HistoryCrypto(key: SymmetricKey(size: .bits256))
        let ciphertext = try crypto1.encrypt(Data("hello".utf8))

        #expect(throws: HistoryCryptoError.decryptionFailed) {
            _ = try crypto2.decrypt(ciphertext)
        }
    }

    @Test("Tampered ciphertext fails authentication")
    func tamperedCiphertext() throws {
        let crypto = HistoryCrypto(key: SymmetricKey(size: .bits256))
        var ciphertext = try crypto.encrypt(Data("hello".utf8))
        // Flip a byte in the middle (the ciphertext body).
        let mid = ciphertext.count / 2
        ciphertext[mid] ^= 0xFF

        #expect(throws: HistoryCryptoError.decryptionFailed) {
            _ = try crypto.decrypt(ciphertext)
        }
    }

    @Test("Short ciphertext is reported as corrupted")
    func tooShort() {
        let crypto = HistoryCrypto(key: SymmetricKey(size: .bits256))
        #expect(throws: HistoryCryptoError.corrupted) {
            _ = try crypto.decrypt(Data([0x01, 0x02, 0x03]))
        }
    }

    @Test("Empty plaintext still round-trips")
    func emptyPlaintext() throws {
        let crypto = HistoryCrypto(key: SymmetricKey(size: .bits256))
        let ciphertext = try crypto.encrypt(Data())
        let decrypted = try crypto.decrypt(ciphertext)
        #expect(decrypted == Data())
    }
}

struct KeychainKeyStoreTests {
    @Test("InMemoryKeyStore generates and returns a stable key")
    func inMemoryKeyStoreStable() throws {
        let store = InMemoryKeyStore()
        #expect(try store.loadKey() == nil)

        let k1 = try store.loadOrCreateKey()
        let k2 = try store.loadOrCreateKey()
        #expect(k1.withUnsafeBytes { Data($0) } == k2.withUnsafeBytes { Data($0) })
    }

    @Test("deleteKey clears the stored value")
    func deleteClears() throws {
        let store = InMemoryKeyStore()
        _ = try store.generateAndStoreKey()
        try store.deleteKey()
        #expect(try store.loadKey() == nil)
    }
}
