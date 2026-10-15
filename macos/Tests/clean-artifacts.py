#!/usr/bin/env python3
"""清理已结束验收的测试安装包和可执行文件；默认仅列出范围。"""
from pathlib import Path
import argparse
import json
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / '.build'
MACHO = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe'}


def candidates():
    result = []
    if not BUILD.is_dir() or BUILD.is_symlink():
        return result
    for app in sorted(BUILD.iterdir()):
        if app.suffix != '.app' or app.is_symlink():
            continue
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        bundle = info.get('CFBundleIdentifier', '')
        # The shipped App lives in build/, and its bundle ID is also explicitly excluded.
        if not bundle.startswith('local.comind.') or bundle == 'local.comind.cockpit':
            continue
        name = app.stem
        if not (name.endswith(('Preview', ' QA', 'Probe')) or name.startswith(('ChatPerformance', 'Scroll', 'TableScroll'))):
            continue
        result.append(app)
        staging = BUILD / (name + '-sources')
        if staging.is_dir() and not staging.is_symlink():
            result.append(staging)
    for binary in sorted(BUILD.iterdir()):
        if binary.is_symlink() or not binary.is_file():
            continue
        if not (binary.name.endswith('-smoke') or binary.name in {'smoke', 'live-progress'}):
            continue
        with binary.open('rb') as f:
            if f.read(4) in MACHO:
                result.append(binary)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true', help='退出测试 App 后执行清理')
    args = parser.parse_args()
    paths = candidates()
    print(json.dumps([str(p.relative_to(ROOT)) for p in paths], ensure_ascii=False, indent=2))
    if not args.execute or not paths:
        return
    # Never remove running test executables or race an active build. A denied process
    # inventory stops the cleanup, instead of treating unavailable evidence as idle.
    commands = subprocess.run(['/bin/ps', '-axo', 'comm='], text=True, capture_output=True, check=True).stdout.splitlines()
    for command in commands:
        command = command.strip()
        if any(command == str(p) or command.startswith(str(p) + '/') for p in paths):
            raise SystemExit('仍有测试进程在运行，请先正常退出后再清理。')
        if Path(command).name in {'swiftc', 'swift-frontend', 'clang', 'ld'}:
            raise SystemExit('检测到编译进程，请构建结束后再清理。')
    total = sum(int(subprocess.check_output(['/usr/bin/du', '-sk', str(p)], text=True).split()[0]) for p in paths)
    for p in paths:
        if p.parent != BUILD or p.is_symlink():
            raise SystemExit('清理路径发生变化，已停止。')
        if p.is_dir():
            shutil.rmtree(p)
        else:
            p.unlink()
    assert all(not p.exists() for p in paths)
    print(f'已清理 {len(paths)} 个产物，原占用 {total / 1024:.1f} MiB。')


if __name__ == '__main__':
    main()
