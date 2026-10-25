#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { appendFileSync, copyFileSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';

const [mode, rootArgument, coreArgument, libraryArgument, proofArgument, configuration] = process.argv.slice(2);
const root = resolve(rootArgument ?? '.');
const core = resolve(coreArgument ?? '.');
const library = resolve(libraryArgument ?? '.');
const proof = resolve(proofArgument ?? '.');
const statePath = join(proof, 'cohort.json');
const packagePaths = ['', 'Tools', 'Tuist'];
const identities = ['mlx-swift', 'mlx-swift-lm'];
const refs = Object.fromEntries(['LMD_REF', 'CORE_REF', 'LIBRARY_REF', 'SWIFTLM_REF'].map(key => [key, process.env[key]]));
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const readJSON = path => JSON.parse(readFileSync(path, 'utf8'));
const writeJSON = (path, value) => writeFileSync(path, JSON.stringify(value, null, 2) + '\n');

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}
function command(directory, executable, args, stream = false) {
  return execFileSync(executable, args, { cwd: directory, encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024, stdio: stream ? 'inherit' : ['ignore', 'pipe', 'pipe'] })?.trim() ?? '';
}
const git = (directory, ...args) => command(directory, 'git', args);
const diff = (directory, ...args) => execFileSync('git', ['diff', ...args], { cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });

function pinManifest(path, identity, revision) {
  const text = readFileSync(path, 'utf8');
  const pattern = new RegExp('(url:\\s*"https://github\\.com/agoodkind/' + identity
    + '(?:\\.git)?",\\s*revision:\\s*")([0-9a-f]{40})(")', 'g');
  const matches = [...text.matchAll(pattern)];
  requireCondition(matches.length === 1, 'Expected one immutable ' + identity + ' requirement in ' + path);
  writeFileSync(path, text.replace(pattern, (_match, prefix, _old, suffix) => prefix + revision + suffix));
  return matches[0][2];
}

function configureMirrors(exportToRunner) {
  let count = Number(process.env.GIT_CONFIG_COUNT ?? '0');
  requireCondition(Number.isSafeInteger(count) && count >= 0, 'GIT_CONFIG_COUNT must be a nonnegative integer');
  const entries = [['protocol.file.allow', 'always']];
  for (const [identity, directory] of [['mlx-swift', core], ['mlx-swift-lm', library]]) {
    for (const suffix of ['', '.git']) {
      entries.push(['url.' + pathToFileURL(directory).href + '.insteadOf',
        'https://github.com/agoodkind/' + identity + suffix]);
    }
  }
  const lines = [];
  for (const [key, value] of entries) {
    process.env['GIT_CONFIG_KEY_' + count] = key;
    process.env['GIT_CONFIG_VALUE_' + count] = value;
    lines.push('GIT_CONFIG_KEY_' + count + '=' + key, 'GIT_CONFIG_VALUE_' + count + '=' + value);
    count += 1;
  }
  process.env.GIT_CONFIG_COUNT = String(count);
  lines.push('GIT_CONFIG_COUNT=' + count);
  if (exportToRunner && process.env.GITHUB_ENV) appendFileSync(process.env.GITHUB_ENV, lines.join('\n') + '\n');
}

function prepare() {
  for (const [key, value] of Object.entries(refs)) {
    requireCondition(/^[0-9a-f]{40}$/.test(value ?? ''), 'Set ' + key + ' to a full immutable commit SHA');
  }
  for (const [directory, expected] of [[root, refs.LMD_REF], [core, refs.CORE_REF],
    [library, refs.LIBRARY_REF], [join(root, 'SwiftLM'), refs.SWIFTLM_REF]]) {
    requireCondition(git(directory, 'rev-parse', 'HEAD') === expected, 'Unexpected source commit in ' + directory);
  }
  requireCondition(git(library, 'status', '--porcelain').length === 0, 'The dedicated library checkout must be clean');
  mkdirSync(proof, { recursive: true });
  const oldCoreRequirement = pinManifest(join(library, 'Package.swift'), 'mlx-swift', refs.CORE_REF);
  const libraryDiff = diff(library, '--binary', '--full-index', refs.LIBRARY_REF);
  let effectiveLibrary = refs.LIBRARY_REF;
  if (libraryDiff) {
    requireCondition(git(library, 'diff', '--name-only') === 'Package.swift', 'The library overlay changed more than Package.swift');
    git(library, 'add', 'Package.swift');
    const tree = git(library, 'write-tree');
    effectiveLibrary = git(library, '-c', 'user.name=CI cohort preparation',
      '-c', 'user.email=noreply@github.com', 'commit-tree', tree, '-p', refs.LIBRARY_REF,
      '-m', 'Prepare the CI core requirement\n\nCo-authored-by: Codex <noreply@openai.com>');
    git(library, 'checkout', '--detach', effectiveLibrary);
    git(library, 'update-ref', 'refs/tags/ci-cohort-' + effectiveLibrary, effectiveLibrary);
  }
  git(library, 'diff', '--exit-code', refs.LIBRARY_REF, effectiveLibrary, '--', '.', ':!Package.swift');
  writeFileSync(join(proof, 'library-overlay.patch'), libraryDiff);
  const state = { requested: refs, effective_library: effectiveLibrary, library_base: refs.LIBRARY_REF,
    old_core_requirement: oldCoreRequirement, new_core_requirement: refs.CORE_REF,
    library_overlay_sha256: hash(readFileSync(join(proof, 'library-overlay.patch'))),
    library_overlay_tree: git(library, 'rev-parse', effectiveLibrary + '^{tree}'),
    library_overlay_ref: effectiveLibrary === refs.LIBRARY_REF ? null : 'refs/tags/ci-cohort-' + effectiveLibrary,
    runtime_source_comparison: 'git diff --exit-code base effective -- . :!Package.swift passed',
    mirrors: { 'mlx-swift': pathToFileURL(core).href, 'mlx-swift-lm': pathToFileURL(library).href } };
  for (const packagePath of packagePaths) {
    const relative = join(packagePath, 'Package.resolved');
    const original = git(root, 'show', refs.LMD_REF + ':' + relative);
    const name = packagePath ? packagePath.toLowerCase() + '-Package.resolved' : 'Package.resolved';
    writeFileSync(join(proof, 'baseline-' + name), original + '\n');
  }
  writeJSON(statePath, state);
  for (const packagePath of ['', 'Tuist']) {
    pinManifest(join(root, packagePath, 'Package.swift'), 'mlx-swift', refs.CORE_REF);
    pinManifest(join(root, packagePath, 'Package.swift'), 'mlx-swift-lm', effectiveLibrary);
  }
  configureMirrors(true);
  git(root, 'update-index', '--cacheinfo', '160000,' + refs.SWIFTLM_REF + ',SwiftLM');
  command(root, 'git', ['submodule', 'update', '--init', '--recursive', 'SwiftLM'], true);
  for (const [identity, directory, revision] of [['mlx-swift', core, refs.CORE_REF],
    ['mlx-swift-lm', library, effectiveLibrary]]) {
    const nested = join(root, 'SwiftLM', identity);
    git(nested, 'fetch', '--no-tags', directory, revision);
    git(nested, 'checkout', '--detach', revision);
  }
  for (const packagePath of packagePaths) {
    command(root, 'swift', ['package', '--package-path', join(root, packagePath), '--jobs', '4', 'resolve'], true);
  }
  verify();
}

function verify() {
  const state = readJSON(statePath);
  for (const [key, value] of Object.entries(refs)) requireCondition(state.requested[key] === value, 'Cohort input changed: ' + key);
  requireCondition(git(root, 'rev-parse', 'HEAD') === refs.LMD_REF, 'LMD source commit changed');
  requireCondition(git(core, 'rev-parse', 'HEAD') === refs.CORE_REF, 'Dedicated core checkout changed');
  requireCondition(git(library, 'rev-parse', 'HEAD') === state.effective_library, 'Dedicated library overlay changed');
  git(library, 'diff', '--exit-code', refs.LIBRARY_REF, state.effective_library, '--', '.', ':!Package.swift');
  requireCondition(git(library, 'status', '--porcelain') === '', 'The effective library checkout must be clean');
  const expected = { 'mlx-swift': refs.CORE_REF, 'mlx-swift-lm': state.effective_library };
  const resolved = [];
  for (const packagePath of packagePaths) {
    const path = join(root, packagePath, 'Package.resolved');
    const lock = readJSON(path);
    const name = packagePath ? packagePath.toLowerCase() + '-Package.resolved' : 'Package.resolved';
    const baseline = readJSON(join(proof, 'baseline-' + name));
    const otherPins = value => new Map(value.pins.filter(pin => !identities.includes(pin.identity)).map(pin => [pin.identity, pin]));
    requireCondition(isDeepStrictEqual(otherPins(lock), otherPins(baseline)),
      'Resolver changed dependencies outside the requested MLX cohort: ' + path);
    for (const identity of identities) {
      const pins = lock.pins.filter(pin => pin.identity === identity);
      requireCondition(pins.length === 1 && pins[0].state.revision === expected[identity],
        'Resolved revision mismatch: ' + path + ' ' + identity);
      const checkout = join(root, packagePath, '.build/checkouts', identity);
      requireCondition(git(checkout, 'rev-parse', 'HEAD') === expected[identity], 'Resolved checkout mismatch: ' + checkout);
      requireCondition(git(checkout, 'status', '--porcelain', '--untracked-files=no') === '', 'Resolved source package changed: ' + checkout);
    }
    const artifact = packagePath ? packagePath.toLowerCase() + '-Package.resolved' : 'Package.resolved';
    copyFileSync(path, join(proof, artifact));
    resolved.push({ package: packagePath || '.', sha256: hash(readFileSync(path)), revisions: expected });
  }
  requireCondition(git(join(root, 'SwiftLM'), 'rev-parse', 'HEAD') === refs.SWIFTLM_REF, 'SwiftLM source commit changed');
  for (const identity of identities) {
    requireCondition(git(join(root, 'SwiftLM', identity), 'rev-parse', 'HEAD') === expected[identity],
      'Nested SwiftLM checkout mismatch: ' + identity);
  }
  const allowed = new Set(['Package.swift', 'Tuist/Package.swift', 'Package.resolved', 'Tools/Package.resolved', 'Tuist/Package.resolved', 'SwiftLM']);
  for (const path of git(root, 'diff', '--name-only', 'HEAD').split('\n').filter(Boolean)) {
    requireCondition(allowed.has(path), 'Unexpected LMD source change: ' + path);
  }
  writeFileSync(join(proof, 'lmd-cohort.patch'), diff(root, '--binary', '--full-index', 'HEAD'));
  state.resolved = resolved;
  writeJSON(statePath, state);
  console.log('Verified exact core, effective library, SwiftLM, and LMD cohort');
}

function artifacts() {
  requireCondition(configuration === 'Release' || configuration === 'Debug', 'Select Release or Debug artifact proof');
  verify();
  const records = [];
  const shaderDirectory = join(proof, 'shaders', configuration);
  mkdirSync(shaderDirectory, { recursive: true });
  function shader(source, destination, name) {
    requireCondition(statSync(source).size > 0 && statSync(destination).size > 0, 'Empty shader artifact');
    const digest = hash(readFileSync(source));
    requireCondition(hash(readFileSync(destination)) === digest, 'Staged shader differs from its source: ' + destination);
    const copy = join(shaderDirectory, name);
    mkdirSync(resolve(copy, '..'), { recursive: true });
    copyFileSync(destination, copy);
    records.push({ source, destination, sha256: digest });
  }
  const derived = join(root, 'Derived/Build/Products', configuration, 'mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib');
  const nax = ['steel_gemm_fused_nax', 'steel_gemm_splitk_nax', 'steel_gemm_gather_nax',
    'steel_gemm_segmented_nax', 'steel_attention_nax', 'quantized_nax', 'fp_quantized_nax'];
  if (configuration === 'Release') {
    const products = join(root, 'Products/Build/Release');
    shader(derived, join(products, 'mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib'), 'lmd/bundle-default.metallib');
    shader(derived, join(products, 'default.metallib'), 'lmd/adjacent-default.metallib');
    const child = command(root, 'swift', ['build', '--package-path', 'SwiftLM', '-c', 'release', '--show-bin-path']);
    shader(join(child, 'default.metallib'), join(products, 'swiftlm/default.metallib'), 'swiftlm/default.metallib');
    for (const name of nax) {
      shader(join(root, 'Derived/nax', name + '.metallib'), join(products, 'nax', name + '.metallib'), 'lmd/nax/' + name + '.metallib');
      shader(join(child, 'nax', name + '.metallib'), join(products, 'swiftlm/nax', name + '.metallib'), 'swiftlm/nax/' + name + '.metallib');
    }
    stateBinaries(products, child);
  } else {
    const bin = command(root, 'swift', ['build', '--build-system', 'native', '--jobs', '4', '-Xswiftc', '-explicit-module-build', '-c', 'debug', '--show-bin-path']);
    const runner = join(bin, 'lmdPackageTests.xctest/Contents/MacOS');
    shader(derived, join(runner, 'mlx.metallib'), 'tests/mlx.metallib');
    for (const name of nax) shader(join(root, 'Derived/nax', name + '.metallib'), join(runner, 'nax', name + '.metallib'), 'tests/nax/' + name + '.metallib');
  }
  writeJSON(join(proof, configuration.toLowerCase() + '-shaders.json'), records);
  console.log('Verified and copied ' + records.length + ' source-built shader artifacts');
}

function stateBinaries(products, child) {
  const state = readJSON(statePath);
  const native = command(root, 'swift', ['build', '--build-system', 'native', '--jobs', '4', '-Xswiftc', '-explicit-module-build', '-c', 'release', '--show-bin-path']);
  for (const name of ['lmd', 'lmd-serve', 'lmd-model-host']) {
    requireCondition(hash(readFileSync(join(products, name))) === hash(readFileSync(join(native, name))),
      'Staged root executable differs from its native Release build: ' + name);
  }
  state.binaries = Object.fromEntries(['lmd', 'lmd-serve', 'lmd-model-host', 'swiftlm/SwiftLM'].map(name =>
    [name, hash(readFileSync(join(products, name)))]));
  requireCondition(state.binaries['swiftlm/SwiftLM'] === hash(readFileSync(join(child, 'SwiftLM'))), 'Staged SwiftLM binary differs from its build');
  writeJSON(statePath, state);
}

try {
  requireCondition(rootArgument && coreArgument && libraryArgument && proofArgument,
    'Usage: lmd-cohort.mjs prepare|verify|artifacts <lmd> <core> <library> <proof> [Release|Debug]');
  if (mode === 'prepare') prepare();
  else if (mode === 'verify') verify();
  else if (mode === 'artifacts') artifacts();
  else throw new Error('Select prepare, verify, or artifacts');
} catch (error) {
  console.error('LMD cohort validation failed: ' + error.message);
  process.exitCode = 1;
}
