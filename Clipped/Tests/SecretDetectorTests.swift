@testable import Clipped
import Testing

struct SecretDetectorTests {
    /// Fixtures are assembled at runtime via concatenation so the literal source bytes
    /// never contain a full secret-looking token. This keeps GitHub push-protection happy
    /// while still giving the detector a string that matches its regexes.
    private static func token(_ prefix: String, _ body: String) -> String {
        prefix + body
    }

    @Test("Detects Stripe/Clerk secret and publishable keys")
    func detectsStripeStyle() {
        #expect(SecretDetector.containsSecret(Self.token("sk_", "test_EXAMPLEabcdefghij0123456789")))
        #expect(SecretDetector.containsSecret(Self.token("sk_", "live_EXAMPLEabcdefghij0123456789")))
        #expect(SecretDetector.containsSecret(Self.token("pk_", "test_EXAMPLEabcdefghij0123456789")))
        #expect(SecretDetector.containsSecret(Self.token("whsec", "_EXAMPLEabcdefghij0123456789")))
    }

    @Test("Detects env-var lines in a config dump")
    func detectsEnvDump() {
        let clerkPublishable = Self.token("pk_", "test_EXAMPLEabcdefghij0123456789")
        let clerkSecret = Self.token("sk_", "test_EXAMPLEabcdefghij0123456789")
        let envDump = """
        NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=\(clerkPublishable)
        CLERK_SECRET_KEY=\(clerkSecret)
        """
        #expect(SecretDetector.containsSecret(envDump))
    }

    @Test("Detects GitHub personal access tokens")
    func detectsGitHubTokens() {
        #expect(SecretDetector.containsSecret(Self.token("ghp", "_EXAMPLEabcdefghij0123456789")))
        #expect(SecretDetector.containsSecret(Self.token("gho", "_EXAMPLEabcdefghij0123456789")))
        #expect(SecretDetector.containsSecret(Self.token("ghs", "_EXAMPLEabcdefghij0123456789")))
    }

    @Test("Detects Slack tokens")
    func detectsSlackTokens() {
        #expect(SecretDetector.containsSecret(Self.token("xox", "b-EXAMPLE-EXAMPLE-abcdefghij")))
        #expect(SecretDetector.containsSecret(Self.token("xox", "p-EXAMPLE-EXAMPLE-abcdefghij")))
    }

    @Test("Detects AWS access keys")
    func detectsAWSKeys() {
        #expect(SecretDetector.containsSecret(Self.token("AKIA", "EXAMPLEEXAMPLE00")))
        #expect(SecretDetector.containsSecret(Self.token("ASIA", "EXAMPLEEXAMPLE00")))
    }

    @Test("Detects Google API keys")
    func detectsGoogleKeys() {
        #expect(SecretDetector.containsSecret(Self.token("AIza", "EXAMPLEabcdefghij0123456789abcdef")))
    }

    @Test("Detects OpenAI API keys")
    func detectsOpenAIKeys() {
        #expect(SecretDetector.containsSecret(Self.token("sk-", "EXAMPLEabcdefghij0123456789abcdef")))
        #expect(SecretDetector.containsSecret(Self.token("sk-", "proj-EXAMPLEabcdefghij0123456789")))
    }

    @Test("Detects JWT tokens")
    func detectsJWTs() {
        let jwt = Self.token("eyJ", "hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9")
            + "."
            + Self.token("eyJ", "zdWIiOiIxMjM0NTY3ODkwIn0")
            + "."
            + "EXAMPLEsignatureValueXYZ0123456789"
        #expect(SecretDetector.containsSecret(jwt))
    }

    @Test("Detects generic env-style lines with long values")
    func detectsGenericEnvLines() {
        #expect(SecretDetector.containsSecret("DATABASE_URL=postgres://user:hunter2abc@host/db"))
        #expect(SecretDetector.containsSecret("API_TOKEN=abcdef1234567890abcdef1234567890"))
    }

    @Test("Does not flag ordinary prose")
    func ignoresPlainText() {
        #expect(!SecretDetector.containsSecret("hello world"))
        #expect(!SecretDetector.containsSecret("Meeting at 3pm tomorrow"))
        #expect(!SecretDetector.containsSecret("Talk to sk about the test later"))
    }

    @Test("Does not flag short tokens that lack sufficient entropy")
    func ignoresShortTokens() {
        #expect(!SecretDetector.containsSecret(Self.token("sk_", "test_abc")))
        #expect(!SecretDetector.containsSecret(Self.token("ghp", "_short")))
        #expect(!SecretDetector.containsSecret(Self.token("AKIA", "123")))
    }

    @Test("Does not flag an env-line with a short value")
    func ignoresShortEnvValue() {
        #expect(!SecretDetector.containsSecret("PORT=3000"))
        #expect(!SecretDetector.containsSecret("DEBUG=true"))
    }

    @Test("Detects when a secret is embedded in larger text")
    func detectsEmbeddedSecret() {
        let secret = Self.token("sk_", "test_EXAMPLEabcdefghij0123456789")
        let mixed = """
        Here is the config we discussed:

            CLERK_SECRET_KEY=\(secret)

        Let me know if you need anything else.
        """
        #expect(SecretDetector.containsSecret(mixed))
    }
}
