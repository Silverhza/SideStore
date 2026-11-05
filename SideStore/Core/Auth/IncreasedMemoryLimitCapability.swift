import Foundation

enum IncreasedMemoryLimitCapability {
    static let entitlement = "com.apple.developer.kernel.increased-memory-limit"

    static func isRequested(original: [String: any Sendable], custom: [String: any Sendable]?,
                            additionalValue: (any Sendable)?) -> Bool {
        // Older cached profiles may lack this key even when the source IPA has it.
        (additionalValue as? Bool) ?? (custom?[entitlement] as? Bool)
            ?? (original[entitlement] as? Bool) ?? false
    }

    static func makeRequest(baseURL: URL, appID: String, name: String, bundleIdentifier: String,
                            teamID: String, headers: [String: String]) throws -> URLRequest {
        // The legacy updateAppId action does not enable this capability. Use the
        // same JSON API as AltSign/GetMoreRam; device behavior needs proper testing.
        let capability: [String: Any] = [
            "type": "bundleIdCapabilities",
            "attributes": ["enabled": true, "settings": []],
            "relationships": [
                "capability": ["data": ["id": "INCREASED_MEMORY_LIMIT", "type": "capabilities"]]
            ]
        ]
        let body: [String: Any] = ["data": [
            "id": appID,
            "type": "bundleIds",
            "attributes": [
                "name": name,
                "identifier": bundleIdentifier,
                "teamId": teamID,
                "seedId": teamID,
                "bundleType": "bundle",
                "hasExclusiveManagedCapabilities": false
            ],
            "relationships": ["bundleIdCapabilities": ["data": [capability]]]
        ]]

        let url = baseURL.appendingPathComponent("bundleIds").appendingPathComponent(appID)
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        return request
    }

    static func enable(using request: URLRequest, session: URLSession = .shared) async throws {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CapabilityError.invalidResponse
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errors = json?["errors"] as? [[String: Any]] ?? []
        if !(200..<300).contains(response.statusCode) || !errors.isEmpty {
            let reason = errors.first?["detail"] as? String
                ?? errors.first?["title"] as? String
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw CapabilityError.rejected(status: response.statusCode, reason: reason)
        }
        guard let resource = json?["data"] as? [String: Any],
              resource["id"] as? String == request.url?.lastPathComponent,
              resource["type"] as? String == "bundleIds" else {
            throw CapabilityError.invalidResponse
        }
    }

    private enum CapabilityError: LocalizedError {
        case invalidResponse
        case rejected(status: Int, reason: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Apple returned an invalid response while enabling Increased Memory Limit."
            case .rejected(let status, let reason):
                return "Could not enable Increased Memory Limit (HTTP \(status)): \(reason)"
            }
        }
    }
}
