import Testing
@testable import DockExtender

struct FormatTests {
    @Test func percentRoundsAndStaysInRange() {
        #expect(Format.percent(0.494) == "49%")
        #expect(Format.percent(0.495) == "50%")
        #expect(Format.percent(1.4) == "100%")
        #expect(Format.percent(-0.2) == "0%")
    }

    @Test func bytesPickAUnitThatReadsWell() {
        #expect(Format.bytes(512) == "512 B")
        #expect(Format.bytes(1_500_000) == "1.5 MB")
        #expect(Format.bytes(368_000_000_000) == "368 GB")
        // Memory counts in powers of two, like Activity Monitor.
        #expect(Format.bytes(64 * 1024 * 1024 * 1024, binary: true) == "64.0 GB")
    }

    @Test func ratesStartAtKilobytes() {
        #expect(Format.rate(0) == "0 KB/s")
        #expect(Format.rate(1_200_000) == "1.2 MB/s")
        #expect(Format.compactRate(505_000) == "505 KB")
    }

    @Test func durationsGrowFromSecondsToHours() {
        #expect(Format.duration(0) == "0 s")
        #expect(Format.duration(59.9) == "59 s")
        #expect(Format.duration(60) == "1 min")
        #expect(Format.duration(3599) == "59 min")
        #expect(Format.duration(3 * 3600 + 5 * 60) == "3 h 05 min")
        #expect(Format.duration(-4) == "0 s")
    }
}
