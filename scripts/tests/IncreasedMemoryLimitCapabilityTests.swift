// Run from the repository root:
// swiftc -swift-version 6 SideStore/Core/Auth/IncreasedMemoryLimitCapability.swift \
//   scripts/tests/IncreasedMemoryLimitCapabilityTests.swift -o /tmp/memory-capability-tests
// /tmp/memory-capability-tests
// All URLSession requests are intercepted. No Apple account or network is used.

import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    func allRequests() -> [URLRequest] {
        lock.withLock { requests }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = RequestRecorder()

    // Claim every request so even an accidental URL change cannot access a network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        let identifier = request.url!.lastPathComponent
        if identifier == "NETWORK_FAILURE" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }

        let status: Int
        let body: String
        switch identifier {
        case "SUCCESS", "OTHER_APP":
            status = 200
            body = #"{"data":{"id":"\#(identifier)","type":"bundleIds"}}"#
        case "CREATED":
            status = 201
            body = #"{"data":{"id":"CREATED","type":"bundleIds"}}"#
        case "CONFLICT":
            status = 409
            body = #"{"errors":[{"title":"Capability conflict","detail":"Personal Team cannot enable this capability."}]}"#
        case "FORBIDDEN":
            status = 403
            body = #"{"errors":[{"title":"Authentication required"}]}"#
        case "SERVER_FAILURE":
            status = 500
            body = "unavailable"
        case "ERROR_IN_SUCCESS":
            status = 200
            body = #"{"errors":[{"detail":"Capability rejected."}],"data":{"id":"ERROR_IN_SUCCESS","type":"bundleIds"}}"#
        case "EMPTY":
            status = 204
            body = ""
        case "INVALID_JSON":
            status = 200
            body = "not json"
        case "MISSING_DATA":
            status = 200
            body = "{}"
        case "WRONG_APP":
            status = 200
            body = #"{"data":{"id":"another-app-id","type":"bundleIds"}}"#
        case "WRONG_TYPE":
            status = 200
            body = #"{"data":{"id":"WRONG_TYPE","type":"capabilities"}}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/vnd.api+json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
private struct IncreasedMemoryLimitCapabilityTests {
    static func makeRequest(_ identifier: String) throws -> URLRequest {
        try IncreasedMemoryLimitCapability.makeRequest(
            baseURL: URL(string: "https://memory-capability.test/services/v1/")!,
            appID: identifier,
            name: "Memory Test",
            bundleIdentifier: "test.memory.app",
            teamID: "TESTTEAM",
            headers: ["X-Apple-I-Identity-Id": "fixture-user", "X-Apple-GS-Token": "fixture-token",
                      "Content-Type": "incorrect/value"]
        )
    }

    static func verifyRequest() throws {
        let request = try makeRequest("SUCCESS")
        try expect(request.url?.absoluteString == "https://memory-capability.test/services/v1/bundleIds/SUCCESS", "Wrong capability URL")
        try expect(request.httpMethod == "PATCH", "Modern capability must use raw PATCH")
        try expect(request.value(forHTTPHeaderField: "X-HTTP-Method-Override") == nil, "Unexpected method override")
        try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.api+json", "Wrong content type")
        try expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.api+json", "Wrong Accept header")
        try expect(request.value(forHTTPHeaderField: "X-Apple-I-Identity-Id") == "fixture-user", "Missing session identity")
        try expect(request.value(forHTTPHeaderField: "X-Apple-GS-Token") == "fixture-token", "Missing session token")

        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try expect(body["urlEncodedQueryParams"] == nil, "Legacy request wrapper must not replace capability JSON")
        let resource = body["data"] as! [String: Any]
        try expect(resource["id"] as? String == "SUCCESS", "Resource must use portal App ID, not bundle identifier")
        try expect(resource["type"] as? String == "bundleIds", "Wrong resource type")
        let attributes = resource["attributes"] as! [String: Any]
        try expect(attributes["identifier"] as? String == "test.memory.app", "Wrong bundle identifier")
        try expect(attributes["name"] as? String == "Memory Test", "Wrong app name")
        try expect(attributes["teamId"] as? String == "TESTTEAM", "Wrong team")
        try expect(attributes["seedId"] as? String == "TESTTEAM", "Wrong seed")
        try expect(attributes["bundleType"] as? String == "bundle", "Wrong bundle type")
        try expect(attributes["hasExclusiveManagedCapabilities"] as? Bool == false, "Unexpected managed capability")
        let relationships = resource["relationships"] as! [String: Any]
        let capabilities = relationships["bundleIdCapabilities"] as! [String: Any]
        let entries = capabilities["data"] as! [[String: Any]]
        try expect(entries.count == 1, "Only requested memory capability should be changed")
        let entry = entries[0]
        try expect(entry["type"] as? String == "bundleIdCapabilities", "Wrong relationship type")
        let entryAttributes = entry["attributes"] as! [String: Any]
        try expect(entryAttributes["enabled"] as? Bool == true, "Capability must be enabled")
        try expect((entryAttributes["settings"] as? [Any])?.isEmpty == true, "Unexpected capability settings")
        let entryRelationships = entry["relationships"] as! [String: Any]
        let capability = entryRelationships["capability"] as! [String: Any]
        let capabilityResource = capability["data"] as! [String: Any]
        try expect(capabilityResource["id"] as? String == "INCREASED_MEMORY_LIMIT", "Wrong modern capability identifier")
        try expect(capabilityResource["type"] as? String == "capabilities", "Wrong capability resource type")
    }

    static func verifyRequestedEntitlement() throws {
        let key = IncreasedMemoryLimitCapability.entitlement
        func requested(_ original: [String: any Sendable], _ custom: [String: any Sendable]? = nil,
                       _ additional: (any Sendable)? = nil) -> Bool {
            IncreasedMemoryLimitCapability.isRequested(original: original, custom: custom, additionalValue: additional)
        }
        try expect(requested([key: true]), "Source IPA request was lost")
        try expect(requested([key: true], [:]), "Old cached profile must not hide the source IPA request")
        try expect(!requested([:]), "Missing entitlement must not request a capability")
        try expect(!requested([key: false]), "Source false must not request a capability")
        try expect(!requested([key: true], [key: false]), "Explicit custom false must suppress the request")
        try expect(requested([:], [key: true]), "Explicit custom request was lost")
        try expect(!requested([key: true], nil, false), "Main bundle override must take precedence")
        try expect(requested([key: true], nil, "entitlement descriptor"), "A descriptor is not a Boolean override")
    }

    static func expectFailure(_ identifier: String, containing text: String, session: URLSession) async throws {
        do {
            try await IncreasedMemoryLimitCapability.enable(using: makeRequest(identifier), session: session)
        } catch {
            try expect(error.localizedDescription.contains(text), "\(identifier): unexpected error: \(error.localizedDescription)")
            return
        }
        throw TestFailure(description: "\(identifier): unexpectedly succeeded")
    }

    static func main() async throws {
        try verifyRequestedEntitlement()
        try verifyRequest()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for identifier in ["SUCCESS", "OTHER_APP", "CREATED"] {
            try await IncreasedMemoryLimitCapability.enable(using: makeRequest(identifier), session: session)
        }
        try await expectFailure("CONFLICT", containing: "Personal Team cannot enable this capability.", session: session)
        try await expectFailure("FORBIDDEN", containing: "Authentication required", session: session)
        try await expectFailure("SERVER_FAILURE", containing: "HTTP 500", session: session)
        try await expectFailure("ERROR_IN_SUCCESS", containing: "Capability rejected.", session: session)
        for identifier in ["EMPTY", "INVALID_JSON", "MISSING_DATA", "WRONG_APP", "WRONG_TYPE"] {
            try await expectFailure(identifier, containing: "invalid response", session: session)
        }
        do {
            try await IncreasedMemoryLimitCapability.enable(using: makeRequest("NETWORK_FAILURE"), session: session)
            throw TestFailure(description: "Network error unexpectedly succeeded")
        } catch let error as URLError {
            try expect(error.code == .timedOut, "Network error did not propagate unchanged")
        }

        let requests = StubURLProtocol.recorder.allRequests()
        try expect(requests.count == 13, "Unexpected number of outgoing requests: \(requests.count)")
        try expect(requests.allSatisfy { $0.httpMethod == "PATCH" }, "URLSession changed PATCH method")
        try expect(requests.allSatisfy { $0.url?.host == "memory-capability.test" }, "Unexpected request host")
        try expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Apple-GS-Token") == "fixture-token" }, "URLSession lost session headers")
        print("PASS: request contract and 13 mocked capability responses; no network access")
    }
}
