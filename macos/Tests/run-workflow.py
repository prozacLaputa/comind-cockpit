#!/usr/bin/env python3
from pathlib import Path
import subprocess, sys
root = Path(__file__).resolve().parent.parent
build = root / '.build'; build.mkdir(exist_ok=True)
sources = sorted(str(p) for p in (root / 'Sources').glob('*.swift') if p.name != 'CoMindApp.swift')
binary = build / 'workflow-reliability-smoke'
suites = ['WorkflowReliabilitySmoke', 'CoMindSourceSmoke', 'DocumentsSmoke', 'ReliabilitySmoke']
parts=[]
for suite in suites:
    path=root/'Tests'/(suite+'.swift')
    parts.append(f'#sourceLocation(file: "{path}", line: 1)\n'+path.read_text().replace('@main struct ', 'struct ', 1)+'\n#sourceLocation()')
parts.append('@main struct WorkflowRegression { @MainActor static func main() async throws {\n'+'\n'.join('try await '+name+'.main()' for name in suites)+'\n} }')
combined=build/'WorkflowRegression.swift';combined.write_text('\n'.join(parts))
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(build / 'module-cache'), '-framework', 'SwiftUI', '-framework', 'AppKit', *sources, str(combined), '-o', str(binary)], check=True)
if '--build-only' not in sys.argv:
    subprocess.run([str(binary)], check=True)
