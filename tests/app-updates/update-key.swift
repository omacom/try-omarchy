// A throwaway update key for tests; a release's key stays in its Mac's keychain.
//   update-key generate        prints the private seed, then the public key
//   update-key sign SEED FILE  prints FILE's signature

import CryptoKit
import Foundation

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "generate" {
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
} else if arguments.count == 4, arguments[1] == "sign" {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: arguments[2])!)
    let signature = try key.signature(for: Data(contentsOf: URL(filePath: arguments[3])))
    print(signature.base64EncodedString())
} else {
    exit(64)
}
