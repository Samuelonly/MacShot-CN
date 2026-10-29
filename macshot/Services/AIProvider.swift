import Foundation
import CryptoKit

// MARK: - Keys

/// API keys are kept in a 0600 file under Application Support, never in
/// UserDefaults: Settings Backup exports UserDefaults, and a key must not
/// leave the Mac in that file. The Keychain was tried first, but every
/// rebuild re-signs the app, so macOS then asked for the login password on
/// launch and blocked the main thread. A file has no such prompt.
enum SecretStore {
    private static let lock = NSLock()

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macshot", isDirectory: true)
    }
    private static var fileURL: URL { directory.appendingPathComponent("ai-secrets.json") }

    static func set(_ value: String?, account: String) {
        lock.lock()
        defer { lock.unlock() }
        var secrets = load()
        if let value, !value.isEmpty {
            secrets[account] = value
        } else {
            secrets.removeValue(forKey: account)
        }
        save(secrets)
    }

    static func value(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return load()[account]
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return secrets
    }

    private static func save(_ secrets: [String: String]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: fileURL.path)
    }
}

// MARK: - Configuration

/// One BYOK provider, for translation or for cloud OCR. The key is kept out
/// of this struct so the rest can be stored in UserDefaults and exported.
struct AIProviderConfig: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case openAI
        case gemini
        case deepl
        /// Tencent Cloud TMT ("翻译君"): TC3-HMAC-SHA256 signed requests.
        case tencent
        /// Youdao Zhiyun v3: sha256(appKey + q + salt + curtime + appSecret).
        case youdao
        /// Volcengine ("火山翻译"): HMAC-SHA256 v4 signing.
        case volcengine
        /// Any HTTP JSON service.
        case template

        var title: String {
            switch self {
            case .openAI: return L("OpenAI-compatible API")
            case .gemini: return L("Google Gemini")
            case .deepl: return L("DeepL")
            case .tencent: return L("Tencent Cloud TMT")
            case .youdao: return L("Youdao Translate")
            case .volcengine: return L("Volcengine Translate")
            case .template: return L("HTTP template")
            }
        }

        /// The order shown in the engine pop-up: the common AI engines first,
        /// the catch-all template last.
        static let orderedCases: [Mode] = [
            .openAI, .gemini, .deepl, .tencent, .youdao, .volcengine, .template,
        ]
    }

    enum Role: String, Codable {
        case translation
        case ocr

        var defaultsKey: String { "aiProvider.\(rawValue)" }
        var keyAccount: String { "\(rawValue).apiKey" }
        /// Second credential for vendors that sign with an app secret
        /// (Tencent SecretKey, Youdao app secret). Kept out of UserDefaults like
        /// the key itself.
        var secretAccount: String { "\(rawValue).apiSecret" }
    }

    var mode: Mode = .openAI
    /// OpenAI-compatible: the API root, like https://api.openai.com/v1.
    var baseURL = ""
    var model = ""
    var systemPrompt = "Translate the user's text into {{to}}. Reply with the translation only, keeping the line breaks."
    /// Template: any HTTP JSON service.
    var method = "POST"
    var urlTemplate = ""
    var headers = "Content-Type: application/json\nAuthorization: Bearer {{key}}"
    var bodyTemplate = ""
    /// Dotted path to the text in the response, like choices.0.message.content.
    var responsePath = ""
    /// Seconds, 1 to 10.
    var timeout: Double = 3
    /// Tencent Cloud region, like ap-guangzhou. Only used by the TMT engine.
    var region = "ap-guangzhou"

    var apiKey: String {
        get { SecretStore.value(account: role.keyAccount) ?? "" }
        set { SecretStore.set(newValue, account: role.keyAccount) }
    }

    var apiSecret: String {
        get { SecretStore.value(account: role.secretAccount) ?? "" }
        set { SecretStore.set(newValue, account: role.secretAccount) }
    }

    private var role: Role {
        // The role is implied by where the config is stored.
        Role(rawValue: storedRole) ?? .translation
    }

    private var storedRole = Role.translation.rawValue

    func isConfigured(_ role: Role) -> Bool {
        let key = SecretStore.value(account: role.keyAccount) ?? ""
        switch mode {
        case .openAI:
            guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
                  !model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            return role == .ocr || !key.isEmpty
        case .template:
            return !urlTemplate.trimmingCharacters(in: .whitespaces).isEmpty && !bodyTemplate.isEmpty
        case .tencent, .youdao, .volcengine:
            // These vendors sign each request with the second credential, so a
            // lone key is not enough to make a call.
            let secret = SecretStore.value(account: role.secretAccount) ?? ""
            return !key.isEmpty && !secret.isEmpty
        case .gemini, .deepl:
            return !key.isEmpty
        }
    }

    static func load(_ role: Role) -> AIProviderConfig {
        guard let data = UserDefaults.standard.data(forKey: role.defaultsKey),
              var config = try? JSONDecoder().decode(AIProviderConfig.self, from: data) else {
            var fresh = AIProviderConfig()
            fresh.storedRole = role.rawValue
            if role == .ocr {
                fresh.mode = .template
                fresh.headers = "Content-Type: application/json"
                fresh.bodyTemplate = "{\"image\": \"{{imageBase64}}\"}"
            } else {
                fresh.bodyTemplate = "{\"text\": \"{{text}}\", \"to\": \"{{to}}\"}"
            }
            return fresh
        }
        config.storedRole = role.rawValue
        return config
    }

    func save(_ role: Role) {
        var copy = self
        copy.storedRole = role.rawValue
        if let data = try? JSONEncoder().encode(copy) {
            UserDefaults.standard.set(data, forKey: role.defaultsKey)
        }
    }
}

// MARK: - Errors

enum AIProviderError: LocalizedError {
    case notConfigured
    case invalidKey
    case rateLimited
    case timedOut
    case http(Int)
    case invalidResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L("No translation service is configured. Add your own provider in Settings › Capture › Translation.")
        case .invalidKey:
            return L("The API key is invalid or has no permission for this service.")
        case .rateLimited:
            return L("The service is rate limiting requests. Try again in a moment.")
        case .timedOut:
            return L("The request timed out.")
        case .http(let code):
            return String(format: L("The service returned HTTP %d."), code)
        case .invalidResponse(let detail):
            return detail.isEmpty ? L("The response did not match the configured response path.") : detail
        case .network(let detail):
            return detail.isEmpty ? L("No network connection.") : detail
        }
    }
}

// MARK: - Requests

enum AIProvider {

    // MARK: Translation

    /// Translates one string with the user's provider. The completion is on
    /// the main queue.
    static func translate(text: String, to target: String, from source: String,
                          config: AIProviderConfig,
                          completion: @escaping (Result<String, Error>) -> Void) {
        guard config.isConfigured(.translation) else {
            completion(.failure(AIProviderError.notConfigured))
            return
        }
        let key = config.apiKey
        let values = ["text": text, "to": target, "from": source, "key": key]

        switch config.mode {
        case .openAI:
            guard let url = chatURL(config.baseURL) else {
                completion(.failure(AIProviderError.invalidResponse(L("The Base URL is not a valid address."))))
                return
            }
            let system = expand(config.systemPrompt, values)
            let body: [String: Any] = [
                "model": config.model,
                "temperature": 0,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": text],
                ],
            ]
            send(url: url, method: "POST", headers: ["Content-Type": "application/json",
                                                     "Authorization": "Bearer \(key)"],
                 body: try? JSONSerialization.data(withJSONObject: body),
                 path: "choices.0.message.content", timeout: config.timeout, completion: completion)

        case .template:
            sendTemplate(config: config, values: values, completion: completion)

        case .tencent:
            sendTencent(config: config, text: text, target: target, completion: completion)

        case .youdao:
            sendYoudao(config: config, text: text, target: target, completion: completion)

        case .gemini:
            sendGemini(config: config, text: text, target: target,
                       prompt: expand(config.systemPrompt, values), completion: completion)

        case .deepl:
            sendDeepL(config: config, text: text, target: target, completion: completion)

        case .volcengine:
            sendVolcengine(config: config, text: text, target: target, completion: completion)
        }
    }

    // MARK: OCR

    /// Sends a PNG as base64 to the user's OCR provider and returns plain text.
    static func recognizeText(pngBase64: String, config: AIProviderConfig,
                              completion: @escaping (Result<String, Error>) -> Void) {
        guard config.isConfigured(.ocr) else {
            completion(.failure(AIProviderError.notConfigured))
            return
        }
        let key = config.apiKey
        let mime = "image/png"
        let values = ["imageBase64": pngBase64, "imageMime": mime, "key": key,
                      "to": TranslationService.targetLanguage, "text": ""]

        switch config.mode {
        case .openAI:
            guard let url = chatURL(config.baseURL) else {
                completion(.failure(AIProviderError.invalidResponse(L("The Base URL is not a valid address."))))
                return
            }
            let body: [String: Any] = [
                "model": config.model,
                "temperature": 0,
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "Extract all text from this image. Reply with the text only, preserving line breaks."],
                        ["type": "image_url",
                         "image_url": ["url": "data:\(mime);base64,\(pngBase64)"]],
                    ],
                ]],
            ]
            send(url: url, method: "POST", headers: ["Content-Type": "application/json",
                                                     "Authorization": "Bearer \(key)"],
                 body: try? JSONSerialization.data(withJSONObject: body),
                 path: "choices.0.message.content", timeout: config.timeout, completion: completion)

        case .template:
            sendTemplate(config: config, values: values, completion: completion)

        case .gemini:
            // Gemini takes the image inline, in the same request body.
            sendGemini(config: config, pngBase64: pngBase64, target: TranslationService.targetLanguage,
                       prompt: "Extract all text from this image. Reply with the text only, preserving line breaks.",
                       completion: completion)

        case .tencent:
            // Tencent Cloud OCR is a different service from TMT: same key,
            // different host and a different signing scope.
            sendTencentOCR(config: config, pngBase64: pngBase64, completion: completion)

        case .youdao, .volcengine, .deepl:
            completion(.failure(AIProviderError.invalidResponse(
                L("This engine only translates text; it cannot read images."))))
        }
    }

    // MARK: Tencent rate limiting

    /// One serial queue for every Tencent call (TMT and OCR share the quota).
    private static let tencentQueue = DispatchQueue(label: "com.sw33tlie.macshot.tencent",
                                                    qos: .utility)
    private static let tencentSlotLock = NSLock()
    private static var tencentLastCall = Date.distantPast

    /// Waits until 300 ms have passed since the previous call, which keeps the
    /// app under the 4-per-second vendor limit.
    private static func waitForTencentSlot() {
        tencentSlotLock.lock()
        defer { tencentSlotLock.unlock() }
        let gap: TimeInterval = 0.3
        let elapsed = Date().timeIntervalSince(tencentLastCall)
        if elapsed < gap { Thread.sleep(forTimeInterval: gap - elapsed) }
        tencentLastCall = Date()
    }

    // MARK: Test

    /// Translates "Hello" and reports how long the round trip took.
    static func test(_ config: AIProviderConfig,
                     completion: @escaping (Result<(text: String, seconds: TimeInterval), Error>) -> Void) {
        let started = Date()
        translate(text: "Hello", to: TranslationService.targetLanguage, from: "en",
                  config: config) { result in
            switch result {
            case .success(let text):
                completion(.success((text, Date().timeIntervalSince(started))))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: Templates

    private static func sendTemplate(config: AIProviderConfig,
                                     values: [String: String],
                                     completion: @escaping (Result<String, Error>) -> Void) {
        let urlText = expand(config.urlTemplate, values)
        guard let url = URL(string: urlText) else {
            completion(.failure(AIProviderError.invalidResponse(L("The request URL is not valid."))))
            return
        }
        var headers: [String: String] = [:]
        for line in config.headers.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = expand(value, values)
        }
        let body = config.bodyTemplate.isEmpty ? nil : expand(config.bodyTemplate, values).data(using: .utf8)
        send(url: url, method: config.method.uppercased(), headers: headers, body: body,
             path: config.responsePath, timeout: config.timeout, completion: completion)
    }

    private static func expand(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { text, pair in
            text.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value)
        }
    }

    /// The chat completions endpoint, whether the user gave a root
    /// (…/v1) or the full endpoint (…/chat/completions).
    private static func chatURL(_ base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard var url = URL(string: trimmed) else { return nil }
        if trimmed.hasSuffix("chat/completions") { return url }
        url.appendPathComponent("chat")
        url.appendPathComponent("completions")
        return url
    }

    // MARK: - Vendor adapters

    /// Vendors spell the target language differently from Apple's identifiers.
    private static func tencentLanguage(_ code: String) -> String {
        if code.hasPrefix("zh") { return "zh" }
        return code.split(separator: "-").first.map(String.init) ?? code
    }

    private static func youdaoLanguage(_ code: String) -> String {
        if code.hasPrefix("zh-Hant") { return "zh-CHT" }
        if code.hasPrefix("zh") { return "zh-CHS" }
        return code.split(separator: "-").first.map(String.init) ?? code
    }

    /// Tencent Cloud TMT ("翻译君"). Every request carries a TC3-HMAC-SHA256
    /// signature: the canonical request hashes method, URI, query, the
    /// content-type and host headers and the payload, and the signature is an
    /// HMAC chain secretKey → date → service → "tc3_request".
    private static func sendTencent(config: AIProviderConfig, text: String, target: String,
                                    completion: @escaping (Result<String, Error>) -> Void) {
        let payload: [String: Any] = [
            "SourceText": text,
            "Source": "auto",
            "Target": tencentLanguage(target),
            "ProjectId": 0,
        ]
        sendTencentSigned(config: config, service: "tmt", action: "TextTranslate",
                          version: "2018-03-21",
                          defaultEndpoint: "https://tmt.tencentcloudapi.com",
                          payload: payload, path: "Response.TargetText",
                          completion: completion)
    }

    /// Tencent Cloud OCR. Same TC3 signing as TMT, but the service is "ocr"
    /// and the endpoint is ocr.tencentcloudapi.com, so a TMT key and the OCR
    /// endpoint are what a hand-written Base URL has to supply.
    private static func sendTencentOCR(config: AIProviderConfig, pngBase64: String,
                                       completion: @escaping (Result<String, Error>) -> Void) {
        sendTencentSigned(config: config, service: "ocr", action: "GeneralBasicOCR",
                          version: "2018-11-19",
                          defaultEndpoint: "https://ocr.tencentcloudapi.com",
                          payload: ["ImageBase64": pngBase64, "LanguageType": "auto"],
                          path: "Response.TextDetections", textLines: true,
                          completion: completion)
    }

    /// Signs one Tencent Cloud API call. `service` picks the scope ("tmt" for
    /// translation, "ocr" for image text), which is part of the signature.
    private static func sendTencentSigned(config: AIProviderConfig,
                                          service: String, action: String, version: String,
                                          defaultEndpoint: String,
                                          payload: [String: Any], path: String,
                                          textLines: Bool = false,
                                          completion: @escaping (Result<String, Error>) -> Void) {
        let secretId = config.apiKey
        let secretKey = config.apiSecret
        guard !secretId.isEmpty, !secretKey.isEmpty else {
            completion(.failure(AIProviderError.notConfigured))
            return
        }
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespaces)
        let endpoint = trimmed.isEmpty ? defaultEndpoint : trimmed
        guard let url = URL(string: endpoint), let host = url.host else {
            completion(.failure(AIProviderError.invalidResponse(L("The Base URL is not a valid address."))))
            return
        }
        let region = config.region.trimmingCharacters(in: .whitespaces)
        let timestamp = Int(Date().timeIntervalSince1970)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(.failure(AIProviderError.invalidResponse("")))
            return
        }
        let contentType = "application/json;charset=utf-8"
        let signedHeaders = "content-type;host"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\n"
        let canonicalRequest = [
            "POST", "/", "",
            canonicalHeaders, signedHeaders,
            sha256Hex(body),
        ].joined(separator: "\n")
        let scope = "\(day)/\(service)/tc3_request"
        let stringToSign = ["TC3-HMAC-SHA256", String(timestamp), scope, sha256Hex(canonicalRequest)]
            .joined(separator: "\n")
        // TC3 keys the HMAC chain with "TC3" + SecretKey, not the bare secret.
        let signingKey = hmacSHA256(hmacSHA256(hmacSHA256(Data(("TC3" + secretKey).utf8), day), service),
                                    "tc3_request")
        let signature = hmacSHA256(signingKey, stringToSign).hexString
        let authorization = "TC3-HMAC-SHA256 Credential=\(secretId)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        let headers = [
            "Content-Type": contentType,
            "Authorization": authorization,
            "X-TC-Action": action,
            "X-TC-Version": version,
            "X-TC-Timestamp": String(timestamp),
            "X-TC-Region": region.isEmpty ? "ap-guangzhou" : region,
        ]
        tencentQueue.async {
            waitForTencentSlot()
            sendTencentRequest(url: url, headers: headers, body: body, config: config,
                               path: path, textLines: textLines, attemptsLeft: 2,
                               completion: completion)
        }
    }

    /// The vendor caps its APIs at 4 calls per second, and a multi-line capture
    /// fires one call per line, so requests are serialised with a small gap and
    /// the frequency error is retried instead of surfacing as a failure.
    private static func sendTencentRequest(url: URL, headers: [String: String], body: Data,
                                           config: AIProviderConfig, path: String,
                                           textLines: Bool, attemptsLeft: Int,
                                           completion: @escaping (Result<String, Error>) -> Void) {
        sendRequest(url: url, method: "POST", headers: headers, body: body, timeout: config.timeout) { result in
            switch result {
            case .failure(let error):
                finish(.failure(error), completion)
            case .success(let json):
                if let response = json as? [String: Any],
                   let serviceError = response["Response"] as? [String: Any],
                   let code = serviceError["Error"] as? [String: Any] {
                    let message = (code["Message"] as? String) ?? ""
                    let reason = (code["Code"] as? String) ?? ""
                    let rateLimited = reason == "RequestLimitExceeded"
                        || message.lowercased().contains("frequency limit")
                    if rateLimited, attemptsLeft > 0 {
                        tencentQueue.asyncAfter(deadline: .now() + 1.2) {
                            sendTencentRequest(url: url, headers: headers, body: body,
                                               config: config, path: path, textLines: textLines,
                                               attemptsLeft: attemptsLeft - 1,
                                               completion: completion)
                        }
                        return
                    }
                    finish(.failure(AIProviderError.invalidResponse(message)), completion)
                    return
                }
                if textLines {
                    // OCR returns one entry per detected line; keep their order.
                    guard let list = jsonValue(at: path, in: json) as? [[String: Any]] else {
                        finish(.failure(AIProviderError.invalidResponse("")), completion)
                        return
                    }
                    let lines = list.compactMap { $0["DetectedText"] as? String }
                        .filter { !$0.isEmpty }
                    guard !lines.isEmpty else {
                        finish(.failure(AIProviderError.invalidResponse(
                            L("The service returned no text for this image."))), completion)
                        return
                    }
                    finish(.success(lines.joined(separator: "\n")), completion)
                    return
                }
                guard let value = jsonValue(at: path, in: json) else {
                    finish(.failure(AIProviderError.invalidResponse("")), completion)
                    return
                }
                finish(.success(Self.text(from: value)), completion)
            }
        }
    }

    /// Youdao Zhiyun v3. The signature is a plain SHA-256 over
    /// appKey + truncated q + salt + curtime + appSecret, sent as a form post.
    private static func sendYoudao(config: AIProviderConfig, text: String, target: String,
                                   completion: @escaping (Result<String, Error>) -> Void) {
        let appKey = config.apiKey
        let appSecret = config.apiSecret
        guard !appKey.isEmpty, !appSecret.isEmpty else {
            completion(.failure(AIProviderError.notConfigured))
            return
        }
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespaces)
        let endpoint = trimmed.isEmpty ? "https://openapi.youdao.com/api" : trimmed
        guard let url = URL(string: endpoint) else {
            completion(.failure(AIProviderError.invalidResponse(L("The Base URL is not a valid address."))))
            return
        }
        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        let truncated = text.count <= 20
            ? text
            : "\(text.prefix(10))\(text.count)\(text.suffix(10))"
        let sign = sha256Hex(Data((appKey + truncated + salt + curtime + appSecret).utf8))

        let params: [(String, String)] = [
            ("q", text),
            ("from", "auto"),
            ("to", youdaoLanguage(target)),
            ("appKey", appKey),
            ("salt", salt),
            ("sign", sign),
            ("signType", "v3"),
            ("curtime", curtime),
        ]
        let encoded = params.map { name, value in
            let escaped = value.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? value
            return "\(name)=\(escaped)"
        }.joined(separator: "&")
        let headers = ["Content-Type": "application/x-www-form-urlencoded"]
        sendRequest(url: url, method: "POST", headers: headers,
                    body: Data(encoded.utf8), timeout: config.timeout) { result in
            switch result {
            case .failure(let error):
                finish(.failure(error), completion)
            case .success(let json):
                if let code = jsonValue(at: "errorCode", in: json).map({ "\($0)" }), code != "0" {
                    finish(.failure(AIProviderError.invalidResponse(
                        String(format: L("Youdao returned error %@."), code))), completion)
                    return
                }
                guard let value = jsonValue(at: "translation.0", in: json) else {
                    finish(.failure(AIProviderError.invalidResponse("")), completion)
                    return
                }
                finish(.success(Self.text(from: value)), completion)
            }
        }
    }

    /// Gemini ("Google Gemini"). Text and images share one endpoint; the API
    /// key rides in the query string.
    private static func sendGemini(config: AIProviderConfig, text: String? = nil,
                                   pngBase64: String? = nil, target: String, prompt: String,
                                   completion: @escaping (Result<String, Error>) -> Void) {
        let key = config.apiKey
        guard !key.isEmpty else {
            completion(.failure(AIProviderError.notConfigured))
            return
        }
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "https://generativelanguage.googleapis.com" : trimmed
        let model = config.model.trimmingCharacters(in: .whitespaces).isEmpty
            ? "gemini-2.0-flash" : config.model.trimmingCharacters(in: .whitespaces)
        guard let escapedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(base)/v1beta/models/\(escapedModel):generateContent?key=\(key)") else {
            completion(.failure(AIProviderError.invalidResponse(L("The Base URL is not a valid address."))))
            return
        }
        var parts: [[String: Any]] = []
        if let text {
            parts.append(["text": prompt + "\n\n" + text])
        } else {
            parts.append(["text": prompt])
        }
        if let pngBase64 {
            parts.append(["inline_data": ["mime_type": "image/png", "data": pngBase64]])
        }
        let body: [String: Any] = ["contents": [["parts": parts]]]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(AIProviderError.invalidResponse("")))
            return
        }
        send(url: url, method: "POST", headers: ["Content-Type": "application/json"],
             body: payload, path: "candidates.0.content.parts.0.text", timeout: config.timeout,
             completion: completion)
    }

    /// DeepL. The free plan keys end in ":fx" and live on api-free.deepl.com.
    private static func sendDeepL(config: AIProviderConfig, text: String, target: String,
                                  completion: @escaping (Result<String, Error>) -> Void) {
        let key = config.apiKey
        guard !key.isEmpty else {
            completion(.failure(AIProviderError.notConfigured))
            return
        }
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty
            ? (key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com")
            : trimmed
        guard let url = URL(string: base + "/v2/translate") else {
            completion(.failure(AIProviderError.invalidResponse(L("The Base URL is not a valid address."))))
            return
        }
        let form = "text=\(text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text)"
            + "&target_lang=\(deeplLanguage(target))"
        send(url: url, method: "POST",
             headers: ["Authorization": "DeepL-Auth-Key \(key)",
                       "Content-Type": "application/x-www-form-urlencoded"],
             body: Data(form.utf8), path: "translations.0.text", timeout: config.timeout,
             completion: completion)
    }

    /// Volcengine machine translation ("火山翻译"). Signed like AWS SigV4: the
    /// canonical request covers method, URI, sorted query, the four signed
    /// headers and the payload hash.
    private static func sendVolcengine(config: AIProviderConfig, text: String, target: String,
                                       completion: @escaping (Result<String, Error>) -> Void) {
        let accessKey = config.apiKey
        let secretKey = config.apiSecret
        guard !accessKey.isEmpty, !secretKey.isEmpty else {
            completion(.failure(AIProviderError.notConfigured))
            return
        }
        let host = "translate.volcengineapi.com"
        let query = "Action=TranslateText&Version=2020-06-01"
        guard let url = URL(string: "https://\(host)?\(query)") else {
            completion(.failure(AIProviderError.invalidResponse("")))
            return
        }
        let region = config.region.trimmingCharacters(in: .whitespaces).isEmpty
            ? "cn-north-1" : config.region.trimmingCharacters(in: .whitespaces)

        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        stampFormatter.timeZone = TimeZone(identifier: "UTC")
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        let xDate = stampFormatter.string(from: Date())
        let shortDate = String(xDate.prefix(8))

        let body: [String: Any] = [
            "TextList": [text],
            "SourceLanguage": "auto",
            "TargetLanguage": volcLanguage(target),
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(AIProviderError.invalidResponse("")))
            return
        }
        let payloadHash = sha256Hex(payload)
        let contentType = "application/json"
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\n"
            + "x-content-sha256:\(payloadHash)\nx-date:\(xDate)\n"
        let canonicalRequest = ["POST", "/", query, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(shortDate)/\(region)/translate/request"
        let stringToSign = ["HMAC-SHA256", xDate, scope, sha256Hex(canonicalRequest)]
            .joined(separator: "\n")
        let signingKey = hmacSHA256(
            hmacSHA256(hmacSHA256(hmacSHA256(Data(secretKey.utf8), shortDate), region), "translate"),
            "request")
        let signature = hmacSHA256(signingKey, stringToSign).hexString
        let authorization = "HMAC-SHA256 Credential=\(accessKey)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        let headers = [
            "Content-Type": contentType,
            "X-Date": xDate,
            "X-Content-Sha256": payloadHash,
            "Authorization": authorization,
        ]
        send(url: url, method: "POST", headers: headers, body: payload,
             path: "TranslationList.0.Translation", timeout: config.timeout, completion: completion)
    }

    private static func deeplLanguage(_ code: String) -> String {
        if code.hasPrefix("zh") { return "ZH" }
        if code == "en" { return "EN-US" }
        return code.split(separator: "-").first.map { $0.uppercased() } ?? code.uppercased()
    }

    private static func volcLanguage(_ code: String) -> String {
        if code.hasPrefix("zh") { return "zh" }
        return code.split(separator: "-").first.map(String.init) ?? code
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    private static func hmacSHA256(_ key: Data, _ message: String) -> Data {
        let symmetric = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetric))
    }

    // MARK: Transport

    /// Shared transport: sends the request, maps transport and HTTP failures to
    /// `AIProviderError`, and hands back the decoded JSON object so vendor
    /// adapters can inspect their own error envelopes.
    private static func sendRequest(url: URL, method: String, headers: [String: String],
                                    body: Data?, timeout: Double,
                                    completion: @escaping (Result<Any, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = min(max(timeout, 1), 10)
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                let urlError = error as? URLError
                let mapped: AIProviderError
                switch urlError?.code {
                case .timedOut: mapped = .timedOut
                case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
                    mapped = .network("")
                default: mapped = .network(error.localizedDescription)
                }
                finishJSON(.failure(mapped), completion)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finishJSON(.failure(AIProviderError.invalidResponse("")), completion)
                return
            }
            switch http.statusCode {
            case 401, 403:
                finishJSON(.failure(AIProviderError.invalidKey), completion)
                return
            case 429:
                finishJSON(.failure(AIProviderError.rateLimited), completion)
                return
            case 200..<300:
                break
            default:
                finishJSON(.failure(AIProviderError.http(http.statusCode)), completion)
                return
            }
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) else {
                finishJSON(.failure(AIProviderError.invalidResponse("")), completion)
                return
            }
            finishJSON(.success(json), completion)
        }.resume()
    }

    private static func finishJSON(_ result: Result<Any, Error>,
                                   _ completion: @escaping (Result<Any, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    private static func send(url: URL, method: String, headers: [String: String],
                             body: Data?, path: String, timeout: Double,
                             completion: @escaping (Result<String, Error>) -> Void) {
        sendRequest(url: url, method: method, headers: headers, body: body, timeout: timeout) { result in
            switch result {
            case .failure(let error):
                finish(.failure(error), completion)
            case .success(let json):
                guard let value = jsonValue(at: path, in: json) else {
                    finish(.failure(AIProviderError.invalidResponse(
                        L("The response did not contain the configured response path."))), completion)
                    return
                }
                finish(.success(Self.text(from: value)), completion)
            }
        }
    }

    private static func finish(_ result: Result<String, Error>,
                               _ completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    /// Reads "a.0.b" out of dictionaries and arrays.
    static func jsonValue(at path: String, in json: Any) -> Any? {
        let parts = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return json }
        var current: Any? = json
        for part in parts {
            if let dictionary = current as? [String: Any] {
                current = dictionary[part]
            } else if let array = current as? [Any], let index = Int(part), index < array.count {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    /// Translators answer with a string, a list of strings or an object with
    /// a text field; all three are accepted.
    private static func text(from value: Any) -> String {
        if let string = value as? String { return string }
        if let strings = value as? [String] { return strings.joined(separator: "\n") }
        if let dictionary = value as? [String: Any],
           let string = dictionary["text"] as? String { return string }
        if let array = value as? [[String: Any]] {
            return array.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return String(describing: value)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
