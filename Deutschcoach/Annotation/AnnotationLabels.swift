import Foundation

// The label set (DESIGN.md §5). Codes are what the LLM emits; display names live in the
// `Labels` string catalog. Values outside the set are kept and shown in neutral gray (§4.3).

nonisolated enum PartOfSpeech: String, CaseIterable, Sendable {
    case noun = "NOUN", propn = "PROPN", pron = "PRON", det = "DET", adj = "ADJ"
    case verb = "VERB", aux = "AUX", adv = "ADV", adp = "ADP", cconj = "CCONJ"
    case sconj = "SCONJ", num = "NUM", part = "PART", intj = "INTJ", punct = "PUNCT"
}

nonisolated enum GrammaticalCase: String, CaseIterable, Sendable {
    case nom = "Nom", acc = "Acc", dat = "Dat", gen = "Gen"
}

nonisolated enum VerbForm: String, CaseIterable, Sendable {
    case fin = "Fin", inf = "Inf", part2 = "Part2", part1 = "Part1"
}

/// Noun gender and number (item 5 of a NOUN row).
nonisolated enum NounGender: String, CaseIterable, Sendable {
    case masc = "Masc", fem = "Fem", neut = "Neut"
    case mascPlur = "Masc|Plur", femPlur = "Fem|Plur", neutPlur = "Neut|Plur"
    case plur = "Plur"
}

/// Colors of the label set; each has a light and a dark value in the asset catalog (§5.3, §5.5).
nonisolated enum LabelColor: Sendable, Equatable {
    case nom, acc, dat, gen, ink, slate
    /// Unknown labels.
    case neutral

    init(_ grammaticalCase: GrammaticalCase) {
        switch grammaticalCase {
        case .nom: self = .nom
        case .acc: self = .acc
        case .dat: self = .dat
        case .gen: self = .gen
        }
    }
}

nonisolated enum LineStyle: Sendable, Equatable {
    case solid, double, dotted, dashed, thin
}

/// Sentence constituents drawn as underlines (§5.5).
nonisolated enum Constituent: String, CaseIterable, Sendable {
    case subj = "Subj", pred = "Pred", objAcc = "ObjAcc", objDat = "ObjDat", objGen = "ObjGen"
    case predC = "PredC", objPrep = "ObjPrep"
    case advT = "AdvT", advL = "AdvL", advM = "AdvM", advC = "AdvC"
    case attr = "Attr"

    var lineStyle: LineStyle {
        switch self {
        case .subj, .objAcc, .objDat, .objGen, .objPrep: .solid
        case .pred: .double
        case .predC: .dotted
        case .advT, .advL, .advM, .advC: .dashed
        case .attr: .thin
        }
    }

    var color: LabelColor {
        switch self {
        case .subj, .predC: .nom
        case .objAcc: .acc
        case .objDat: .dat
        case .objGen: .gen
        case .pred: .ink
        case .objPrep, .advT, .advL, .advM, .advC, .attr: .slate
        }
    }
}

/// Clauses drawn as a light background (§5.5).
nonisolated enum ClauseKind: String, CaseIterable, Sendable {
    case sub = "Sub", rel = "Rel", inf = "Inf"
}
