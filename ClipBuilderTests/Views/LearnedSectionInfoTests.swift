import Testing
@testable import Clip_Builder

struct LearnedSectionInfoTests {
    @Test func everySectionIsExplained() {
        for kind in LearnedPreferences.Kind.allCases {
            let entry = LearnedSectionInfo.entry(kind)
            #expect(!entry.title.isEmpty)
            #expect(!entry.purpose.isEmpty, "\(kind) needs a purpose")
            #expect(!entry.usedBy.isEmpty, "\(kind) needs at least one consumer")
            #expect(entry.usedBy.allSatisfy { !$0.qualifier.isEmpty }, "\(kind) consumers need qualifiers")
            #expect(Set(entry.usedBy.map(\.id)).count == entry.usedBy.count, "\(kind) lists a consumer twice")
            #expect(entry.editLocation != nil || !entry.readOnlyReason.isEmpty,
                    "\(kind) needs an edit location or a read-only reason")
        }
    }
    @Test func lessonsAreEditedOnThePage() {
        #expect(LearnedSectionInfo.entry(.lessons).editLocation == .page)
        #expect(LearnedSectionInfo.entry(.benchmarks).editLocation == nil)
        #expect(LearnedSectionInfo.entry(.style).editLocations.count == 3)
        #expect(LearnedSectionInfo.entry(.vocabulary).editLocations.count == 2)
        #expect(!LearnedSectionInfo.entry(.vocabulary).emptyNote.isEmpty)
    }
    @Test func everyModelIsExplained() {
        for item in ReelModelItem.allCases {
            let entry = ReelModelInfo.entry(item)
            #expect(!entry.title.isEmpty)
            #expect(!entry.predicts.isEmpty)
            #expect(!entry.trainedFrom.isEmpty)
            #expect(!entry.whenEnabled.isEmpty)
        }
    }
    @Test func consumersHaveLabelsAndSymbols() {
        for consumer in LearnedSectionInfo.Consumer.allCases {
            #expect(!consumer.label.isEmpty)
            #expect(!consumer.symbol.isEmpty)
        }
    }
}

struct LearnedLessonsSummaryTests {
    @Test func activeCountExcludesDismissed() {
        let kept = WizardLesson(learnedID: "a", id: 1, text: "Keep", pinned: false, evidence: "")
        let dismissed = WizardLesson(learnedID: "b", id: 2, text: "Hide", pinned: false, evidence: "")
        let legacy = WizardLesson(id: 3, text: "Legacy", pinned: false, evidence: "")
        var profile = BrandProfile(name: "Test")
        profile.learnedSharing.dismissedLessons = ["b", LearnedPreferences.stableID("Legacy")]
        #expect(LearnedLessonsSummary.activeCount(lessons: [kept, dismissed, legacy], profile: profile) == 1)
    }
    @Test func fieldEditorsRoundTripRawProfileValues() {
        var profile = BrandProfile(name: "Test")
        profile.houseStyle = "Raw https://example.com"
        profile.tasteCategories = [.init(key: "fight", label: "Fight", rubric: "R", exemplarFrames: ["f.jpg"], studiedCount: 2)]
        profile.hashtags = ["mma"]
        #expect(LearnedFieldEdit.houseStyle.draft(from: profile).text == "Raw https://example.com")
        let category = LearnedFieldEdit.category(key: "fight")
        var draft = category.draft(from: profile)
        #expect(draft.label == "Fight" && draft.text == "R")
        draft.text = "Better"
        let edited = category.apply(draft, to: profile)
        #expect(edited.tasteCategories[0].rubric == "Better")
        #expect(edited.tasteCategories[0].exemplarFrames == ["f.jpg"])
        var tags = LearnedFieldEdit.hashtags.draft(from: profile)
        tags.list = ["mma", "ufc"]
        #expect(LearnedFieldEdit.hashtags.apply(tags, to: profile).hashtags == ["mma", "ufc"])
        #expect(LearnedFieldEdit.forItem(field: "hashtag", id: "x") == .hashtags)
        #expect(LearnedFieldEdit.forItem(field: "lesson", id: "x") == nil)
    }
    @Test func commitRefusesAProfileSwitch() {
        var profile = BrandProfile(name: "Test")
        profile.houseStyle = "Old"
        var draft = LearnedFieldEdit.houseStyle.draft(from: profile)
        draft.text = "New"
        #expect(LearnedFieldEdit.houseStyle.commit(draft, to: profile, openedOn: "Other") == nil)
        #expect(LearnedFieldEdit.houseStyle.commit(draft, to: profile, openedOn: "Test")?.houseStyle == "New")
    }
}
