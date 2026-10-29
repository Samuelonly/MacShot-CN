import AppKit

/// Which engine reads text from a capture. Local Vision is the default and
/// needs no account; a cloud OCR service is optional and BYOK.
enum OCREngine: String, CaseIterable {
    case local
    case cloud

    var title: String {
        switch self {
        case .local: return L("Local Vision (on-device)")
        case .cloud: return L("Custom cloud OCR (your key)")
        }
    }

    static var current: OCREngine {
        get {
            UserDefaults.standard.string(forKey: "ocrEngine").flatMap(OCREngine.init(rawValue:)) ?? .local
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ocrEngine") }
    }

    /// Whether OCR should go to the configured cloud service right now.
    static var usesCloud: Bool {
        current == .cloud && AIProviderConfig.load(.ocr).isConfigured(.ocr)
    }
}

enum CloudOCR {

    /// PNG base64 for the body templates. Vision reads the pixels already;
    /// an encoder round trip keeps the request simple.
    static func pngBase64(_ cgImage: CGImage) -> String? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return data.base64EncodedString()
    }

    static func recognize(cgImage: CGImage,
                          completion: @escaping (Result<String, Error>) -> Void) {
        guard let base64 = pngBase64(cgImage) else {
            completion(.failure(AIProviderError.invalidResponse(L("Could not encode the image for OCR."))))
            return
        }
        recognize(pngBase64: base64, config: AIProviderConfig.load(.ocr), completion: completion)
    }

    static func recognize(pngBase64: String,
                          config: AIProviderConfig,
                          completion: @escaping (Result<String, Error>) -> Void) {
        AIProvider.recognizeText(pngBase64: pngBase64, config: config, completion: completion)
    }
}
