//
//  InputTelemetryTests.swift
//  BetterCaptureTests
//
//  Created by Diip3sh on 25.09.26.
//

import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing
@testable import BetterCapture

struct InputTelemetryTests {

    private let capture = InputTelemetry.Capture(kind: .area, videoSize: CGSize(width: 1600, height: 1200))

    private let geometry = InputTelemetry.Geometry(
        time: 1,
        screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
        contentRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
        boundingRect: nil,
        contentScale: 1,
        scaleFactor: 2
    )

    // MARK: - videoTime

    @Test func videoTimeIsMeasuredFromTheAnchor() {
        #expect(InputTelemetry.videoTime(hostTime: 103.5, anchor: 100, duration: 10) == 3.5)
    }

    @Test func videoTimeDropsEventsBeforeTheAnchorOrAfterTheEnd() {
        #expect(InputTelemetry.videoTime(hostTime: 99.5, anchor: 100, duration: 10) == nil)
        #expect(InputTelemetry.videoTime(hostTime: 110.5, anchor: 100, duration: 10) == nil)
    }

    // MARK: - rebased

    @Test func rebasedMovesEventsOntoTheVideoTimeline() {
        var telemetry = InputTelemetry(capture: capture, keystrokesAvailable: true)
        telemetry.clicks = [
            .init(time: 98, location: .zero, button: .left, isDown: true, clickCount: 1),
            .init(time: 102, location: .zero, button: .left, isDown: false, clickCount: 1)
        ]
        telemetry.scrolls = [.init(time: 105, location: .zero, delta: CGVector(dx: 0, dy: -3))]
        telemetry.keys = [.init(time: 111, keyCode: 8, modifiers: ["command"], isRepeat: false)]

        let rebased = telemetry.rebased(anchor: 100, duration: 10)

        #expect(rebased.clicks.map(\.time) == [2])
        #expect(rebased.scrolls.map(\.time) == [5])
        #expect(rebased.keys.isEmpty)
    }

    @Test func rebasedPinsTheLastCursorPositionBeforeTheAnchorToZero() {
        var telemetry = InputTelemetry(capture: capture, keystrokesAvailable: false)
        telemetry.cursor = [
            .init(time: 99, location: CGPoint(x: 1, y: 1)),
            .init(time: 99.5, location: CGPoint(x: 2, y: 2)),
            .init(time: 101, location: CGPoint(x: 3, y: 3))
        ]

        let rebased = telemetry.rebased(anchor: 100, duration: 10)

        #expect(rebased.cursor == [
            .init(time: 0, location: CGPoint(x: 2, y: 2)),
            .init(time: 1, location: CGPoint(x: 3, y: 3))
        ])
    }

    @Test func rebasedPinsTheLastGeometryBeforeTheAnchorToZero() {
        var moved = geometry
        moved.time = 104
        moved.screenRect.origin.x = 10
        var early = geometry
        early.time = 99
        var telemetry = InputTelemetry(capture: capture, keystrokesAvailable: false)
        telemetry.geometry = [early, moved]

        let rebased = telemetry.rebased(anchor: 100, duration: 10)

        #expect(rebased.geometry.map(\.time) == [0, 4])
        #expect(rebased.geometry.map(\.screenRect.minX) == [0, 10])
    }

    // MARK: - videoPixel

    @Test func videoPixelScalesADisplayCaptureByItsScaleFactor() {
        #expect(InputTelemetry.videoPixel(for: CGPoint(x: 100.5, y: 200), geometry: geometry) == CGPoint(x: 201, y: 400))
    }

    @Test func videoPixelOffsetsAnAreaOnADisplayLeftOfThePrimary() {
        let area = InputTelemetry.Geometry(
            time: 0,
            screenRect: CGRect(x: -1820, y: 50, width: 800, height: 600),
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            boundingRect: nil,
            contentScale: 1,
            scaleFactor: 1
        )
        #expect(InputTelemetry.videoPixel(for: CGPoint(x: -1420, y: 350), geometry: area) == CGPoint(x: 400, y: 300))
    }

    @Test func videoPixelFollowsAWindowScaledDownAndLetterboxed() {
        // A 1000x500 pt window fitted into a 1500x1000 px (750x500 pt) frame: scaled by 0.75,
        // then centred vertically in the 125 pt left over
        let window = InputTelemetry.Geometry(
            time: 0,
            screenRect: CGRect(x: 200, y: 100, width: 1000, height: 500),
            contentRect: CGRect(x: 0, y: 62.5, width: 750, height: 375),
            boundingRect: nil,
            contentScale: 0.75,
            scaleFactor: 2
        )
        #expect(InputTelemetry.videoPixel(for: CGPoint(x: 200, y: 100), geometry: window) == CGPoint(x: 0, y: 125))
        #expect(InputTelemetry.videoPixel(for: CGPoint(x: 700, y: 350), geometry: window) == CGPoint(x: 750, y: 500))
    }

    @Test func videoPixelInsetsAWindowCapturedWithItsShadow() {
        // Recorded values: a 1710x1074 pt window whose shadow adds 112 pt each way, fitted into a
        // 3420x2148 px video. The cursor tip was found at this pixel in the extracted frame.
        let window = InputTelemetry.Geometry(
            time: 0,
            screenRect: CGRect(x: 0, y: 38, width: 1710, height: 1074),
            contentRect: CGRect(x: 0, y: 0, width: 1649.939255475998, height: 1073.9999763965607),
            boundingRect: nil,
            contentScale: 0.9055649042129517,
            scaleFactor: 2
        )
        let pixel = InputTelemetry.videoPixel(for: CGPoint(x: 1402.546875, y: 329.19921875), geometry: window)
        #expect(abs(pixel.x - 2641) <= 4)
        #expect(abs(pixel.y - 598) <= 4)
    }

    // MARK: - CaptureGeometryTracker

    @Test func geometryIsReadOnlyFromCompleteFrames() throws {
        let screenRect = CGRect(x: -56, y: -2, width: 1892, height: 1188)
        let contentRect = CGRect(x: 0, y: 0, width: 1710, height: 1074)
        var attachments: [String: Any] = [
            SCStreamFrameInfo.status.rawValue: SCFrameStatus.complete.rawValue,
            SCStreamFrameInfo.screenRect.rawValue: screenRect.dictionaryRepresentation,
            SCStreamFrameInfo.contentRect.rawValue: contentRect.dictionaryRepresentation,
            SCStreamFrameInfo.contentScale.rawValue: NSNumber(value: 0.904),
            SCStreamFrameInfo.scaleFactor.rawValue: NSNumber(value: 2)
        ]

        let read = try #require(CaptureGeometryTracker.geometry(from: attachments, time: 12))
        #expect(read == .init(
            time: 12, screenRect: screenRect, contentRect: contentRect, boundingRect: nil, contentScale: 0.904, scaleFactor: 2
        ))

        attachments[SCStreamFrameInfo.status.rawValue] = SCFrameStatus.idle.rawValue
        #expect(CaptureGeometryTracker.geometry(from: attachments, time: 12) == nil)
    }

    @Test func trackerKeepsOnlyChangesWhileEnabled() {
        let tracker = CaptureGeometryTracker()
        var repeated = geometry
        repeated.time = 2
        var moved = geometry
        moved.time = 3
        moved.screenRect.origin.x = 10

        tracker.append(geometry)
        #expect(tracker.track.isEmpty)

        tracker.reset(isEnabled: true)
        tracker.append(geometry)
        tracker.append(repeated)
        tracker.append(moved)
        #expect(tracker.track == [geometry, moved])
    }

    // MARK: - topLeft

    @Test func topLeftFlipsAgainstThePrimaryScreenHeight() {
        #expect(InputTelemetry.topLeft(CGPoint(x: 10, y: 100), primaryScreenHeight: 982) == CGPoint(x: 10, y: 882))
    }

    @Test func topLeftGivesNegativeYOnADisplayAboveThePrimary() {
        #expect(InputTelemetry.topLeft(CGPoint(x: 2200, y: 1200), primaryScreenHeight: 982) == CGPoint(x: 2200, y: -218))
    }

    // MARK: - modifierNames

    @Test func modifierNamesFollowTheMacOSOrder() {
        #expect(InputTelemetry.modifierNames([.maskCommand, .maskShift, .maskControl]) == ["control", "shift", "command"])
    }

    @Test func modifierNamesIgnoreNonModifierFlags() {
        #expect(InputTelemetry.modifierNames([.maskNumericPad]).isEmpty)
    }

    // MARK: - sidecarURL

    @Test func sidecarSitsNextToTheVideoWithTheSameBaseName() {
        let video = URL(filePath: "/Users/me/Movies/BetterCapture_2026-09-25-10.00.00.mov")
        #expect(InputTelemetry.sidecarURL(for: video).path() == "/Users/me/Movies/BetterCapture_2026-09-25-10.00.00.telemetry.json")
    }

    // MARK: - Encoding

    @Test func encodingRoundTripsAndIncludesTheVersion() throws {
        var telemetry = InputTelemetry(capture: capture, keystrokesAvailable: true)
        telemetry.geometry = [geometry]
        telemetry.cursor = [.init(time: 0.5, location: CGPoint(x: 120, y: 80))]
        telemetry.clicks = [.init(time: 1, location: CGPoint(x: 120, y: 80), button: .right, isDown: true, clickCount: 2)]
        telemetry.scrolls = [.init(time: 1.5, location: CGPoint(x: 120, y: 80), delta: CGVector(dx: 0, dy: 4))]
        telemetry.keys = [.init(time: 2, keyCode: 8, modifiers: ["command"], isRepeat: false)]

        let data = try JSONEncoder().encode(telemetry)
        let object = try JSONSerialization.jsonObject(with: data)
        let json = try #require(object as? [String: Any])

        #expect(json["version"] as? Int == 2)
        #expect(json["geometry"] != nil)
        #expect(try JSONDecoder().decode(InputTelemetry.self, from: data) == telemetry)
    }
}
