@testable import Clipped
import Testing

@MainActor
struct HexColorParserTests {
    @Test("Parses 6-digit hex colour")
    func sixDigit() {
        let color = HexColorParser.parse("#FF5733")
        #expect(color != nil)
    }

    @Test("Parses 3-digit shorthand hex colour")
    func threeDigit() {
        let color = HexColorParser.parse("#f0a")
        #expect(color != nil)
    }

    @Test("Returns nil for invalid hex")
    func invalid() {
        #expect(HexColorParser.parse("not a colour") == nil)
        #expect(HexColorParser.parse("#GGG") == nil)
        #expect(HexColorParser.parse("") == nil)
    }

    @Test("Finds first hex colour in text")
    func firstColorInText() {
        let color = HexColorParser.firstColor(in: "Background is #2ecc71 and text is #333")
        #expect(color != nil)
    }

    @Test("Returns nil when no hex colour present")
    func noColorInText() {
        #expect(HexColorParser.firstColor(in: "no colours here") == nil)
    }

    @Test("Parses without hash prefix returns nil")
    func noHash() {
        #expect(HexColorParser.parse("FF5733") == nil)
    }
}
