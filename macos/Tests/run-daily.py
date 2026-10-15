#!/usr/bin/env python3
"""Compile the isolated daily-use regressions together, without contacting real Codex."""
from pathlib import Path
import subprocess, sys

root = Path(__file__).resolve().parent.parent
suites = ['DailyUseSmoke', 'ChatContinuitySmoke', 'WorkspaceSearchSmoke', 'ContextEfficiencySmoke', 'NoteActivitySmoke', 'SendSafetySmoke', 'ChatInputSmoke']
build = root / '.build'
build.mkdir(exist_ok=True)
parts = []
for suite in suites:
    path = root / 'Tests' / (suite + '.swift')
    # Keep #filePath relative fixture discovery and protocol paths identical to standalone runs.
    parts.append(f'#sourceLocation(file: "{path}", line: 1)\n' + path.read_text().replace('@main struct ', 'struct ', 1) + '\n#sourceLocation()')
parts.append('@main struct DailyRegression { @MainActor static func main() async throws {\n' + '\n'.join('try await ' + name + '.main()' for name in suites) + '\n} }')
combined = build / 'DailyRegression.swift'
combined.write_text('\n'.join(parts))
binary = build / 'daily-regression-smoke'
sources = sorted(str(p) for p in (root / 'Sources').glob('*.swift') if p.name != 'CoMindApp.swift')
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(build / 'module-cache'), '-framework', 'SwiftUI', '-framework', 'AppKit', *sources, str(combined), '-o', str(binary)], check=True)
if '--build-only' not in sys.argv:
    subprocess.run([str(binary), str(root / 'Tests/fake_codex.py')], cwd=root.parent, check=True)
