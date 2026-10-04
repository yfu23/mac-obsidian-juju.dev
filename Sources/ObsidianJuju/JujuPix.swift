import AppKit
import JujuPixCore
import LocalAuthentication
import ObsidianJujuCore
import Security
import SwiftUI

/// JujuPix encrypted photos (`![](<juju:photo.jpg.jjpx>)`): unlock, lock, auto-lock and the optional Keychain.
/// Decrypted photos only ever live in memory (`JujuSchemeHandler` serves them straight from `JujuPixKeys`).
extension VaultModel {
    /// Clicking a locked photo (`photo`) or the palette command. Photos from several JujuPix libraries can be
    /// unlocked side by side: a click on a photo whose library is still locked asks again, even if other photos are
    /// unlocked. Uses the Keychain (Touch ID / Mac password) first when the user chose to remember the keys.
    /// `whenUnlocked` runs instead when the photo's library is already unlocked (the reading view zooms it).
    func requestJujuPixUnlock(photo: URL? = nil, whenUnlocked: (@MainActor () -> Void)? = nil) {
        guard let photo else { return askForJujuPix(target: nil, header: nil) }
        let keys = jujuPixKeys
        DispatchQueue.global(qos: .userInitiated).async {
            let header = (try? Data(contentsOf: photo, options: .mappedIfSafe)).flatMap { JujuPixKeys.header($0) }
            DispatchQueue.main.async { [weak self] in
                // Its library is unlocked: the photo is showing (or about to).
                if let header, keys.hasKey(for: header) { whenUnlocked?(); return }
                self?.askForJujuPix(target: photo, header: header)
            }
        }
    }

    private func askForJujuPix(target: URL?, header: JjpxHeader?) {
        if UserDefaults.standard.bool(forKey: SettingsKey.jujuPixRememberInKeychain), JujuPixKeychain.hasSavedKeys,
           !jujuPixKeychainTried {
            jujuPixKeychainTried = true
            JujuPixKeychain.load(reason: "unlock JujuPix photos in your notes") { [weak self] data in
                guard let self else { return }
                let restored = data.map { self.jujuPixKeys.restore($0) } ?? false
                if restored { self.jujuPixDidChange(unlocked: true) }
                // The Keychain may not have this photo's library yet: ask for its password.
                if !restored || header.map({ !self.jujuPixKeys.hasKey(for: $0) }) == true {
                    self.jujuPixTarget = target
                    self.showJujuPixUnlock = true
                }
            }
            return
        }
        jujuPixTarget = target
        showJujuPixUnlock = true
    }

    /// `.jjpx` files to check a password or recovery key against: `preferred` (the clicked photo) first, then the
    /// photos the current note uses, then one photo per JujuPix library (a folder with `.jujupix`) or per folder
    /// in the attachment folders and the vault.
    func jujuPixSamples(preferred: URL?) -> [URL] {
        let ext = externalAttachments
        var out: [URL] = []
        var seen = Set<String>(), groups = Set<String>()
        var libraryRoot: [String: String] = [:]
        let fm = FileManager.default
        func group(_ file: URL, top: URL) -> String {
            var dir = file.deletingLastPathComponent().standardizedFileURL
            var visited: [String] = []
            var found: String?
            while found == nil {
                if let known = libraryRoot[dir.path] { found = known; break }
                visited.append(dir.path)
                if fm.fileExists(atPath: dir.appendingPathComponent(".jujupix").path) { found = dir.path; break }
                let up = dir.deletingLastPathComponent()
                if up.path == dir.path { break }
                dir = up
            }
            let g = found ?? top.standardizedFileURL.path
            for v in visited { libraryRoot[v] = g }
            return g
        }
        func add(_ file: URL, top: URL?) {
            if let top, !groups.insert(group(file, top: top)).inserted { return }
            if seen.insert(file.standardizedFileURL.path).inserted { out.append(file) }
        }
        if let preferred { add(preferred, top: nil) }
        let noteText: String? = activeTabID.flatMap { editSessions[$0]?.text }
            ?? activePath.flatMap { path in vaultURL.flatMap { try? String(contentsOf: $0.appendingPathComponent(path), encoding: .utf8) } }
        for name in JujuRef.names(in: noteText ?? "") where JujuRef.isEncrypted(name) {
            if let hit = ext.resolve(name) { add(ext.folders[hit.folder].appendingPathComponent(hit.path), top: nil) }
        }
        for hit in ext.entries where JujuRef.isEncrypted(hit.path) {
            add(ext.folders[hit.folder].appendingPathComponent(hit.path), top: ext.folders[hit.folder])
        }
        if let root = vaultURL {
            for file in snapshot.files where file.ext == "jjpx" { add(root.appendingPathComponent(file.path), top: root) }
        }
        return Array(out.prefix(40))
    }

    /// The file behind a `juju://jjpx/<folder index or v>/<path>` image address.
    func jujuPixFile(src: String) -> URL? {
        guard let c = URLComponents(string: src), c.scheme == "juju", c.host == "jjpx",
              let path = c.percentEncodedPath.removingPercentEncoding else { return nil }
        let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0] == "v" { return vaultURL.flatMap { VaultReader.containedURL($0, parts[1]) } }
        let folders = externalAttachments.folders
        guard let i = Int(parts[0]), folders.indices.contains(i) else { return nil }
        return VaultReader.containedURL(folders[i], parts[1])
    }

    func jujuPixDidChange(unlocked: Bool, message: String? = nil) {
        jujuPixUnlocked = unlocked
        if !unlocked { jujuPixKeychainTried = false }
        if unlocked, UserDefaults.standard.bool(forKey: SettingsKey.jujuPixRememberInKeychain),
           let data = jujuPixKeys.exported() {
            JujuPixKeychain.save(data)
        }
        jujuPixGeneration += 1
        editSessions.values.forEach { $0.livePreview?.reloadImages() }
        for tab in tabs where controller(for: tab.id).usesExternal { rerender(tabID: tab.id) }
        flash(message ?? (unlocked ? "JujuPix photos unlocked" : "JujuPix photos locked"))
    }

    func lockJujuPix() {
        guard jujuPixUnlocked || jujuPixKeys.isUnlocked else { return }
        jujuPixKeys.lock()
        jujuPixDidChange(unlocked: false)
    }

    /// Settings → "Remember in Keychain" changed.
    func jujuPixKeychainSettingChanged(_ on: Bool) {
        if on {
            if let data = jujuPixKeys.exported() { JujuPixKeychain.save(data) }
        } else {
            JujuPixKeychain.delete()
        }
    }

    /// Locks after the Mac has been idle for the chosen time (and on sleep or screen lock), unless the user chose
    /// "Only when quitting".
    func startJujuPixAutoLock() {
        guard jujuPixIdleTimer == nil else { return }
        jujuPixIdleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkJujuPixIdle() }
        }
        let lockIfTimed: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.jujuPixAutoLockMinutes > 0 else { return }
                self.lockJujuPix()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                                          queue: .main, using: lockIfTimed)
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil,
                                                            queue: .main, using: lockIfTimed)
    }

    nonisolated static var jujuPixAutoLockMinutes: Int {
        UserDefaults.standard.object(forKey: SettingsKey.jujuPixAutoLockMinutes) as? Int
            ?? SettingsKey.defaultJujuPixAutoLockMinutes
    }

    private func checkJujuPixIdle() {
        let minutes = Self.jujuPixAutoLockMinutes
        guard minutes > 0, jujuPixUnlocked else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= Double(minutes * 60) { lockJujuPix() }
    }
}

/// The derived JujuPix keys (never the password) in the login Keychain. Reading them first asks for Touch ID or
/// the Mac password.
enum JujuPixKeychain {
    private static let service = "ObsidianJuju JujuPix keys"
    private static let account = "keys"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var hasSavedKeys: Bool {
        var q = query
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ data: Data) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrLabel as String] = service
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    /// Asks for Touch ID (or the Mac password), then reads the keys. Calls back on the main thread.
    static func load(reason: String, completion: @escaping @MainActor (Data?) -> Void) {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            var data: Data?
            if ok {
                var q = query
                q[kSecReturnData as String] = true
                var item: CFTypeRef?
                if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess { data = item as? Data }
            }
            DispatchQueue.main.async { completion(data) }
        }
    }
}

/// Asks for the JujuPix password (or recovery key) and checks it against a photo the notes use.
struct JujuPixUnlockView: View {
    @ObservedObject var model: VaultModel
    @State private var secret = ""
    @State private var useRecoveryKey = false
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Unlock JujuPix photos", systemImage: "lock.fill").font(.title3.bold())
            if model.jujuPixUnlocked {
                Text(model.jujuPixTarget == nil
                     ? "Some photos are unlocked. To add photos from another JujuPix library, enter that library’s password."
                     : "This photo is from a JujuPix library that’s still locked. Enter that library’s password.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Encrypted photos (.jjpx) are decrypted in memory only and lock again "
                 + (SettingsKeyText.autoLock) + ".")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $useRecoveryKey) {
                Text("Password").tag(false)
                Text("Recovery key").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            SecureField(useRecoveryKey ? "Recovery key (XXXXXX-XXXXXX-…)" : "JujuPix password", text: $secret)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(unlock)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.showJujuPixUnlock = false }.keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock).keyboardShortcut(.defaultAction).disabled(secret.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func unlock() {
        guard !secret.isEmpty, !working else { return }
        let target = model.jujuPixTarget
        let samples = model.jujuPixSamples(preferred: target)
        guard !samples.isEmpty else {
            error = "No .jjpx photos found in the vault or the attachment folders."
            return
        }
        working = true
        error = nil
        let keys = model.jujuPixKeys, secret = secret, recovery = useRecoveryKey
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            var count = 0
            var targetOpens = true
            let data = samples.compactMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            do {
                count = recovery ? try keys.unlock(recoveryKey: secret, samples: data) : try keys.unlock(password: secret, samples: data)
                if let target, let header = (try? Data(contentsOf: target, options: .mappedIfSafe)).flatMap({ JujuPixKeys.header($0) }) {
                    targetOpens = keys.hasKey(for: header)
                }
            } catch JujuPixKeys.UnlockError.wrongSecret(let m) {
                failure = m
            } catch JujuPixKeys.UnlockError.unreadable(let m) {
                failure = "Couldn’t read the photos: \(m)"
            } catch {
                failure = "Couldn’t read the photos: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                working = false
                if let failure {
                    error = failure
                    return
                }
                let message = count > 1 ? "\(count) JujuPix libraries unlocked" : nil
                model.jujuPixDidChange(unlocked: true, message: message)
                if targetOpens {
                    model.showJujuPixUnlock = false
                } else {
                    // Another library opened, but not the clicked photo's: keep asking for that one.
                    self.secret = ""
                    error = "That unlocked another library, but not this photo’s. Enter the password of the library it’s from."
                }
            }
        }
    }
}

enum SettingsKeyText {
    static var autoLock: String {
        let m = VaultModel.jujuPixAutoLockMinutes
        return m <= 0 ? "when you quit ObsidianJuju" : m % 60 == 0 ? "after \(m / 60) hour\(m == 60 ? "" : "s") idle" : "after \(m) minutes idle"
    }
}
