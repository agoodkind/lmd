//
//  VectorBlob.swift
//  SwiftLMHostProtocol
//
//  Encodes embedding vectors as one contiguous little-endian Float32 blob so a
//  batch crosses the XPC boundary in a single message without per-element JSON.
//

import Foundation

public enum VectorBlobError: Error, Equatable {
  case payloadNotMultipleOfDims(payloadFloats: Int, dims: Int)
}

public enum VectorBlob {
  /// Flatten row-major into little-endian Float32. Returns the per-vector
  /// dimension and the blob. All rows are assumed equal length, since
  /// embedding output is rectangular.
  public static func encode(_ vectors: [[Float]]) -> (dims: Int, payload: Data) {
    guard let first = vectors.first else {
      return (0, Data())
    }
    let dims = first.count
    var payload = Data(capacity: vectors.count * dims * 4)
    for vector in vectors {
      for value in vector {
        var little = value.bitPattern.littleEndian
        withUnsafeBytes(of: &little) { payload.append(contentsOf: $0) }
      }
    }
    return (dims, payload)
  }

  /// Reconstruct row-major vectors from the blob. Throws when the float count
  /// is not a whole multiple of `dims`.
  public static func decode(dims: Int, payload: Data) throws -> [[Float]] {
    guard dims > 0 else {
      return []
    }
    let totalFloats = payload.count / 4
    guard totalFloats % dims == 0 else {
      throw VectorBlobError.payloadNotMultipleOfDims(payloadFloats: totalFloats, dims: dims)
    }
    let bytes = [UInt8](payload)
    var floats = [Float](repeating: 0, count: totalFloats)
    for i in 0..<totalFloats {
      let base = i * 4
      let bits =
        UInt32(bytes[base]) | (UInt32(bytes[base + 1]) << 8)
        | (UInt32(bytes[base + 2]) << 16) | (UInt32(bytes[base + 3]) << 24)
      floats[i] = Float(bitPattern: bits)
    }
    var out: [[Float]] = []
    out.reserveCapacity(totalFloats / dims)
    var index = 0
    while index < totalFloats {
      out.append(Array(floats[index..<index + dims]))
      index += dims
    }
    return out
  }
}
