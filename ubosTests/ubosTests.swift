//
//  ubosTests.swift
//  ubosTests
//
//  Created by Noel Rohi on 6/5/26.
//

import Foundation
import Testing
@testable import ubos

@MainActor
struct ubosTests {

    @Test func openCodeGoSnapshotUsesRealLocalUsage() async throws {
        UserDefaults.standard.set(true, forKey: AppPreferences.openCodeGoEnabledKey)

        let snapshot = OpenCodeGoUsageProvider.loadSnapshot()

        #expect(snapshot.id == OpenCodeGoUsageProvider.id)
        #expect(snapshot.status == "live", "OpenCode Go status: \(snapshot.status). Message: \(snapshot.message ?? "none")")
        expectMetricLabels(snapshot, include: ["Session", "Weekly", "Monthly"])
        let hasOnlyProgressLines = !snapshot.lines.contains { !$0.showsProgress }
        #expect(hasOnlyProgressLines)
    }

    @Test func cursorSnapshotUsesLiveProviderDataAndRequestFallback() async throws {
        UserDefaults.standard.set(true, forKey: AppPreferences.cursorEnabledKey)

        let snapshot = await CursorUsageProvider.loadSnapshot()

        #expect(snapshot.id == CursorUsageProvider.id)
        #expect(snapshot.status == "live", "Cursor status: \(snapshot.status). Message: \(snapshot.message ?? "none")")
        expectMetricLabels(snapshot, include: ["Total usage", "Auto usage", "API usage", "Requests"])
    }

    @Test func codexSnapshotUsesCliOAuthWhamUsage() async throws {
        UserDefaults.standard.set(true, forKey: AppPreferences.codexEnabledKey)

        let snapshot = await CodexUsageProvider.loadSnapshot()

        #expect(snapshot.id == CodexUsageProvider.id)
        #expect(snapshot.status == "live", "Codex status: \(snapshot.status). Message: \(snapshot.message ?? "none")")
        expectMetricLabels(snapshot, include: ["Session", "Weekly", "Reviews"])
    }

    @Test func codexAuthAcceptsRefreshTokenOnlyState() throws {
        let data = Data("""
        {
          "tokens": {
            "refresh_token": "refresh-token"
          }
        }
        """.utf8)

        #expect(CodexUsageProvider.authJSONHasTokenLikeAuthForTesting(data))
    }

    @Test func codexRefreshPersistencePreservesUnknownCliFields() throws {
        let existing = Data("""
        {
          "last_refresh": "2026-01-01T00:00:00Z",
          "provider_specific_root": "keep-me",
          "tokens": {
            "access_token": "old-access",
            "refresh_token": "old-refresh",
            "provider_specific_token": "keep-token"
          }
        }
        """.utf8)

        let mergedData = try CodexUsageProvider.mergedAuthJSONForTesting(
            existingData: existing,
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: "new-id",
            accountID: "account-1",
            lastRefresh: "2026-06-05T00:00:00Z"
        )
        let merged = try #require(JSONSerialization.jsonObject(with: mergedData) as? [String: Any])
        let tokens = try #require(merged["tokens"] as? [String: Any])

        #expect(merged["last_refresh"] as? String == "2026-06-05T00:00:00Z")
        #expect(merged["provider_specific_root"] as? String == "keep-me")
        #expect(tokens["access_token"] as? String == "new-access")
        #expect(tokens["refresh_token"] as? String == "new-refresh")
        #expect(tokens["id_token"] as? String == "new-id")
        #expect(tokens["account_id"] as? String == "account-1")
        #expect(tokens["provider_specific_token"] as? String == "keep-token")
    }

    private func expectMetricLabels(_ snapshot: UsageSnapshot, include expectedLabels: [String]) {
        let labels = Set(snapshot.lines.map(\.label))
        for label in expectedLabels {
            #expect(labels.contains(label), "Expected \(snapshot.name) to include metric label: \(label). Found: \(labels.sorted().joined(separator: ", "))")
        }
    }
}
