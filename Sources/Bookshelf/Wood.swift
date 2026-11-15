import AppKit

enum Wood {
    /// Warm oak wall panelling with vertical planks, grain and a soft vignette.
    static func wall(size: CGSize, scale: CGFloat) -> CGImage? {
        renderImage(size: size, scale: scale) { rect in
            let width = rect.width
            let height = rect.height

            let base = NSGradient(colors: [
                NSColor(calibratedRed: 0.66, green: 0.45, blue: 0.27, alpha: 1),
                NSColor(calibratedRed: 0.43, green: 0.27, blue: 0.15, alpha: 1)
            ])
            base?.draw(in: rect, angle: -90)

            let plankWidth: CGFloat = 212
            var plankIndex = 0
            var x: CGFloat = 0
            var random = SeededRandom(seed: 42)

            while x < width {
                let plankRect = CGRect(x: x, y: 0, width: plankWidth, height: height)
                let variation = (random.next() - 0.5) * 0.09
                let plankColor = NSColor(
                    calibratedRed: 0.62 + variation,
                    green: 0.42 + variation * 0.8,
                    blue: 0.25 + variation * 0.5,
                    alpha: 0.55
                )
                plankColor.setFill()
                plankRect.fill()

                // Vertical grain inside the plank.
                var grainX = x + random.range(4, 26)
                while grainX < x + plankWidth - 4 {
                    let path = NSBezierPath()
                    let phase = random.range(0, .pi * 2)
                    let amplitude = random.range(0.6, 3.4)
                    let frequency = random.range(0.008, 0.026)
                    path.move(to: NSPoint(x: grainX, y: 0))
                    var y: CGFloat = 0
                    while y < height {
                        let offset = sin(y * frequency + phase) * amplitude
                        path.line(to: NSPoint(x: grainX + offset, y: y))
                        y += 22
                    }
                    let dark = random.next() > 0.45
                    let alpha = random.range(0.025, 0.075)
                    (dark ? NSColor.black.withAlphaComponent(alpha)
                          : NSColor.white.withAlphaComponent(alpha * 0.8)).setStroke()
                    path.lineWidth = random.range(0.5, 1.7)
                    path.stroke()

                    grainX += random.range(5, 15)
                }

                // Plank seams: dark groove with a light lip.
                NSColor(calibratedWhite: 0.12, alpha: 0.55).setFill()
                CGRect(x: x + plankWidth - 2, y: 0, width: 2, height: height).fill()
                NSColor(calibratedWhite: 0.95, alpha: 0.07).setFill()
                CGRect(x: x + plankWidth, y: 0, width: 1, height: height).fill()

                x += plankWidth
                plankIndex += 1
            }

            // Horizontal grain drift and subtle tone bands.
            var randomBands = SeededRandom(seed: 7)
            for _ in 0..<26 {
                let y = randomBands.range(0, Double(height))
                let bandHeight = randomBands.range(20, 90)
                let alpha = randomBands.range(0.008, 0.03)
                (randomBands.next() > 0.5 ? NSColor.black : NSColor.white)
                    .withAlphaComponent(alpha).setFill()
                CGRect(x: 0, y: y, width: width, height: bandHeight).fill()
            }

            // Fine speckle for a photographic feel.
            var speckle = SeededRandom(seed: 99)
            for _ in 0..<2600 {
                let px = speckle.range(0, Double(width))
                let py = speckle.range(0, Double(height))
                let alpha = speckle.range(0.01, 0.05)
                (speckle.next() > 0.5 ? NSColor.black : NSColor.white)
                    .withAlphaComponent(alpha).setFill()
                CGRect(x: px, y: py, width: 1.2, height: 1.2).fill()
            }

            // Top light falling on the wall.
            NSGradient(colors: [
                NSColor.white.withAlphaComponent(0.10),
                NSColor.white.withAlphaComponent(0.0),
                NSColor.black.withAlphaComponent(0.18)
            ])?.draw(in: rect, angle: -90)

            // Vignette.
            NSGradient(colors: [
                NSColor.black.withAlphaComponent(0),
                NSColor.black.withAlphaComponent(0.38)
            ])?.draw(in: rect, relativeCenterPosition: .zero)
        }
    }

    static func shelfBoard(size: CGSize, scale: CGFloat) -> CGImage? {
        renderImage(size: size, scale: scale) { rect in
            NSGradient(colors: [
                NSColor(calibratedRed: 0.72, green: 0.50, blue: 0.30, alpha: 1),
                NSColor(calibratedRed: 0.50, green: 0.33, blue: 0.18, alpha: 1)
            ])?.draw(in: rect, angle: -90)

            var random = SeededRandom(seed: 11)
            for _ in 0..<40 {
                let y = random.range(0, Double(rect.height))
                let alpha = random.range(0.02, 0.08)
                (random.next() > 0.5 ? NSColor.black : NSColor.white)
                    .withAlphaComponent(alpha).setFill()
                CGRect(x: 0, y: y, width: rect.width, height: random.range(0.6, 2.0)).fill()
            }
        }
    }
}
