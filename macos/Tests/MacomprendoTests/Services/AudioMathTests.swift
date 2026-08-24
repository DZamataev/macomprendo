import Foundation
import Testing
@testable import Macomprendo

@Suite struct AudioMathTests {
    @Test func rmsOfSilenceIsZero() {
        #expect(AudioMath.rms([0, 0, 0, 0]) == 0)
    }

    @Test func rmsOfEmptyBufferIsZero() {
        #expect(AudioMath.rms([]) == 0)
    }

    @Test func rmsOfFullScaleSquareWaveIsOne() {
        #expect(abs(AudioMath.rms([1, -1, 1, -1]) - 1) < 0.0001)
    }

    @Test func levelIsZeroAtOrBelowTheNoiseFloor() {
        #expect(AudioMath.level(fromRMS: 0) == 0)
        #expect(AudioMath.level(fromRMS: 0.001) == 0)      // -60 dBFS
        #expect(AudioMath.level(fromRMS: 0.0001) == 0)     // -80 dBFS, clamped
    }

    @Test func levelIsOneAtFullScale() {
        #expect(AudioMath.level(fromRMS: 1) == 1)
        #expect(AudioMath.level(fromRMS: 2) == 1)
    }

    @Test func levelIsHalfwayAtMinus30dB() {
        #expect(abs(AudioMath.level(fromRMS: 0.0316228) - 0.5) < 0.01)
    }
}

@Suite struct PCMResamplerTests {
    @Test func passesSamplesThroughWhenRatesMatch() {
        var resampler = PCMResampler(inputRate: 16_000, outputRate: 16_000)
        #expect(resampler.resample([0, 1, 2, 3, 4]) == [0, 1, 2, 3])
        #expect(resampler.resample([5, 6]) == [4, 5])
    }

    @Test func halvesTheSampleCountWhenDecimatingByTwo() {
        var resampler = PCMResampler(inputRate: 32_000, outputRate: 16_000)
        let output = resampler.resample(Array(repeating: 0.5, count: 100))
        #expect(output.count == 50)
        #expect(output.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    @Test func keepsPhaseAcrossChunkBoundaries() {
        var resampler = PCMResampler(inputRate: 32_000, outputRate: 16_000)
        #expect(resampler.resample([0, 1, 2, 3]) == [0, 2])
        #expect(resampler.resample([4, 5, 6, 7]) == [4, 6])
    }

    @Test func interpolatesBetweenSamplesWhenUpsampling() {
        var resampler = PCMResampler(inputRate: 8_000, outputRate: 16_000)
        #expect(resampler.resample([0, 1]) == [0, 0.5])
    }

    @Test func emptyInputProducesNoOutput() {
        var resampler = PCMResampler(inputRate: 48_000, outputRate: 16_000)
        #expect(resampler.resample([]).isEmpty)
    }
}
