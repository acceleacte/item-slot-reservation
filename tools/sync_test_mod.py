#!/usr/bin/env python
"""把发布源同步到游戏的本地测试副本 mods/item-slot-reservation-test/

测试副本 = release/ 的全部运行文件 + modinfo 三处标识：
  * name 加 [TEST]
  * version 加 -test
  * description 头部标「本地测试版」

为什么要有这个脚本：手工 cp release/modinfo.lua 覆盖测试副本会把这三处标识一起抹掉，
游戏里就出现两个同名模组条目，人和存档都分不清是哪个（2026-11-04 已踩过一次）

用法：
    python tools/sync_test_mod.py
    python tools/sync_test_mod.py --target "D:/.../mods/item-slot-reservation-test"
    python tools/sync_test_mod.py --check-only     # 只校验，不写

默认源是 ../release，默认目标是 Steam 的 mods/item-slot-reservation-test
"""

import argparse
import shutil
import sys
from pathlib import Path

TEST_SUFFIX = "[TEST]"
TEST_VERSION_SUFFIX = "-test"
TEST_DESC_HEADER = "【本地测试版】非创意工坊发布版本，仅用于本地联机测试"
COPY_FILES = ("modmain.lua", "modicon.png")
COPY_DIRS = ("images", "scripts")

DEFAULT_SOURCE = Path(__file__).resolve().parent.parent.parent / "release"
DEFAULT_TARGET = Path(
    r"D:/Program Files (x86)/Steam/steamapps/common/Don't Starve Together/mods/item-slot-reservation-test"
)


def build_test_modinfo(source: str) -> str:
    """把发布版 modinfo 转成测试版：name/version/description 三处标识"""
    out = source

    # name：只加一次
    marker = 'name = "'
    start = out.index(marker)
    end = out.index('"', start + len(marker))
    name = out[start + len(marker):end]
    if not name.endswith(TEST_SUFFIX):
        out = out[:end] + TEST_SUFFIX + out[end:]

    # version：只加一次
    marker = 'version = "'
    start = out.index(marker)
    end = out.index('"', start + len(marker))
    version = out[start + len(marker):end]
    if not version.endswith(TEST_VERSION_SUFFIX):
        out = out[:end] + TEST_VERSION_SUFFIX + out[end:]

    # description 头部：只加一次
    if TEST_DESC_HEADER not in out:
        marker = "description = [[\n"
        index = out.index(marker) + len(marker)
        out = out[:index] + TEST_DESC_HEADER + "\n" + out[index:]

    return out


def check(target: Path) -> list:
    """返回测试副本里缺失 / 不符合的项，空列表代表合格"""
    problems = []
    modinfo = target / "modinfo.lua"
    if not modinfo.is_file():
        return [f"缺少 {modinfo}"]

    text = modinfo.read_text(encoding="utf-8")
    if f'name = "' in text:
        name = text.split('name = "', 1)[1].split('"', 1)[0]
        if not name.endswith(TEST_SUFFIX):
            problems.append(f"name 缺少 {TEST_SUFFIX}：{name}")
    version = text.split('version = "', 1)[1].split('"', 1)[0]
    if not version.endswith(TEST_VERSION_SUFFIX):
        problems.append(f"version 缺少 {TEST_VERSION_SUFFIX}：{version}")
    if TEST_DESC_HEADER not in text:
        problems.append("description 缺少「本地测试版」提示")
    return problems


def sync(source: Path, target: Path) -> None:
    if not (source / "modinfo.lua").is_file():
        sys.exit(f"源目录不对，找不到 modinfo.lua：{source}")

    target.mkdir(parents=True, exist_ok=True)

    for name in COPY_FILES:
        src = source / name
        if src.is_file():
            shutil.copy2(src, target / name)

    for name in COPY_DIRS:
        src = source / name
        if not src.is_dir():
            continue
        dst = target / name
        if dst.is_dir():
            shutil.rmtree(dst)
        shutil.copytree(src, dst)

    modinfo = build_test_modinfo((source / "modinfo.lua").read_text(encoding="utf-8"))
    (target / "modinfo.lua").write_text(modinfo, encoding="utf-8", newline="\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="同步发布源到本地测试副本")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE, help="发布源目录（默认 ../release）")
    parser.add_argument("--target", type=Path, default=DEFAULT_TARGET, help="游戏里的测试副本目录")
    parser.add_argument("--check-only", action="store_true", help="只校验，不写文件")
    args = parser.parse_args()

    if not args.check_only:
        sync(args.source, args.target)
        print(f"已同步 {args.source} -> {args.target}")

    problems = check(args.target)
    if problems:
        for item in problems:
            print(f"[FAIL] {item}")
        return 1

    text = (args.target / "modinfo.lua").read_text(encoding="utf-8")
    name = text.split('name = "', 1)[1].split('"', 1)[0]
    version = text.split('version = "', 1)[1].split('"', 1)[0]
    print(f"[OK] name = {name}")
    print(f"[OK] version = {version}")
    print("[OK] description 带「本地测试版」提示")
    return 0


if __name__ == "__main__":
    sys.exit(main())
