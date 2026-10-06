import Foundation

extension SupabaseClient {
    func createTeam(name: String) async throws -> UUID {
        try await uuidRPC("create_team", body: ["name": .string(name)])
    }

    func createInvite(teamID: UUID, email: String) async throws -> UUID {
        try await uuidRPC("create_invite", body: ["team_id": .string(teamID.uuidString), "email": .string(email)])
    }

    func redeemInvite(code: UUID) async throws -> UUID {
        try await uuidRPC("redeem_invite", body: ["code": .string(code.uuidString)])
    }

    private func uuidRPC(_ name: String, body: SyncMapping.WireRow) async throws -> UUID {
        let data = try await request(path: "rest/v1/rpc/\(name)", method: "POST", body: body)
        return try JSONDecoder().decode(UUID.self, from: data)
    }

    func teams() async throws -> [TeamSyncTeam] {
        let data = try await request(path: "rest/v1/teams", query: [.init(name: "select", value: "id,name")])
        return try JSONDecoder().decode([TeamSyncTeam].self, from: data)
    }

    func profiles(teamID: UUID) async throws -> [SyncMapping.WireRow] {
        let data = try await request(path: "rest/v1/profile_documents", query: [
            .init(name: "team_id", value: "eq.\(teamID.uuidString)"), .init(name: "deleted_at", value: "is.null"),
            .init(name: "select", value: "profile_id,document_json")
        ])
        return try JSONDecoder().decode([SyncMapping.WireRow].self, from: data)
    }

    func members(teamID: UUID) async throws -> [TeamSyncMember] {
        let data = try await request(path: "rest/v1/rpc/team_members_with_email", method: "POST",
                                     body: ["team_id": .string(teamID.uuidString)])
        return try JSONDecoder().decode([TeamSyncMember].self, from: data)
    }
}

nonisolated struct TeamSyncTeam: Decodable, Sendable, Identifiable {
    let id: UUID
    let name: String
}

nonisolated struct TeamSyncMember: Decodable, Sendable, Identifiable {
    let user_id: UUID
    let email: String
    let role: String
    var id: UUID { user_id }
}

nonisolated struct TeamSyncProfile: Sendable, Identifiable {
    let id: UUID
    let name: String
}
