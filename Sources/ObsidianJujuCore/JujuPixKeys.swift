import Foundation
import JujuPixCore

/// Keys for JujuPix `.jjpx` encrypted photos used in notes as `![](<juju:photo.jpg.jjpx>)`.
///
/// Decryption is done by JujuPix's own core (JujuPixCore), in memory only: decrypted photos are never written
/// anywhere. Unlocking with the JujuPix password (or the library's recovery key) keeps the derived key-encryption
/// keys in memory until `lock()`. Keys are kept per library (`passwordKeyId` / `recoveryKeyId`), so photos from
/// several JujuPix libraries with different passwords open side by side once each password has been entered.
/// The passwords themselves are kept too while unlocked, so a library not checked at unlock time but sharing a
/// password still opens; `exported()` (for the Keychain) holds only the derived keys.
public final class JujuPixKeys: @unchecked Sendable {
    public enum Outcome {
        case image(Data, mimeType: String)
        /// Locked (or none of the keys opens it); the header is for a placeholder.
        case locked(JjpxHeader)
        case failed(String)
    }

    public enum UnlockError: Error, Equatable {
        case wrongSecret(String)
        case unreadable(String)
    }

    private let lock_ = NSLock()
    private var passwordKeys: [String: Data] = [:]
    private var recoveryKeys: [String: Data] = [:]
    private var passwords: [String] = []
    /// Password-key ids that none of `passwords` opens (so Argon2id isn't rerun for every locked photo).
    private var noMatch: Set<String> = []

    public init() {}

    public var isUnlocked: Bool {
        lock_.withLock { !passwordKeys.isEmpty || !recoveryKeys.isEmpty || !passwords.isEmpty }
    }

    /// Whether a key for this photo's library is held (it opens without asking).
    public func hasKey(for header: JjpxHeader) -> Bool {
        lock_.withLock { passwordKeys[header.passwordKeyId] != nil || recoveryKeys[header.recoveryKeyId] != nil }
    }

    public static func header(_ bytes: Data) -> JjpxHeader? { try? jjpxHeader(bytes: bytes) }

    /// Checks `password` against `sample` (any `.jjpx` it should open) and keeps its key. Slow (Argon2id).
    public func unlock(password: String, sample: Data) throws {
        _ = try unlock(password: password, samples: [sample])
    }

    /// Tries `password` on one photo per library among `samples` (libraries already unlocked are skipped) and keeps
    /// the key of every library it opens. Returns how many libraries it unlocked; throws if it opens none.
    /// Slow: one Argon2id run per library.
    @discardableResult
    public func unlock(password: String, samples: [Data]) throws -> Int {
        let libraries = try Self.perLibrary(samples, id: \.passwordKeyId)
        var unlocked = 0
        var lastError: Error?
        for (header, bytes) in libraries where !hasKey(for: header) {
            do {
                let key = try jjpxPasswordKey(bytes: bytes, password: password)
                lock_.withLock {
                    passwordKeys[header.passwordKeyId] = key
                    noMatch.remove(header.passwordKeyId)
                }
                unlocked += 1
            } catch CoreError.WrongPassword {
                continue
            } catch {
                lastError = error
            }
        }
        if unlocked > 0 {
            lock_.withLock {
                if !passwords.contains(password) { passwords.append(password) }
                noMatch.removeAll()
            }
            return unlocked
        }
        if let lastError { throw UnlockError.unreadable(Self.message(lastError)) }
        throw UnlockError.wrongSecret(libraries.allSatisfy { hasKey(for: $0.0) } ? "Already unlocked" : "Wrong password")
    }

    /// Checks a recovery key against `sample` and keeps its key.
    public func unlock(recoveryKey: String, sample: Data) throws {
        _ = try unlock(recoveryKey: recoveryKey, samples: [sample])
    }

    /// Checks a recovery key against the photos among `samples` from its library and keeps its key.
    @discardableResult
    public func unlock(recoveryKey: String, samples: [Data]) throws -> Int {
        let libraries = try Self.perLibrary(samples, id: \.recoveryKeyId)
        guard let rk = try? jjpxRecoveryKey(recoveryKey: recoveryKey) else {
            throw UnlockError.wrongSecret("That isn’t a valid recovery key")
        }
        guard let (_, bytes) = libraries.first(where: { $0.0.recoveryKeyId == rk.recoveryKeyId }) else {
            throw UnlockError.wrongSecret(libraries.count == 1 ? "This photo was encrypted with a different recovery key"
                                          : "That recovery key doesn’t belong to these photos’ libraries")
        }
        guard (try? jjpxDecryptWithKey(bytes: bytes, key: rk.key)) != nil else {
            throw UnlockError.wrongSecret("Wrong recovery key")
        }
        lock_.withLock { recoveryKeys[rk.recoveryKeyId] = rk.key }
        return 1
    }

    /// One readable photo per library (by `id`), in the order given. Throws only if none is readable.
    private static func perLibrary(_ samples: [Data], id: KeyPath<JjpxHeader, String>) throws -> [(JjpxHeader, Data)] {
        var seen = Set<String>()
        var out: [(JjpxHeader, Data)] = []
        var firstError: Error?
        for bytes in samples {
            do {
                let header = try jjpxHeader(bytes: bytes)
                if seen.insert(header[keyPath: id]).inserted { out.append((header, bytes)) }
            } catch {
                firstError = firstError ?? error
            }
        }
        if out.isEmpty { throw UnlockError.unreadable(firstError.map(message) ?? "No photos to check the password against") }
        return out
    }

    /// Forgets every key.
    public func lock() {
        lock_.withLock {
            passwordKeys.removeAll()
            recoveryKeys.removeAll()
            passwords = []
            noMatch = []
        }
    }

    /// The derived keys (not the password), for saving in the Keychain.
    public func exported() -> Data? {
        let saved = lock_.withLock { Saved(password: passwordKeys, recovery: recoveryKeys) }
        guard !saved.password.isEmpty || !saved.recovery.isEmpty else { return nil }
        return try? JSONEncoder().encode(saved)
    }

    /// Restores keys from `exported()`. Returns false if the data isn't valid.
    @discardableResult
    public func restore(_ data: Data) -> Bool {
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data),
              !saved.password.isEmpty || !saved.recovery.isEmpty else { return false }
        lock_.withLock {
            passwordKeys.merge(saved.password) { $1 }
            recoveryKeys.merge(saved.recovery) { $1 }
        }
        return true
    }

    /// Decrypts a `.jjpx` file's bytes, or says why it can't.
    public func open(_ bytes: Data) -> Outcome {
        let header: JjpxHeader
        do { header = try jjpxHeader(bytes: bytes) } catch { return .failed(Self.message(error)) }
        var (key, passwords) = lock_.withLock { () -> (Data?, [String]) in
            let key = passwordKeys[header.passwordKeyId] ?? recoveryKeys[header.recoveryKeyId]
            return (key, noMatch.contains(header.passwordKeyId) ? [] : self.passwords)
        }
        if key == nil, !passwords.isEmpty {
            // A library that wasn't checked at unlock time: try the passwords entered so far.
            for password in passwords {
                if let derived = try? jjpxPasswordKey(bytes: bytes, password: password) {
                    lock_.withLock { passwordKeys[header.passwordKeyId] = derived }
                    key = derived
                    break
                }
            }
            if key == nil { lock_.withLock { _ = noMatch.insert(header.passwordKeyId) } }
        }
        guard let key else { return .locked(header) }
        do {
            return .image(try jjpxDecryptWithKey(bytes: bytes, key: key), mimeType: header.originalType)
        } catch CoreError.WrongPassword {
            return .locked(header)
        } catch {
            return .failed(Self.message(error))
        }
    }

    private struct Saved: Codable {
        var password: [String: Data]
        var recovery: [String: Data]
    }

    private static func message(_ error: Error) -> String {
        if let e = error as? CoreError {
            switch e {
            case .Corrupt(let m), .WrongPassword(let m), .Io(let m), .UnsupportedFormat(let m): return m
            default: return "\(e)"
            }
        }
        return error.localizedDescription
    }
}
