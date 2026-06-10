import Nimble
import XCTest

@testable import SwiftLMHostProtocol

final class OpenAIEmbeddingsInputTests: XCTestCase {
  func testParsesSingleStringInput() throws {
    let body = Data(#"{"model":"m","input":"hello"}"#.utf8)
    let inputs = try OpenAIEmbeddingsInput.parse(body)
    expect(inputs) == ["hello"]
  }

  func testParsesArrayOfStringsInput() throws {
    let body = Data(#"{"model":"m","input":["a","b","c"]}"#.utf8)
    let inputs = try OpenAIEmbeddingsInput.parse(body)
    expect(inputs) == ["a", "b", "c"]
  }

  func testEmptyArrayInputParsesToEmpty() throws {
    let body = Data(#"{"model":"m","input":[]}"#.utf8)
    let inputs = try OpenAIEmbeddingsInput.parse(body)
    expect(inputs) == []
  }

  func testMissingInputThrows() {
    let body = Data(#"{"model":"m"}"#.utf8)
    expect { try OpenAIEmbeddingsInput.parse(body) }
      .to(throwError(OpenAIEmbeddingsInputError.inputMissingOrWrongType))
  }

  func testNumericInputThrows() {
    let body = Data(#"{"model":"m","input":123}"#.utf8)
    expect { try OpenAIEmbeddingsInput.parse(body) }
      .to(throwError(OpenAIEmbeddingsInputError.inputMissingOrWrongType))
  }

  func testArrayWithNonStringElementThrows() {
    let body = Data(#"{"model":"m","input":["a",2]}"#.utf8)
    expect { try OpenAIEmbeddingsInput.parse(body) }
      .to(throwError(OpenAIEmbeddingsInputError.inputMissingOrWrongType))
  }

  func testMalformedJSONThrows() {
    let body = Data("not json".utf8)
    expect { try OpenAIEmbeddingsInput.parse(body) }
      .to(throwError(OpenAIEmbeddingsInputError.malformedJSON))
  }
}
