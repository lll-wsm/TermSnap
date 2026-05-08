//
//  TermSnapTests.swift
//  TermSnapTests
//
//  Created by lll on 2026/4/30.
//

import Testing
import AppKit
@testable import TermSnap

struct TermSnapTests {

    @Test func overlayGeometryConvertsPointToGlobalTopLeftSpace() async throws {
        let desktop = CGRect(x: -1440, y: 0, width: 3360, height: 1080)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let localPoint = CGPoint(x: 100, y: 50)

        let converted = OverlayGeometry.toGlobalTopLeft(point: localPoint, on: screen, desktopBounds: desktop)

        #expect(converted.x == 100)
        #expect(converted.y == 1030)
    }

    @Test func overlayGeometryConvertsGlobalRectToLocalBottomLeftSpace() async throws {
        let desktop = CGRect(x: -1440, y: 0, width: 3360, height: 1080)
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let globalTopLeftRect = CGRect(x: -1300, y: 200, width: 400, height: 300)

        let converted = OverlayGeometry.fromGlobalTopLeft(rect: globalTopLeftRect, toLocalOn: screen, desktopBounds: desktop)

        #expect(converted.origin.x == 140)
        #expect(converted.origin.y == 580)
        #expect(converted.width == 400)
        #expect(converted.height == 300)
    }

}
