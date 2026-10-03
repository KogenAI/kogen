import Foundation
import Security

let arguments = CommandLine.arguments
var keychainReference: SecKeychain?
let openStatus = SecKeychainOpen(arguments[1], &keychainReference)

guard openStatus == errSecSuccess, let keychain = keychainReference else {
  fputs("unable to open test keychain: \(openStatus)\n", stderr)
  exit(1)
}

var securityApplicationReference: SecTrustedApplication?
let applicationStatus =
  SecTrustedApplicationCreateFromPath("/usr/bin/security", &securityApplicationReference)

guard applicationStatus == errSecSuccess,
      let securityApplication = securityApplicationReference else {
  fputs("unable to trust security for test keychain: \(applicationStatus)\n", stderr)
  exit(1)
}

var accessReference: SecAccess?
let accessStatus = SecAccessCreate(
  "Kogen temporary test item" as CFString,
  [securityApplication] as CFArray,
  &accessReference
)

guard accessStatus == errSecSuccess, let access = accessReference else {
  fputs("unable to create test keychain access: \(accessStatus)\n", stderr)
  exit(1)
}

do {
  let passwordData = try Data(contentsOf: URL(fileURLWithPath: arguments[3]))
  let item: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "kogen",
    kSecAttrAccount as String: arguments[2],
    kSecValueData as String: passwordData,
    kSecAttrAccess as String: access,
    kSecUseKeychain as String: keychain
  ]
  let status = SecItemAdd(item as CFDictionary, nil)

  guard status == errSecSuccess else {
    fputs("unable to add test item: \(status)\n", stderr)
    exit(1)
  }
} catch {
  fputs("unable to read test item data: \(error)\n", stderr)
  exit(1)
}
