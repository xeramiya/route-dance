#!/bin/sh
# RouteDance.xcodeproj を XcodeGen で生成する。
#
# 既定の対応OSは iOS 27 / macOS 27。SDKが入るまでは次のように一時的に下げる:
#   DEPLOYMENT_IOS=26.0 DEPLOYMENT_MACOS=26.0 scripts/generate.sh
# 署名のチームは DEVELOPMENT_TEAM で変えられる（既定は個人チーム）。
set -eu
cd "$(dirname "$0")/.."
export DEPLOYMENT_IOS="${DEPLOYMENT_IOS:-27.0}"
export DEPLOYMENT_MACOS="${DEPLOYMENT_MACOS:-27.0}"
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-DJ6Z82ND37}"
if [ ! -d Models/MoGe2S.mlpackage ]; then
  echo "注意: Models/MoGe2S.mlpackage がありません。Tools/ModelConversion/README.md の手順で生成してください（深度推定なしで動きます）。" >&2
fi
xcodegen generate
echo "iOS ${DEPLOYMENT_IOS} / macOS ${DEPLOYMENT_MACOS}、チーム ${DEVELOPMENT_TEAM} で生成しました。"
