//
//  MitameEngine.h
//  Mitame
//
//  hidpi-mirror（https://github.com/pasky/hidpi-mirror、MIT License、
//  Copyright (c) 2026 Petr Baudis）の処理を、アプリから呼べる形にしたもの。
//  元は「起動したら動き続け、困ったら exit して launchd に起動し直してもらう」
//  コマンドだったので、開始・停止・作り直しを関数で呼べるように変えている。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 見た目 width×height の HiDPI 仮想ディスプレイを作り、画面をそこへミラーする。
/// builtin が YES なら内蔵ディスプレイ、NO なら vendor の外部モニターが対象。
/// すでに動いていれば一度止めてから作り直す。画面がなければ（抜いている・閉じている）、出てくるのを待つ。
/// 作れなかったときだけ NO。
/// 外部モニターは vendor・model・serial で見分ける（model・serial が 0 なら問わない）。
/// 内蔵を選んでいて外部モニターもあるときは、メインの画面は変えない。
BOOL MitameStart(unsigned int width, unsigned int height, BOOL builtin,
                 uint32_t vendor, uint32_t model, uint32_t serial);

/// ミラーを外して仮想ディスプレイを消す。モニターは元の解像度に戻る。
void MitameStop(void);

/// 今の設定のまま作り直す（メニューの「作り直す」・ウォッチドッグ用）。
void MitameRebuild(void);

/// 利用者がオンにしているか（モニターを抜いている間もオンのまま）。
BOOL MitameIsRunning(void);

/// いま仮想ディスプレイがあってミラーしているか（モニターを抜いている間は NO）。
BOOL MitameIsMirroring(void);

/// つながっている画面（内蔵と外部モニター。仮想ディスプレイは除く）の一覧。
/// 各要素のキー：vendor・model・serial・nativeWidth・nativeHeight・builtin（NSNumber）、
/// name（NSString、ミラー中のモニターは macOS の画面一覧に出てこないので無いことがある）
NSArray<NSDictionary<NSString *, id> *> *MitameListDisplays(void);

/// 状態が変わったとき（ウォッチドッグの作り直しなど）にメインキューで呼ばれる。
void MitameSetChangeHandler(void (^_Nullable handler)(void));

NS_ASSUME_NONNULL_END
