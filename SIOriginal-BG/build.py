# SIOriginal-BG v3.0.0-BG 本地构建（Windows / ziglang + theos iPhoneOS16.5 SDK）
# 产物：artifacts/SIOriginalBG.dylib（TrollFools 注入）+ artifacts/SIOriginalBG.ipa（TrollStore 安装）
import os, sys, stat, zipfile, subprocess, shutil

ROOT  = os.path.dirname(os.path.abspath(__file__))
PY    = r"C:\Users\Administrator\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
SDK   = r"C:\Users\Administrator\WorkBuddy\2026-10-20-01-45-41\sdk\iPhoneOS16.5.sdk"
OUT   = os.path.join(ROOT, "artifacts")
BUILD = os.path.join(ROOT, "build")

os.makedirs(OUT, exist_ok=True)
shutil.rmtree(BUILD, ignore_errors=True)
os.makedirs(BUILD)

ZIG = [PY, "-m", "ziglang", "cc"]
# target 决定 LC_BUILD_VERSION 的 minos（zig 驱动拒绝 -Wl,-platform_version）；
# SDK 由 -isysroot 显式指定（16.5），minos 保持 14.0，iOS 14+ 设备都能装。
COMMON = ["-target", "aarch64-ios.14.0", "-O2",
          "-isysroot", SDK,
          "-isystem", os.path.join(SDK, "usr", "include"),
          "-F", os.path.join(SDK, "System", "Library", "Frameworks"),
          "-miphoneos-version-min=14.0".replace("=", " "),
          "-fobjc-arc", "-w"]

def run(cmd):
    print(">>", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.stdout.strip(): print(r.stdout.strip())
    if r.returncode != 0:
        print(r.stderr.strip())
        raise SystemExit("FAILED: %s" % " ".join(cmd))
    if r.stderr.strip(): print("[stderr]", r.stderr.strip()[:2000])

# ---------- ① dylib ----------
dylib = os.path.join(OUT, "SIOriginalBG.dylib")
run(ZIG + COMMON + [
    "-dynamiclib",
    "-install_name", "@rpath/SIOriginalBG.dylib",
    "-undefined", "dynamic_lookup",
    "-L", os.path.join(SDK, "usr", "lib"),
    "-lSystem",
    # headerpad：把 __text 推离 Mach-O 头，规避真机「跳进段首函数即 SIGILL」（lld 不接受 -sectalign）
    "-Wl,-headerpad,0x4000",
    "-ITweak",
    "-framework", "Foundation", "-framework", "UIKit",
    "-framework", "AVFoundation", "-framework", "AudioToolbox",
    "-framework", "UserNotifications",
    os.path.join(ROOT, "Tweak", "SIOriginalBG.m"),
    "-o", dylib])

# ---------- ② App 可执行 ----------
exe = os.path.join(BUILD, "SIOriginalBG")
run(ZIG + COMMON + [
    "-Wl,-headerpad,0x4000",
    "-L", os.path.join(SDK, "usr", "lib"),
    "-framework", "Foundation", "-framework", "UIKit",
    "-framework", "CoreFoundation", "-framework", "CoreGraphics",
    "-lobjc",
    os.path.join(ROOT, "App", "main.m"),
    "-o", exe])

# ---------- ③ 组装 .app / IPA ----------
appdir = os.path.join(BUILD, "Payload", "SIOriginalBG.app")
os.makedirs(appdir)
shutil.copy2(exe, os.path.join(appdir, "SIOriginalBG"))
os.chmod(os.path.join(appdir, "SIOriginalBG"), 0o755)
for f in ["Info.plist", "AppIcon.png", "Icon-60@2x.png", "Icon-60@3x.png",
          "Icon-76@2x.png", "Icon-83.5@2x.png"]:
    shutil.copy2(os.path.join(ROOT, "App", f), os.path.join(appdir, f))

ipa = os.path.join(OUT, "SIOriginalBG.ipa")
if os.path.exists(ipa): os.remove(ipa)
with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as z:
    for dp, dn, fn in os.walk(os.path.join(BUILD, "Payload")):
        for f in sorted(fn):
            p = os.path.join(dp, f)
            z.write(p, os.path.relpath(p, BUILD))

# ---------- ④ lief 校验 ----------
import lief

def show(path, want):
    print("\n== %s" % os.path.basename(path))
    b = lief.parse(path)
    if b is None:
        print("  !! lief cannot parse"); return
    if isinstance(b, lief.MachO.FatBinary):
        print("  FAT entries:", len(b))
        b = b.at(0)
    hdr = b.header
    print("  magic      :", hdr.magic)
    print("  file_type  :", hdr.file_type, "(want %s)" % want)
    print("  cpu        :", hdr.cpu_type)
    print("  size       :", os.path.getsize(path), "bytes")
    cmds = [str(c.command) for c in b.commands]
    print("  load cmds  :", cmds)
    for c in b.commands:
        if "ID_DYLIB" in str(c.command):
            try: print("  install_name:", c.dylib.name)
            except Exception: pass
    print("  segments   :", [s.name for s in b.segments])
    for s in b.segments:
        if s.name == "__TEXT":
            print("  __TEXT     : vmaddr=0x%x fileoff=0x%x vsize=0x%x" %
                  (s.virtual_address, s.file_offset, s.virtual_size))
    # 入口 / 构造函数符号
    syms = [s.name for s in b.symbols]
    print("  has SIOBGEntry:", any("SIOBGEntry" in s for s in syms))
    print("  has BGAppDelegate:", any("BGAppDelegate" in s for s in syms))

show(dylib, "MH_DYLIB")
show(exe, "MH_EXECUTE")

print("\nartifacts:")
for f in sorted(os.listdir(OUT)):
    print("  %-22s %8d bytes" % (f, os.path.getsize(os.path.join(OUT, f))))
print("\nOK")
