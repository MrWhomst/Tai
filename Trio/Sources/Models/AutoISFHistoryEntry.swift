import Foundation

struct AutoISFHistoryEntry: JSON, Equatable, Hashable {
    let smb: Decimal?
    let insulin_req: Decimal?
    let sensitivity_ratio: Decimal?
    let tbr: Decimal?
    var timestamp: Date?
    let bg: Decimal?
    let isf: Decimal?
    let smb_ratio: Decimal?
    let dura_ratio: Decimal?
    let bg_ratio: Decimal?
    let pp_ratio: Decimal?
    let acce_ratio: Decimal?
    let autoISF_ratio: Decimal?
    let iob_TH: Decimal?
    let iob: Decimal?
    let parabola_fit_minutes: Decimal?
    let parabola_fit_last_delta: Decimal?
    let parabola_fit_next_delta: Decimal?
    let parabola_fit_correlation: Decimal?
    let parabola_fit_a0: Decimal?
    let parabola_fit_a1: Decimal?
    let parabola_fit_a2: Decimal?
    let dura_min: Decimal?
    let dura_avg: Decimal?
    let bg_acce: Decimal?

    static func == (lhs: AutoISFHistoryEntry, rhs: AutoISFHistoryEntry) -> Bool {
        lhs.timestamp == rhs.timestamp &&
            lhs.bg == rhs.bg &&
            lhs.isf == rhs.isf
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(timestamp)
        hasher.combine(bg)
        hasher.combine(isf)
    }
}

extension AutoISFHistoryEntry {
    private enum CodingKeys: String, CodingKey {
        case smb
        case insulin_req
        case sensitivity_ratio
        case tbr
        case timestamp
        case bg
        case isf
        case smb_ratio
        case dura_ratio
        case bg_ratio
        case pp_ratio
        case acce_ratio
        case autoISF_ratio
        case iob_TH
        case iob
        case parabola_fit_minutes
        case parabola_fit_last_delta
        case parabola_fit_next_delta
        case parabola_fit_correlation
        case parabola_fit_a0
        case parabola_fit_a1
        case parabola_fit_a2
        case dura_min
        case dura_avg
        case bg_acce
    }
}
