//
//  TestResultVerifier.swift
//  lmd-maintenance
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-10-25.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import SwiftMkCore

enum TestResultVerifier {
  static func verifySwiftPM(log: URL, discovery: URL, selectors: [String]) throws -> [String] {
    let discovered = try discoveredClasses(at: discovery, selectors: selectors)
    let classes = discovered.selected
    let lines = try String(contentsOf: log, encoding: .utf8).components(separatedBy: .newlines)
    var results = XCTestLogResults()
    let patterns = try XCTestLogPatterns()
    for (index, line) in lines.enumerated() {
      if let started = patterns.started.match(line) {
        let name = try started.required("suite")
        results.activeSuites[name, default: 0] += 1
      }
      if let completed = patterns.completed.match(line) {
        try results.finishSuite(
          completed, summary: lines.dropFirst(index + 1).first, pattern: patterns.summary)
      }
      let caseRecord = patterns.caseRecord(in: line)
      if let test = patterns.objectiveC.match(caseRecord) ?? patterns.swift.match(caseRecord) {
        try results.finishTest(test, selectedClasses: classes)
      } else if let test = patterns.unqualifiedSwift.match(caseRecord) {
        try results.finishUnqualifiedTest(test, discovery: discovered)
      }
    }
    try requireMaintenanceCondition(
      results.activeSuites.isEmpty,
      "XCTest did not finish suites: " + results.activeSuites.keys.sorted().joined(separator: ", "))
    return try classes.keys.sorted().map { key in
      guard let methods = classes[key], let name = key.split(separator: ".").last else {
        throw MaintenanceError.failure("Invalid discovered XCTest class: \(key)")
      }
      try requireMaintenanceCondition(
        !methods.isEmpty && results.summaries[String(name)] == methods.count,
        "XCTest class did not complete every discovered case: \(key) (expected \(methods.count)).")
      for method in methods.sorted() {
        try requireMaintenanceCondition(
          results.completedMethods[key]?.contains(method) == true,
          "XCTest case did not finish: \(key)/\(method)")
      }
      return "\(key): \(methods.count) discovered cases completed without failures or skips"
    }
  }

  static func verifyXcode(report: URL, selectors: [String]) throws -> [String] {
    let decoded = try JSONDecoder().decode(XcodeTestReport.self, from: Data(contentsOf: report))
    let nodes = decoded.testNodes.flatMap(\.flattened)
    return try selectors.map { selector in
      let suites = nodes.filter { node in
        node.nodeType == "Test Suite" && node.nodeIdentifierURL?.hasSuffix("/" + selector) == true
      }
      try requireMaintenanceCondition(
        suites.count == 1, "xcresult must contain one selected suite: \(selector)")
      guard let suite = suites.first else {
        throw MaintenanceError.failure("xcresult did not contain selected suite: \(selector)")
      }
      let counts = try suite.verifiedCounts()
      try requireMaintenanceCondition(
        counts.functions > 0 && counts.cases > 0,
        "xcresult selected suite did not execute cases: \(selector)")
      return
        "\(selector): \(counts.functions) functions / \(counts.cases) cases passed without skips"
    }
  }

  private static func discoveredClasses(
    at path: URL, selectors: [String]
  ) throws -> XCTestDiscovery {
    let pattern = try TestLogPattern(#"^(?<module>\w+)\.(?<name>\w+)/(?<method>\S+)$"#)
    let discovery = try String(contentsOf: path, encoding: .utf8)
    var classes: [String: Set<String>] = [:]
    var allClasses: [String: Set<String>] = [:]
    for line in discovery.components(separatedBy: .newlines) {
      guard let match = pattern.match(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        continue
      }
      let module = try match.required("module")
      let name = try match.required("name")
      let key = module + "." + name
      let method = try match.required("method")
      allClasses[key, default: []].insert(method)
      guard selectors.contains(module) || selectors.contains(name) || selectors.contains(key) else {
        continue
      }
      classes[key, default: []].insert(method)
    }
    for selector in selectors {
      try requireMaintenanceCondition(
        classes.keys.contains { key in
          key == selector || key.hasPrefix(selector + ".") || key.hasSuffix("." + selector)
        },
        "Discovery did not include selected XCTest class or module: \(selector)")
    }
    return XCTestDiscovery(all: allClasses, selected: classes)
  }
}

// MARK: - XCTestDiscovery

private struct XCTestDiscovery {
  let all: [String: Set<String>]
  let selected: [String: Set<String>]
}

// MARK: - XCTestLogPatterns

private struct XCTestLogPatterns {
  let started: TestLogPattern
  let completed: TestLogPattern
  let summary: TestLogPattern
  let objectiveC: TestLogPattern
  let swift: TestLogPattern
  let unqualifiedSwift: TestLogPattern

  func caseRecord(in line: String) -> String {
    guard let marker = line.range(of: "Test Case '") else { return line }
    return String(line[marker.lowerBound...])
  }

  init() throws {
    started = try TestLogPattern(#"^Test Suite '(?<suite>[^']+)' started at "#)
    completed = try TestLogPattern(#"^Test Suite '(?<suite>[^']+)' (?<status>passed|failed) at "#)
    summary = try TestLogPattern(
      #"^\s*Executed (?<count>\d+) tests?, with (?:(?<skipped>\d+) tests? skipped and )?(?<failed>\d+) failures? \("#
    )
    objectiveC = try TestLogPattern(
      #"^Test Case '-\[(?<class>\w+\.\w+) (?<method>\S+)\]' (?<status>passed|failed|skipped)\b"#)
    swift = try TestLogPattern(
      #"^Test Case '(?<class>\w+\.\w+)\.(?<method>\w+)' (?<status>passed|failed|skipped)\b"#)
    unqualifiedSwift = try TestLogPattern(
      #"^Test Case '(?<class>\w+)\.(?<method>\w+)' (?<status>passed|failed|skipped)\b"#)
  }
}

// MARK: - XCTestLogResults

private struct XCTestLogResults {
  var activeSuites: [String: Int] = [:]
  var summaries: [String: Int] = [:]
  var completedMethods: [String: Set<String>] = [:]

  mutating func finishSuite(
    _ match: TestLogMatch, summary: String?, pattern: TestLogPattern
  ) throws {
    let name = try match.required("suite")
    guard let summary, let counts = pattern.match(summary),
      let count = Int(try counts.required("count")),
      let failed = Int(try counts.required("failed"))
    else {
      throw MaintenanceError.failure("Missing XCTest summary after suite: \(name)")
    }
    let skipped: Int
    if let text = counts.value("skipped") {
      guard let skippedCount = Int(text) else {
        throw MaintenanceError.failure("Invalid XCTest skipped count after suite: \(name)")
      }
      skipped = skippedCount
    } else {
      skipped = 0
    }
    try requireMaintenanceCondition(
      try match.required("status") == "passed" && skipped == 0 && failed == 0,
      "XCTest suite failed or skipped tests: \(name)")
    guard let active = activeSuites[name], active > 0 else {
      throw MaintenanceError.failure("XCTest suite finished without starting: \(name)")
    }
    if active == 1 {
      activeSuites.removeValue(forKey: name)
    } else {
      activeSuites[name] = active - 1
    }
    summaries[name] = count
  }

  mutating func finishTest(
    _ match: TestLogMatch, selectedClasses: [String: Set<String>]
  ) throws {
    let key = try match.required("class")
    guard selectedClasses[key] != nil else { return }
    try finishTest(match, key: key)
  }

  mutating func finishUnqualifiedTest(_ match: TestLogMatch, discovery: XCTestDiscovery) throws {
    let name = try match.required("class")
    let candidates = discovery.all.keys.filter { key in key.hasSuffix("." + name) }
    guard candidates.contains(where: { discovery.selected[$0] != nil }) else { return }
    try requireMaintenanceCondition(
      candidates.count == 1,
      "Ambiguous unqualified XCTest class: \(name) (\(candidates.sorted().joined(separator: ", ")))"
    )
    guard let key = candidates.first else {
      throw MaintenanceError.failure("Discovery did not include XCTest class: \(name)")
    }
    try finishTest(match, key: key)
  }

  private mutating func finishTest(_ match: TestLogMatch, key: String) throws {
    let method = try match.required("method")
    try requireMaintenanceCondition(
      try match.required("status") == "passed", "XCTest case did not pass: \(key)/\(method)")
    completedMethods[key, default: []].insert(method)
  }
}

// MARK: - TestLogPattern

private struct TestLogPattern {
  let expression: NSRegularExpression

  init(_ pattern: String) throws {
    expression = try NSRegularExpression(pattern: pattern)
  }

  func match(_ text: String) -> TestLogMatch? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let result = expression.firstMatch(in: text, range: range) else { return nil }
    return TestLogMatch(text: text, result: result)
  }
}

// MARK: - TestLogMatch

private struct TestLogMatch {
  let text: String
  let result: NSTextCheckingResult

  func value(_ name: String) -> String? {
    guard let range = Range(result.range(withName: name), in: text) else { return nil }
    return String(text[range])
  }

  func required(_ name: String) throws -> String {
    guard let value = value(name) else {
      throw MaintenanceError.failure("Test result is missing the \(name) field.")
    }
    return value
  }
}

// MARK: - XcodeTestReport

private struct XcodeTestReport: Codable {
  let testNodes: [XcodeTestNode]
}

// MARK: - XcodeTestNode

private struct XcodeTestNode: Codable {
  let nodeType: String
  let nodeIdentifierURL: String?
  let name: String?
  let result: String?
  let children: [XcodeTestNode]?

  var flattened: [XcodeTestNode] {
    [self] + (children ?? []).flatMap(\.flattened)
  }

  func verifiedCounts() throws -> XcodeTestCounts {
    if nodeType == "Runtime Warning" {
      Output.logError("Xcode runtime warning: " + (name ?? nodeIdentifierURL ?? nodeType))
      return XcodeTestCounts()
    }
    try requireMaintenanceCondition(
      result == "Passed", "xcresult did not pass: \(nodeIdentifierURL ?? name ?? nodeType)")
    var counts = XcodeTestCounts()
    if nodeType == "Test Case" {
      counts.functions += 1
      if !(children ?? []).contains(where: { $0.nodeType == "Arguments" }) {
        counts.cases += 1
      }
    }
    if nodeType == "Arguments" {
      counts.cases += 1
    }
    for child in children ?? [] {
      let childCounts = try child.verifiedCounts()
      counts.functions += childCounts.functions
      counts.cases += childCounts.cases
    }
    return counts
  }
}

// MARK: - XcodeTestCounts

private struct XcodeTestCounts {
  var functions = 0
  var cases = 0
}
