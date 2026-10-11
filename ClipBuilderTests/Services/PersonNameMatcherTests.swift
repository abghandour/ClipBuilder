import Testing
@testable import Clip_Builder

@Suite("Fuzzy person name matching")
struct PersonNameMatcherTests {
    @Test("exact names beat prefixes, which beat substrings")
    func exactPrefixSubstringOrder() {
        let exact = PersonRecord(id: 1, key: "person-1", name: "Ana", descriptor: "")
        let prefix = PersonRecord(id: 2, key: "person-2", name: "Anabel", descriptor: "")
        let substring = PersonRecord(id: 3, key: "person-3", name: "Mariana", descriptor: "")
        #expect(PersonNameMatcher.score(query: "ana", against: [exact.name]) == 1.0)
        #expect(PersonNameMatcher.score(query: "ana", against: [prefix.name]) == 0.9)
        #expect(PersonNameMatcher.score(query: "ana", against: [substring.name]) == 0.8)
        #expect(PersonNameMatcher.rank([substring, prefix, exact], query: "ana") == [exact, prefix, substring])
    }

    @Test("partial query tokens can match separate name tokens")
    func multiTokenQuery() {
        #expect(PersonNameMatcher.score(query: "car prat", against: ["Carlos Prates"]) == 0.7)
        #expect(PersonNameMatcher.score(query: "arlos rate", against: ["Carlos Prates"]) == 0.7)
        #expect(PersonNameMatcher.score(query: "carlso pratez", against: ["Carlos Prates"]) == 0.5)
        #expect(PersonNameMatcher.score(query: "carlso zzzzzzz", against: ["Carlos Prates"]) == nil)
    }

    @Test("a whole-name prefix ranks above a later token's prefix, which ranks above a substring")
    func tokenPrefix() {
        let surname = PersonRecord(id: 1, key: "person-1", name: "Maria José", descriptor: "")
        let firstName = PersonRecord(id: 2, key: "person-2", name: "José Silva", descriptor: "")
        let inside = PersonRecord(id: 3, key: "person-3", name: "Ana Josefina", descriptor: "")
        #expect(PersonNameMatcher.score(query: "jose", against: [surname.name]) == 0.85)
        #expect(PersonNameMatcher.score(query: "jose", against: [firstName.name]) == 0.9)
        #expect(PersonNameMatcher.score(query: "jose", against: [inside.name]) == 0.85)
        #expect(PersonNameMatcher.rank([surname, inside, firstName], query: "jose") == [firstName, surname, inside])
    }

    @Test("transpositions and substitutions match without confusing Carlos and Marcelo")
    func typos() {
        let carlos = PersonRecord(id: 1, key: "person-1", name: "Carlos Prates", descriptor: "")
        let marcelo = PersonRecord(id: 2, key: "person-2", name: "Marcelo", descriptor: "")
        #expect(PersonNameMatcher.score(query: "carlso", against: [carlos.name]) == 0.5)
        #expect(PersonNameMatcher.score(query: "pratez", against: [carlos.name]) == 0.5)
        #expect(PersonNameMatcher.rank([marcelo, carlos], query: "carlso") == [carlos])
        #expect(PersonNameMatcher.rank([marcelo, carlos], query: "pratez") == [carlos])
        #expect(PersonNameMatcher.score(query: "carlos", against: [marcelo.name]) == nil)
    }

    @Test("a missing letter matches Guernuiel")
    func guernuelTypo() {
        #expect(PersonNameMatcher.score(query: "guernuel", against: ["Guernuiel"]) == 0.5)
    }

    @Test("typo tolerance also applies to a name token's prefix")
    func typoPrefixAndThreshold() {
        #expect(PersonNameMatcher.score(query: "cral", against: ["Carlos"]) == 0.5)
        #expect(PersonNameMatcher.score(query: "xbcye", against: ["Abcde"]) == nil)
        #expect(PersonNameMatcher.score(query: "xbcdyf", against: ["Abcdef"]) == 0.5)
    }

    @Test("case, diacritics, and surrounding whitespace are folded")
    func foldedNames() {
        let jose = PersonRecord(id: 1, key: "person-1", name: "José", descriptor: "")
        #expect(PersonNameMatcher.score(query: " JOSÉ \n", against: [" jose \t"]) == 1.0)
        #expect(PersonNameMatcher.rank([jose], query: "jose") == [jose])
    }

    @Test("empty queries preserve input and have no score")
    func emptyQuery() {
        let people = [
            PersonRecord(id: 2, key: "person-2", name: "Zoe", descriptor: ""),
            PersonRecord(id: 1, key: "person-1", name: "Ana", descriptor: "")
        ]
        #expect(PersonNameMatcher.rank(people, query: "") == people)
        #expect(PersonNameMatcher.rank(people, query: " \n\t ") == people)
        #expect(PersonNameMatcher.score(query: "", against: ["Ana"]) == nil)
        #expect(PersonNameMatcher.score(query: " \n\t ", against: ["Ana"]) == nil)
    }

    @Test("unmatched names return no people and descriptors never match")
    func noMatch() {
        let person = PersonRecord(id: 1, key: "person-1", name: "Carlos Prates", descriptor: "José")
        #expect(PersonNameMatcher.rank([person], query: "jose").isEmpty)
        #expect(PersonNameMatcher.rank([person], query: "zzzzzz").isEmpty)
        #expect(PersonNameMatcher.rank([], query: "carlos").isEmpty)
        #expect(PersonNameMatcher.score(query: "carlos", against: []) == nil)
    }

    @Test("equal scores preserve caller order within each score group")
    func rankingStability() {
        let firstPrefix = PersonRecord(id: 4, key: "person-4", name: "Anabel", descriptor: "")
        let secondPrefix = PersonRecord(id: 2, key: "person-2", name: "Anastasia", descriptor: "")
        let firstSubstring = PersonRecord(id: 3, key: "person-3", name: "Mariana", descriptor: "")
        let secondSubstring = PersonRecord(id: 1, key: "person-1", name: "Diana", descriptor: "")
        let people = [firstSubstring, firstPrefix, secondSubstring, secondPrefix]
        #expect(PersonNameMatcher.rank(people, query: "ana")
                == [firstPrefix, secondPrefix, firstSubstring, secondSubstring])
    }

    @Test("the best alias wins and displayed fallback names remain searchable")
    func bestNameAndFallback() {
        let person = PersonRecord(id: 1, key: "josé-silva", name: "Joe", descriptor: "")
        let unnamed = PersonRecord(id: 2, key: "person-2", name: "", descriptor: "")
        #expect(PersonNameMatcher.score(query: "ana", against: ["Mariana", "Anabel", "Ana"]) == 1.0)
        #expect(PersonNameMatcher.rank([person], query: "silva") == [person])
        #expect(PersonNameMatcher.rank([unnamed], query: "unnamed") == [unnamed])
    }

    @Test("subsequences require at least sixty percent of query characters in one token")
    func subsequenceConcentration() {
        #expect(PersonNameMatcher.score(query: "abcde", against: ["axbxcxdxe"]) == 0.3)
        #expect(PersonNameMatcher.score(query: "abcde", against: ["axbxc dye"]) == 0.3)
        #expect(PersonNameMatcher.score(query: "acdf", against: ["ab cd ef"]) == nil)
        #expect(PersonNameMatcher.score(query: "abcde", against: ["exdxcxbxa"]) == nil)
        #expect(PersonNameMatcher.score(query: "abcdef", against: ["abc axbxcxdxexf"]) == 0.3)
    }
}
