//
//  ClaudeModelsConfigTests.swift
//  TermSnapTests
//

import Testing
import Foundation
@testable import TermSnap

struct ClaudeModelsConfigTests {

    // MARK: - Parsing

    @Test func parsesFullProvider() throws {
        let json = """
        {
          "default": "glm",
          "models": {
            "glm": {
              "model_name": "GLM-5.1",
              "small_fast_model": "GLM-5.1",
              "default_sonnet_model": "GLM-5.1",
              "default_opus_model": "GLM-5.1",
              "default_haiku_model": "GLM-5.1",
              "base_url": "https://open.bigmodel.cn/api/anthropic",
              "api_key_env": "$GLM_API_KEY"
            }
          }
        }
        """
        let cfg = try #require(ClaudeModelsConfig.parse(data: json.data(using: .utf8)!))
        #expect(cfg.defaultKey == "glm")
        #expect(cfg.providers.count == 1)
        let p = try #require(cfg.provider(forKey: "glm"))
        #expect(p.modelName == "GLM-5.1")
        #expect(p.baseURL == "https://open.bigmodel.cn/api/anthropic")
        #expect(p.apiKeyEnv == "$GLM_API_KEY")
        #expect(p.smallFastModel == "GLM-5.1")
    }

    @Test func parsesProviderWithOnlyRequiredFields() throws {
        let json = """
        {
          "models": {
            "minimal": {
              "model_name": "X",
              "base_url": "https://api.example.com/anthropic",
              "api_key_env": "$X_KEY"
            }
          }
        }
        """
        let cfg = try #require(ClaudeModelsConfig.parse(data: json.data(using: .utf8)!))
        #expect(cfg.defaultKey == nil)
        let p = try #require(cfg.provider(forKey: "minimal"))
        #expect(p.smallFastModel == nil)
        #expect(p.defaultSonnetModel == nil)
    }

    @Test func dropsProviderMissingRequiredField() throws {
        let json = """
        {
          "models": {
            "good": { "model_name": "G", "base_url": "u", "api_key_env": "$K" },
            "bad":  { "model_name": "B" }
          }
        }
        """
        let cfg = try #require(ClaudeModelsConfig.parse(data: json.data(using: .utf8)!))
        #expect(cfg.providers.count == 1)
        #expect(cfg.provider(forKey: "good") != nil)
        #expect(cfg.provider(forKey: "bad") == nil)
    }

    @Test func emptyModelsParsesToEmptyList() throws {
        let json = #"{"models": {}}"#
        let cfg = try #require(ClaudeModelsConfig.parse(data: json.data(using: .utf8)!))
        #expect(cfg.providers.isEmpty)
    }

    @Test func malformedJSONReturnsNil() {
        #expect(ClaudeModelsConfig.parse(data: Data("not json".utf8)) == nil)
    }

    @Test func missingModelsReturnsNil() {
        #expect(ClaudeModelsConfig.parse(data: Data(#"{"default":"x"}"#.utf8)) == nil)
    }

    // MARK: - Order preservation

    @Test func preservesJSONKeyOrder() throws {
        let json = """
        {
          "models": {
            "zeta":  { "model_name": "Z", "base_url": "u", "api_key_env": "$K" },
            "alpha": { "model_name": "A", "base_url": "u", "api_key_env": "$K" },
            "mike":  { "model_name": "M", "base_url": "u", "api_key_env": "$K" }
          }
        }
        """
        let cfg = try #require(ClaudeModelsConfig.parse(data: json.data(using: .utf8)!))
        #expect(cfg.providers.map(\.key) == ["zeta", "alpha", "mike"])
    }

    // MARK: - launchSnippet

    @Test func launchSnippetIncludesAllSetFields() {
        let p = ClaudeProvider(
            modelName: "GLM-5.1",
            smallFastModel: "GLM-Air",
            defaultSonnetModel: "GLM-5.1",
            defaultOpusModel: "GLM-Pro",
            defaultHaikuModel: "GLM-Air",
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            apiKeyEnv: "$GLM_API_KEY",
            iconOverride: nil
        )
        let cmd = ClaudeModelsConfig.launchSnippet(for: p)
        #expect(cmd.contains("ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic"))
        #expect(cmd.contains("ANTHROPIC_AUTH_TOKEN=$GLM_API_KEY"))
        #expect(cmd.contains("ANTHROPIC_MODEL=GLM-5.1"))
        #expect(cmd.contains("ANTHROPIC_SMALL_FAST_MODEL=GLM-Air"))
        #expect(cmd.contains("ANTHROPIC_DEFAULT_SONNET_MODEL=GLM-5.1"))
        #expect(cmd.contains("ANTHROPIC_DEFAULT_OPUS_MODEL=GLM-Pro"))
        #expect(cmd.contains("ANTHROPIC_DEFAULT_HAIKU_MODEL=GLM-Air"))
        #expect(cmd.hasSuffix(" claude"))
    }

    @Test func launchSnippetSkipsNilFields() {
        let p = ClaudeProvider(
            modelName: "M",
            smallFastModel: nil,
            defaultSonnetModel: nil,
            defaultOpusModel: nil,
            defaultHaikuModel: nil,
            baseURL: "https://x",
            apiKeyEnv: "$K",
            iconOverride: nil
        )
        let cmd = ClaudeModelsConfig.launchSnippet(for: p)
        #expect(!cmd.contains("SMALL_FAST"))
        #expect(!cmd.contains("DEFAULT_SONNET"))
        #expect(cmd == "ANTHROPIC_BASE_URL=https://x ANTHROPIC_AUTH_TOKEN=$K ANTHROPIC_MODEL=M claude")
    }

    // MARK: - Icon override

    @Test func iconOverrideIsDecoded() throws {
        let json = """
        {
          "models": {
            "doubao": {
              "model_name": "doubao-pro",
              "base_url": "https://x",
              "api_key_env": "$DOUBAO_API_KEY",
              "icon": { "label": "豆", "color": "#3A7AFE", "text_color": "#FFFFFF", "shape": "circle" }
            }
          }
        }
        """
        let cfg = try #require(ClaudeModelsConfig.parse(data: json.data(using: .utf8)!))
        let p = try #require(cfg.provider(forKey: "doubao"))
        let icon = try #require(p.iconOverride)
        #expect(icon.label == "豆")
        #expect(icon.color == "#3A7AFE")
        #expect(icon.textColor == "#FFFFFF")
        #expect(icon.shape == "circle")
    }

    @Test func iconOverrideAbsentParsesToNil() throws {
        let json = """
        {"models": {"x": {"model_name": "X", "base_url": "u", "api_key_env": "$K"}}}
        """
        let cfg = try #require(ClaudeModelsConfig.parse(data: json.data(using: .utf8)!))
        #expect(cfg.provider(forKey: "x")?.iconOverride == nil)
    }

    @Test func emptyIconObjectParsesToNil() throws {
        let json = """
        {"models": {"x": {"model_name": "X", "base_url": "u", "api_key_env": "$K", "icon": {}}}}
        """
        let cfg = try #require(ClaudeModelsConfig.parse(data: json.data(using: .utf8)!))
        #expect(cfg.provider(forKey: "x")?.iconOverride == nil)
    }
}
