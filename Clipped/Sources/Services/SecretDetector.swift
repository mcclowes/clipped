import Foundation

/// Detects common API-key / secret patterns by prefix so the UI can mask them.
/// Precision-over-recall: a match means the string *looks like* a real secret, not that
/// it definitely is one. Used to flag items for display masking only — raw bytes still
/// round-trip through the clipboard unchanged so paste continues to work.
enum SecretDetector {
    private static let rawPatterns: [String] = [
        // Stripe / Clerk / webhook secrets: sk_live_, sk_test_, pk_live_, pk_test_,
        // rk_live_, rk_test_, whsec_...
        #"\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9._-]{16,}"#,
        #"\bwhsec_[A-Za-z0-9._-]{20,}"#,
        // GitHub tokens: ghp_, gho_, ghu_, ghs_, ghr_
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,
        // Slack bot/user/app tokens
        #"\bxox[bpars]-[A-Za-z0-9-]{10,}"#,
        // AWS access key IDs (permanent + temporary)
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        // Google API keys (canonical length is 35 suffix chars; allow more for safety)
        #"\bAIza[A-Za-z0-9_-]{30,}"#,
        // Supabase service role keys
        #"\bsbp_[A-Za-z0-9]{20,}"#,
        // OpenAI API keys (legacy + project-scoped)
        #"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}"#,
        // JWT tokens
        #"\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
        // Generic env-var line: UPPER_SNAKE=<long value with no whitespace>
        #"(?m)^[A-Z][A-Z0-9_]{2,}=\S{16,}$"#,
        // Credentials embedded in a URL: scheme://user:password@host (git remotes, DB strings).
        #"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/:@]+:[^\s/@]{4,}@"#,
        // One-time / verification codes appearing next to an OTP keyword.
        #"(?i)\b(?:one[- ]?time|verification|security|auth(?:entication)?|2fa|otp|passcode|pin|login)\b[^\n]{0,24}\b\d{4,8}\b"#,
        #"(?i)\b\d{4,8}\b[^\n]{0,24}\b(?:code|otp|passcode|2fa|pin)\b"#,
    ]

    private static let compiled: [NSRegularExpression] = rawPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines])
    }

    static func containsSecret(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        if compiled.contains(where: { $0.firstMatch(in: text, options: [], range: range) != nil }) {
            return true
        }
        // A copy that is *only* a 6–8 digit code is almost always an OTP/2FA code. Kept narrow
        // (6–8, whole-string) so years ("2024") and short IDs don't trip it.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (6...8).contains(trimmed.count), trimmed.allSatisfy(\.isNumber) {
            return true
        }
        return false
    }
}
