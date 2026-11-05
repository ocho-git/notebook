import Foundation

struct BookSpring {
    var value: Float
    var velocity: Float = 0
    var target: Float
    var response: Float
    var damping: Float

    init(_ value: Float, _ tuning: (response: Float, damping: Float)) {
        self.value = value
        target = value
        response = tuning.response
        damping = tuning.damping
    }

    mutating func step(_ dt: Float) {
        let k = pow(2 * .pi / response, 2), c = 4 * .pi * damping / response
        let steps = max(1, Int((dt / (1 / 240)).rounded(.up)))
        let h = dt / Float(steps)
        for _ in 0..<steps {
            velocity += (-k * (value - target) - c * velocity) * h
            value += velocity * h
        }
    }

    var settled: Bool { abs(value - target) < 0.0004 && abs(velocity) < 0.002 }
    mutating func tune(_ tuning: (response: Float, damping: Float)) { response = tuning.response; damping = tuning.damping }
    mutating func snap() { value = target; velocity = 0 }
}
