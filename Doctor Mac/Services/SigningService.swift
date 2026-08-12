//
//  SigningService.swift
//  Doctor Mac
//
//  Lists code-signing identities available in the login keychain.
//

import Foundation
import Security

enum SigningService {
    /// Parse `security find-identity -v -p codesigning`, then resolve each
    /// certificate's expiry from the keychain.
    static func identities() async -> [SigningIdentity] {
        let res = await Shell.capture(
            ["security", "find-identity", "-v", "-p", "codesigning"])
        var out: [SigningIdentity] = []
        // Lines like:  1) <40-hex-sha1> "Developer ID Application: Name (TEAM)"
        for line in res.output.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let firstQuote = t.firstIndex(of: "\""),
                  let lastQuote = t.lastIndex(of: "\""), firstQuote < lastQuote else { continue }
            let name = String(t[t.index(after: firstQuote)..<lastQuote])
            // The sha1 is the 40-hex token before the first quote.
            let prefix = t[..<firstQuote]
            let sha1 = prefix.split(separator: " ").first { $0.count == 40 && $0.allSatisfy { $0.isHexDigit } }
            guard let sha1 = sha1 else { continue }
            out.append(SigningIdentity(sha1: String(sha1), name: name,
                                       expiry: await expiry(certificateNamed: name)))
        }
        return out
    }

    /// Expiry (notAfter) of the certificate with the given common name, via the
    /// keychain PEM. If several match (renewed certs), the latest expiry wins.
    static func expiry(certificateNamed name: String) async -> Date? {
        let res = await Shell.capture(["security", "find-certificate", "-a", "-c", name, "-p"])
        return pemBlocks(in: res.output)
            .compactMap { notAfter(pem: $0) }
            .max()
    }

    private static func pemBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inside = false
        for line in text.split(separator: "\n") {
            if line.contains("BEGIN CERTIFICATE") { inside = true; current = []; continue }
            if line.contains("END CERTIFICATE") { inside = false; blocks.append(current.joined()); continue }
            if inside { current.append(String(line)) }
        }
        return blocks
    }

    private static func notAfter(pem base64: String) -> Date? {
        guard let der = Data(base64Encoded: base64),
              let cert = SecCertificateCreateWithData(nil, der as CFData),
              let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let seconds = entry[kSecPropertyKeyValue] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
