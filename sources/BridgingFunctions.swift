//
//  BridgingFunctions.swift
//  Owltype
//
//  Created by Leo Liu on 5/11/24.
//

import Foundation

infix operator ?= : AssignmentPrecedence
// swiftlint:disable:next operator_whitespace
func ?=<T>(left: inout T, right: T?) {
  if let right = right {
    left = right
  }
}
// swiftlint:disable:next operator_whitespace
func ?=<T>(left: inout T?, right: T?) {
  if let right = right {
    left = right
  }
}

extension NSRange {
  static let empty = NSRange(location: NSNotFound, length: 0)
}
