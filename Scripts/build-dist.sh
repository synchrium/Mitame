#!/bin/zsh
#
# 配る用の Mitame.app を作る（Apple Developer Program なし・アドホック署名、Intel と Apple silicon の両方入り）。
#
# 普段の Release ビルドは Xcode の Personal Team の証明書（Apple Development）で署名されていて、
# 署名の名前に Apple ID のメールアドレスと Team ID が入る。配るものにはそれを入れないため、
# 名前の無い「アドホック署名」（codesign -s -）でビルドし直す。
#
# 使い方: Scripts/build-dist.sh
# できるもの: dist/Mitame.app と dist/Mitame-<バージョン>.zip
#
set -euo pipefail

cd "${0:A:h}/.."
ROOT=$PWD
DERIVED=$ROOT/DerivedData/Mitame-dist
DIST=$ROOT/dist
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

rm -rf "$DIST"
mkdir -p "$DIST"

# アドホック署名でビルドする。
# ENABLE_CODE_COVERAGE=NO：テストのカバレッジの仕込みを入れない（入れるとソースの場所 /Users/… が実行ファイルに残る）
# DEPLOYMENT_POSTPROCESSING=YES：デバッグ用の地図（.o とソースの場所の一覧）を削る。archive のときと同じ strip
xcodebuild -project Mitame.xcodeproj -scheme Mitame -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO DEPLOYMENT_POSTPROCESSING=YES \
    PROVISIONING_PROFILE_SPECIFIER= \
    build | grep -E "error:|warning: .*sign|BUILD" || true

APP=$DERIVED/Build/Products/Release/Mitame.app
[[ -d $APP ]] || { echo "ビルドに失敗しました"; exit 1; }

# ビルドの最後に Xcode が LaunchServices に登録するので、外す
# （残ると、ここの Mitame がログイン時の起動などで使われてしまうことがある）
"$LSREGISTER" -u "$APP" 2>/dev/null || true

ditto "$APP" "$DIST/Mitame.app"

# 確かめる：署名に名前が無いこと・個人の情報が入っていないこと
echo "--- 署名"
codesign -dvv "$DIST/Mitame.app" 2>&1 | grep -E "Signature|Authority|TeamIdentifier" || true
codesign --verify --deep --strict "$DIST/Mitame.app" && echo "署名の検証: OK"
# 探す文字：この Mac のユーザー名、ソースの場所（/Users/…）、
# キーチェーンにある署名用の証明書の名前に入っているメール・証明書の ID・Team ID、プロジェクトの Team ID。
# 名前をスクリプトに直接書くと、それ自体がリポジトリに残ってしまうので、その場で調べる
words=("$(id -un)" "/Users/")
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
words+=(${(f)"$(print -r -- "$identities" | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' | sort -u)"})
words+=(${(f)"$(print -r -- "$identities" | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()' | sort -u)"})
words+=(${(f)"$(security find-certificate -a -p -c "Apple Development" 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | grep -oE 'OU *= *[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' | sort -u)"})
words+=(${(f)"$(sed -nE 's/.*"DEVELOPMENT_TEAM": "([A-Z0-9]+)".*/\1/p' Mitame.xcodeproj/project.xcproj | sort -u)"})
words=(${words:#})   # 空のものを除く
args=()
for w in $words; do args+=(-e "$w"); done
echo "探す文字: ${#words} 個"
if LC_ALL=C /usr/bin/grep -rlaF "${args[@]}" "$DIST/Mitame.app"; then
    echo "個人の情報が入っています。配らないでください"
    exit 1
fi
echo "個人の情報: なし"

# サンドボックスの外で動かす（中だと仮想ディスプレイの非公開 API と log stream が使えない）
if codesign -d --entitlements - --xml "$DIST/Mitame.app" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
    echo "アプリがサンドボックスの中になっています"
    exit 1
fi
echo "サンドボックス: 外（OK）"

# Intel と Apple silicon の両方が入っていること
ARCHS_IN=$(lipo -archs "$DIST/Mitame.app/Contents/MacOS/Mitame")
[[ $ARCHS_IN == *x86_64* && $ARCHS_IN == *arm64* ]] || { echo "Universal になっていません: $ARCHS_IN"; exit 1; }
echo "Universal: $ARCHS_IN"

# 配る zip。ditto は .app の中のシンボリックリンクを保つ。
# --norsrc --noextattr --noacl：拡張属性などを入れない（入れると「._Contents」のような ._ で始まる
# ファイルとして zip に入り、アーカイブユーティリティ以外（Mitame や Windows）ではそのまま見えてしまう。
# 署名は拡張属性ではなく _CodeSignature などのファイルにあるので、外しても困らない）
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$DIST/Mitame.app/Contents/Info.plist")
ditto -c -k --norsrc --noextattr --noacl --keepParent "$DIST/Mitame.app" "$DIST/Mitame-$VERSION.zip"
if zipinfo -1 "$DIST/Mitame-$VERSION.zip" | grep -qE '(^|/)\._'; then
    echo "zip に ._ で始まるファイルが入っています"
    exit 1
fi
echo "--- できたもの"
ls -l "$DIST"
