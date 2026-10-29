import AppKit

/// The BYOK fields for one provider: an OpenAI-compatible API (any vendor)
/// or an HTTP template for services with their own JSON shape. Used for
/// translation and for cloud OCR, since they share the same request.
final class AIProviderEditor: NSView {

    let role: AIProviderConfig.Role

    private let modePopup = NSPopUpButton()
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let keyField = NSSecureTextField()
    private let secretField = NSSecureTextField()
    private let regionField = NSTextField()
    private let promptField = NSTextField()
    private let methodField = NSTextField()
    private let urlField = NSTextField()
    private let headersField = NSTextView()
    private let bodyField = NSTextView()
    private let pathField = NSTextField()
    private let timeoutField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let testButton = NSButton(title: L("Test Connection"), target: nil, action: nil)

    private var templateRows: [NSView] = []
    private var secretRow: NSView?
    private var regionRow: NSView?
    private var baseURLRow: NSView?
    private var modelRow: NSView?
    private var promptRow: NSView?

    /// Both roles show the same engine list in the same order, so the two
    /// pop-ups match: AI engines first, the generic template last.
    private var modes: [AIProviderConfig.Mode] { AIProviderConfig.Mode.orderedCases }

    init(role: AIProviderConfig.Role) {
        self.role = role
        super.init(frame: .zero)
        build()
        load()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var config: AIProviderConfig { AIProviderConfig.load(role) }

    // MARK: - Layout

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.alignment = .leading

        modePopup.addItems(withTitles: modes.map(\.title))
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        // Rows fill the editor width; controls keep their natural size.
        modePopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        stack.addArrangedSubview(row(L("Request:"), modePopup))

        for field in [baseURLField, modelField, keyField, secretField, regionField,
                      promptField, methodField, urlField, pathField, timeoutField] {
            field.font = NSFont.systemFont(ofSize: 12)
            field.controlSize = .small
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        baseURLField.placeholderString = "https://api.openai.com/v1"
        modelField.placeholderString = L("Model, like gpt-4o-mini")
        keyField.placeholderString = L("API key (stored in Keychain)")
        secretField.placeholderString = L("App secret (stored in Keychain)")
        regionField.placeholderString = "ap-guangzhou"
        promptField.placeholderString = L("System prompt; {{to}} becomes the target language")
        methodField.stringValue = "POST"
        urlField.placeholderString = "https://example.com/api/translate"
        pathField.placeholderString = "choices.0.message.content"
        timeoutField.placeholderString = L("Timeout in seconds")

        baseURLRow = row(L("Base URL:"), baseURLField)
        modelRow = row(L("Model:"), modelField)
        promptRow = row(L("Prompt:"), promptField)
        regionRow = row(L("Region:"), regionField)
        secretRow = row(L("App secret:"), secretField)
        templateRows = [
            row(L("Method:"), methodField),
            row(L("URL:"), urlField),
            row(L("Headers:"), makeTextArea(headersField, height: 58)),
            row(L("Body:"), makeTextArea(bodyField, height: 58)),
            row(L("Response path:"), pathField),
        ]
        // Base URL is shared by the OpenAI, Tencent and Youdao engines.
        for view in [baseURLRow!, modelRow!, promptRow!, regionRow!, secretRow!] + templateRows {
            stack.addArrangedSubview(view)
        }
        // The key belongs to every engine: Bearer token, {{key}} in a template,
        // SecretId for Tencent or appKey for Youdao.
        stack.addArrangedSubview(row(L("API key:"), keyField))

        stack.addArrangedSubview(row(L("Timeout:"), timeoutField))

        for textView in [headersField, bodyField] {
            textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.isRichText = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
        }

        let buttons = NSStackView(views: [testButton])
        buttons.spacing = 8
        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.bezelStyle = .rounded
        testButton.controlSize = .small
        testButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        stack.addArrangedSubview(buttons)

        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(statusLabel)

        let note = NSTextField(wrappingLabelWithString: role == .translation
            ? L("Your key is kept in the Keychain and is never included in settings backups.")
            : L("The image is sent as base64. Use {{imageBase64}} in the URL, headers or body, and {{imageMime}} for the type."))
        note.font = NSFont.systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 420
        stack.addArrangedSubview(note)
    }

    private func row(_ label: String, _ field: NSView) -> NSStackView {
        let name = NSTextField(labelWithString: label)
        name.font = NSFont.systemFont(ofSize: 11)
        name.alignment = .right
        name.textColor = .secondaryLabelColor
        name.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let row = NSStackView(views: [name, field])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func makeTextArea(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 320).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    // MARK: - Load and save

    private func load() {
        let config = config
        modePopup.selectItem(at: modes.firstIndex(of: config.mode) ?? 0)
        baseURLField.stringValue = config.baseURL
        modelField.stringValue = config.model
        promptField.stringValue = config.systemPrompt
        methodField.stringValue = config.method
        urlField.stringValue = config.urlTemplate
        headersField.string = config.headers
        bodyField.string = config.bodyTemplate
        pathField.stringValue = config.responsePath
        regionField.stringValue = config.region
        timeoutField.stringValue = String(format: "%.0f", config.timeout)
        keyField.stringValue = config.apiKey
        secretField.stringValue = config.apiSecret

        // Placeholder tells whether a key is already stored without showing it.
        if !config.apiKey.isEmpty { keyField.placeholderString = L("Key saved; type to replace") }
        if !config.apiSecret.isEmpty { secretField.placeholderString = L("Secret saved; type to replace") }
        updateMode(animated: false)
    }

    @objc private func modeChanged() { updateMode(animated: true) }

    private func selectedMode() -> AIProviderConfig.Mode {
        guard modes.indices.contains(modePopup.indexOfSelectedItem) else { return .openAI }
        return modes[modePopup.indexOfSelectedItem]
    }

    private func updateMode(animated: Bool) {
        let mode = selectedMode()
        modelRow?.isHidden = !(mode == .openAI || mode == .gemini)
        // Gemini and Volcengine expand the prompt too; the template has its
        // own body.
        promptRow?.isHidden = !(role == .translation
                                && (mode == .openAI || mode == .gemini))
        // Gemini, DeepL and Volcengine talk to a fixed endpoint.
        baseURLRow?.isHidden = !(mode == .openAI || mode == .tencent || mode == .youdao)
        regionRow?.isHidden = !(mode == .tencent || mode == .volcengine)
        // Tencent, Youdao and Volcengine sign each request, so they need a
        // second credential.
        secretRow?.isHidden = !(mode == .tencent || mode == .youdao || mode == .volcengine)
        for view in templateRows { view.isHidden = mode != .template }

        // Each vendor has its own default region; avoid carrying Tencent's
        // ap-guangzhou over to Volcengine, which signs with cn-north-1.
        let region = regionField.stringValue.trimmingCharacters(in: .whitespaces)
        if mode == .volcengine, region.isEmpty || region == "ap-guangzhou" {
            regionField.stringValue = "cn-north-1"
        } else if mode == .tencent, region.isEmpty || region == "cn-north-1" {
            regionField.stringValue = "ap-guangzhou"
        }

        switch mode {
        case .openAI: baseURLField.placeholderString = "https://api.openai.com/v1"
        case .gemini: modelField.placeholderString = "gemini-2.0-flash"
        case .deepl: keyField.placeholderString = L("DeepL API key (stored in Keychain)")
        case .tencent: baseURLField.placeholderString = "https://tmt.tencentcloudapi.com"
        case .youdao: baseURLField.placeholderString = "https://openapi.youdao.com/api"
        case .volcengine: regionField.placeholderString = "cn-north-1"
        case .template: break
        }
        if animated { needsLayout = true }
    }

    /// Writes what is on screen, including the key, which goes to the Keychain.
    func save() {
        var config = config
        config.mode = selectedMode()
        config.baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.systemPrompt = promptField.stringValue
        config.method = methodField.stringValue.isEmpty ? "POST" : methodField.stringValue
        config.urlTemplate = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.headers = headersField.string
        config.bodyTemplate = bodyField.string
        config.responsePath = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.region = regionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.timeout = min(max(Double(timeoutField.stringValue) ?? 3, 1), 10)
        timeoutField.stringValue = String(format: "%.0f", config.timeout)
        config.save(role)
        config.apiKey = keyField.stringValue
        config.apiSecret = secretField.stringValue
    }

    // MARK: - Test

    @objc private func testConnection() {
        save()
        testButton.isEnabled = false
        statusLabel.stringValue = L("Testing…")

        switch role {
        case .translation:
            AIProvider.test(config) { [weak self] result in
                guard let self else { return }
                self.testButton.isEnabled = true
                switch result {
                case .success(let outcome):
                    self.statusLabel.stringValue = String(
                        format: L("Connected. “Hello” → “%@” in %.1f s."), outcome.text, outcome.seconds)
                case .failure(let error):
                    self.statusLabel.stringValue = error.localizedDescription
                }
            }

        case .ocr:
            guard let png = Self.samplePNG() else {
                testButton.isEnabled = true
                statusLabel.stringValue = L("Could not build a test image.")
                return
            }
            CloudOCR.recognize(pngBase64: png, config: config) { [weak self] result in
                guard let self else { return }
                self.testButton.isEnabled = true
                switch result {
                case .success(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusLabel.stringValue = trimmed.isEmpty
                        ? L("Connected, but the service returned no text.")
                        : String(format: L("Connected. Read: “%@”"), String(trimmed.prefix(40)))
                case .failure(let error):
                    self.statusLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    /// A small picture with a word on it, so OCR can be checked without a
    /// capture in hand.
    private static func samplePNG() -> String? {
        let size = NSSize(width: 240, height: 72)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(rect: rect).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 34, weight: .medium),
                .foregroundColor: NSColor.black,
            ]
            ("Hello" as NSString).draw(at: NSPoint(x: 24, y: 18), withAttributes: attributes)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }
}
