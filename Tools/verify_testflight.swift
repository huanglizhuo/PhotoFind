import CryptoKit
import Foundation

// asc-cli cannot read build/group relationships; verify Apple's automatic internal distribution.
func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func containsBuild(_ data: Data, id: String) throws -> Bool {
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let builds = object?["data"] as? [[String: Any]] else {
        throw NSError(domain: "TestFlight", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid build response"])
    }
    return builds.contains { ($0["id"] as? String) == id && ($0["type"] as? String) == "builds" }
}

if CommandLine.arguments.dropFirst().first == "--self-test" {
    assert(base64URL(Data([251, 255])) == "-_8")
    let sample = Data(#"{"data":[{"id":"expected","type":"builds"}]}"#.utf8)
    let found = try containsBuild(sample, id: "expected")
    let missing = try containsBuild(sample, id: "other")
    assert(found && !missing)
    do {
        _ = try containsBuild(Data("{}".utf8), id: "expected")
        fatalError("Malformed response accepted")
    } catch {}
    print("TestFlight group checks passed")
} else {
    let env = ProcessInfo.processInfo.environment
    guard CommandLine.arguments.count == 3,
          let keyID = env["ASC_KEY_ID"], let issuer = env["ASC_ISSUER_ID"],
          let keyPath = env["ASC_PRIVATE_KEY_PATH"] else {
        fatalError("Expected build ID, group ID and ASC credentials")
    }
    let build = CommandLine.arguments[1], group = CommandLine.arguments[2]
    guard UUID(uuidString: build) != nil, UUID(uuidString: group) != nil else {
        fatalError("Invalid build/group ID")
    }
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let claims = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 300, "aud": "appstoreconnect-v1"])
    let payload = "\(base64URL(header)).\(base64URL(claims))"
    let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: keyPath, encoding: .utf8))
    let token = payload + "." + base64URL(try key.signature(for: Data(payload.utf8)).rawRepresentation)
    var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com/v1/betaGroups/\(group)/relationships/builds?limit=200")!)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        print("Distribution check failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        print(String(data: data, encoding: .utf8) ?? "")
        exit(1)
    }
    guard try containsBuild(data, id: build) else {
        print("Build is not yet assigned to the expected internal group")
        exit(1)
    }
    print("Verified TestFlight build \(build) in internal group \(group)")
}
