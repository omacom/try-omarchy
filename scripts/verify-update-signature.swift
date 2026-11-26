// verify-update-signature PUBLIC_KEY SIGNATURE FILE
// Checks FILE the way an installed app does before it installs the update.

import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let publicKey = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
      let file = try? Data(contentsOf: URL(filePath: arguments[3]), options: .alwaysMapped)
else {
    FileHandle.standardError.write(Data("usage: verify-update-signature PUBLIC_KEY SIGNATURE FILE\n".utf8))
    exit(64)
}
exit(key.isValidSignature(signature, for: file) ? 0 : 1)
