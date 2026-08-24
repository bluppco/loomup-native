import CryptoKit
import Foundation
import Loomup

#if canImport(DeviceCheck) && os(iOS)
import DeviceCheck
import StoreKit
#endif

public enum AppleAppIntegrityError: Error, Sendable {
    case unsupportedPlatform
    case unavailable
    case malformedResponse
    case server(String)
}

/// App Attest provider for App Store and TestFlight builds. The provider owns
/// an install key in Keychain and obtains a fresh server grant for every
/// protected request.
public actor AppleAppIntegrityProvider: AppIntegrityProvider {
    private let baseURL: URL
    private let appID: String
    private let http: any HTTPTransport
    private let keyStore: KeychainRefreshTokenStore

    public init(
        baseURL: URL,
        appID: String,
        http: any HTTPTransport = URLSessionHTTPTransport()
    ) {
        self.baseURL = baseURL
        self.appID = appID
        self.http = http
        self.keyStore = KeychainRefreshTokenStore(
            service: "com.loomup.sdk.app-attest-key",
            account: appID
        )
    }

    public func prepareGrant(for request: AppIntegrityRequest) async throws -> String {
#if canImport(DeviceCheck) && os(iOS)
        let challenge: ChallengeEnvelope = try await post(
            path: "/app-integrity/v1/challenge",
            body: ChallengeBody(
                appID: appID,
                platform: "ios",
                method: request.method,
                pathAndQuery: request.pathAndQuery,
                bodySHA256: request.bodySHA256
            ),
            token: request.authorizationToken
        )
        guard DCAppAttestService.shared.isSupported else {
            throw AppleAppIntegrityError.unavailable
        }
        // App Attest expects SHA256(clientData). The server uses the provider
        // request hash string as clientData and verifies this exact digest.
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.data.requestHash.utf8)))
        var keyID = try keyStore.loadRefreshToken()
        var keyToPersist: String?
        let usingExistingKey = keyID != nil
        let proof: ProofBody
        let kind: String
        if let existingKey = keyID {
            let assertion: Data
            do {
                assertion = try await DCAppAttestService.shared.generateAssertion(
                    existingKey,
                    clientDataHash: clientDataHash
                )
            } catch {
                // Device restores and App Attest key invalidation can leave a
                // stale identifier in Keychain. Re-register once with a fresh
                // challenge instead of permanently wedging the installation.
                try keyStore.saveRefreshToken(nil)
                return try await prepareGrant(for: request)
            }
            kind = "apple_app_attest"
            proof = ProofBody(
                attestationObject: nil,
                assertion: assertion.base64EncodedString(),
                clientDataHash: clientDataHash.base64EncodedString(),
                appTransaction: nil
            )
        } else {
            let newKey = try await DCAppAttestService.shared.generateKey()
            let attestation = try await DCAppAttestService.shared.attestKey(
                newKey,
                clientDataHash: clientDataHash
            )
            keyID = newKey
            keyToPersist = newKey
            let transaction = try await AppTransaction.shared
            kind = "apple_app_attest"
            proof = ProofBody(
                attestationObject: attestation.base64EncodedString(),
                assertion: nil,
                clientDataHash: clientDataHash.base64EncodedString(),
                appTransaction: transaction.jwsRepresentation
            )
        }
        let verified: VerifyEnvelope
        do {
            verified = try await post(
                path: "/app-integrity/v1/verify",
                body: VerifyBody(
                    challengeID: challenge.data.challengeID,
                    appID: appID,
                    platform: "ios",
                    proofKind: kind,
                    proof: proof,
                    keyID: keyID
                ),
                token: request.authorizationToken
            )
        } catch AppleAppIntegrityError.server(let message)
            where usingExistingKey && message.contains("unknown Apple App Attest key")
        {
            try keyStore.saveRefreshToken(nil)
            return try await prepareGrant(for: request)
        }
        if let keyToPersist {
            try keyStore.saveRefreshToken(keyToPersist)
        }
        return verified.data.grant
#else
        throw AppleAppIntegrityError.unsupportedPlatform
#endif
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        token: String?
    ) async throws -> Response {
        let data = try JSONEncoder().encode(body)
        var request = URLRequest(url: joined(path))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (responseData, response) = try await http.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AppleAppIntegrityError.server(String(data: responseData, encoding: .utf8) ?? "HTTP \(status)")
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: responseData) else {
            throw AppleAppIntegrityError.malformedResponse
        }
        return decoded
    }

    private func joined(_ path: String) -> URL {
        URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!
    }

}

private struct ChallengeBody: Encodable {
    let appID: String
    let platform: String
    let method: String
    let pathAndQuery: String
    let bodySHA256: String
    enum CodingKeys: String, CodingKey {
        case appID = "app_id"
        case platform, method
        case pathAndQuery = "path_and_query"
        case bodySHA256 = "body_sha256"
    }
}

private struct ChallengeEnvelope: Decodable {
    struct Payload: Decodable {
        let challengeID: String
        let nonce: String
        let requestHash: String
        enum CodingKeys: String, CodingKey {
            case challengeID = "challenge_id"
            case nonce
            case requestHash = "request_hash"
        }
    }
    let data: Payload
}

private struct ProofBody: Codable {
    let attestationObject: String?
    let assertion: String?
    let clientDataHash: String
    let appTransaction: String?
    enum CodingKeys: String, CodingKey {
        case attestationObject = "attestation_object"
        case assertion
        case clientDataHash = "client_data_hash"
        case appTransaction = "app_transaction"
    }
}

private struct VerifyBody: Encodable {
    let challengeID: String
    let appID: String
    let platform: String
    let proofKind: String
    let proof: ProofBody
    let keyID: String?
    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case appID = "app_id"
        case platform
        case proofKind = "proof_kind"
        case proof
        case keyID = "key_id"
    }
}

private struct VerifyEnvelope: Decodable {
    struct Payload: Decodable { let grant: String }
    let data: Payload
}
