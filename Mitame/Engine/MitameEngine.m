//
//  MitameEngine.m
//  Mitame
//
//  元: hidpi-mirror.m（https://github.com/pasky/hidpi-mirror 12cac7d）
//  MIT License, Copyright (c) 2026 Petr Baudis
//
//  Mitame での変更点（日本語のコメントの部分）:
//  - main() をやめて MitameStart / MitameStop / MitameRebuild にした
//  - ウォッチドッグは exit せず、アプリの中で仮想ディスプレイだけを作り直す
//  - 対象のモニターの vendor・大きさは引数で受け取る
//
// Original header:
// hidpi-mirror: force HiDPI rendering on a non-4K external display by
// creating a virtual HiDPI display (private CGVirtualDisplay API, same
// technique as BetterDummy/BetterDisplay) and mirroring the physical
// display onto it. The GPU downsamples the 2x framebuffer -> sharp text.

#import "MitameEngine.h"
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// ---- Private CoreGraphics API declarations (typing only; classes are
// ---- instantiated via NSClassFromString so we don't need link symbols) ----
@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
// --------------------------------------------------------------------------

static uint32_t gVendor = 4268; // 0x10AC = Dell; override via argv[3]
// Mitame: 同じメーカーのモニターが 2 台あっても見分けられるように、型番とシリアルでも探す
static uint32_t gModel = 0, gSerial = 0;
// Mitame: YES なら外部モニターではなく内蔵ディスプレイを HiDPI にする
static BOOL gBuiltin = NO;
// Mitame: メインの画面を、利用者が使っていたとおりにしておくための覚え。
// gTargetWasMain：HiDPI にする画面がメインだったか（最初は YES＝元の hidpi-mirror と同じ動き）。
// gOtherMain：そうでないとき、メインだった実際の画面。
// 切り替える直前と、落ち着いて動いている間（システム設定でメインを変えたとき）に覚え直す
static BOOL gTargetWasMain = YES;
static CGDirectDisplayID gOtherMain = 0;

// Mitame: gTargetWasMain を、HiDPI にする画面ごとに設定ファイルにも残す（再起動のあと、
// 画面がまだ見えないうちに起動しても、前の使い方がわかるように）。
// キーは targetWasMain.builtin / targetWasMain.<vendor>-<model>-<serial>
static NSString *mainKey(BOOL builtin, uint32_t vendor, uint32_t model, uint32_t serial) {
    return builtin ? @"targetWasMain.builtin"
                   : [NSString stringWithFormat:@"targetWasMain.%u-%u-%u", vendor, model, serial];
}

static void saveTargetWasMain(void) {
    [NSUserDefaults.standardUserDefaults setBool:gTargetWasMain
                                          forKey:mainKey(gBuiltin, gVendor, gModel, gSerial)];
}
#define MITAME_VIRTUAL_VENDOR 0xB33F

static CGVirtualDisplay *gVirtual = nil;  // keep-alive
static CGDirectDisplayID gVirtualID = 0;
static unsigned int gLW = 2048, gLH = 1152; // desired "looks like" size

// Mitame: d が HiDPI にしたい画面か（内蔵なら内蔵かどうかだけ、外部ならメーカー・型番・シリアル）
static BOOL isTarget(CGDirectDisplayID d) {
    if (d == gVirtualID) return NO;
    if (gBuiltin) return CGDisplayIsBuiltin(d);
    if (CGDisplayIsBuiltin(d)) return NO;
    return CGDisplayVendorNumber(d) == gVendor &&
           (!gModel || CGDisplayModelNumber(d) == gModel) &&
           (!gSerial || CGDisplaySerialNumber(d) == gSerial);
}

static CGDirectDisplayID findDell(void) {
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(16, ids, &count);
    for (uint32_t i = 0; i < count; i++)
        if (isTarget(ids[i])) return ids[i];
    return kCGNullDirectDisplay;
}

// Mitame: メインになっている実際の画面。仮想ディスプレイ（Mitame・hidpi-mirror）がメインなら、
// それを映している画面を返す
static CGDirectDisplayID physicalMain(void) {
    CGDirectDisplayID main = CGMainDisplayID();
    if (main != gVirtualID && CGDisplayVendorNumber(main) != MITAME_VIRTUAL_VENDOR)
        return main;
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return main;
    for (uint32_t i = 0; i < n; i++)
        if (CGDisplayMirrorsDisplay(ids[i]) == main) return ids[i];
    return main;
}

static BOOL displayOnline(CGDirectDisplayID d) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (!d || CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < n; i++)
        if (ids[i] == d) return YES;
    return NO;
}

// Mitame: HiDPI にしている画面と仮想ディスプレイのほかに、ふつうの画面（内蔵・外部）があるか
static BOOL otherOnline(void) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < n; i++) {
        CGDirectDisplayID d = ids[i];
        if (d == gVirtualID || isTarget(d)) continue;
        if (CGDisplayVendorNumber(d) == MITAME_VIRTUAL_VENDOR) continue;
        if (CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay) continue;
        return YES;
    }
    return NO;
}

// Find the HiDPI mode (points = gLW x gLH, pixels = 2x) on the virtual
// display. Returns a retained mode ref, or NULL.
static CGDisplayModeRef copyWantedMode(void) {
    CFStringRef k = kCGDisplayShowDuplicateLowResolutionModes;
    CFBooleanRef v = kCFBooleanTrue;
    CFDictionaryRef opts = CFDictionaryCreate(
        NULL, (const void **)&k, (const void **)&v, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(gVirtualID, opts);
    CFRelease(opts);
    if (!modes) { NSLog(@"no modes for virtual display?"); return NULL; }
    CGDisplayModeRef want = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m =
            (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetWidth(m) == gLW &&
            CGDisplayModeGetHeight(m) == gLH &&
            CGDisplayModeGetPixelWidth(m) == 2 * gLW) {
            want = (CGDisplayModeRef)CFRetain(m);
            break;
        }
    }
    CFRelease(modes);
    if (!want) NSLog(@"HiDPI mode %ux%u@2x not found!", gLW, gLH);
    return want;
}

// YES unless the built-in or the Dell is online and awake (other virtual
// displays, e.g. other apps', may claim to be awake regardless). While
// the displays sleep (incl. dark wakes), WindowServer reports the Dell as
// unmirrored, but can't reconfigure anything: transactions block 10s+
// and fail (err 1014), often spanning system sleep. It restores the
// saved arrangement on wake by itself, so just stay out of its way.
static BOOL displaysAsleep(void) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return YES;
    for (uint32_t i = 0; i < n; i++)
        if ((CGDisplayIsBuiltin(ids[i]) || isTarget(ids[i])) &&
            !CGDisplayIsAsleep(ids[i]))
            return NO;
    return YES;
}

// After a reconnect (or our restart), the mirror comes back -- restored by
// WindowServer or by us -- but often with the built-in display as main;
// reclaim the main role for the mirror set. Translate the WHOLE
// arrangement so the virtual display lands on (0,0): setting just one
// display's origin is silently normalized away. Separate transaction
// after the mirror. Returns YES once the mirror set is main.
// Mitame: 仮想ディスプレイに限らず、指定した画面 target をメインにできるようにした
static BOOL makeMain(CGDirectDisplayID target) {
    CGRect vb = CGDisplayBounds(target);
    int32_t dx = (int32_t)vb.origin.x, dy = (int32_t)vb.origin.y;
    if (dx == 0 && dy == 0) {
        NSLog(@"claimMain: %s already main",
              target == gVirtualID ? "mirror set" : "previous main display");
        return YES;
    }
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return NO;
    CGDisplayConfigRef cfg;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay)
            continue; // mirror followers inherit their master's origin
        CGRect b = CGDisplayBounds(ids[i]);
        if (CGConfigureDisplayOrigin(cfg, ids[i], (int32_t)b.origin.x - dx,
                                     (int32_t)b.origin.y - dy) !=
            kCGErrorSuccess) {
            // Never persist a partial translation (e.g. hot-unplug).
            CGCancelDisplayConfiguration(cfg);
            NSLog(@"claimMain: configuring origin of %u failed", ids[i]);
            return NO;
        }
    }
    CGError err = CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently);
    NSLog(@"claimMain: shift arrangement by (%d,%d): %s (err=%d)", -dx, -dy,
          err == kCGErrorSuccess ? "OK" : "FAILED", err);
    return err == kCGErrorSuccess;
}

static BOOL claimMain(void) {
    // Mitame: HiDPI にした画面がもともとメインでなく、ほかの画面があるなら、
    // メインは前の画面のまま（ミラーで macOS が動かしてしまったら戻す）
    if (!gTargetWasMain && otherOnline()) {
        if (!displayOnline(gOtherMain)) {
            // 前のメインの画面が分からない・いないとき（再起動した直後など）は、
            // 内蔵があれば内蔵、なければほかの最初の画面
            CGDirectDisplayID ids[16];
            uint32_t n = 0;
            CGDirectDisplayID pick = 0;
            if (CGGetOnlineDisplayList(16, ids, &n) == kCGErrorSuccess) {
                for (uint32_t i = 0; i < n; i++) {
                    CGDirectDisplayID d = ids[i];
                    if (d == gVirtualID || isTarget(d)) continue;
                    if (CGDisplayVendorNumber(d) == MITAME_VIRTUAL_VENDOR) continue;
                    if (CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay) continue;
                    if (!pick || CGDisplayIsBuiltin(d)) pick = d;
                }
            }
            if (!pick) {
                NSLog(@"claimMain: no other display, leaving main alone");
                return YES;
            }
            NSLog(@"claimMain: previous main display unknown, using %u", pick);
            gOtherMain = pick;
        }
        return makeMain(gOtherMain);
    }
    return makeMain(gVirtualID);
}

// Mitame: 落ち着いて動いている間に、どの画面がメインかを覚え直す（システム設定で変えたとき用）
static void learnMain(void) {
    BOOL targetMain = (CGMainDisplayID() == gVirtualID);
    CGDirectDisplayID other = targetMain ? gOtherMain : physicalMain();
    if (targetMain == gTargetWasMain && other == gOtherMain) return;
    gTargetWasMain = targetMain;
    gOtherMain = other;
    saveTargetWasMain();
    NSLog(@"main display is now %s (%u)", targetMain ? "the mirror set" : "another display",
          targetMain ? gVirtualID : other);
}

// Bumped on every mirror attempt and whenever the Dell is offline or the
// displays sleep, invalidating pending claimMain follow-ups.
static unsigned gMirrorSeq = 0;
// Claim main once per (re)appearance of the Dell (and at startup) --
// even when WindowServer restored the mirror by itself, which restores
// the mirror but not reliably the main role. Manual rearranging is
// respected until the next reconnect.
static BOOL gClaimPending = YES;
static int gClaimFailures = 0;
static CGDirectDisplayID gLastDell = kCGNullDirectDisplay;

static void armClaim(void) {
    gClaimPending = YES;
    gClaimFailures = 0;
}

// Keep the claim pending until it succeeds (retried by the next polls),
// but give up after a few failures -- each can block for seconds.
static void tryClaim(void) {
    if (claimMain()) {
        gClaimPending = NO;
    } else if (++gClaimFailures >= 5) {
        NSLog(@"claimMain: giving up until the next reconnect");
        gClaimPending = NO;
    }
}

// Mitame: 利用者がオンにしているか（仮想ディスプレイがあるかとは別。
// モニターを抜いている間は仮想ディスプレイを消すが、オンのまま待つ）
static BOOL gWanted = NO;
// Mitame: macOS から「眠る」の知らせが来てから「起きた」の少しあとまで YES。
// その間はミラーに触らない（眠りかけに画面の状態を見ると、ミラーが外れたように見えて
// かけ直しが 10 秒以上止まって失敗するため）
static BOOL gSystemAsleep = NO;
static CFAbsoluteTime gStartTime; // 仮想ディスプレイを作った時刻（ウォッチドッグ用）
static BOOL createVirtual(void);
static void destroyVirtual(void);
static void notifyChange(void);

// Mitame: 外部モニターを本来の 1 倍のモード（ネイティブ・一番高いリフレッシュレート）にする。
// ミラーを外したあと、macOS が「1920×1080 を 3840×2160 で描く」ような HiDPI のモードを残すことがあり、
// その状態からミラーにすると、マウスや文字入力のたびに外部モニターがちらつく（2026-11-14 に確認）。
// 内蔵ディスプレイではちらつきが出ていないので触らない。設定はこのログインの間だけ
static void setNativeMode(CGDirectDisplayID d) {
    if (!d || CGDisplayIsBuiltin(d)) return;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(d);
    if (cur) {
        BOOL ok = (CGDisplayModeGetIOFlags(cur) & kDisplayModeNativeFlag) &&
                  CGDisplayModeGetPixelWidth(cur) == CGDisplayModeGetWidth(cur);
        CFRelease(cur);
        if (ok) return;
    }
    CFStringRef k = kCGDisplayShowDuplicateLowResolutionModes;
    CFBooleanRef v = kCFBooleanTrue;
    CFDictionaryRef opts = CFDictionaryCreate(
        NULL, (const void **)&k, (const void **)&v, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, opts);
    CFRelease(opts);
    if (!modes) return;
    CGDisplayModeRef best = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (!(CGDisplayModeGetIOFlags(m) & kDisplayModeNativeFlag)) continue;
        if (CGDisplayModeGetPixelWidth(m) != CGDisplayModeGetWidth(m)) continue; // 1 倍だけ
        if (!best || CGDisplayModeGetPixelWidth(m) * CGDisplayModeGetPixelHeight(m) >
                         CGDisplayModeGetPixelWidth(best) * CGDisplayModeGetPixelHeight(best) ||
            (CGDisplayModeGetPixelWidth(m) == CGDisplayModeGetPixelWidth(best) &&
             CGDisplayModeGetRefreshRate(m) > CGDisplayModeGetRefreshRate(best)))
            best = m;
    }
    if (best) {
        CGDisplayConfigRef cfg;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            CGConfigureDisplayWithDisplayMode(cfg, d, best, NULL);
            CGError err = CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
            NSLog(@"set native mode %zux%zu@%.0f on %u: err=%d",
                  CGDisplayModeGetWidth(best), CGDisplayModeGetHeight(best),
                  CGDisplayModeGetRefreshRate(best), d, err);
        }
    }
    CFRelease(modes);
}

// Mitame: HiDPI にする画面と仮想ディスプレイ以外の、ふつうの画面のモードを今のままにする
static void keepOtherModes(CGDisplayConfigRef cfg, CGDirectDisplayID target) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return;
    for (uint32_t i = 0; i < n; i++) {
        CGDirectDisplayID d = ids[i];
        if (d == target || d == gVirtualID) continue;
        if (CGDisplayVendorNumber(d) == MITAME_VIRTUAL_VENDOR) continue;
        if (CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay) continue;
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);
        if (!m) continue;
        CGConfigureDisplayWithDisplayMode(cfg, d, m, NULL);
        CFRelease(m);
    }
}

static void mirrorNow(void) {
    static BOOL wasOffline = NO, wasAsleep = NO;
    if (!gWanted || gSystemAsleep) return;
    if (displaysAsleep()) {
        gMirrorSeq++;
        if (!wasAsleep) NSLog(@"displays asleep, leaving configuration alone");
        wasAsleep = YES;
        return;
    }
    if (wasAsleep) NSLog(@"displays awake");
    wasAsleep = NO;
    CGDirectDisplayID dell = findDell();
    if (dell == kCGNullDirectDisplay) {
        if (!wasOffline)
            NSLog(@"display not online (KVM switched away?), waiting...");
        wasOffline = YES;
        gMirrorSeq++;
        armClaim();
        // Mitame: 見えない画面として残らないように、仮想ディスプレイを消す
        if (gVirtual) {
            NSLog(@"removing virtual display while the monitor is away");
            destroyVirtual();
            notifyChange();
        }
        return;
    }
    wasOffline = NO;
    // Mitame: モニターが（また）あるのに仮想ディスプレイがなければ作る
    if (!gVirtual) {
        // macOS が覚えている配置から自分でミラーを戻すこともあるので、作る前に本来のモードにしておく
        setNativeMode(dell);
        if (!createVirtual()) return; // 次の見回りでまた試す
        gStartTime = CFAbsoluteTimeGetCurrent();
        armClaim();
        notifyChange();
    }
    gLastDell = dell;
    BOOL mirrored = (CGDisplayMirrorsDisplay(dell) == gVirtualID);
    // NB: CGDisplayCopyDisplayMode can return NULL (CFAutorelease(NULL)
    // would crash), e.g. while the virtual display is the master of a
    // hardware mirror set -- then the Dell reflects the set's mode.
    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(gVirtualID);
    if (!curMode && mirrored) curMode = CGDisplayCopyDisplayMode(dell);
    BOOL rightMode =
        curMode && CGDisplayModeGetPixelWidth(curMode) == 2 * gLW;
    if (curMode) CFRelease(curMode);
    if (mirrored && rightMode) {
        if (gClaimPending) tryClaim();
        else learnMain();
        return;
    }
    // Mitame: ふつうの表示の外部モニターをミラーにする前に、本来の 1 倍のモードに戻す（ちらつき対策）
    if (!mirrored) setNativeMode(dell);
    CGDisplayModeRef want = rightMode ? NULL : copyWantedMode();
    NSLog(@"mirrorNow: mirrored=%d rightMode=%d want=%s", mirrored, rightMode,
          want ? "found" : "NULL");
    // Single transaction: set HiDPI mode AND mirror atomically.
    CGError err = kCGErrorFailure;
    CGConfigureOption options[] = {kCGConfigureForSession,
                                   kCGConfigurePermanently};
    for (int i = 0; i < 2 && err != kCGErrorSuccess; i++) {
        CGDisplayConfigRef cfg;
        CGBeginDisplayConfiguration(&cfg);
        if (want) {
            CGError e1 = CGConfigureDisplayWithDisplayMode(cfg, gVirtualID,
                                                           want, NULL);
            NSLog(@"  CGConfigureDisplayWithDisplayMode: err=%d", e1);
        }
        if (!mirrored) CGConfigureDisplayMirrorOfDisplay(cfg, dell, gVirtualID);
        // Mitame: ほかの画面（内蔵など）は今のモードのままと伝える。伝えないと、配置を保存するときに
        // macOS が古い保存の値に戻すことがある（内蔵が「スペースを拡大」から「デフォルト」に戻った、2026-11-14）
        keepOtherModes(cfg, dell);
        err = CGCompleteDisplayConfiguration(cfg, options[i]);
        NSLog(@"mode+mirror transaction (%s): %s (err=%d)",
              i == 0 ? "session" : "permanent",
              err == kCGErrorSuccess ? "OK" : "FAILED", err);
    }
    if (want) CFRelease(want);
    unsigned seq = ++gMirrorSeq;
    // Claim main if WE just (re)established the mirror, or the Dell just
    // reappeared -- not after a mode-only repair otherwise.
    BOOL claim = (!mirrored || gClaimPending) && err == kCGErrorSuccess;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        // Skip if superseded (new attempt, disconnect, display sleep --
        // reconfiguring then blocks and fails) or the mirror didn't take.
        if (claim && seq == gMirrorSeq && !displaysAsleep() &&
            findDell() == dell && CGDisplayMirrorsDisplay(dell) == gVirtualID) {
            tryClaim();
        }
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(gVirtualID);
        if (!cur) return;
        CFAutorelease(cur);
        NSLog(@"post-transaction actual mode: %zux%zu points, %zux%zu pixels",
              CGDisplayModeGetWidth(cur), CGDisplayModeGetHeight(cur),
              CGDisplayModeGetPixelWidth(cur), CGDisplayModeGetPixelHeight(cur));
    });
}

static void unmirror(void) {
    CGDirectDisplayID dell = findDell();
    if (dell == kCGNullDirectDisplay) return;
    if (CGDisplayMirrorsDisplay(dell) == kCGNullDirectDisplay) return;
    CGDisplayConfigRef cfg;
    CGBeginDisplayConfiguration(&cfg);
    CGConfigureDisplayMirrorOfDisplay(cfg, dell, kCGNullDirectDisplay);
    // Session only: a stop/restart of this agent must not persist an
    // unmirrored arrangement that WindowServer would later restore.
    CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    NSLog(@"unmirrored");
    // Mitame: ミラーを外したあとに変わったモードが残らないように、本来の 1 倍のモードに戻す
    setNativeMode(dell);
}

static void reconfigCB(CGDirectDisplayID d, CGDisplayChangeSummaryFlags flags,
                       void *userInfo) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    // The Dell (dis)appeared: (re)claim main once it's back, even if a
    // poll never saw it offline (quick replug, or unplugged while asleep);
    // a removal also invalidates pending claimMain follow-ups.
    if (((flags & kCGDisplayRemoveFlag) && d == gLastDell) ||
        ((flags & kCGDisplayAddFlag) && isTarget(d))) {
        gMirrorSeq++;
        armClaim();
    }
    // Mitame: モニターが抜かれたら、すぐに仮想ディスプレイを片付けに行く
    if ((flags & kCGDisplayRemoveFlag) && d != gVirtualID && d == gLastDell) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ mirrorNow(); });
    }
    if (flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag)) notifyChange();
    if (flags & kCGDisplayAddFlag) {
        // Display (re)appeared -- e.g. KVM switched back. Give WindowServer
        // a moment to settle, then re-establish the mirror.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ mirrorNow(); });
    }
}

// ---- Watchdog: WindowServer failing to feed our virtual display ----
// When the Dell is unplugged, our virtual display instance (even a fresh
// one) can go bad: WindowServer logs "VirtualDisplay::clone_update failed
// to copy surface" -- a burst at the unplug, up to once per frame (120/s)
// later -- freezing the built-in display, and a reconnected Dell stays
// black. Our own CoreGraphics view sees nothing wrong (it goes stale
// too). A fresh process with a fresh virtual display fixes it, so watch
// WindowServer's log and exit -- launchd (KeepAlive) restarts us. The log
// line doesn't say WHICH virtual display failed, so it might be another
// app's; the restart budget below bounds the damage.
#ifndef WATCHDOG_MATCH // overridable for testing
#define WATCHDOG_MATCH "VirtualDisplay::clone_update failed"
#endif
#ifndef WATCHDOG_STATE // overridable for testing
#define WATCHDOG_STATE @"Mitame.watchdog"
#endif
// All watchdog state lives on its own serial queue: the main queue runs
// CoreGraphics transactions that can block for 10s+.
static dispatch_queue_t gWDQueue;
static NSTask *gLogTask = nil;
// Mitame: ウォッチドッグは動いている間だけ。止めたあとに log stream を起こし直さないための印
static BOOL gWDActive = NO;      // on gWDQueue
static BOOL gWDLatched = NO;     // on gWDQueue。作り直しを頼んだら下ろす
static void (^gChangeHandler)(void) = nil;
static void notifyChange(void) {
    void (^h)(void) = gChangeHandler;
    if (h) dispatch_async(dispatch_get_main_queue(), h);
}

// Restarts can't help if the failing virtual display isn't ours (another
// app's): allow at most 10 watchdog restarts in any 30 minutes, tracked
// across restarts in a file. (Not fewer: every unplug of the Dell breaks
// our virtual display and costs one restart -- think KVM switching.)
// Returns 0 (and records the restart) if allowed now, else the number of
// seconds until it will be.
static double restartWait(CFAbsoluteTime now) {
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:WATCHDOG_STATE];
    NSString *old = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    NSMutableArray *recent = [NSMutableArray array];
    double oldest = now;
    for (NSString *f in [old componentsSeparatedByString:@" "]) {
        double t = f.doubleValue;
        if (now - t < 1800 && t <= now) {
            [recent addObject:f];
            if (t < oldest) oldest = t;
        }
    }
    if (recent.count >= 10) return oldest + 1800 - now;
    [recent addObject:[NSString stringWithFormat:@"%f", now]];
    [[recent componentsJoinedByString:@" "]
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding
              error:NULL];
    return 0;
}

// A burst was seen: the display stays broken even after the log goes
// silent, so a restart that isn't allowed yet is deferred, not dropped.
static void watchdogRestart(void) { // on gWDQueue
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // Minimum uptime, so a persistent problem can't become a tight loop.
    double wait = gStartTime + 60 - now;
    if (wait <= 0) wait = restartWait(now);
    if (wait > 0) {
        NSLog(@"watchdog: a virtual display is failing, restart deferred "
              @"by %.0fs (uptime / restart budget)", wait);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(wait * NSEC_PER_SEC) + 1),
                       gWDQueue, ^{ watchdogRestart(); });
        return;
    }
    NSLog(@"watchdog: WindowServer keeps failing to update a virtual "
          @"display (" WATCHDOG_MATCH "), rebuilding");
    // Mitame: exit せず、メインキューで仮想ディスプレイだけを作り直す。
    // 次の失敗でまた反応できるように印を下ろす。
    gWDLatched = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (MitameIsRunning()) MitameRebuild();
    });
}

static void watchdogHit(void) { // on gWDQueue
    static CFAbsoluteTime windowStart = 0;
    static int hits = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - windowStart > 10) { windowStart = now; hits = 0; }
    // Never healthy, but require a few (seen: just 5 at an unplug, then
    // silence with the Dell black on replug).
    if (!gWDActive || ++hits < 3 || gWDLatched) return;
    gWDLatched = YES;
    watchdogRestart();
}

static void startWatchdog(void);
static void restartWatchdogLater(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                   gWDQueue, ^{ if (gWDActive && !gLogTask.running) startWatchdog(); });
}

static void startWatchdog(void) { // on gWDQueue
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    t.arguments = @[ @"stream", @"--style", @"compact", @"--predicate",
        @"process == \"WindowServer\" AND eventMessage CONTAINS \""
        WATCHDOG_MATCH "\"" ];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSMutableData *buf = [NSMutableData data]; // pipe reads aren't lines
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        dispatch_async(gWDQueue, ^{
            if (!d.length) return; // EOF; terminationHandler respawns
            [buf appendData:d];
            const char *b = buf.bytes, *nl;
            size_t off = 0, len = buf.length;
            while ((nl = memchr(b + off, '\n', len - off))) {
                // Count matching lines (skips log stream's header line).
                NSString *l = [[NSString alloc]
                    initWithBytes:b + off length:nl - (b + off)
                         encoding:NSUTF8StringEncoding];
                if ([l containsString:@"WindowServer"] &&
                    [l containsString:@WATCHDOG_MATCH])
                    watchdogHit();
                off = nl - b + 1;
            }
            [buf replaceBytesInRange:NSMakeRange(0, off) withBytes:NULL
                              length:0];
        });
        if (!d.length) h.readabilityHandler = nil;
    };
    t.terminationHandler = ^(NSTask *task) {
        if (!gWDActive) return; // Mitame: 止めたので起こし直さない
        NSLog(@"watchdog: log stream exited (%d), restarting it in 10s",
              task.terminationStatus);
        restartWatchdogLater();
    };
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) {
        NSLog(@"watchdog: can't run log stream (%@), retrying in 10s", err);
        restartWatchdogLater();
        return;
    }
    gLogTask = t;
}

// Don't leave an orphaned log stream behind when we exit (atexit; may run
// on any thread, incl. gWDQueue -- so no dispatch_sync here).
static void killLogStream(void) {
    NSTask *t = gLogTask;
    if (t.running) { t.terminationHandler = nil; [t terminate]; }
}

// ======================================================================
// Mitame: ここから下はアプリから呼ぶための入口（元の main() を分けたもの）
// ======================================================================

static dispatch_source_t gPoll = nil;
static BOOL gCallbackRegistered = NO;
static id gActivity = nil;

static void startWatchdogIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWDQueue = dispatch_queue_create("watchdog", DISPATCH_QUEUE_SERIAL);
        atexit(killLogStream);
    });
    dispatch_async(gWDQueue, ^{
        if (gWDActive) return;
        gWDActive = YES;
        gWDLatched = NO;
        if (!gLogTask.running) startWatchdog();
    });
}

static void stopWatchdog(void) {
    if (!gWDQueue) return;
    dispatch_async(gWDQueue, ^{
        gWDActive = NO;
        killLogStream();
        gLogTask = nil;
    });
}

// 仮想ディスプレイを消す。ミラーを外すのはディスプレイが起きているときだけ
// （寝ているときは設定の変更が 10 秒以上止まって失敗するため。消せばミラーも外れる）。
static void destroyVirtual(void) {
    if (!gVirtual) return;
    if (!displaysAsleep()) unmirror();
    gMirrorSeq++;
    gVirtual = nil; // 解放すると仮想ディスプレイが消える
    gVirtualID = 0;
    gLastDell = kCGNullDirectDisplay;
}

static BOOL createVirtual(void) {
    CGVirtualDisplayDescriptor *desc =
        [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    if (!desc) { NSLog(@"CGVirtualDisplay API unavailable"); return NO; }
    desc.name = @"Mitame";
    desc.queue = dispatch_get_main_queue();
    // Mitame: 縦横比はモニターに合わせる（元は 16:9 の 5120x2880 決め打ち）。
    // 一番大きいモードが maxPixels になるように、2 倍の大きさが 5120 を超えるときは広げる
    unsigned int maxW = MAX(5120u, gLW * 2);
    unsigned int maxH = (unsigned int)((double)maxW * gLH / gLW + 0.5) & ~1u;
    desc.sizeInMillimeters = CGSizeMake(553.7, 553.7 * gLH / gLW);
    desc.maxPixelsWide = maxW;
    desc.maxPixelsHigh = maxH;
    // sRGB-ish primaries
    desc.redPrimary   = CGPointMake(0.680, 0.320);
    desc.greenPrimary = CGPointMake(0.265, 0.690);
    desc.bluePrimary  = CGPointMake(0.150, 0.060);
    desc.whitePoint   = CGPointMake(0.3127, 0.3290);
    // Fresh identity (macOS stores mode prefs per vendor+product; the
    // original identity has a stale 3840x2160@1x preference stuck to it)
    desc.vendorID  = MITAME_VIRTUAL_VENDOR;
    desc.productID = 0x2049 + gLW / 16 + gLH; // identity varies per size
    desc.serialNum = 1;
    desc.terminationHandler = ^(id a, id b) {
        // Mitame: 元は exit(0)。アプリは終わらせず、状態が変わったことだけ知らせる
        NSLog(@"virtual display terminated");
        notifyChange();
    };

    gVirtual = [[NSClassFromString(@"CGVirtualDisplay") alloc]
                   initWithDescriptor:desc];
    if (!gVirtual) { NSLog(@"failed to create virtual display"); return NO; }
    gVirtualID = gVirtual.displayID;

    CGVirtualDisplaySettings *settings =
        [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = 1;
    // Full mode list: macOS only synthesizes proper HiDPI variants for
    // a rich list topped by maxPixels.
    Class modeCls = NSClassFromString(@"CGVirtualDisplayMode");
    // WindowServer ignores programmatic mode changes on virtual displays
    // and always runs the PREFERRED (first listed) mode -- so put the
    // desired mode first; keep the rest for HiDPI mode-list synthesis.
    NSMutableArray *modes = [NSMutableArray arrayWithObject:
        [[modeCls alloc] initWithWidth:gLW * 2 height:gLH * 2 refreshRate:60]];
    // Mitame: 元の {5120x2880, 4608x2592, ...} と同じ割合で、縦横比をモニターに合わせる
    double factors[] = {1.0, 0.9, 0.8, 0.75, 0.65625, 0.625};
    for (size_t i = 0; i < sizeof(factors) / sizeof(factors[0]); i++) {
        unsigned int w = (unsigned int)(maxW * factors[i] + 0.5) & ~1u;
        unsigned int h = (unsigned int)(maxH * factors[i] + 0.5) & ~1u;
        if (w != gLW * 2)
            [modes addObject:[[modeCls alloc] initWithWidth:w
                                                     height:h
                                                refreshRate:60]];
    }
    settings.modes = modes;
    NSLog(@"UI will look like %ux%u (framebuffer %ux%u)", gLW, gLH, gLW*2, gLH*2);
    if (![gVirtual applySettings:settings]) {
        NSLog(@"applySettings failed");
        gVirtual = nil;
        gVirtualID = 0;
        return NO;
    }
    NSLog(@"virtual display up, id=%u", gVirtualID);
    return YES;
}

// Mitame: 眠る・起きるの知らせを受け取る（コマンドの hidpi-mirror にはなかったもの）
static void registerSleepObservers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static unsigned sleepGen = 0;
        NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
        for (NSNotificationName name in @[ NSWorkspaceWillSleepNotification,
                                           NSWorkspaceScreensDidSleepNotification ]) {
            [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *n) {
                sleepGen++;
                gMirrorSeq++; // 予定していた claimMain も取り消す
                if (!gSystemAsleep) NSLog(@"%@: pausing", n.name);
                gSystemAsleep = YES;
            }];
        }
        for (NSNotificationName name in @[ NSWorkspaceDidWakeNotification,
                                           NSWorkspaceScreensDidWakeNotification ]) {
            [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *n) {
                if (!gSystemAsleep) return;
                NSLog(@"%@: resuming in 3s", n.name);
                unsigned gen = sleepGen;
                // 起きた直後は macOS が自分でミラーを戻すので、少し待ってから見る
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                               dispatch_get_main_queue(), ^{
                    if (gen != sleepGen) return; // その間にまた眠った
                    gSystemAsleep = NO;
                    mirrorNow();
                });
            }];
        }
    });
}

BOOL MitameStart(unsigned int width, unsigned int height, BOOL builtin,
                 uint32_t vendor, uint32_t model, uint32_t serial) {
    // どの画面がメインだったかは、今のミラーを外す前に見る。
    // 新しく HiDPI にする画面を探すため、いったん新しい設定に入れ替えてから戻す
    {
        BOOL ob = gBuiltin;
        uint32_t ov = gVendor, om = gModel, os = gSerial;
        gBuiltin = builtin; gVendor = vendor; gModel = model; gSerial = serial;
        CGDirectDisplayID target = findDell();
        gBuiltin = ob; gVendor = ov; gModel = om; gSerial = os;
        if (target) {
            CGDirectDisplayID pm = physicalMain();
            gTargetWasMain = (pm == target);
            if (!gTargetWasMain) gOtherMain = pm;
            [NSUserDefaults.standardUserDefaults setBool:gTargetWasMain
                                                  forKey:mainKey(builtin, vendor, model, serial)];
        } else {
            // 見えないとき（抜いている・ふたを閉じている・起動した直後）は、保存した覚えを使う。
            // 覚えがなければ YES（元の hidpi-mirror と同じ動き）
            id saved = [NSUserDefaults.standardUserDefaults
                objectForKey:mainKey(builtin, vendor, model, serial)];
            gTargetWasMain = saved ? [saved boolValue] : YES;
            gOtherMain = 0; // 前のメインの画面はつながったときに探す
        }
        NSLog(@"target was main: %d (other main %u)", gTargetWasMain, gOtherMain);
    }
    destroyVirtual();
    gLW = width;
    gLH = height;
    gBuiltin = builtin;
    gVendor = vendor;
    gModel = model;
    gSerial = serial;
    gWanted = YES;
    armClaim();
    registerSleepObservers();

    // Opt out of App Nap: as a windowless background agent we are a
    // prime timer-coalescing victim -- observed in the wild as the 10s
    // poll silently never firing again after days of sleep/wake
    // cycles. (Also DISPATCH_TIMER_STRICT below.)
    if (!gActivity)
        gActivity = [[NSProcessInfo processInfo]
            beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                              reason:@"display watchdog must keep polling"];

    startWatchdogIfNeeded();

    if (!gCallbackRegistered) {
        CGDisplayRegisterReconfigurationCallback(reconfigCB, NULL);
        gCallbackRegistered = YES;
    }
    // モニターがあれば、ここで仮想ディスプレイを作ってミラーする（なければつながるのを待つ）
    mirrorNow();
    // Belt and braces: reconfiguration callbacks have proven flaky
    // across login sessions, so also poll (cheap no-op when all good).
    if (!gPoll) {
        gPoll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0,
                                       DISPATCH_TIMER_STRICT,
                                       dispatch_get_main_queue());
        dispatch_source_set_timer(gPoll,
                                  dispatch_time(DISPATCH_TIME_NOW,
                                                10 * NSEC_PER_SEC),
                                  10 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(gPoll, ^{ mirrorNow(); });
        dispatch_resume(gPoll);
    }
    notifyChange();
    return gVirtual != nil || findDell() == kCGNullDirectDisplay;
}

void MitameStop(void) {
    gWanted = NO;
    if (gPoll) { dispatch_source_cancel(gPoll); gPoll = nil; }
    if (gCallbackRegistered) {
        CGDisplayRemoveReconfigurationCallback(reconfigCB, NULL);
        gCallbackRegistered = NO;
    }
    stopWatchdog();
    destroyVirtual();
    if (gActivity) {
        [[NSProcessInfo processInfo] endActivity:gActivity];
        gActivity = nil;
    }
    notifyChange();
}

void MitameRebuild(void) {
    if (!gWanted) return;
    NSLog(@"rebuilding virtual display");
    MitameStart(gLW, gLH, gBuiltin, gVendor, gModel, gSerial);
}

BOOL MitameIsRunning(void) { return gWanted; }

BOOL MitameIsMirroring(void) { return gVirtual != nil; }

// モニターの本来の解像度（ネイティブのモード）。ミラー中でも正しく読める
static CGSize nativePixels(CGDirectDisplayID d) {
    CFStringRef k = kCGDisplayShowDuplicateLowResolutionModes;
    CFBooleanRef v = kCFBooleanTrue;
    CFDictionaryRef opts = CFDictionaryCreate(
        NULL, (const void **)&k, (const void **)&v, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(d, opts);
    CFRelease(opts);
    size_t bw = 0, bh = 0;
    if (modes) {
        for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
            CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
            if (!(CGDisplayModeGetIOFlags(m) & kDisplayModeNativeFlag)) continue;
            size_t w = CGDisplayModeGetPixelWidth(m), h = CGDisplayModeGetPixelHeight(m);
            if (w * h > bw * bh) { bw = w; bh = h; }
        }
        CFRelease(modes);
    }
    if (!bw) { // ネイティブの印がないモニター：一番大きいモードで代用
        bw = CGDisplayPixelsWide(d);
        bh = CGDisplayPixelsHigh(d);
    }
    return CGSizeMake(bw, bh);
}

static NSString *screenName(CGDirectDisplayID d) {
    for (NSScreen *s in NSScreen.screens) {
        NSNumber *num = s.deviceDescription[@"NSScreenNumber"];
        if (num.unsignedIntValue == d) return s.localizedName;
    }
    return nil;
}

NSArray<NSDictionary<NSString *, id> *> *MitameListDisplays(void) {
    NSMutableArray *list = [NSMutableArray array];
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return list;
    for (uint32_t i = 0; i < n; i++) {
        CGDirectDisplayID d = ids[i];
        if (d == gVirtualID) continue;
        if (CGDisplayVendorNumber(d) == MITAME_VIRTUAL_VENDOR) continue; // Mitame・hidpi-mirror
        CGSize px = nativePixels(d);
        NSMutableDictionary *info = [@{
            @"vendor": @(CGDisplayVendorNumber(d)),
            @"model": @(CGDisplayModelNumber(d)),
            @"serial": @(CGDisplaySerialNumber(d)),
            @"nativeWidth": @((unsigned int)px.width),
            @"nativeHeight": @((unsigned int)px.height),
            @"builtin": @((BOOL)CGDisplayIsBuiltin(d)),
        } mutableCopy];
        NSString *name = screenName(d); // ミラー中は出てこない
        if (name) info[@"name"] = name;
        [list addObject:info];
    }
    return list;
}

void MitameSetChangeHandler(void (^handler)(void)) {
    gChangeHandler = [handler copy];
}
