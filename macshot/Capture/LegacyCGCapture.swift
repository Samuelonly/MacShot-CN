import CoreGraphics
import Darwin

/// ENH: The app now targets macOS 15, where the SDK obsoletes
/// `CGWindowListCreateImage` in favour of ScreenCaptureKit. The symbol is still
/// exported by CoreGraphics at runtime, and the pre-ScreenCaptureKit capture
/// paths rely on it, so it is resolved once at runtime instead of being
/// hard-linked against a declaration the SDK no longer publishes.
enum LegacyCGCapture {
    private typealias CreateImageFn =
        @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let createImageFn: CreateImageFn? = {
        guard
            let handle = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
            let symbol = dlsym(handle, "CGWindowListCreateImage")
        else { return nil }
        return unsafeBitCast(symbol, to: CreateImageFn.self)
    }()

    /// Same contract as `CGWindowListCreateImage`: the caller owns the result.
    /// Returns nil if the symbol is gone, which lets the callers keep their
    /// existing failure handling.
    static func createImage(
        _ screenBounds: CGRect,
        _ listOption: CGWindowListOption,
        _ windowID: CGWindowID,
        _ imageOption: CGWindowImageOption
    ) -> CGImage? {
        guard let function = createImageFn else { return nil }
        return function(screenBounds, listOption.rawValue, windowID, imageOption.rawValue)?
            .takeRetainedValue()
    }
}
