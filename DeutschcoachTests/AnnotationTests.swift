import Foundation
import Testing
@testable import Deutschcoach

struct AnnotationDecodingTests {
    @Test func decodesFourAndFiveItemRows() throws {
        let json = #"{"words":[["Ich","ich","PRON","Nom"],["Kindern","Kind","NOUN","Dat","Neut|Plur"]],"spans":[{"fn":"Subj","tokens":[0]}]}"#
        let annotation = try JSONDecoder().decode(SentenceAnnotation.self, from: Data(json.utf8))
        #expect(annotation.words[0] == AnnotationToken(form: "Ich", lemma: "ich", pos: "PRON", feature: "Nom"))
        #expect(annotation.words[1].gender == "Neut|Plur")
        #expect(annotation.spans == [AnnotationSpan(fn: "Subj", tokens: [0])])
    }

    @Test(arguments: [#"[["a","b","c"]]"#, #"[["a","b","c","d","e","f"]]"#])
    func rejectsWrongItemCount(words: String) {
        let json = #"{"words":\#(words),"spans":[]}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SentenceAnnotation.self, from: Data(json.utf8))
        }
    }

    @Test func roundTripsThroughJSON() throws {
        let examples = try AnnotationExample.loadBundled()
        for example in examples {
            let data = try JSONEncoder().encode(example.annotation)
            #expect(try JSONDecoder().decode(SentenceAnnotation.self, from: data) == example.annotation)
        }
    }

    @Test func bundledExamplesLoad() throws {
        let examples = try AnnotationExample.loadBundled()
        #expect(examples.count == 7)
        for example in examples {
            // Forms joined back must reproduce the sentence (ignoring spaces), as in §4.3 rule 2.
            let joined = example.words.map(\.form).joined()
            #expect(joined == example.de.replacingOccurrences(of: " ", with: ""), "\(example.title)")
        }
    }
}

struct LabelCatalogTests {
    let zh = LabelCatalog(language: "zh")
    let en = LabelCatalog(language: "en")

    private func token(_ pos: String, _ feature: String, _ gender: String? = nil) -> AnnotationToken {
        AnnotationToken(form: "x", lemma: "x", pos: pos, feature: feature, gender: gender)
    }

    @Test func chineseLabelsMatchReference() {
        #expect(zh.partOfSpeech(token("NOUN", "Dat", "Neut|Plur")) == "中性名词复数")
        #expect(zh.partOfSpeech(token("NOUN", "Acc", "Masc")) == "阳性名词")
        #expect(zh.partOfSpeech(token("NOUN", "Nom", "Plur")) == "名词复数")
        #expect(zh.partOfSpeech(token("DET", "Dat")) == "冠词")
        #expect(zh.feature(token("DET", "Dat")) == "与格")
        #expect(zh.feature(token("ADP", "Acc")) == "+宾格")
        #expect(zh.feature(token("AUX", "Part2")) == "过去分词")
        #expect(zh.constituentName("ObjPrep") == "介词宾语")
        #expect(zh.clauseName(.sub) == "从句")
    }

    @Test func englishLabels() {
        #expect(en.partOfSpeech(token("NOUN", "Dat", "Neut|Plur")) == "neuter noun, plural")
        #expect(en.feature(token("ADP", "Dat")) == "+dative")
        #expect(en.constituentName("Subj") == "subject")
    }

    @Test func punctuationHasNoSmallText() {
        #expect(zh.partOfSpeech(token("PUNCT", "")) == nil)
        #expect(zh.feature(token("PUNCT", "")) == nil)
    }

    @Test func unknownCodesFallBackToRawCode() {
        #expect(zh.partOfSpeech(token("X", "")) == "X")
        #expect(zh.feature(token("VERB", "Imp")) == "Imp")
        #expect(zh.constituentName("Vocative") == "Vocative")
        #expect(zh.partOfSpeech(token("NOUN", "Nom", "Dual")) == "名词")
    }

    @Test func everyLabelHasBothLanguages() {
        let keys = PartOfSpeech.allCases.map { "pos." + $0.rawValue }
            + GrammaticalCase.allCases.map { "case." + $0.rawValue }
            + VerbForm.allCases.map { "verbForm." + $0.rawValue }
            + NounGender.allCases.map { "noun." + $0.rawValue.replacingOccurrences(of: "|", with: ".") }
            + Constituent.allCases.map { "fn." + $0.rawValue }
            + ClauseKind.allCases.map { "clause." + $0.rawValue }
        for key in keys {
            #expect(zh.text(key, fallback: "<missing>") != "<missing>", "zh \(key)")
            #expect(en.text(key, fallback: "<missing>") != "<missing>", "en \(key)")
        }
    }
}

struct AnnotationLayoutTests {
    private func example(_ prefix: String) throws -> AnnotationExample {
        try #require(try AnnotationExample.loadBundled().first { $0.title.hasPrefix(prefix) })
    }

    @Test func runs() {
        #expect(AnnotationLayout.runs(of: [1, 2, 5]) == [[1, 2], [5]])
        #expect(AnnotationLayout.runs(of: []) == [])
    }

    @Test func flatSentenceHasOneLevel() throws {
        let layout = AnnotationLayout(try example("A1").annotation)
        #expect(layout.levelCount == 1)
        #expect(layout.bars[0].map { $0?.fn } == ["Subj", "Pred", "ObjDat", "ObjDat", "ObjAcc", "ObjAcc", nil])
        #expect(layout.bars[0][2]?.isRunStart == true)
        #expect(layout.bars[0][3]?.isRunEnd == true)
        #expect(layout.clauses.allSatisfy { $0 == nil })
    }

    @Test func discontinuousPredicateNamesOnlyFirstRun() throws {
        let layout = AnnotationLayout(try example("A2 trennbares").annotation)
        let first = try #require(layout.bars[0][1])
        let second = try #require(layout.bars[0][5])
        #expect(first.fn == "Pred" && first.showsName && first.isRunStart && first.isRunEnd)
        #expect(second.fn == "Pred" && !second.showsName && second.isRunStart && second.isRunEnd)
        #expect(first.lineStyle == .double && first.color == .ink)
    }

    @Test func containedConstituentGoesToSecondLevel() throws {
        let layout = AnnotationLayout(try example("B1 Genitiv").annotation)
        #expect(layout.levelCount == 2)
        #expect(layout.bars[0][2]?.fn == "Subj")
        #expect(layout.bars[0][2]?.showsName == false)
        #expect(layout.bars[1][2]?.fn == "Attr")
        #expect(layout.bars[1][2]?.showsName == true)
        #expect(layout.bars[1][2]?.lineStyle == .thin)
        #expect(layout.bars[0][5]?.lineStyle == .dotted)  // PredC
    }

    @Test func clauseAsConstituentNestsInnerSpans() throws {
        let layout = AnnotationLayout(try example("B1 dass").annotation)
        #expect(layout.levelCount == 2)
        #expect(layout.bars[0].map { $0?.fn } == ["Subj", "Pred", nil, "ObjAcc", "ObjAcc", "ObjAcc", "ObjAcc", "ObjAcc", "ObjAcc", nil])
        #expect(layout.bars[1].map { $0?.fn } == [nil, nil, nil, nil, "Subj", "ObjPrep", "ObjPrep", "ObjPrep", "Pred", nil])
        #expect(layout.clauses[2] == nil)
        #expect(layout.clauses[3] == .init(kind: .sub, isStart: true, isEnd: false))
        #expect(layout.clauses[8] == .init(kind: .sub, isStart: false, isEnd: true))
    }

    @Test func subjectInterruptedByCommaHasTwoRuns() throws {
        let layout = AnnotationLayout(try example("B1 Relativ").annotation)
        #expect(layout.bars[0][0]?.showsName == true)
        #expect(layout.bars[0][1]?.isRunEnd == true)
        #expect(layout.bars[0][2] == nil)  // comma
        #expect(layout.bars[0][3]?.fn == "Subj")
        #expect(layout.bars[0][3]?.isRunStart == true)
        #expect(layout.bars[0][3]?.showsName == false)
        #expect(layout.bars[1][3]?.fn == "Subj")  // relative pronoun, inside the outer subject
        #expect(layout.clauses[3]?.kind == .rel)
    }

    @Test func unknownLabelsAreNeutral() {
        let annotation = SentenceAnnotation(
            words: [AnnotationToken(form: "Hallo", lemma: "hallo", pos: "INTJ", feature: "")],
            spans: [AnnotationSpan(fn: "Vocative", tokens: [0])]
        )
        let bar = AnnotationLayout(annotation).bars[0][0]
        #expect(bar?.constituent == nil)
        #expect(bar?.color == .neutral)
        #expect(bar?.lineStyle == .solid)
    }

    @Test func outOfRangeTokensAreIgnored() {
        let annotation = SentenceAnnotation(
            words: [AnnotationToken(form: "Ja", lemma: "ja", pos: "INTJ", feature: "")],
            spans: [AnnotationSpan(fn: "Subj", tokens: [0, 7]), AnnotationSpan(fn: "Sub", tokens: [-1, 3])]
        )
        let layout = AnnotationLayout(annotation)
        #expect(layout.bars[0][0]?.fn == "Subj")
        #expect(layout.clauses == [nil])
    }
}
