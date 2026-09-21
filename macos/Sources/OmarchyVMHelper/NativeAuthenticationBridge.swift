import AppKit
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

enum NativeAuthenticationOperation: String, Equatable {
    case disable
    case enroll
    case sudo
    case onePasswordUnlock = "onepassword-unlock"

    var localizedReason: String {
        switch self {
        case .disable:
            "Disable Touch ID for sudo in this Try Omarchy guest"
        case .enroll:
            "Pair this Try Omarchy guest for Touch ID sudo testing"
        case .sudo:
            "Approve sudo in the focused Try Omarchy guest"
        case .onePasswordUnlock:
            "Unlock 1Password in the focused Try Omarchy guest"
        }
    }
}

struct NativeAuthenticationRequest: Equatable {
    static let maximumLineBytes = 4096
    static let protocolVersion = 3

    let operation: NativeAuthenticationOperation
    let guestID: String
    let requestID: String
    let challenge: String
    let user: String
    let requestingUser: String
    let service: String
    let tty: String

    static func decode(_ data: Data) throws -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.sorted() == [
                  "challenge", "guestId", "operation", "requestId", "requestingUser",
                  "service", "tty", "type", "user", "version",
              ],
              object["type"] as? String == "authorize",
              object["version"] as? Int == protocolVersion,
              let operationValue = object["operation"] as? String,
              let operation = NativeAuthenticationOperation(rawValue: operationValue),
              let guestID = object["guestId"] as? String,
              isLowercaseHex(guestID, bytes: 32),
              let requestID = object["requestId"] as? String,
              let identifier = UUID(uuidString: requestID),
              identifier.uuidString.lowercased() == requestID,
              let challenge = object["challenge"] as? String,
              isLowercaseHex(challenge, bytes: 32),
              let user = object["user"] as? String,
              let requestingUser = object["requestingUser"] as? String,
              let service = object["service"] as? String,
              let tty = object["tty"] as? String else {
            throw HelperError.io("guest sent an invalid authentication request")
        }

        switch operation {
        case .disable, .enroll:
            guard service == "sudo", user.isEmpty, requestingUser.isEmpty, tty.isEmpty else {
                throw HelperError.io("guest sent an invalid authentication control request")
            }
        case .sudo:
            guard service == "sudo", isAccountName(user),
                  isAccountName(requestingUser),
                  isInteractiveTTY(tty) else {
                throw HelperError.io("guest sent invalid sudo authentication context")
            }
        case .onePasswordUnlock:
            guard service == "com.1password.1Password.unlock",
                  isAccountName(user), requestingUser == user, tty.isEmpty else {
                throw HelperError.io("guest sent invalid 1Password unlock context")
            }
        }

        return Self(
            operation: operation,
            guestID: guestID,
            requestID: requestID,
            challenge: challenge,
            user: user,
            requestingUser: requestingUser,
            service: service,
            tty: tty
        )
    }

    func signaturePayload(issuedAt: Int64, expiresAt: Int64, keyID: String) -> Data {
        let fields = [
            "try-omarchy-native-authentication-v3",
            guestID,
            operation.rawValue,
            requestID,
            challenge,
            user,
            requestingUser,
            service,
            tty,
            String(issuedAt),
            String(expiresAt),
            keyID,
        ]
        return Data(fields.joined(separator: "\0").utf8)
    }

    private static func isLowercaseHex(_ value: String, bytes: Int) -> Bool {
        value.utf8.count == bytes * 2
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isAccountName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...32).contains(bytes.count),
              let first = bytes.first,
              first == 95 || (97...122).contains(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            $0 == 45 || $0 == 95 || (48...57).contains($0) || (97...122).contains($0)
        }
    }

    private static func isInteractiveTTY(_ value: String) -> Bool {
        let suffix: Substring
        if value.hasPrefix("/dev/pts/") {
            suffix = value.dropFirst("/dev/pts/".count)
        } else if value.hasPrefix("/dev/tty") {
            suffix = value.dropFirst("/dev/tty".count)
        } else {
            return false
        }
        return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) }
    }
}

struct NativeAuthenticationApproval: Equatable {
    let issuedAt: Int64
    let expiresAt: Int64
    let keyID: String
    let publicKey: Data
    let signature: Data
}

struct NativeAuthenticationResponse: Equatable {
    let request: NativeAuthenticationRequest
    let approved: Bool
    let approval: NativeAuthenticationApproval?

    init(request: NativeAuthenticationRequest, approval: NativeAuthenticationApproval?) {
        self.request = request
        self.approved = approval != nil
        self.approval = approval
    }

    init(disabledRequest request: NativeAuthenticationRequest) {
        self.request = request
        self.approved = true
        self.approval = nil
    }

    func encode() throws -> Data {
        let object: [String: Any] = [
            "type": "authorization-result",
            "version": NativeAuthenticationRequest.protocolVersion,
            "operation": request.operation.rawValue,
            "guestId": request.guestID,
            "requestId": request.requestID,
            "challenge": request.challenge,
            "user": request.user,
            "requestingUser": request.requestingUser,
            "service": request.service,
            "tty": request.tty,
            "approved": approved,
            "issuedAt": approval?.issuedAt ?? 0,
            "expiresAt": approval?.expiresAt ?? 0,
            "keyId": approval?.keyID ?? "",
            "publicKey": approval?.publicKey.base64EncodedString() ?? "",
            "signature": approval?.signature.base64EncodedString() ?? "",
        ]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}

protocol HostAuthorizationSigning: AnyObject {
    func authorize(_ request: NativeAuthenticationRequest) throws -> NativeAuthenticationApproval?
    func disable(guestID: String) throws
    func cancel()
}

enum NativeAuthenticationPrompt {
    static func approve(
        timeout: TimeInterval = 55,
        evaluate: (@escaping (Bool) -> Void) -> Void,
        cancel: () -> Void
    ) -> Bool {
        let completion = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var approved = false
        evaluate { success in
            lock.lock()
            approved = success
            lock.unlock()
            completion.signal()
        }
        guard completion.wait(timeout: .now() + timeout) == .success else {
            cancel()
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return approved
    }
}

final class SecureEnclaveAuthorizationSigner: HostAuthorizationSigning, @unchecked Sendable {
    static let approvalLifetimeSeconds: Int64 = 15

    private let lock = NSLock()
    private let keyDirectory: URL
    private var activeContext: LAContext?

    init(keyDirectory: URL? = nil) {
        self.keyDirectory = keyDirectory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("Try Omarchy", isDirectory: true)
            .appendingPathComponent("Native Authentication Keys", isDirectory: true)
    }

    func authorize(_ request: NativeAuthenticationRequest) throws -> NativeAuthenticationApproval? {
        guard SecureEnclave.isAvailable else {
            fputs("[authentication-bridge] The Secure Enclave is unavailable.\n", stderr)
            return nil
        }
        let keyURL = keyURL(for: request.guestID)
        let keyAlreadyExists = try keyExists(at: keyURL)
        if request.operation == .disable {
            throw HelperError.io("disable request reached the signing path")
        }
        if request.operation != .enroll && !keyAlreadyExists {
            fputs("[authentication-bridge] Touch ID sudo is not enrolled for this Mac.\n", stderr)
            return nil
        }

        guard let context = authenticate(reason: request.operation.localizedReason) else {
            return nil
        }
        defer { clear(context) }

        let privateKey: SecureEnclave.P256.Signing.PrivateKey
        if request.operation == .enroll && !keyAlreadyExists {
            privateKey = try createPrivateKey(authenticationContext: context)
            try saveKeyRepresentation(privateKey.dataRepresentation, to: keyURL)
        } else {
            privateKey = try loadPrivateKey(
                from: keyURL,
                authenticationContext: context
            )
        }
        let publicKeyData = privateKey.publicKey.x963Representation
        guard publicKeyData.count == 65,
              publicKeyData.first == 0x04 else {
            throw HelperError.io("cannot export Secure Enclave P-256 public key")
        }
        let keyID = SHA256.hash(data: publicKeyData)
            .map { String(format: "%02x", $0) }
            .joined()
        let issuedAt = Int64(Date().timeIntervalSince1970)
        let expiresAt = issuedAt + Self.approvalLifetimeSeconds
        let payload = request.signaturePayload(
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            keyID: keyID
        )

        let signature = try privateKey.signature(for: payload).derRepresentation
        return NativeAuthenticationApproval(
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            keyID: keyID,
            publicKey: publicKeyData,
            signature: signature
        )
    }

    func disable(guestID: String) throws {
        let keyURL = keyURL(for: guestID)
        guard try keyExists(at: keyURL) else { return }
        guard Darwin.unlink(keyURL.path) == 0 else {
            throw HelperError.io("cannot remove Secure Enclave key representation")
        }
    }

    func cancel() {
        lock.lock()
        let context = activeContext
        activeContext = nil
        lock.unlock()
        context?.invalidate()
    }

    private func authenticate(reason: String) -> LAContext? {
        let context = LAContext()
        context.localizedCancelTitle = "Return to Omarchy"
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0

        var availabilityError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &availabilityError
        ) else {
            let detail = availabilityError?.localizedDescription ?? "Touch ID is unavailable"
            fputs("[authentication-bridge] \(detail)\n", stderr)
            return nil
        }

        lock.lock()
        activeContext = context
        lock.unlock()

        let result = NativeAuthenticationPrompt.approve(
            evaluate: { completion in
                context.evaluatePolicy(
                    .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: reason
                ) { success, _ in completion(success) }
            },
            cancel: { context.invalidate() }
        )
        if !result {
            clear(context)
            return nil
        }
        return context
    }

    private func clear(_ context: LAContext) {
        lock.lock()
        if activeContext === context {
            activeContext = nil
        }
        lock.unlock()
    }

    private func keyURL(for guestID: String) -> URL {
        keyDirectory.appendingPathComponent("\(guestID).key", isDirectory: false)
    }

    private func keyExists(at url: URL) throws -> Bool {
        var information = stat()
        if lstat(url.path, &information) == 0 {
            guard (information.st_mode & S_IFMT) == S_IFREG,
                  information.st_uid == getuid(),
                  (information.st_mode & 0o777) == 0o600 else {
                throw HelperError.io("Secure Enclave key representation is unsafe")
            }
            return true
        }
        if errno == ENOENT { return false }
        throw HelperError.io("cannot inspect Secure Enclave key representation")
    }

    private func createPrivateKey(
        authenticationContext: LAContext
    ) throws -> SecureEnclave.P256.Signing.PrivateKey {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &accessError
        ) else {
            throw HelperError.io(
                "cannot create Secure Enclave access control: \(errorDescription(accessError))"
            )
        }
        return try SecureEnclave.P256.Signing.PrivateKey(
            compactRepresentable: false,
            accessControl: accessControl,
            authenticationContext: authenticationContext
        )
    }

    private func saveKeyRepresentation(_ representation: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: keyDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: keyDirectory.path
        )
        var directoryInfo = stat()
        guard lstat(keyDirectory.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid(),
              (directoryInfo.st_mode & 0o777) == 0o700 else {
            throw HelperError.io("Secure Enclave key directory is unsafe")
        }

        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw HelperError.io("cannot create Secure Enclave key representation")
        }
        var completed = false
        defer {
            Darwin.close(descriptor)
            if !completed {
                Darwin.unlink(url.path)
            }
        }
        try NativeBridgeSocket.writeAll(
            representation,
            to: descriptor,
            label: "Secure Enclave key representation"
        )
        guard Darwin.fsync(descriptor) == 0 else {
            throw HelperError.io("cannot sync Secure Enclave key representation")
        }
        completed = true
    }

    private func loadPrivateKey(
        from url: URL,
        authenticationContext: LAContext
    ) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard try keyExists(at: url) else {
            throw HelperError.io("Secure Enclave key representation is missing")
        }
        let representation = try Data(contentsOf: url, options: .uncached)
        guard representation.count <= 4096 else {
            throw HelperError.io("Secure Enclave key representation is too large")
        }
        return try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: representation,
            authenticationContext: authenticationContext
        )
    }

    private func errorDescription(_ error: Unmanaged<CFError>?) -> String {
        error?.takeRetainedValue().localizedDescription
            ?? "unknown Security framework error"
    }
}

final class NativeAuthenticationBridge {
    typealias FocusProbe = () -> Bool
    typealias ProcessAlive = () -> Bool

    private let descriptor: Int32
    private let signer: HostAuthorizationSigning
    private let focusProbe: FocusProbe
    private let processAlive: ProcessAlive
    private let stopLock = NSLock()
    private var stopped = false

    init(
        targetPID: pid_t,
        socketPath: String,
        signer: HostAuthorizationSigning = SecureEnclaveAuthorizationSigner(),
        focusProbe: FocusProbe? = nil,
        processAlive: ProcessAlive? = nil
    ) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("native authentication bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(
            path: socketPath,
            label: "authentication bridge"
        )
        self.signer = signer
        self.focusProbe = focusProbe ?? {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID,
                  let application = NSRunningApplication(processIdentifier: targetPID) else {
                return false
            }
            return application.isActive && !application.isTerminated
        }
        self.processAlive = processAlive ?? { processIdentity.isStillRunning }
    }

    deinit {
        stop()
    }

    func run() throws {
        var line = Data()
        while true {
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    try handle(line)
                    line.removeAll(keepingCapacity: true)
                } else if byte != 0x0D {
                    guard line.count < NativeAuthenticationRequest.maximumLineBytes else {
                        throw HelperError.io("guest authentication request exceeds 4 KiB")
                    }
                    line.append(byte)
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest authentication channel")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        stopLock.unlock()
        signer.cancel()
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func handle(_ data: Data) throws {
        let request = try NativeAuthenticationRequest.decode(data)
        if request.operation == .disable {
            var disabled = false
            if processAlive(), focusProbe() {
                do {
                    try signer.disable(guestID: request.guestID)
                    disabled = true
                } catch {
                    fputs("[authentication-bridge] \(error.localizedDescription)\n", stderr)
                }
            }
            let response = disabled
                ? NativeAuthenticationResponse(disabledRequest: request)
                : NativeAuthenticationResponse(request: request, approval: nil)
            try NativeBridgeSocket.writeAll(
                response.encode(),
                to: descriptor,
                label: "authentication"
            )
            return
        }
        var approval: NativeAuthenticationApproval?
        if processAlive(), focusProbe() {
            do {
                let candidate = try signer.authorize(request)
                if processAlive(), focusProbe() {
                    approval = candidate
                }
            } catch {
                fputs("[authentication-bridge] \(error.localizedDescription)\n", stderr)
            }
        }
        let response = NativeAuthenticationResponse(request: request, approval: approval)
        try NativeBridgeSocket.writeAll(
            response.encode(),
            to: descriptor,
            label: "authentication"
        )
    }
}
