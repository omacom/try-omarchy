import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Native authentication bridge")
struct NativeAuthenticationBridgeTests {
    private let requestID = "2a8adad0-e2e3-43a0-882f-82f64d691c86"
    private let challenge = String(repeating: "ab", count: 32)
    private let guestID = String(repeating: "ef", count: 32)

    @Test("an abandoned prompt is canceled and late approval cannot approve the next prompt")
    func promptTimeout() {
        var lateCompletion: ((Bool) -> Void)?
        var canceled = false
        #expect(!NativeAuthenticationPrompt.approve(
            timeout: 0.01,
            evaluate: { lateCompletion = $0 },
            cancel: { canceled = true }
        ))
        #expect(canceled)
        lateCompletion?(true)
        #expect(!NativeAuthenticationPrompt.approve(
            evaluate: { $0(false) }, cancel: {}
        ))
        #expect(NativeAuthenticationPrompt.approve(
            evaluate: { $0(true) }, cancel: {}
        ))
    }

    @Test("sudo requests use a strict versioned context")
    func sudoRequestSchema() throws {
        let line = Data(
            #"{"challenge":"\#(challenge)","guestId":"\#(guestID)","operation":"sudo","requestId":"\#(requestID)","requestingUser":"test","service":"sudo","tty":"/dev/pts/4","type":"authorize","user":"test","version":3}"#.utf8
        )
        #expect(
            try NativeAuthenticationRequest.decode(line)
                == NativeAuthenticationRequest(
                    operation: .sudo,
                    guestID: guestID,
                    requestID: requestID,
                    challenge: challenge,
                    user: "test",
                    requestingUser: "test",
                    service: "sudo",
                    tty: "/dev/pts/4"
                )
        )
    }

    @Test("1Password unlock is separated from sudo and other 1Password actions")
    func onePasswordRequestSchema() throws {
        let line = Data(
            #"{"challenge":"\#(challenge)","guestId":"\#(guestID)","operation":"onepassword-unlock","requestId":"\#(requestID)","requestingUser":"test","service":"com.1password.1Password.unlock","tty":"","type":"authorize","user":"test","version":3}"#.utf8
        )
        let request = try NativeAuthenticationRequest.decode(line)
        #expect(request.operation == .onePasswordUnlock)
        #expect(request.operation.localizedReason == "Unlock 1Password in the focused Try Omarchy guest")
        for (field, value) in [
            ("service", "sudo"), ("service", "com.1password.1Password.authorizeCLI"),
            ("requestingUser", "other"), ("tty", "/dev/pts/4"), ("operation", "sudo"),
        ] {
            var object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
            object[field] = value
            let invalid = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: HelperError.self) { try NativeAuthenticationRequest.decode(invalid) }
        }
    }

    @Test("enrollment cannot smuggle sudo context")
    func enrollmentSchema() throws {
        let valid = Data(
            #"{"challenge":"\#(challenge)","guestId":"\#(guestID)","operation":"enroll","requestId":"\#(requestID)","requestingUser":"","service":"sudo","tty":"","type":"authorize","user":"","version":3}"#.utf8
        )
        #expect(try NativeAuthenticationRequest.decode(valid).operation == .enroll)

        let invalid = Data(
            #"{"challenge":"\#(challenge)","guestId":"\#(guestID)","operation":"enroll","requestId":"\#(requestID)","requestingUser":"test","service":"sudo","tty":"","type":"authorize","user":"test","version":3}"#.utf8
        )
        #expect(throws: HelperError.self) {
            try NativeAuthenticationRequest.decode(invalid)
        }
    }

    @Test("malformed or extensible authorization requests are rejected")
    func invalidRequests() {
        for line in [
            "not json",
            #"{"challenge":"short","guestId":"\#(guestID)","operation":"sudo","requestId":"\#(requestID)","requestingUser":"test","service":"sudo","tty":"/dev/pts/1","type":"authorize","user":"test","version":3}"#,
            #"{"challenge":"\#(challenge)","guestId":"short","operation":"sudo","requestId":"\#(requestID)","requestingUser":"test","service":"sudo","tty":"/dev/pts/1","type":"authorize","user":"test","version":3}"#,
            #"{"challenge":"\#(challenge)","guestId":"\#(guestID)","operation":"sudo","requestId":"not-a-uuid","requestingUser":"test","service":"sudo","tty":"/dev/pts/1","type":"authorize","user":"test","version":3}"#,
            #"{"challenge":"\#(challenge)","guestId":"\#(guestID)","operation":"sudo","requestId":"\#(requestID)","requestingUser":"test","service":"login","tty":"/dev/pts/1","type":"authorize","user":"test","version":3}"#,
            #"{"challenge":"\#(challenge)","guestId":"\#(guestID)","operation":"sudo","requestId":"\#(requestID)","requestingUser":"test","service":"sudo","tty":"unknown","type":"authorize","user":"test","version":3}"#,
            #"{"challenge":"\#(challenge)","extra":true,"guestId":"\#(guestID)","operation":"sudo","requestId":"\#(requestID)","requestingUser":"test","service":"sudo","tty":"/dev/pts/1","type":"authorize","user":"test","version":3}"#,
        ] {
            #expect(throws: HelperError.self) {
                try NativeAuthenticationRequest.decode(Data(line.utf8))
            }
        }
    }

    @Test("signature payload binds every sudo context field")
    func signaturePayload() {
        let request = NativeAuthenticationRequest(
            operation: .sudo,
            guestID: guestID,
            requestID: requestID,
            challenge: challenge,
            user: "root",
            requestingUser: "test",
            service: "sudo",
            tty: "/dev/pts/7"
        )
        #expect(
            request.signaturePayload(
                issuedAt: 1_788_623_100,
                expiresAt: 1_788_623_115,
                keyID: String(repeating: "cd", count: 32)
            )
                == Data(
                    [
                        "try-omarchy-native-authentication-v3",
                        guestID,
                        "sudo",
                        requestID,
                        challenge,
                        "root",
                        "test",
                        "sudo",
                        "/dev/pts/7",
                        "1788623100",
                        "1788623115",
                        String(repeating: "cd", count: 32),
                    ].joined(separator: "\0").utf8
                )
        )
    }

    @Test("approved responses carry signed material and denials carry none")
    func responseSchema() throws {
        let request = NativeAuthenticationRequest(
            operation: .sudo,
            guestID: guestID,
            requestID: requestID,
            challenge: challenge,
            user: "test",
            requestingUser: "test",
            service: "sudo",
            tty: "/dev/pts/2"
        )
        let publicKey = Data([0x04] + Array(repeating: UInt8(0x11), count: 64))
        let signature = Data([0x30, 0x02, 0x01, 0x01])
        let encoded = try NativeAuthenticationResponse(
            request: request,
            approval: NativeAuthenticationApproval(
                issuedAt: 1_788_623_100,
                expiresAt: 1_788_623_115,
                keyID: String(repeating: "cd", count: 32),
                publicKey: publicKey,
                signature: signature
            )
        ).encode()
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object.keys.sorted() == [
            "approved", "challenge", "expiresAt", "guestId", "issuedAt", "keyId",
            "operation", "publicKey", "requestId", "requestingUser", "service",
            "signature", "tty", "type", "user", "version",
        ])
        #expect(object["approved"] as? Bool == true)
        #expect(object["publicKey"] as? String == publicKey.base64EncodedString())
        #expect(object["signature"] as? String == signature.base64EncodedString())
        #expect(encoded.last == 0x0A)

        let denied = try NativeAuthenticationResponse(request: request, approval: nil).encode()
        let deniedObject = try #require(
            JSONSerialization.jsonObject(with: denied) as? [String: Any]
        )
        #expect(deniedObject["approved"] as? Bool == false)
        #expect(deniedObject["issuedAt"] as? Int == 0)
        #expect(deniedObject["keyId"] as? String == "")

        let disable = NativeAuthenticationRequest(
            operation: .disable,
            guestID: guestID,
            requestID: requestID,
            challenge: challenge,
            user: "",
            requestingUser: "",
            service: "sudo",
            tty: ""
        )
        let disabled = try NativeAuthenticationResponse(disabledRequest: disable).encode()
        let disabledObject = try #require(
            JSONSerialization.jsonObject(with: disabled) as? [String: Any]
        )
        #expect(disabledObject["approved"] as? Bool == true)
        #expect(disabledObject["issuedAt"] as? Int == 0)
        #expect(disabledObject["keyId"] as? String == "")
    }

    @Test("prompt text is fixed by operation and approvals are short-lived")
    func promptPolicy() {
        #expect(NativeAuthenticationOperation.enroll.localizedReason.contains("Pair"))
        #expect(NativeAuthenticationOperation.disable.localizedReason.contains("Disable"))
        #expect(NativeAuthenticationOperation.sudo.localizedReason.contains("sudo"))
        #expect(SecureEnclaveAuthorizationSigner.approvalLifetimeSeconds == 15)
    }

    @Test("disable removes only the requested safe key representation")
    func disableKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let key = directory.appendingPathComponent("\(guestID).key")
        try Data([0x01, 0x02]).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        let signer = SecureEnclaveAuthorizationSigner(keyDirectory: directory)

        try signer.disable(guestID: guestID)
        #expect(!FileManager.default.fileExists(atPath: key.path))
        try signer.disable(guestID: guestID)
    }
}
