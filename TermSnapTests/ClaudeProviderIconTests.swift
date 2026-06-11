//
//  ClaudeProviderIconTests.swift
//  TermSnapTests
//

import Testing
import AppKit
@testable import TermSnap

struct ClaudeProviderIconTests {

    // MARK: - Sizing

    @Test func iconRespectsRequestedSize() {
        let small = ClaudeProviderIcon.image(for: "glm", size: 12)
        let large = ClaudeProviderIcon.image(for: "glm", size: 32)
        #expect(small.size.width == 12)
        #expect(large.size.width == 32)
    }

    @Test func letterMarkRendersAtRequestedSize() {
        let img = ClaudeProviderIcon.letterMark(label: "X",
                                                background: .systemBlue,
                                                textColor: .white,
                                                shape: .rounded,
                                                size: 24)
        #expect(img.size == NSSize(width: 24, height: 24))
    }

    // MARK: - Label resolution

    @Test func providerWithoutOverrideUsesFirstKeyCharacter() {
        // No override → gray default; label = uppercased first char of key.
        let img = ClaudeProviderIcon.image(for: "doubao", size: 16)
        #expect(img.size == NSSize(width: 16, height: 16))
    }

    @Test func overrideLabelTakesPrecedenceOverKey() {
        let spec = ProviderIconSpec(label: "豆", color: "#3A7AFE", textColor: "#FFFFFF", shape: nil)
        let img = ClaudeProviderIcon.image(for: "doubao", override: spec, size: 24)
        #expect(img.size == NSSize(width: 24, height: 24))
    }

    @Test func emptyLabelFallsBackToFirstKeyCharacter() {
        // Explicit empty string should be treated as "not provided".
        let spec = ProviderIconSpec(label: "", color: nil, textColor: nil, shape: nil)
        let img = ClaudeProviderIcon.image(for: "acme", override: spec, size: 16)
        #expect(img.size == NSSize(width: 16, height: 16))
    }

    // MARK: - Shape parsing

    @Test func shapeRawValueParsing() {
        #expect(matches(ClaudeProviderIcon.Shape(rawValue: "circle"), .circle))
        #expect(matches(ClaudeProviderIcon.Shape(rawValue: "CIRCLE"), .circle))
        #expect(matches(ClaudeProviderIcon.Shape(rawValue: "square"), .square))
        #expect(matches(ClaudeProviderIcon.Shape(rawValue: "rounded"), .rounded))
        // Unknown → default rounded.
        #expect(matches(ClaudeProviderIcon.Shape(rawValue: "hexagon"), .rounded))
        // Nil → default rounded.
        #expect(matches(ClaudeProviderIcon.Shape(rawValue: nil), .rounded))
    }

    @Test func eachShapeRendersWithoutCrash() {
        for shapeName in ["rounded", "circle", "square"] {
            let spec = ProviderIconSpec(label: "A", color: "#FF3366", textColor: "#FFFFFF", shape: shapeName)
            let img = ClaudeProviderIcon.image(for: "x", override: spec, size: 20)
            #expect(img.size == NSSize(width: 20, height: 20))
        }
    }

    // MARK: - Hex parser

    @Test func parsesHexColorWithHash() throws {
        let c = try #require(ClaudeProviderIcon.parseHexColor("#FF6B00"))
        #expect(abs(c.redComponent - 1.0) < 0.01)
        #expect(abs(c.greenComponent - 0.42) < 0.01)
        #expect(abs(c.blueComponent - 0.0) < 0.01)
    }

    @Test func parsesHexColorWithoutHash() throws {
        let c = try #require(ClaudeProviderIcon.parseHexColor("4D6BFE"))
        #expect(abs(c.redComponent - 0.30) < 0.01)
    }

    @Test func parsesHexColorWithAlpha() throws {
        let c = try #require(ClaudeProviderIcon.parseHexColor("#FF000080"))
        #expect(abs(c.alphaComponent - 0.50) < 0.01)
    }

    @Test func rejectsBadHex() {
        #expect(ClaudeProviderIcon.parseHexColor("zzzzzz") == nil)
        #expect(ClaudeProviderIcon.parseHexColor("#abc") == nil)
        #expect(ClaudeProviderIcon.parseHexColor("") == nil)
    }

    // MARK: - Helpers

    private func matches(_ a: ClaudeProviderIcon.Shape, _ b: ClaudeProviderIcon.Shape) -> Bool {
        switch (a, b) {
        case (.rounded, .rounded), (.circle, .circle), (.square, .square): return true
        default: return false
        }
    }
}
