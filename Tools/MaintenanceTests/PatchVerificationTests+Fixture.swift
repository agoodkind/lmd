//
//  PatchVerificationTests+Fixture.swift
//  LMDMaintenanceTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import Nimble
import SwiftMkCore
import XCTest

@testable import lmd_maintenance

// MARK: - PatchVerificationTests

extension PatchVerificationTests {
  final class Fixture {
    private static let patchCount = 2
    let root: URL
    let catalogRoot: URL
    let catalogDirectory: URL
    let catalog: URL
    let report: URL
    let repositories: [URL]
    let workflowPaths = [
      ".github/workflows/downstream_integration.yml",
      ".github/workflows/downstream_integration.yml", ".github/workflows/ci.yml",
    ]
    let oldWorkflowRef = String(
      repeating: "1",
      count: PatchCatalog.gitObjectIDLength)
    var catalogRef = ""
    var sources: [PatchCatalog.Source] = []

    init() throws {
      let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("lmd-patch-tests-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
      root = temporaryRoot
      catalogRoot = root.appendingPathComponent("catalog")
      catalogDirectory = catalogRoot.appendingPathComponent("patches")
      catalog = catalogDirectory.appendingPathComponent("manifest.json")
      report = root.appendingPathComponent("report.json")
      repositories = ["core", "library", "swiftlm"].map { temporaryRoot.appendingPathComponent($0) }
      try FileManager.default.createDirectory(
        at: catalogDirectory,
        withIntermediateDirectories: true)
      try initialize(catalogRoot)
      for (index, repository) in repositories.enumerated() {
        try FileManager.default.createDirectory(
          at: repository,
          withIntermediateDirectories: true)
        try initialize(repository)
        sources.append(
          try createSource(
            index: index,
            repository: repository))
      }
      try saveCatalog()
    }

    func remove() {
      Output.debug("patches.test_cleanup_started")
      do {
        try FileManager.default.removeItem(at: root)
      } catch {
        Output.error("Cannot remove temporary Git test repositories: \(error)")
        fail("Cannot remove temporary Git test repositories: \(error)")
      }
    }

    func arguments(
      coreRef: String? = nil,
      coreProfile: String? = nil
    ) -> [String] {
      var result = [
        "--catalog", catalog.path, "--catalog-ref", catalogRef, "--report", report.path,
      ]
      for (index, label) in ["core", "library", "swiftlm"].enumerated() {
        result += ["--\(label)-repository", repositories[index].path]
        if index == 0, let coreRef {
          result += ["--\(label)-ref", coreRef]
        } else {
          result += ["--\(label)-ref", sources[index].forkCommit]
        }
      }
      if let coreProfile {
        result += ["--core-profile", coreProfile]
      }
      return result
    }

    func verify(_ arguments: [String]) throws {
      let result = try verificationResult(arguments)
      try requireMaintenanceCondition(
        result.status == 0, "Patch verification failed (\(result.status)): \(result.stderr)")
    }

    func verificationResult(
      _ arguments: [String],
      environment: [String: String] = [:]
    ) throws -> Shell.Result {
      let binary = try MaintenanceTestExecutable.locate(for: PatchVerificationTests.self)
      return isolatedRun(
        binary.path,
        ["verify-patches"] + arguments,
        environment: environment)
    }

    func replacing(
      _ source: PatchCatalog.Source,
      patches: [PatchCatalog.Patch]
    )
      -> PatchCatalog.Source
    {
      PatchCatalog.Source(
        repository: source.repository,
        upstreamRepository: source.upstreamRepository,
        upstreamCommit: source.upstreamCommit,
        forkCommit: source.forkCommit,
        expectedTree: source.expectedTree,
        patches: patches,
        profiles: source.profiles)
    }

    func saveCatalog() throws {
      Output.debug("patches.saveCatalog_started")
      let manifest = PatchCatalog(
        version: 1,
        sources: sources,
        protections: [
          PatchCatalog.Protection(
            feature: "Preserve the feature",
            repository: PatchCatalog.repositories[0],
            selectors: ["PatchVerificationTests"])
        ])
      try JSONEncoder().encode(manifest).write(to: catalog)
      try commitCatalog()
    }

    func commitCatalog() throws {
      catalogRef = try commit(catalogRoot)
    }

    func snapshots() throws -> [String] {
      try (repositories + [catalogRoot]).map { repository in
        let head = try git(
          repository,
          ["rev-parse", "HEAD"])
        let refs = try git(
          repository,
          ["show-ref"])
        let status = try git(
          repository,
          ["status", "--porcelain=v1", "--untracked-files=all"])
        let index = try Data(contentsOf: repository.appendingPathComponent(".git/index"))
        let objects = repository.appendingPathComponent(".git/objects")
        guard
          let enumerator = FileManager.default.enumerator(
            at: objects,
            includingPropertiesForKeys: [.isRegularFileKey])
        else {
          throw MaintenanceError.failure("Cannot inspect temporary Git objects.")
        }
        var objectDigests: [String] = []
        for case let file as URL in enumerator {
          guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            continue
          }
          objectDigests.append(file.path + ":" + maintenanceSHA256(try Data(contentsOf: file)))
        }
        return [head, refs, status, maintenanceSHA256(index)]
          .joined(separator: "\n") + objectDigests.sorted().joined(separator: "\n")
      }
    }

    func commit(_ repository: URL) throws -> String {
      _ = try git(
        repository,
        ["add", "--all"])
      _ = try git(
        repository,
        ["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Update fixture"])
      return try git(
        repository,
        ["rev-parse", "HEAD"]
      ).trimmingCharacters(
        in: .whitespacesAndNewlines)
    }

    private func initialize(_ repository: URL) throws {
      _ = try git(
        repository,
        ["init", "--quiet", "--initial-branch=main", "--object-format=sha1"])
    }

    private func createSource(
      index: Int,
      repository: URL
    ) throws -> PatchCatalog.Source {
      Output.debug("patches.createSource_started")
      let feature = repository.appendingPathComponent("Feature.swift")
      try Data("upstream\n".utf8).write(to: feature)
      try createWorkflow(index: index, repository: repository)
      let upstream = try commit(repository)
      let directory = String(PatchCatalog.repositories[index].split(separator: "/").last ?? "")
      var previous = upstream
      var patches: [PatchCatalog.Patch] = []
      for step in 1...Self.patchCount {
        try Data("upstream\nowned feature \(step)\n".utf8).write(to: feature)
        let next = try commit(repository)
        let path = String(format: "%@/%04d-feature.patch", directory, step)
        patches.append(
          try createPatch(
            path,
            from: previous,
            to: next,
            repository: repository))
        previous = next
      }
      var profiles: [PatchCatalog.Profile] = []
      if index == 0 {
        profiles = [
          PatchCatalog.Profile(
            name: "core-reviewed-snapshot",
            commit: upstream,
            patch: try createPatch(
              "profiles/core-reviewed-snapshot.patch",
              from: previous,
              to: upstream,
              repository: repository))
        ]
      }
      return PatchCatalog.Source(
        repository: PatchCatalog.repositories[index],
        upstreamRepository: "upstream/fixture",
        upstreamCommit: upstream,
        forkCommit: previous,
        expectedTree: try git(
          repository,
          ["rev-parse", "\(previous)^{tree}"]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines),
        patches: patches,
        profiles: profiles)
    }

    private func createWorkflow(index: Int, repository: URL) throws {
      Output.debug("patches.createWorkflow_started")
      let workflow = repository.appendingPathComponent(workflowPaths[index])
      try FileManager.default.createDirectory(
        at: workflow.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      var job = "lmd_consumer"
      if index == 1 {
        job = "lmd-consumer"
      }
      let workflowText = """
        name: Integration
        on: workflow_dispatch
        jobs:
          \(job):
            uses: agoodkind/lmd/.github/workflows/lmd_integration.yml@\(oldWorkflowRef)
            with:
              lmd_ref: \(oldWorkflowRef)

        """
      try Data(workflowText.utf8).write(to: workflow)
    }

    private func createPatch(
      _ path: String,
      from sourceCommit: String,
      to destinationCommit: String,
      repository: URL
    ) throws -> PatchCatalog.Patch {
      Output.debug("patches.createPatch_started")
      let destination = catalogDirectory.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      _ = try git(
        repository,
        [
          "diff", "--binary", "--full-index", sourceCommit, destinationCommit,
          "--output=\(destination.path)",
        ])
      return PatchCatalog.Patch(
        path: path,
        sha256: maintenanceSHA256(try Data(contentsOf: destination)),
        expectedTree: try git(
          repository,
          ["rev-parse", "\(destinationCommit)^{tree}"]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func git(_ repository: URL, _ arguments: [String]) throws -> String {
      Output.debug("patches.fixture_git_command_started")
      let result = isolatedRun(
        "git",
        ["-C", repository.path] + arguments,
        environment: [
          "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0",
          "GIT_AUTHOR_NAME": "Patch Verification", "GIT_AUTHOR_EMAIL": "patches@example.invalid",
          "GIT_COMMITTER_NAME": "Patch Verification",
          "GIT_COMMITTER_EMAIL": "patches@example.invalid",
        ])
      try requireMaintenanceCondition(
        result.status == 0, "Git fixture command failed: \(result.stderr)")
      return result.stdout
    }

    private func isolatedRun(
      _ executable: String,
      _ arguments: [String],
      environment: [String: String]
    ) -> Shell.Result {
      Output.debug("patches.fixture_subprocess_started")
      let inheritedGitKeys = ProcessInfo.processInfo.environment.keys.filter { key in
        key.hasPrefix("GIT_") && environment[key] == nil
      }
      var isolatedArguments: [String] = []
      for key in inheritedGitKeys.sorted() {
        isolatedArguments += ["-u", key]
      }
      isolatedArguments += [executable] + arguments
      return Shell.run("/usr/bin/env", isolatedArguments, environment: environment)
    }
  }
}
