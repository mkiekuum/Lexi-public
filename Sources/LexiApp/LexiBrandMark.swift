import SwiftUI

/// Two folded pages share one spine, forming the compact Lexi mark.
struct LexiBrandMark: Shape {
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let x = rect.midX - size / 2, y = rect.midY - size / 2
        func p(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: x + size * a, y: y + size * b)
        }
        var path = Path()
        path.move(to: p(0.17, 0.24))
        path.addQuadCurve(to: p(0.50, 0.34), control: p(0.34, 0.19))
        path.addQuadCurve(to: p(0.83, 0.24), control: p(0.66, 0.19))
        path.addLine(to: p(0.83, 0.69))
        path.addQuadCurve(to: p(0.50, 0.79), control: p(0.66, 0.64))
        path.addQuadCurve(to: p(0.17, 0.69), control: p(0.34, 0.64))
        path.closeSubpath()
        path.move(to: p(0.50, 0.34))
        path.addLine(to: p(0.50, 0.79))
        return path
    }
}
