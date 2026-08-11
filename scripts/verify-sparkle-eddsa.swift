import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(70)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: verify-sparkle-eddsa.swift UPDATE SIGNATURE PUBLIC_KEY")
}

let updateURL = URL(fileURLWithPath: CommandLine.arguments[1])
let signatureText = CommandLine.arguments[2]
let publicKeyText = CommandLine.arguments[3]

guard
    let signature = Data(base64Encoded: signatureText),
    signature.count == 64,
    signature.base64EncodedString() == signatureText
else {
    fail("invalid EdDSA signature encoding")
}
guard
    let publicKeyData = Data(base64Encoded: publicKeyText),
    publicKeyData.count == 32,
    publicKeyData.base64EncodedString() == publicKeyText
else {
    fail("invalid EdDSA public key encoding")
}

do {
    let update = try Data(contentsOf: updateURL, options: .mappedIfSafe)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard publicKey.isValidSignature(signature, for: update) else {
        fail("EdDSA signature verification failed")
    }
} catch {
    fail("could not verify EdDSA signature")
}
