@testable import Clipped
import Testing

struct ContentCategoryDetectorTests {
    // MARK: - Email

    @Test("Detects plain email addresses")
    func detectsEmails() {
        #expect(EmailDetector.contains("alice@example.com"))
        #expect(EmailDetector.contains("Contact me at bob.smith+filter@example.co.uk please"))
        #expect(EmailDetector.contains("support@sub.domain.io"))
    }

    @Test("Rejects strings that look like but aren't emails")
    func rejectsNonEmails() {
        #expect(!EmailDetector.contains("hello world"))
        #expect(!EmailDetector.contains("@handle"))
        #expect(!EmailDetector.contains("user@"))
        #expect(!EmailDetector.contains("@example.com"))
    }

    // MARK: - Phone numbers

    @Test("Detects phone numbers in common formats")
    func detectsPhoneNumbers() {
        #expect(PhoneNumberDetector.contains("+1 (415) 555-0199"))
        #expect(PhoneNumberDetector.contains("Call 020 7946 0958 tomorrow"))
        #expect(PhoneNumberDetector.contains("555-867-5309"))
    }

    @Test("Rejects short digit runs that aren't phone numbers")
    func rejectsShortDigitRuns() {
        // Six-digit order numbers should not register as phone numbers.
        #expect(!PhoneNumberDetector.contains("order 12345"))
        #expect(!PhoneNumberDetector.contains("room 42"))
    }

    // MARK: - Hex colors

    @Test("Detects hex colors via HexColorParser")
    func detectsHexColors() {
        #expect(HexColorParser.firstColor(in: "background: #ff00aa;") != nil)
        #expect(HexColorParser.firstColor(in: "#F0A") != nil)
    }

    @Test("Rejects strings without hex colors")
    func rejectsNonHexColors() {
        #expect(HexColorParser.firstColor(in: "hello world") == nil)
        #expect(HexColorParser.firstColor(in: "#nothex") == nil)
    }

    // MARK: - Numbers / currency

    @Test("Detects currency amounts")
    func detectsCurrency() {
        #expect(NumberDetector.contains("$100"))
        #expect(NumberDetector.contains("Total: €1,234.56"))
        #expect(NumberDetector.contains("£50"))
        #expect(NumberDetector.contains("¥9999"))
    }

    @Test("Detects percentages")
    func detectsPercentages() {
        #expect(NumberDetector.contains("50%"))
        #expect(NumberDetector.contains("Conversion 12.5 %"))
    }

    @Test("Detects thousands-separated numbers")
    func detectsThousands() {
        #expect(NumberDetector.contains("1,234,567"))
        #expect(NumberDetector.contains("Revenue was 12,345.67"))
    }

    @Test("Detects bare numeric strings")
    func detectsBareNumbers() {
        #expect(NumberDetector.contains("420"))
        #expect(NumberDetector.contains("3.14159"))
        #expect(NumberDetector.contains("-42"))
    }

    @Test("Ignores plain sentences that contain digits")
    func ignoresIncidentalDigits() {
        #expect(!NumberDetector.contains("the year 2024 was fine"))
        #expect(!NumberDetector.contains("meeting at 3pm"))
    }

    // MARK: - IP addresses

    @Test("Detects valid IPv4 addresses")
    func detectsIPv4() {
        #expect(IPAddressDetector.contains("192.168.1.1"))
        #expect(IPAddressDetector.contains("Server is at 10.0.0.255 right now"))
        #expect(IPAddressDetector.contains("127.0.0.1"))
        #expect(IPAddressDetector.contains("8.8.8.8"))
    }

    @Test("Rejects strings that aren't valid IPv4 addresses")
    func rejectsNonIPv4() {
        #expect(!IPAddressDetector.contains("999.1.1.1"))
        #expect(!IPAddressDetector.contains("256.0.0.1"))
        #expect(!IPAddressDetector.contains("1.2.3"))
        #expect(!IPAddressDetector.contains("hello world"))
    }

    // MARK: - MAC addresses

    @Test("Detects MAC addresses with either separator")
    func detectsMACAddresses() {
        #expect(MACAddressDetector.contains("00:1B:44:11:3A:B7"))
        #expect(MACAddressDetector.contains("device de-ad-be-ef-00-01 joined"))
        #expect(MACAddressDetector.contains("a1:b2:c3:d4:e5:f6"))
    }

    @Test("Rejects strings that aren't MAC addresses")
    func rejectsNonMACAddresses() {
        // Mixed separators are not valid MAC notation.
        #expect(!MACAddressDetector.contains("00:1B-44:11-3A:B7"))
        // Timestamps have only three colon-separated groups.
        #expect(!MACAddressDetector.contains("12:34:56"))
        #expect(!MACAddressDetector.contains("not a mac address"))
    }

    // MARK: - Aggregate detector

    @Test("Detect returns multiple categories when present together")
    func detectMultiple() {
        let text = "Email alice@example.com or call +1 415 555 0199 for $100 off"
        let categories = ContentCategoryDetector.detect(in: text)
        #expect(categories.contains(.email))
        #expect(categories.contains(.phoneNumber))
        #expect(categories.contains(.number))
    }

    @Test("Detect recognizes network identifiers")
    func detectNetworkIdentifiers() {
        let categories = ContentCategoryDetector.detect(in: "Bind 192.168.0.10 to NIC 00:1B:44:11:3A:B7")
        #expect(categories.contains(.ipAddress))
        #expect(categories.contains(.macAddress))
    }

    @Test("Detect returns empty set for plain text")
    func detectEmpty() {
        let categories = ContentCategoryDetector.detect(in: "hello world")
        #expect(categories.isEmpty)
    }

    // MARK: - Source app classification

    @Test("Source app category lookup by bundle ID")
    func sourceAppLookup() {
        #expect(SourceAppCategory.category(for: "com.apple.Safari") == .browser)
        #expect(SourceAppCategory.category(for: "com.google.Chrome") == .browser)
        #expect(SourceAppCategory.category(for: "com.apple.dt.Xcode") == .codeEditor)
        #expect(SourceAppCategory.category(for: "com.microsoft.VSCode") == .codeEditor)
        #expect(SourceAppCategory.category(for: "com.apple.Terminal") == .terminal)
        #expect(SourceAppCategory.category(for: "com.tinyspeck.slackmacgap") == .communication)
        #expect(SourceAppCategory.category(for: "com.unknown.app") == nil)
    }
}
