import Foundation
import Security
import HowMuchCore

struct AccountIdentity: Codable, Equatable, Identifiable {
    let id: String
    let email: String?
    let displayName: String
    let appleUserID: String
}

struct AccountSession: Codable {
    var accessToken: String
    var refreshToken: String
    var revocationToken: String?
    var expiresAt: Double
    var account: AccountIdentity
}

struct AppleChallenge: Codable {
    let challenge: String
    let nonce: String
}

struct CloudEnvelope: Codable {
    let revision: Int
    let data: TrackerData
    let timezone: String
    let pushReady: Bool?
    /// Made before the official launch.
    let pioneer: Bool?
    /// One of the people building HowMuch.
    let developer: Bool?
    /// Penny items unlocked with gift codes.
    let petUnlocks: [String]?
    /// Coins kept on the server: hellos with friends and gift codes.
    let helloCoins: Int?
}

struct AccountHTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

enum AccountVault {
    private static let service = "com.howmuch.tracker.apple-account"
    static func read<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        var output: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess, let data = output as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw TrackerError.invalid("Your secure account session could not be saved.") }
        } else if status != errSecSuccess { throw TrackerError.invalid("Your secure account session could not be updated.") }
    }
    static func remove(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary)
    }
    static func deviceID() throws -> String {
        if let value = read("installation", as: String.self), UUID(uuidString: value) != nil { return value }
        let value = UUID().uuidString
        try save(value, key: "installation")
        return value
    }
}

@MainActor
final class AccountAPI {
    static let base = URL(string: "https://howmuch-ios.fly.dev")!
    private(set) var session: AccountSession?
    private var refreshTask: Task<AccountSession, Error>?
    func setSession(_ value: AccountSession?) { refreshTask?.cancel(); refreshTask = nil; session = value }

    func publicRequest(_ path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: Self.base.appending(path: path))
        request.httpMethod = "POST"; request.httpBody = body; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }
    func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        guard var current = session else { throw AccountHTTPError(status: 401, message: "Sign in with Apple to continue.") }
        let accountID = current.account.id
        if current.expiresAt < Date().timeIntervalSince1970 + 30 { current = try await refresh() }
        var request = URLRequest(url: Self.base.appending(path: path))
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 25
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let data = try await send(request)
            guard session?.account.id == accountID else { throw CancellationError() }
            return data
        } catch let error as AccountHTTPError where error.status == 401 {
            if session?.accessToken == current.accessToken { current = try await refresh() }
            else if let newer = session { current = newer }
            guard current.account.id == accountID, session?.account.id == accountID else { throw CancellationError() }
            request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
            let data = try await send(request)
            guard session?.account.id == accountID else { throw CancellationError() }
            return data
        }
    }
    private func refresh() async throws -> AccountSession {
        if let task = refreshTask { return try await task.value }
        guard let old = session else { throw AccountHTTPError(status: 401, message: "Sign in again with Apple.") }
        let task = Task<AccountSession, Error> {
            let data = try await self.publicRequest("/v1/auth/refresh", body: JSONEncoder().encode(["refreshToken": old.refreshToken]))
            var next = try JSONDecoder().decode(AccountSession.self, from: data)
            guard next.account.id == old.account.id else { throw TrackerError.invalid("The account session changed unexpectedly.") }
            next.revocationToken = old.revocationToken
            try Task.checkCancellation()
            try AccountVault.save(next, key: "session")
            return next
        }
        refreshTask = task
        do {
            let next = try await task.value
            guard session?.account.id == old.account.id else { throw CancellationError() }
            session = next; refreshTask = nil; return next
        } catch { refreshTask = nil; throw error }
    }
    private func send(_ request: URLRequest) async throws -> Data {
        #if DEBUG
        if let data = try ReceiptUITestFixture.response(for: request) { return data }
        if let data = try TravelReminderUITestFixture.response(for: request) { return data }
        if let data = try PaymentDetectionUITestFixture.response(for: request) { return data }
        if let data = try PetCodesUITestFixture.response(for: request) { return data }
        if let data = try TelegramUITestFixture.response(for: request) { return data }
        if let data = try FriendsUITestFixture.response(for: request) { return data }
        #endif
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw AccountHTTPError(status: status, message: object?["detail"] as? String ?? "HowMuch could not complete that request. Please try again.")
        }
        return data
    }
}

#if DEBUG
/// Penny gift codes for UI tests: making codes, and redeeming one.
@MainActor
private enum PetCodesUITestFixture {
    static var codes: [[String: Any]] = []
    static func response(for request: URLRequest) throws -> Data? {
        guard CommandLine.arguments.contains("--ui-test-pet-codes"), let path = request.url?.path, path.hasPrefix("/v1/pet/") else { return nil }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if path == "/v1/pet/redeem" {
            if (body["code"] as? String)?.uppercased() == "COINS100" {
                return try JSONSerialization.data(withJSONObject: ["items": [], "coins": 100, "unlocked": [], "helloCoins": 100])
            }
            guard (body["code"] as? String)?.uppercased() == "LAUNCH2026" else { throw AccountHTTPError(status: 404, message: "That code isn't valid. Check it and try again.") }
            return try JSONSerialization.data(withJSONObject: ["items": ["halo", "fireworks"], "unlocked": ["fireworks", "halo"]])
        }
        if path == "/v1/pet/codes", request.httpMethod == "POST" {
            let code: [String: Any] = ["code": (body["code"] as? String)?.uppercased() ?? "PENNY-TEST-CODE", "items": body["items"] ?? [], "coins": body["coins"] ?? 0, "label": body["label"] ?? "",
                                       "maxUses": body["max_uses"] ?? 1, "uses": 0, "expires": 0, "created": 0, "disabled": false]
            codes.insert(code, at: 0)
            return try JSONSerialization.data(withJSONObject: code)
        }
        if path.hasPrefix("/v1/pet/codes/"), path.hasSuffix("/forever"), request.httpMethod == "DELETE" {
            let target = String(path.dropFirst("/v1/pet/codes/".count).dropLast("/forever".count)).uppercased()
            guard let index = codes.firstIndex(where: { ($0["code"] as? String) == target }) else { throw AccountHTTPError(status: 404, message: "Code not found.") }
            guard codes[index]["disabled"] as? Bool == true else { throw AccountHTTPError(status: 409, message: "Revoke this code before deleting it.") }
            codes.remove(at: index)
            return try JSONSerialization.data(withJSONObject: ["deleted": target])
        }
        if path.hasPrefix("/v1/pet/codes/"), request.httpMethod == "DELETE" {
            let target = String(path.dropFirst("/v1/pet/codes/".count)).uppercased()
            guard let index = codes.firstIndex(where: { ($0["code"] as? String) == target }) else { throw AccountHTTPError(status: 404, message: "Code not found.") }
            codes[index]["disabled"] = true
            return try JSONSerialization.data(withJSONObject: codes[index])
        }
        return try JSONSerialization.data(withJSONObject: ["codes": codes])
    }
}

/// Friends for UI tests: one friend (Sam's pet Mochi) and one request (Alex).
@MainActor
enum FriendsUITestFixture {
    static func card(_ pet: String, _ owner: String, hat: String) -> [String: Any] {
        ["petName": pet, "ownerName": owner, "stage": 2, "level": 6, "mood": "happy", "streakWeeks": 3,
         "outfit": ["hat": hat, "background": "mint"], "badges": ["first-shift", "regular"]]
    }
    static var friends: [[String: Any]] = [["code": "PENNY-SAMSAM", "card": card("Mochi", "Sam", hat: "party-hat"), "saidHiToday": false, "theySaidHiToday": true]]
    static var incoming: [[String: Any]] = [["code": "PENNY-ALEXAL", "card": card("Bean", "Alex", hat: "beanie"), "saidHiToday": false, "theySaidHiToday": false]]
    static var coins = 0
    static var failedRemoval = false
    static func response(for request: URLRequest) throws -> Data? {
        guard CommandLine.arguments.contains("--ui-test-friends"), let path = request.url?.path, path.hasPrefix("/v1/friends") else { return nil }
        if path.hasSuffix("/hello"), let index = friends.firstIndex(where: { path.contains(($0["code"] as! String)) }) {
            friends[index]["saidHiToday"] = true; coins += 2
            return try JSONSerialization.data(withJSONObject: ["friend": friends[index], "helloCoins": coins])
        }
        if path == "/v1/friends/card" { return try JSONSerialization.data(withJSONObject: ["saved": true]) }
        if path == "/v1/friends", request.httpMethod == "POST" {
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if let index = incoming.firstIndex(where: { $0["code"] as? String == body["code"] as? String }) { friends.append(incoming.remove(at: index)) }
            else { throw AccountHTTPError(status: 404, message: "That friend code isn't right. Check it and try again.") }
        }
        if request.httpMethod == "DELETE" {
            if CommandLine.arguments.contains("--ui-test-friend-remove-error"), !failedRemoval {
                failedRemoval = true
                throw AccountHTTPError(status: 503, message: "Server unavailable.")
            }
            friends.removeAll { path.hasSuffix($0["code"] as! String) }; incoming.removeAll { path.hasSuffix($0["code"] as! String) }
        }
        return try JSONSerialization.data(withJSONObject: ["code": "PENNY-MYCODE", "link": "https://howmuch-ios.fly.dev/friend/MYCODE",
                                                           "friends": friends, "incoming": incoming, "outgoing": [], "helloCoins": coins])
    }
}

/// Telegram linking for UI tests: a link code, then linked once the test says the bot confirmed it.
@MainActor
enum TelegramUITestFixture {
    static var linked = false
    static var openedLink: URL?
    static func response(for request: URLRequest) throws -> Data? {
        guard CommandLine.arguments.contains("--ui-test-telegram"), let path = request.url?.path, path.hasPrefix("/v1/telegram") else { return nil }
        if path == "/v1/telegram/link" {
            // The test stands in for Telegram: tapping Start in the bot links the account.
            linked = true
            return try JSONSerialization.data(withJSONObject: ["url": "https://t.me/paytracker1_bot?start=link-UITESTCODE123", "expires": 0])
        }
        if request.httpMethod == "DELETE" { linked = false }
        return try JSONSerialization.data(withJSONObject: ["linked": linked, "username": linked ? "howmuch_tester" : "", "linkedAt": 0, "bot": "paytracker1_bot"])
    }
}

// Synthetic transport for native UI tests only. It cannot exist in a Release
// build and fails closed rather than sending test tokens to a real service.
@MainActor
private enum PaymentDetectionUITestFixture {
    static var connected = !CommandLine.arguments.contains("--ui-test-email-providers")
    static var provider = "gmail"
    static var iCloudAttempts = 0
    static var autoEnabled = false
    static var rules: [[String: Any]] = [["id": 1, "payer": "QA COMPANY", "event": "Roadshow"]]
    static var receipts: [[String: Any]] = [
        ["id": 1, "amount": "120.00", "currency": "SGD", "payer": "QA COMPANY", "status": "review", "reason": "Verified synthetic DBS alert", "candidates": [["event": "Roadshow", "includes_cab": false]]],
        ["id": 2, "amount": "50.00", "currency": "SGD", "payer": "QA COMPANY", "status": "review", "reason": "Partial synthetic payment", "candidates": []]
    ]
    static func response(for request: URLRequest) throws -> Data? {
        guard CommandLine.arguments.contains("--ui-test-payments") else { return nil }
        guard request.url?.host == AccountAPI.base.host, let path = request.url?.path,
              path.hasPrefix("/v1/payment-detection") else {
            throw AccountHTTPError(status: 503, message: "Unsupported isolated UI test request")
        }
        let method = request.httpMethod ?? "GET"
        if CommandLine.arguments.contains("--ui-test-payments-offline") {
            throw AccountHTTPError(status: 503, message: "Payment service is temporarily unavailable.")
        }
        if CommandLine.arguments.contains("--ui-test-payment-rule-error"), path.hasSuffix("/rules"), method == "POST" {
            throw AccountHTTPError(status: 503, message: "Couldn’t save this payer rule. Please try again.")
        }
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        if path.hasSuffix("/gmail-imap/connect") {
            connected = true; provider = "gmail_imap"
            receipts[0]["trusted"] = false
        } else if path.hasSuffix("/icloud/connect") {
            iCloudAttempts += 1
            if iCloudAttempts == 1 { throw AccountHTTPError(status: 400, message: "Synthetic iCloud connection failed. Check the app-specific password.") }
            connected = true; provider = "icloud"
            receipts[0]["trusted"] = false
            receipts[0]["reason"] = "Email authentication could not be verified."
        } else if path.hasSuffix("/scan") {
            receipts[1]["reason"] = "Synthetic scan completed"
        } else if path.hasSuffix("/connection") && method == "DELETE" {
            connected = false; autoEnabled = false
        } else if path.hasSuffix("/rules") && method == "POST" {
            rules.append(["id": 2, "payer": body["payer"] as? String ?? "", "event": body["event"] as? String ?? ""])
        } else if path.contains("/rules/") && method == "DELETE" {
            let id = Int(path.split(separator: "/").last ?? "") ?? 0
            rules.removeAll { $0["id"] as? Int == id }
        } else if path.contains("/receipts/") {
            let pieces = path.split(separator: "/")
            let id = Int(pieces[pieces.count - 2]) ?? 0
            if let index = receipts.firstIndex(where: { $0["id"] as? Int == id }) {
                receipts[index]["status"] = path.hasSuffix("/confirm") ? "confirmed_paid" : path.hasSuffix("/undo") ? "undone" : "ignored"
                receipts[index]["candidates"] = []
            }
        } else if method == "PATCH" { autoEnabled = body["auto_enabled"] as? Bool ?? false }
        return try JSONSerialization.data(withJSONObject: ["available": true, "connected": connected,
            "provider": provider, "providers": ["gmail": !CommandLine.arguments.contains("--ui-test-email-providers"), "gmail_imap": true, "microsoft": false, "icloud": true],
            "email": connected ? "synthetic@example.test" : NSNull(), "auto_enabled": autoEnabled,
            "error": "", "rules": rules, "receipts": receipts, "events": ["Roadshow", "Brand launch"]])
    }
}
#endif
