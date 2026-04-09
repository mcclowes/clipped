@testable import Clipped
import Testing

struct DeveloperContentDetectorTests {
    @Test("Detects UUIDs")
    func detectsUUIDs() {
        #expect(DeveloperContentDetector.isDeveloperContent("550e8400-e29b-41d4-a716-446655440000"))
        #expect(DeveloperContentDetector.isDeveloperContent("id: 550e8400-e29b-41d4-a716-446655440000"))
    }

    @Test("Detects markdown code blocks")
    func detectsCodeBlocks() {
        let markdown = """
        Here is some code:
        ```swift
        let x = 42
        ```
        """
        #expect(DeveloperContentDetector.isDeveloperContent(markdown))
    }

    @Test("Detects long hex strings (SHA hashes)")
    func detectsHexStrings() {
        #expect(DeveloperContentDetector.isDeveloperContent("da39a3ee5e6b4b0d3255bfef95601890afd80709"))
        #expect(DeveloperContentDetector.isDeveloperContent("commit e3b0c44298fc1c149afbf4c8996fb92427ae41e4"))
    }

    @Test("Detects JWT tokens")
    func detectsJWTs() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(DeveloperContentDetector.isDeveloperContent(jwt))
    }

    @Test("Detects JSON objects")
    func detectsJSON() {
        #expect(DeveloperContentDetector.isDeveloperContent(#"{"key": "value", "count": 42}"#))
        #expect(DeveloperContentDetector.isDeveloperContent(#"[{"id": 1}, {"id": 2}]"#))
    }

    @Test("Detects file paths")
    func detectsFilePaths() {
        #expect(DeveloperContentDetector.isDeveloperContent("/usr/local/bin/python"))
        #expect(DeveloperContentDetector.isDeveloperContent("open /Applications/Xcode.app"))
    }

    @Test("Does not flag plain text as developer content")
    func rejectsPlainText() {
        #expect(!DeveloperContentDetector.isDeveloperContent("hello world"))
        #expect(!DeveloperContentDetector.isDeveloperContent("Meeting at 3pm tomorrow"))
        #expect(!DeveloperContentDetector.isDeveloperContent("Buy milk and eggs"))
    }
}
