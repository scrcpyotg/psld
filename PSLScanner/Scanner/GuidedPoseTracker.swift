import Foundation

enum GuidedPoseStage: Int, CaseIterable {
    case centerStart
    case firstSide
    case centerMiddle
    case oppositeSide
    case centerFinal
    case complete
}

struct GuidedPoseDecision {
    let acceptFrame: Bool
    let status: String
    let progress: Double
    let completed: Bool
}

struct GuidedPoseTracker {
    private(set) var stage: GuidedPoseStage = .centerStart
    private(set) var acceptedInStage = 0
    private(set) var totalAccepted = 0
    private(set) var firstSideSign: Float?

    private let centerStartTarget = 18
    private let firstSideTarget = 16
    private let centerMiddleTarget = 12
    private let oppositeSideTarget = 16
    private let centerFinalTarget = 18

    var totalTarget: Int {
        centerStartTarget +
        firstSideTarget +
        centerMiddleTarget +
        oppositeSideTarget +
        centerFinalTarget
    }

    mutating func reset() {
        stage = .centerStart
        acceptedInStage = 0
        totalAccepted = 0
        firstSideSign = nil
    }

    mutating func evaluate(yaw: Float) -> GuidedPoseDecision {
        guard stage != .complete else {
            return GuidedPoseDecision(
                acceptFrame: false,
                status: "Данных достаточно. Завершаем сканирование…",
                progress: 1,
                completed: true
            )
        }

        let acceptance = accepts(yaw: yaw)
        if acceptance {
            acceptedInStage += 1
            totalAccepted += 1

            if acceptedInStage >= target(for: stage) {
                advanceStage()
            }
        }

        return GuidedPoseDecision(
            acceptFrame: acceptance,
            status: statusText,
            progress: min(0.99, Double(totalAccepted) / Double(max(totalTarget, 1))),
            completed: stage == .complete
        )
    }

    private mutating func accepts(yaw: Float) -> Bool {
        switch stage {
        case .centerStart, .centerMiddle, .centerFinal:
            return abs(yaw) <= 0.105

        case .firstSide:
            if firstSideSign == nil,
               abs(yaw) >= 0.15,
               abs(yaw) <= 0.42 {
                firstSideSign = yaw >= 0 ? 1 : -1
            }

            guard let sign = firstSideSign else { return false }
            return yaw * sign >= 0.14 && yaw * sign <= 0.42

        case .oppositeSide:
            guard let sign = firstSideSign else { return false }
            return yaw * sign <= -0.14 && yaw * sign >= -0.42

        case .complete:
            return false
        }
    }

    private func target(for stage: GuidedPoseStage) -> Int {
        switch stage {
        case .centerStart: return centerStartTarget
        case .firstSide: return firstSideTarget
        case .centerMiddle: return centerMiddleTarget
        case .oppositeSide: return oppositeSideTarget
        case .centerFinal: return centerFinalTarget
        case .complete: return 0
        }
    }

    private mutating func advanceStage() {
        acceptedInStage = 0

        switch stage {
        case .centerStart:
            stage = .firstSide
        case .firstSide:
            stage = .centerMiddle
        case .centerMiddle:
            stage = .oppositeSide
        case .oppositeSide:
            stage = .centerFinal
        case .centerFinal:
            stage = .complete
        case .complete:
            break
        }
    }

    var statusText: String {
        switch stage {
        case .centerStart:
            return "Этап 1/5: смотри прямо и держи лицо расслабленным."
        case .firstSide:
            if firstSideSign == nil {
                return "Этап 2/5: поверни голову в любую сторону на 15–25°."
            }
            return "Этап 2/5: удерживай первый боковой ракурс."
        case .centerMiddle:
            return "Этап 3/5: вернись точно в центр."
        case .oppositeSide:
            return "Этап 4/5: поверни голову в противоположную сторону."
        case .centerFinal:
            return "Этап 5/5: снова смотри прямо."
        case .complete:
            return "Данных достаточно. Завершаем сканирование…"
        }
    }
}
