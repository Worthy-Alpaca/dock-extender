import CoreGraphics
import Testing
@testable import DockExtender

/// What the app remembers about how deep the Dock is at each size.
struct DockCalibrationTests {
    @Test func knowsNothingUntilTheDockWasMeasured() {
        #expect(DockCalibration().thickness(edge: .bottom, tileSize: 54) == nil)
    }

    @Test func returnsTheMeasurementForASizeItHasSeen() {
        var calibration = DockCalibration()
        let isNews = calibration.record(edge: .bottom, tileSize: 54, thickness: 79)
        #expect(isNews)
        #expect(calibration.thickness(edge: .bottom, tileSize: 54) == 79)
        // The same measurement again is not news.
        let isStillNews = calibration.record(edge: .bottom, tileSize: 54, thickness: 79)
        #expect(!isStillNews)
    }

    @Test func borrowsThePaddingOfTheNearestMeasuredSize() {
        var calibration = DockCalibration()
        _ = calibration.record(edge: .bottom, tileSize: 54, thickness: 79)   // 25 pt of padding
        _ = calibration.record(edge: .bottom, tileSize: 45, thickness: 64)   // 19 pt
        #expect(calibration.thickness(edge: .bottom, tileSize: 67) == 92)
        #expect(calibration.thickness(edge: .bottom, tileSize: 47) == 66)
        #expect(calibration.thickness(edge: .bottom, tileSize: 52) == 77)
    }

    @Test func aTieGoesToTheSmallerSizeEveryTime() {
        var calibration = DockCalibration()
        _ = calibration.record(edge: .bottom, tileSize: 46, thickness: 65)   // 19 pt
        _ = calibration.record(edge: .bottom, tileSize: 50, thickness: 75)   // 25 pt
        for _ in 0..<20 {
            #expect(calibration.thickness(edge: .bottom, tileSize: 48) == 67)
        }
    }

    @Test func keepsEdgesApart() {
        var calibration = DockCalibration()
        _ = calibration.record(edge: .bottom, tileSize: 54, thickness: 79)
        #expect(calibration.thickness(edge: .left, tileSize: 54) == nil)
    }

    @Test func aFullDockSaysNothingAboutOtherSizes() {
        // Set to 128 but only 85 deep: the Dock shrank its icons to fit.
        var calibration = DockCalibration()
        let isKept = calibration.record(edge: .bottom, tileSize: 128, thickness: 85)
        #expect(isKept)
        #expect(calibration.thickness(edge: .bottom, tileSize: 128) == 85)
        #expect(calibration.thickness(edge: .bottom, tileSize: 64) == nil)
    }

    @Test func aReadingTakenMidResizeIsNotKept() {
        // Far deeper than the setting allows: the setting had not caught up.
        var calibration = DockCalibration()
        let isKept = calibration.record(edge: .bottom, tileSize: 45, thickness: 120)
        #expect(!isKept)
        #expect(calibration.thickness(edge: .bottom, tileSize: 45) == nil)
    }

    @Test func estimateIsUsedOnlyAsAStartingPoint() {
        #expect(DockGeometry.estimatedThickness(tileSize: 54) == 79)
    }
}
