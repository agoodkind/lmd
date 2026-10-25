#!/usr/bin/env node
import { readFileSync } from 'node:fs';

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

function verifySwiftPM(logPath, discoveryPath, selectors) {
  const discovery = readFileSync(discoveryPath, 'utf8');
  const classes = new Map();
  for (const line of discovery.split(/\r?\n/)) {
    const match = /^(\w+)\.(\w+)\/(\S+)$/.exec(line.trim());
    if (!match) continue;
    const [, module, name, method] = match;
    if (!selectors.some(selector => selector === module || selector === name || selector === module + '.' + name)) continue;
    const key = module + '.' + name;
    if (!classes.has(key)) classes.set(key, new Set());
    classes.get(key).add(method);
  }
  for (const selector of selectors) {
    requireCondition([...classes.keys()].some(key => key === selector || key.startsWith(selector + '.') || key.endsWith('.' + selector)),
      'Discovery did not include selected XCTest class or module: ' + selector);
  }

  const log = readFileSync(logPath, 'utf8');
  const summaries = new Map();
  const completedMethods = new Map();
  const activeSuites = new Set();
  const lines = log.split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const started = /^Test Suite '([^']+)' started at /.exec(line);
    if (started) activeSuites.add(started[1]);
    const suite = /^Test Suite '([^']+)' (passed|failed) at /.exec(line);
    if (suite) {
      const counts = /^\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \(/.exec(lines[index + 1] ?? '');
      requireCondition(counts, 'Missing XCTest summary after suite: ' + suite[1]);
      requireCondition(suite[2] === 'passed' && Number(counts[2] ?? 0) === 0 && Number(counts[3]) === 0,
        'XCTest suite failed or skipped tests: ' + suite[1]);
      activeSuites.delete(suite[1]);
      summaries.set(suite[1], Number(counts[1]));
    }
    const testCase = /^Test Case '-\[(\w+\.\w+) (\S+)\]' (passed|failed|skipped)\b/.exec(line)
      ?? /^Test Case '(\w+\.\w+)\.(\w+)' (passed|failed|skipped)\b/.exec(line);
    if (testCase && classes.has(testCase[1])) {
      requireCondition(testCase[3] === 'passed', 'XCTest case did not pass: ' + testCase[1] + '/' + testCase[2]);
      if (!completedMethods.has(testCase[1])) completedMethods.set(testCase[1], new Set());
      completedMethods.get(testCase[1]).add(testCase[2]);
    }
  }
  requireCondition(activeSuites.size === 0, 'XCTest did not finish suites: ' + [...activeSuites].join(', '));
  for (const [key, methods] of classes) {
    const name = key.slice(key.lastIndexOf('.') + 1);
    requireCondition(summaries.get(name) === methods.size,
      'XCTest class did not complete every discovered case: ' + key + ' (expected ' + methods.size + ', summary ' + summaries.get(name) + ')');
    for (const method of methods) {
      requireCondition(completedMethods.get(key)?.has(method), 'XCTest case did not finish: ' + key + '/' + method);
    }
    console.log(key + ': ' + methods.size + ' discovered cases completed without failures or skips');
  }
}

function verifyXcode(reportPath, selectors) {
  const report = JSON.parse(readFileSync(reportPath, 'utf8'));
  requireCondition(Array.isArray(report.testNodes), 'xcresult JSON does not contain testNodes');
  const nodes = [];
  function visit(node) {
    nodes.push(node);
    for (const child of node.children ?? []) visit(child);
  }
  for (const node of report.testNodes) visit(node);
  for (const selector of selectors) {
    const suites = nodes.filter(node => node.nodeType === 'Test Suite'
      && node.nodeIdentifierURL?.endsWith('/' + selector));
    requireCondition(suites.length === 1, 'xcresult must contain one selected suite: ' + selector);
    let functions = 0;
    let cases = 0;
    function verify(node) {
      if (node.nodeType === 'Runtime Warning') {
        console.warn('Xcode runtime warning: ' + node.name);
        return;
      }
      requireCondition(node.result === 'Passed', 'xcresult did not pass: ' + (node.nodeIdentifierURL ?? node.name) + ' (' + node.result + ')');
      if (node.nodeType === 'Test Case') {
        functions += 1;
        if (!(node.children ?? []).some(child => child.nodeType === 'Arguments')) cases += 1;
      }
      if (node.nodeType === 'Arguments') cases += 1;
      for (const child of node.children ?? []) verify(child);
    }
    verify(suites[0]);
    requireCondition(functions > 0 && cases > 0, 'xcresult selected suite did not execute cases: ' + selector);
    console.log(selector + ': ' + functions + ' functions / ' + cases + ' cases passed without skips');
  }
}

try {
  const [mode, inputPath, ...arguments_] = process.argv.slice(2);
  requireCondition(inputPath, 'Usage: verify-integration-results.mjs swiftpm <log> <discovery> <class-or-module>... | xcode <test-results-json> <suite-path>...');
  if (mode === 'swiftpm') {
    const [discoveryPath, ...selectors] = arguments_;
    requireCondition(discoveryPath && selectors.length > 0, 'SwiftPM validation requires discovery and selected classes or modules');
    verifySwiftPM(inputPath, discoveryPath, selectors);
  } else if (mode === 'xcode') {
    requireCondition(arguments_.length > 0, 'Xcode validation requires selected suite paths');
    verifyXcode(inputPath, arguments_);
  } else {
    throw new Error('Select swiftpm or xcode validation');
  }
} catch (error) {
  console.error('Test result validation failed: ' + error.message);
  process.exitCode = 1;
}
