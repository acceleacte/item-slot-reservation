from pathlib import Path
import os
import sys


# lupa 不在仓库里。按优先级找：环境变量 → 仓库内 → 工作区级（仓库的父目录）
REPO_ROOT = Path(__file__).resolve().parents[1]
CANDIDATES = [
    os.environ.get("ISR_LUPA_PATH"),
    str(REPO_ROOT / ".lua-test-runtime"),
    str(REPO_ROOT.parent / ".lua-test-runtime"),
]
for candidate in CANDIDATES:
    if candidate and Path(candidate).is_dir():
        sys.path.insert(0, candidate)
        break
else:
    sys.exit(
        "找不到 lupa。pip install lupa，或设 ISR_LUPA_PATH 指向 lupa 所在目录\n"
        "已尝试：" + ", ".join(str(c) for c in CANDIDATES)
    )

from lupa import LuaRuntime  # noqa: E402


ROOT = REPO_ROOT


def run_test(path: Path) -> None:
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ISR_TEST_ROOT = ROOT.as_posix()
    lua.execute(path.read_text(encoding="utf-8"), name=str(path))
    print(f"PASS {path.name}")


if __name__ == "__main__":
    tests = sorted(Path(__file__).parent.glob("test_*.lua"))
    for test in tests:
        run_test(test)
    print(f"PASS {len(tests)} test files")
