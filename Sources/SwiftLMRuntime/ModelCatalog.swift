//
//  ModelCatalog.swift
//  SwiftLMRuntime
//
//  Created by Alex Goodkind <alex@goodkind.io> on 2026-04-18.
//  Copyright © 2026
//

import AppLogger
import Foundation

private let log = AppLogger.logger(category: "ModelCatalog")
import SwiftLMCore

// MARK: - ModelCatalog

/// Discovers MLX models on disk and exposes them as ``ModelDescriptor``s.
///
/// The catalog walks a set of root directories (typically `~/.lmstudio/models`
/// and the HF hub cache) and yields one descriptor per model. A "model"
/// is a directory that contains a `config.json` file. That is the convention
/// both LM Studio and HuggingFace use.
public struct ModelCatalog {
  public let roots: [String]
  private let fileManager: FileManager

  public init(roots: [String], fileManager: FileManager = .default) {
    self.roots = roots
    self.fileManager = fileManager
  }

  /// Convenience initializer with the machine's default roots.
  public static var defaultRoots: [String] {
    let home = NSHomeDirectory()
    return [
      "\(home)/.lmstudio/models",
      "\(home)/.cache/huggingface/hub",
    ]
  }

  // MARK: - Discovery

  /// Walk every root and return all discovered models sorted by display name.
  ///
  /// A single model often appears on disk twice. The LM Studio layout
  /// stores the full weights under `~/.lmstudio/models/<pub>/<name>`.
  /// The HF hub cache stores a symlink farm under
  /// `~/.cache/huggingface/hub/models--<pub>--<name>/snapshots/<sha>`
  /// that points back to the same blobs. When both are present we
  /// keep the entry with the larger size (actual weights beat empty
  /// snapshot stubs) and drop the duplicate.
  public func allModels() -> [ModelDescriptor] {
    var results: [ModelDescriptor] = []
    for root in roots where fileManager.fileExists(atPath: root) {
      results.append(contentsOf: models(under: root))
    }

    // Dedup by slug. If two entries share a slug, keep the larger one.
    // Entries without a slug are keyed by displayName instead.
    var bySlug: [String: ModelDescriptor] = [:]
    for desc in results {
      let key = desc.slug ?? desc.displayName
      if let prior = bySlug[key] {
        if desc.sizeBytes > prior.sizeBytes { bySlug[key] = desc }
      } else {
        bySlug[key] = desc
      }
    }

    var deduped = Array(bySlug.values)
    deduped.sort { $0.displayName.lowercased() < $1.displayName.lowercased() }
    return deduped
  }

  // MARK: - Helpers

  /// Recursively search a root for directories containing `config.json`.
  ///
  /// Exposed as `internal` for tests. Limits recursion depth to 4 so a
  /// malformed tree can't hang the walk.
  func models(under root: String, maxDepth: Int = 4) -> [ModelDescriptor] {
    var out: [ModelDescriptor] = []
    walk(root, depth: 0, maxDepth: maxDepth) { dir in
      let config = "\(dir)/config.json"
      guard fileManager.fileExists(atPath: config) else { return .keepWalking }
      out.append(makeDescriptor(path: dir))
      // Stop descending once we found a model directory.
      return .stopDescending
    }
    return out
  }

  private enum WalkStep { case keepWalking, stopDescending }

  private func walk(_ dir: String, depth: Int, maxDepth: Int, step: (String) -> WalkStep) {
    guard depth <= maxDepth else { return }
    let decision = step(dir)
    if case .stopDescending = decision { return }
    guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { return }
    for entry in entries {
      let sub = "\(dir)/\(entry)"
      var isDir: ObjCBool = false
      if fileManager.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue {
        walk(sub, depth: depth + 1, maxDepth: maxDepth, step: step)
      }
    }
  }

  private func makeDescriptor(path: String) -> ModelDescriptor {
    // HF hub cache layout: ~/.cache/huggingface/hub/models--<pub>--<name>/snapshots/<sha>
    // The last path component is a 40-char sha. Walk up two levels to
    // find `models--<pub>--<name>` and translate it into a human slug.
    //
    // A file inside `refs/` is also named `main` and contains the sha of
    // the latest snapshot. If config.json ever appears under refs/ it
    // is not a model and should be skipped. We guard on that here.
    let last = (path as NSString).lastPathComponent
    let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let grand = (((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString).lastPathComponent

    // Skip the `refs/main` sibling which is not a model directory.
    if parent == "refs" {
      // Unreachable in practice because `refs/main` is a file not a
      // dir, but defensive so a weird cache layout cannot poison the
      // list.
      log.debug("catalog.refs_skipped path=\(path, privacy: .public)")
      return ModelDescriptor(
        id: path, displayName: last, path: path, sizeBytes: 0, slug: nil, kind: .chat)
    }

    let displayName: String
    let slug: String?
    if parent == "snapshots" && grand.hasPrefix("models--") {
      // HF hub snapshot. Turn `models--mlx-community--Qwen3.5-4B-MLX-4bit`
      // into the slug `mlx-community/Qwen3.5-4B-MLX-4bit` and use the
      // trailing model name as the display name.
      let bare = String(grand.dropFirst("models--".count))
      let parts = bare.components(separatedBy: "--")
      if parts.count >= 2 {
        let publisher = parts[0]
        let name = parts.dropFirst().joined(separator: "--")
        displayName = name
        slug = "\(publisher)/\(name)"
      } else {
        displayName = bare
        slug = bare
      }
    } else {
      // LM Studio layout: .../<publisher>/<model>.
      displayName = last
      if parent.isEmpty || parent == "models" || parent == "hub" {
        slug = nil
      } else {
        slug = "\(parent)/\(displayName)"
      }
    }

    let kind = Self.inferModelKind(
      modelDir: path, displayName: displayName, slug: slug, fileManager: fileManager)
    return ModelDescriptor(
      id: path,
      displayName: displayName,
      path: path,
      sizeBytes: folderSize(path),
      slug: slug,
      kind: kind
    )
  }

  /// Classify a directory that already contains `config.json`.
  public static func inferModelKind(
    modelDir: String,
    displayName: String,
    slug: String?,
    fileManager: FileManager
  ) -> ModelKind {
    if fileManager.fileExists(atPath: "\(modelDir)/sentence_bert_config.json") {
      return .embedding
    }
    if fileManager.fileExists(atPath: "\(modelDir)/modules.json") {
      return .embedding
    }
    let configPath = "\(modelDir)/config.json"
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return heuristicNameKind(displayName: displayName, slug: slug)
    }
    if let arch = (json["architectures"] as? [String])?.first,
       architectureLooksEmbedding(arch) {
      return .embedding
    }
    if let mt = json["model_type"] as? String {
      let lower = mt.lowercased()
      if ["bert", "nomic_bert", "xlm-roberta", "mpnet"].contains(lower) {
        return .embedding
      }
    }
    return heuristicNameKind(displayName: displayName, slug: slug)
  }

  private static func architectureLooksEmbedding(_ arch: String) -> Bool {
    let pattern =
      "^(Bert|XLMRoberta|MPNet|NomicBert|JinaBert|GTE|SnowflakeArcticEmbed|RobertaForMaskedLM)"
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return false
    }
    let range = NSRange(location: 0, length: (arch as NSString).length)
    return re.firstMatch(in: arch, options: [], range: range) != nil
  }

  private static func heuristicNameKind(displayName: String, slug: String?) -> ModelKind {
    let hay = (displayName + " " + (slug ?? "")).lowercased()
    if hay.contains("embed") {
      return .embedding
    }
    if hay.contains("bge") {
      return .embedding
    }
    return .chat
  }

  /// Sum the size of every file in a directory tree.
  ///
  /// Skips symlinks (HF cache directories are full of them) and bounds
  /// the walk so a pathological tree can't hang the catalog. Any file we
  /// can't stat gets skipped.
  func folderSize(_ path: String) -> Int64 {
    var total: Int64 = 0
    let options: FileManager.DirectoryEnumerationOptions = [
      .skipsHiddenFiles,
      .skipsPackageDescendants,
    ]
    guard let enumerator = fileManager.enumerator(
      at: URL(fileURLWithPath: path),
      includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey],
      options: options
    ) else {
      return 0
    }
    var visited = 0
    let maxVisited = 50_000  // hard cap, way more than any real model tree
    for case let url as URL in enumerator {
      visited += 1
      if visited > maxVisited { break }

      // Prefer the regular-file path: count its size directly.
      if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey]) {
        if values.isRegularFile == true, let bytes = values.fileSize {
          total += Int64(bytes)
          continue
        }
        // HF cache lays out snapshot dirs as symlinks pointing at blobs
        // under a sibling `blobs/` directory. Follow the symlink to a
        // file and count that file's size. Never follow a symlink into
        // a directory (avoids reference cycles).
        if values.isSymbolicLink == true {
          let resolved = url.resolvingSymlinksInPath()
          if let rv = try? resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
             rv.isRegularFile == true,
             let bytes = rv.fileSize {
            total += Int64(bytes)
          }
        }
      }
    }
    return total
  }
}
