import Testing
@testable import Deutschcoach

struct WordAlignerNormalizationTests {
    @Test(arguments: [
        ("Apfel.", "apfel"),
        ("Kindern,", "kindern"),
        ("ICH", "ich"),
        ("Straße", "strasse"),
        ("geht's", "gehts"),
        ("E-Mail", "email"),
        ("Äpfel", "äpfel"),
        ("3", "drei"),
        ("23", "dreiundzwanzig"),
        ("?", ""),
    ])
    func normalize(input: String, expected: String) {
        #expect(WordAligner.normalize(input) == expected)
    }

    @Test func spelledNumberMatchesDigits() {
        #expect(WordAligner.normalize("drei") == WordAligner.normalize("3"))
        #expect(WordAligner.normalize("Dreiundzwanzig") == WordAligner.normalize("23"))
    }
}

struct WordAlignerAlignmentTests {
    let sentence = "Ich gebe den Kindern einen Apfel."

    @Test func exactMatchIgnoresCaseAndPunctuation() {
        let result = WordAligner.align(sentence: sentence, heard: "ich gebe den kindern einen apfel")
        #expect(result.allMatched)
        #expect(result.words.count == 6)
        #expect(result.extra.isEmpty)
    }

    @Test func substitution() {
        let result = WordAligner.align(sentence: sentence, heard: "Ich gebe den Kinder einen Apfel")
        #expect(result.words[3].status == .substituted(heard: "Kinder"))
        #expect(result.matchedCount == 5)
    }

    @Test func missingWord() {
        let result = WordAligner.align(sentence: sentence, heard: "Ich gebe Kindern einen Apfel")
        #expect(result.words[2] == .init(index: 2, text: "den", status: .missing))
        #expect(result.matchedCount == 5)
        #expect(result.extra.isEmpty)
    }

    @Test func extraWord() {
        let result = WordAligner.align(sentence: sentence, heard: "Ich gebe den Kindern heute einen Apfel")
        #expect(result.allMatched)
        #expect(result.extra == ["heute"])
    }

    @Test func nothingHeard() {
        let result = WordAligner.align(sentence: sentence, heard: "")
        #expect(result.words.allSatisfy { $0.status == .missing })
    }

    @Test func eszettAndNumbers() {
        let result = WordAligner.align(sentence: "Die Straße hat 3 Häuser.", heard: "die Strasse hat drei Häuser")
        #expect(result.allMatched)
    }

    @Test func indicesSkipPunctuationTokens() {
        // Token layout as produced by the LLM: punctuation is a separate token.
        let tokens = ["Ich", "gebe", "den", "Kindern", "einen", "Apfel", "."]
        let result = WordAligner.align(target: tokens, heard: "Ich gebe den Kindern einen Birne")
        #expect(result.words.map(\.index) == [0, 1, 2, 3, 4, 5])
        #expect(result.words[5].status == .substituted(heard: "Birne"))
    }
}
