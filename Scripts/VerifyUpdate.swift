import Foundation
import CryptoKit

// All arguments are public. Private signing keys never enter command-line arguments.
let args = CommandLine.arguments
guard args.count == 4, let publicKey = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]) else { exit(2) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
let data = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: data) else {
    fputs("Update signing key does not match the app's embedded public key.\n", stderr)
    exit(1)
}
