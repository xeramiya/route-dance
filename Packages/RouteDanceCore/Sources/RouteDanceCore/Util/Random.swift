import Foundation

/// 再現性のある乱数（SplitMix64）。評価やテストで結果を固定するために使う。
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 標準正規分布（Box-Muller）。
    public mutating func gaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &self)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// 指数移動平均。時定数 tau（秒）で、不等間隔のサンプルにも対応する。
public struct ExponentialSmoother: Sendable {
    public var tau: Double
    public private(set) var value: Double?
    private var lastTime: Double?

    public init(tau: Double) {
        self.tau = tau
    }

    @discardableResult
    public mutating func update(_ x: Double, at t: Double) -> Double {
        guard let v = value, let lt = lastTime else {
            value = x
            lastTime = t
            return x
        }
        let dt = max(0, t - lt)
        let a = tau > 0 ? 1 - exp(-dt / tau) : 1
        let nv = v + a * (x - v)
        value = nv
        lastTime = t
        return nv
    }

    public mutating func reset() {
        value = nil
        lastTime = nil
    }
}
