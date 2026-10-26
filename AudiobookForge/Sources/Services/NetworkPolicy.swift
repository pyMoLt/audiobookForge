import Foundation

/// Network rules for every download the app starts (v4.2): runtimes via
/// pip, models via huggingface_hub, all in child processes. Set once at
/// launch on the app's environment, which those processes inherit — a
/// stalled connection fails after 30 s instead of hanging, pip retries on
/// its own, huggingface_hub resumes partial files on the next attempt, and
/// `ComponentRunner` tries each step up to three times.
enum NetworkPolicy {
    static let stallTimeoutSeconds = 30
    static let attempts = 3

    static var childProcessEnvironment: [String: String] {
        [
            "HF_HUB_DOWNLOAD_TIMEOUT": "\(stallTimeoutSeconds)",
            "HF_HUB_ETAG_TIMEOUT": "\(stallTimeoutSeconds)",
            "PIP_DEFAULT_TIMEOUT": "\(stallTimeoutSeconds)",
            "PIP_RETRIES": "5",
            "UV_HTTP_TIMEOUT": "\(stallTimeoutSeconds)",
        ]
    }

    /// Keeps values the user set themselves.
    static func applyToChildProcesses() {
        for (key, value) in childProcessEnvironment where ProcessInfo.processInfo.environment[key] == nil {
            setenv(key, value, 0)
        }
    }

    /// Errors not worth retrying: missing sign-in/terms, cancellation.
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case PhononEnvironmentManager.InstallError.termsRequired = error { return false }
        return true
    }
}
