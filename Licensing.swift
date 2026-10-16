import Foundation
import CryptoKit
import Security

// MARK: - Данные ключа

struct LicensePayload: Codable, Equatable {
    let v: Int
    let id: String
    /// Код устройства (8 символов) или "*" — без привязки
    let dev: String
    /// Конец действия, unix-время. 0 — бессрочно
    let exp: Int
    let plan: String

    var expiryDate: Date? {
        exp == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(exp))
    }
}

enum LicenseError: LocalizedError {
    case notConfigured
    case format
    case signature
    case wrongDevice
    case expired
    case revoked
    case clockTampered

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Лицензирование не настроено."
        case .format: return "Ключ введён неверно. Скопируйте его целиком."
        case .signature: return "Ключ недействителен."
        case .wrongDevice: return "Ключ выдан для другого кода устройства. Если приложение переустанавливали или переподписывали, код мог измениться: отправьте продавцу новый код."
        case .expired: return "Срок действия ключа истёк."
        case .revoked: return "Ключ отозван."
        case .clockTampered: return "Системное время изменено. Верните правильную дату и время."
        }
    }
}

// MARK: - Хранилище (Keychain, а если он недоступен у подписанного приложения, то UserDefaults)

enum SecureStore {
    private static let service = "com.personal.smoothframes.license"

    static func get(_ key: String) -> String? {
        if let value = keychainGet(key) { return value }
        return UserDefaults.standard.string(forKey: "lic." + key)
    }

    static func set(_ value: String, for key: String) {
        keychainSet(value, key)
        UserDefaults.standard.set(value, forKey: "lic." + key)
    }

    static func remove(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "lic." + key)
    }

    private static func keychainGet(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainSet(_ value: String, _ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Проверка ключей

enum Licensing {

    static var isConfigured: Bool {
        !LicenseConfig.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Код устройства вида A1B2-C3D4: создаётся один раз и запоминается
    static var deviceCode: String {
        if let saved = SecureStore.get("device") { return saved }
        let hash = SHA256.hash(data: Data(UUID().uuidString.utf8))
        let hex = hash.prefix(4).map { String(format: "%02X", $0) }.joined()
        let code = String(hex.prefix(4)) + "-" + String(hex.suffix(4))
        SecureStore.set(code, for: "device")
        return code
    }

    static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Убирает пробелы и переводы строк из вставленного ключа
    static func clean(_ raw: String) -> String {
        raw.filter { !$0.isWhitespace }
    }

    static func verify(_ rawKey: String, now: Date = Date()) throws -> LicensePayload {
        guard isConfigured else { throw LicenseError.notConfigured }

        let key = clean(rawKey)
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard
            parts.count == 3, parts[0] == "SF1",
            let payloadData = base64URLDecode(parts[1]),
            let signature = base64URLDecode(parts[2])
        else { throw LicenseError.format }

        guard
            let pubData = Data(base64Encoded: LicenseConfig.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)),
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData)
        else { throw LicenseError.notConfigured }

        guard publicKey.isValidSignature(signature, for: payloadData) else { throw LicenseError.signature }
        guard let payload = try? JSONDecoder().decode(LicensePayload.self, from: payloadData) else {
            throw LicenseError.format
        }

        if LicenseConfig.revokedIDs.contains(payload.id) { throw LicenseError.revoked }
        if payload.dev != "*" && normalize(payload.dev) != normalize(deviceCode) { throw LicenseError.wrongDevice }

        // Защита от перевода часов назад
        let nowTs = Int(now.timeIntervalSince1970)
        let maxSeen = Int(SecureStore.get("maxseen") ?? "") ?? 0
        if maxSeen > 0 && nowTs < maxSeen - 86_400 { throw LicenseError.clockTampered }
        SecureStore.set(String(max(maxSeen, nowTs)), for: "maxseen")

        if payload.exp != 0 && nowTs >= payload.exp { throw LicenseError.expired }
        return payload
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

// MARK: - Состояние лицензии в приложении

@MainActor
final class LicenseManager: ObservableObject {
    enum State: Equatable {
        /// Ключ проверки не задан: приложение работает без активации
        case devMode
        case locked
        case active(LicensePayload)
    }

    @Published var state: State = .locked
    @Published var message: String?

    init() {
        refresh()
    }

    var isUnlocked: Bool {
        switch state {
        case .devMode, .active: return true
        case .locked: return false
        }
    }

    var deviceCode: String { Licensing.deviceCode }

    func refresh() {
        guard Licensing.isConfigured else {
            setState(.devMode)
            return
        }
        guard let key = SecureStore.get("key") else {
            setState(.locked)
            return
        }
        do {
            setState(.active(try Licensing.verify(key)))
            if message != nil { message = nil }
        } catch {
            setState(.locked)
            message = error.localizedDescription
        }
    }

    private func setState(_ new: State) {
        if state != new { state = new }
    }

    @discardableResult
    func activate(_ raw: String) -> Bool {
        do {
            let payload = try Licensing.verify(raw)
            SecureStore.set(Licensing.clean(raw), for: "key")
            state = .active(payload)
            message = nil
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func deactivate() {
        SecureStore.remove("key")
        message = nil
        refresh()
    }

    /// Строка для карточки «Лицензия»
    var statusText: String {
        switch state {
        case .devMode:
            return "режим разработчика"
        case .locked:
            return "не активирована"
        case .active(let p):
            guard let date = p.expiryDate else { return "бессрочная" }
            let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
            let formatted = date.formatted(date: .abbreviated, time: .omitted)
            return "до \(formatted) (осталось \(max(days, 0)) дн.)"
        }
    }
}
