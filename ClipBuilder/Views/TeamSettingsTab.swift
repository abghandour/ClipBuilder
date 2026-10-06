import SwiftUI

struct TeamSettingsTab: View {
    @Environment(AppStore.self) private var store
    @State private var code = ""
    @State private var teamName = ""
    @State private var joinCode = ""
    @State private var inviteEmail = ""
    @State private var showingAttachment = false

    var body: some View {
        @Bindable var team = store.teamSync
        Form {
            Section("Account") {
                if team.signedIn {
                    LabeledContent("Signed in", value: team.email.isEmpty ? "Team member" : team.email)
                    Button("Sign Out") { Task { await team.signOut() } }
                        .disabled(team.busy)
                } else {
                    TextField("Email", text: $team.email)
                        .textContentType(.emailAddress)
                    Button("Send Code") { Task { await team.sendCode() } }
                        .disabled(team.busy || team.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TextField("Email code", text: $code)
                        .textContentType(.oneTimeCode)
                    Button("Verify Code") { Task { await team.verify(code: code) } }
                        .disabled(team.busy || code.isEmpty)
                }
                if team.busy { ProgressView().controlSize(.small).accessibilityLabel("Updating team account") }
                if let message = team.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if team.signedIn {
                if !team.attached {
                    Section("Create or join a team") {
                        TextField("Team name", text: $teamName)
                        Button("Create Team") { Task { await team.createTeam(name: teamName) } }
                            .disabled(team.busy || teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        TextField("Invite code", text: $joinCode)
                        Button("Join Team") { Task { await team.joinTeam(code: joinCode) } }
                            .disabled(team.busy || joinCode.isEmpty)
                    }
                }
                Section("This profile") {
                    if team.attached {
                        LabeledContent("Profile", value: store.activeProfile.profileName)
                        Text(team.status).foregroundStyle(.secondary)
                        Toggle("Pause sync", isOn: $team.paused)
                            .onChange(of: team.paused) { _, value in team.setPaused(value) }
                            .disabled(team.replacingProfile)
                        Button("Sync Now") { team.syncNow() }
                            .disabled(team.paused || team.syncing || team.replacingProfile)
                    } else if !team.teams.isEmpty {
                        Picker("Team", selection: $team.selectedTeamID) {
                            ForEach(team.teams) { item in Text(item.name).tag(Optional(item.id)) }
                        }
                        .onChange(of: team.selectedTeamID) { Task { await team.selectTeam() } }
                        Picker("Shared profile", selection: $team.selectedProfileID) {
                            Text("Create a new shared profile").tag(UUID?.none)
                            ForEach(team.remoteProfiles) { item in Text(item.name).tag(Optional(item.id)) }
                        }
                        Text("Choose an existing shared profile to merge matching people, assets and Instagram reports. Your local files stay on this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Attach This Profile…") {
                            Task { showingAttachment = await team.prepareAttachment() }
                        }
                        .disabled(team.busy || team.attaching || team.replacingProfile || team.selectedTeamID == nil)
                    } else {
                        Text("Create a team or redeem an invite to share this profile’s brand knowledge.")
                            .foregroundStyle(.secondary)
                    }
                }
                if team.selectedTeamID != nil {
                    Section("Members") {
                        ForEach(team.members) { member in
                            LabeledContent(member.email, value: member.role.capitalized)
                        }
                        Button("Refresh Members") { Task { await team.selectTeam() } }
                            .disabled(team.busy)
                        TextField("Invite by email", text: $inviteEmail)
                            .textContentType(.emailAddress)
                        Button("Create Invite Code") { Task { await team.createInvite(email: inviteEmail) } }
                            .disabled(team.busy || inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let inviteCode = team.inviteCode {
                            Text("Share this code with the invited member. It expires in seven days.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(inviteCode).textSelection(.enabled)
                            Button("Copy Invite Code") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(inviteCode, forType: .string)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            if team.store == nil { team.store = store }
            await team.restore()
        }
        .sheet(isPresented: $showingAttachment) {
            TeamAttachmentSheet(counts: team.counts, profileName: store.activeProfile.profileName) {
                showingAttachment = false
                team.attach()
            }
        }
    }
}

private struct TeamAttachmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let counts: [String: Int]
    let profileName: String
    let attach: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share \(profileName) with your team?").font(.headline)
            Text("Transcripts, people names and Instagram audience data leave this Mac when shared. Phase 1 shares brand knowledge and reports; footage and media files remain on your Mac and Google Drive.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(SyncTable.all, id: \.name) { table in
                        LabeledContent(table.displayName, value: (counts[table.name] ?? 0).formatted())
                    }
                }
            }
            Text("Matching records merge into the shared profile. Initial sync runs in the status bar, where you can stop it.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Attach and Sync", action: attach).keyboardShortcut(.defaultAction)
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 500, height: 570)
    }
}

extension SyncTable {
    var displayName: String {
        switch name {
        case "profile_documents": "Brand profile"
        case "wizard_lessons": "AI lessons"
        case "taste_studies": "Taste studies"
        case "people": "People"
        case "text_overlay_presets": "Text overlay presets"
        case "library_asset_metadata": "Asset descriptions"
        case "ig_accounts": "Instagram accounts"
        case "ig_media": "Instagram media"
        case "ig_report_media": "Report media"
        case "ig_templates": "Reel templates"
        case "ig_account_snapshots": "Account snapshots"
        case "ig_media_insight_snapshots": "Media insights"
        case "ig_account_insights": "Account insights"
        case "ig_audience_demographics": "Audience demographics"
        case "ig_comments": "Comments"
        case "ig_commenter_rankings_import": "Commenter rankings"
        case "ig_commenter_activity_import": "Commenter activity"
        case "ig_comment_heatmap_import": "Comment heatmaps"
        case "ig_reel_analysis_import": "Reel analyses"
        case "ig_ignored_accounts": "Ignored accounts"
        case "ig_report_sync_state": "Report history"
        case "reel_traits": "Reel traits"
        case "reel_outcomes": "Reel outcomes"
        default: name
        }
    }
}
