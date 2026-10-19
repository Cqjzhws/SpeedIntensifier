#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SIOriginal 配置契约检查（v3.0 方案里的 P0 工具原型）

检查四件事：
  1. 键集合：App 写入 / 白名单登记 / dylib 读取，三者是否双向一致
        写而未登记 -> 保存时被静默丢弃（假开关）
        登记而无人写 -> 死配置
        dylib 读但 App 无写入路径 -> 只能手改 plist
        专属覆盖：dylib 读但 App 不写 -> 覆盖里的死开关
  2. **默认值四处对照**：dylib 静态初值 / SIO_resetDefaults / reload 缺键兜底 / App ReadConfig
        （v2.1.19 的 P0 就出在这一层）
  3. 越界兜底与出厂默认是否同值
  4. 退出码：0 = 干净，1 = 有问题（可直接当 CI 门禁）

用法: python config_contract.py <SIOriginal.m> <main.m>
"""
import re, sys, os

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

NUM = r'-?\d+(?:\.\d+)?'
KEY_RE = re.compile(r'\b(\w+)\[@"([A-Za-z][A-Za-z0-9_]*)"\]')

# dylib 全局变量 -> plist 键
VAR2KEY = {
    'gEnabled': 'Enabled', 'gMode': 'Mode', 'gSpeed': 'Speed', 'gSlowFactor': 'SlowFactor',
    'gSpring': 'Spring', 'gExtra': 'Extra', 'gListAccel': 'ListAccel', 'gZoomAccel': 'ZoomAccel',
    'gFastScroll': 'FastScroll', 'gFastTap': 'FastTap', 'gLayerBoost': 'LayerBoost',
    'gFloorDuration': 'FloorDuration', 'gTransBoost': 'TransitionBoost',
    'gInAppNotify': 'InAppNotify', 'gInstantTransition': 'InstantTransition',
    'gHUDFast': 'HUDFast', 'gHUDDelay': 'HUDDelay', 'gWKFastShow': 'WKFastShow',
    'gFUBGEnabled': 'FUBGEnabled', 'gSceneFake': 'FUBGSceneFake', 'gAudioKeep': 'FUBGAudioKeep',
    'gSafeBootEnabled': 'SafeBootEnabled',
}


def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)
    src = re.sub(r'//[^\n]*', ' ', src)
    return src


def block(src, header_re):
    m = re.search(header_re + r'\s*\{', src)
    if not m:
        return ''
    i, depth = m.end(), 1
    while i < len(src) and depth:
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
        i += 1
    return src[m.end():i]


def dylib_reads(src):
    return {m.group(2) for m in KEY_RE.finditer(src) if m.group(1) == 'd'}


def override_reads(src):
    return {m.group(2) for m in KEY_RE.finditer(src) if m.group(1) == 'ovr'}


def app_writes(src):
    return {m.group(1) for m in re.finditer(r'\bcfg\[@"(\w+)"\]\s*=', src)}


def app_override_writes(src):
    """两种写法都认：整块 @{...} 与逐个 ov[@"K"] = ..."""
    keys = set()
    m = re.search(r'ovOut\[ovBid\]\s*=\s*@\{(.*?)\n\s*\};', src, flags=re.S)
    if m:
        keys |= {x.group(1) for x in re.finditer(r'@"(\w+)"\s*:', m.group(1))}
    keys |= {x.group(1) for x in re.finditer(r'\bov\[@"(\w+)"\]\s*=', src)}
    return keys


def override_preserves_unknown(src):
    """App 是否先继承旧字典再覆盖（而不是整块替换）"""
    return bool(re.search(r'\[ovOut\[ovBid\]\s+mutableCopy\]', src))


def whitelist(src):
    m = re.search(r'keys\s*=\s*@\[(.*?)\];', src, flags=re.S)
    if not m:
        return set()
    return {x.group(1) for x in re.finditer(r'@"(\w+)"', m.group(1))}


def consts(src):
    return {m.group(1): m.group(2)
            for m in re.finditer(r'static\s+const\s+\w+\s+(SIO_Def\w+)\s*=\s*(' + NUM + r')', src)}


def num(v, cmap):
    """规范化：@YES/@NO/@(SIO_DefX)/0.01f/YES/NO -> float"""
    v = v.strip().strip(';').strip()
    v = v.replace('f', '') if re.fullmatch(r'-?\d+(?:\.\d+)?f', v) else v
    if v in ('@YES', 'YES', 'true'):
        return 1.0
    if v in ('@NO', 'NO', 'false'):
        return 0.0
    v = v.lstrip('@')
    if v.startswith('(') and v.endswith(')'):
        v = v[1:-1].strip()
    if v in cmap:
        return float(cmap[v])
    m = re.search(NUM, v)
    return float(m.group(0)) if m else None


def static_inits(src):
    out = {}
    for m in re.finditer(r'static\s+(?:const\s+)?(?:double|BOOL|int)\s+(g\w+)\s*=\s*([^;]+);', src):
        var, val = m.group(1), m.group(2)
        if var in VAR2KEY:
            out[VAR2KEY[var]] = val
    return out


def reset_defaults(src):
    body = block(src, r'static\s+void\s+SIO_resetDefaults\s*\(void\)')
    out = {}
    for m in re.finditer(r'(g\w+)\s*=\s*([^;]+);', body):
        var, val = m.group(1), m.group(2)
        if var in VAR2KEY:
            out[VAR2KEY[var]] = val
    return out


def reload_defaults(src):
    """缺键/越界兜底：d[@"K"] ? ... : X;  以及  gSpeed = (...) ? sp : X;"""
    body = block(src, r'static\s+void\s+SIO_reload\s*\(void\)')
    out = {}
    for m in re.finditer(
            r'd\[@"(\w+)"\]\s*\?\s*\[d\[@"\1"\]\s*(?:double|bool|int|unsignedInt)Value\]\s*:\s*([^;]+);',
            body):
        out[m.group(1)] = m.group(2)
    m = re.search(r'gSpeed\s*=\s*\([^;]*?\)\s*\?\s*sp\s*:\s*(' + NUM + r')', body)
    if m:
        out['Speed'] = m.group(1)
    return out


def app_defaults(src):
    body = block(src, r'static\s+NSMutableDictionary\s*\*\s*ReadConfig\s*\(void\)')
    out = {}
    for m in re.finditer(r'if\s*\(!d\[@"(\w+)"\]\)\s*d\[@"\1"\]\s*=\s*([^;]+);', body):
        out[m.group(1)] = m.group(2)
    return out


def main(dy_path, app_path):
    dy = strip_comments(open(dy_path, encoding='utf-8').read())
    app = strip_comments(open(app_path, encoding='utf-8').read())
    cmap = consts(app)

    g_read, o_read = dylib_reads(dy), override_reads(dy)
    w, ow, wl = app_writes(app), app_override_writes(app), whitelist(app)
    sources = {
        '静态初值': static_inits(dy),
        'resetDefaults': reset_defaults(dy),
        'reload 缺键': reload_defaults(dy),
        'App ReadConfig': app_defaults(app),
    }

    print(f'== {os.path.basename(dy_path)} + {os.path.basename(app_path)}')
    print(f'   键统计: dylib 全局 {len(g_read)} | dylib 覆盖 {len(o_read)} | '
          f'App 写入 {len(w)} | App 覆盖写 {len(ow)} | 白名单 {len(wl)}')

    problems = []

    miss = sorted(w - wl)
    if miss:
        problems.append(f'[假开关] App 写入但白名单未登记 -> 保存被丢弃: {", ".join(miss)}')
    dead = sorted(wl - w)
    if dead:
        problems.append(f'[死配置] 白名单登记但永不写入: {", ".join(dead)}')
    hand = sorted(g_read - w)
    if hand:
        problems.append(f'[只能手改] dylib 读但 App 无写入路径: {", ".join(hand)}')
    dead_ov = sorted(o_read - ow)
    if dead_ov:
        if override_preserves_unknown(app):
            print(f'   [WARN] 专属覆盖：dylib 支持但本页无编辑入口（已保留旧值，不会丢失）: '
                  f'{", ".join(dead_ov)}')
        else:
            problems.append(f'[专属死开关+数据丢失] dylib 读覆盖但 App 整块替换时不写入: '
                            f'{", ".join(dead_ov)}')

    # 默认值四处对照
    keys = sorted(set().union(*[set(s) for s in sources.values()]))
    rows, bad = [], []
    for k in keys:
        vals = {}
        for name, s in sources.items():
            if k in s:
                vals[name] = num(s[k], cmap)
        known = [v for v in vals.values() if v is not None]
        if len(known) < 2:
            continue
        rows.append((k, vals))
        if len(set(known)) > 1:
            bad.append(k)

    print('   默认值四处对照:')
    print(f'     {"键":<18}{"静态":>8}{"reset":>9}{"reload":>9}{"App":>10}')
    for k, vals in rows:
        def f(n):
            v = vals.get(n)
            return f'{v:g}' if isinstance(v, float) else '-'
        mark = '  <== 分叉' if k in bad else ''
        print(f'     {k:<18}{f("静态初值"):>8}{f("resetDefaults"):>9}'
              f'{f("reload 缺键"):>9}{f("App ReadConfig"):>10}{mark}')
    if bad:
        problems.append(f'[P0 默认值分叉] {", ".join(bad)}')

    print()
    if problems:
        for p in problems:
            print('  [FAIL]', p)
        return 1
    print('  [OK] 契约干净：键集合双向一致 + 四处默认值一致')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
