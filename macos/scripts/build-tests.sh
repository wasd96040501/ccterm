#!/bin/bash
# 一次性编译 App + Test bundle，产物给后续 test-without-building 用。
# CI 上 build job 调用一次,N 个 shard job 共享产物,省 N-1 次重复编译。
#
# 用法:
#   ./scripts/build-tests.sh                  # 输出到 build/DD/
#   DERIVED_DATA=/tmp/foo ./scripts/build-tests.sh
#
# 产物:
#   $DERIVED_DATA/Build/Products/*.xctestrun
#   $DERIVED_DATA/Build/Products/Debug/ccterm.app
#   $DERIVED_DATA/Build/Products/Debug/cctermUITests-Runner.app  等
#
# xctestrun 文件用 __TESTROOT__ 占位符引用产物路径,所以整个 Products 目录
# 可以原样打包传到别的机器,只要解压到相同相对位置即可使用。

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="ccterm"
DESTINATION='platform=macOS,arch=arm64'
DERIVED_DATA="${DERIVED_DATA:-build/DD}"

# fzf submodule guard,沿用 build.sh 的逻辑
if [ ! -f ../thirdparty/fzf/main.go ]; then
  echo "Initializing git submodules..."
  git -C .. submodule update --init --recursive
fi

mkdir -p "$DERIVED_DATA"

echo "Building tests ($SCHEME, derivedData=$DERIVED_DATA)..."
START_TIME=$(date +%s)

# 不重定向输出:CI 日志希望看到完整编译过程;本地用户也只在排查 build 失败时调用。
xcodebuild \
  -project ccterm.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build-for-testing

ELAPSED=$(( $(date +%s) - START_TIME ))

XCTESTRUN=$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -1)
if [ -z "$XCTESTRUN" ]; then
  echo "error: build-for-testing finished but no .xctestrun was produced in $DERIVED_DATA/Build/Products" >&2
  exit 1
fi

echo ""
echo "Build for testing succeeded (${ELAPSED}s)"
echo "xctestrun: $XCTESTRUN"
echo "products:  $DERIVED_DATA/Build/Products"
