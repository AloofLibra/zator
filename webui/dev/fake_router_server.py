#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Фейковый dev-сервер, имитирующий роутер с zapret2 WebUI.

Назначение
----------
Позволяет разрабатывать и гонять фронтенд `webui/` (index.html, app.js,
styles.css) локально, без реального устройства и без `/opt/zapret2`.

Что делает
----------
* Отдаёт настоящие статические файлы из `webui/` как есть.
* Реализует те же CGI-эндпоинты, что и `webui/cgi-bin/*.cgi`, воспроизводя
  JSON-контракт из `webui/dev/API_CONTRACT.md` максимально точно (те же поля,
  те же коды ошибок, те же edge-case'ы).
* Держит фейковое состояние «роутера» во временной директории (НИКОГДА не в
  `/opt/zapret2` и не в самом репозитории):
    - копия `config.default` (читается и правится sed-логикой как lib/config.sh);
    - фейковые `locked.tsv` / `locked.manual.tsv` / `profile.lock`;
    - флаг «nfqws2 running».
* Логирует каждый запрос и то, каким фейковым состоянием он обработан.

Ограничения
-----------
Только стандартная библиотека Python (http.server/json/argparse/re/tempfile).
Никаких pip-зависимостей — в духе dependency-light WebUI этого репозитория.

Парсинг конфига и lock-файлов — честный Python-порт функций из
`lib/config.sh` и `lib/orchestra_state.sh` (awk/sed-логика перенесена 1:1,
сверяйтесь с комментариями-ссылками).
"""

import argparse
import io
import json
import os
import random
import re
import shutil
import sys
import tarfile
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


# ===========================================================================
# Константы контракта (взяты из webui/cgi-bin/_lib.sh)
# ===========================================================================

# all_profiles_json() — _lib.sh:109
PROFILES = [
    (1, "YouTube TCP", "Основной TCP профиль для YouTube"),
    (2, "Googlevideo", "Видео-домены YouTube"),
    (3, "Blocked Sites", "Основные блокировки сайтов"),
    (4, "Discord TCP", "TCP профиль Discord"),
    (5, "YouTube QUIC", "UDP 443 для YouTube"),
    (6, "Voice UDP", "Discord/STUN и голосовые сервисы"),
    (7, "UDP Games", "Игровой UDP (порты 1026-65531)"),
    (8, "Fallback TLS", "Безразборный режим TLS (profile 8)"),
    (9, "Fallback HTTP", "Безразборный режим HTTP (profile 9)"),
]

# Fallback profiles (is_fallback=True)
FALLBACK_PROFILES = {8, 9}

# UDP Games profile (is_udp_games=True) — гейтинг как у fallback, но по
# состоянию config_mode_text udp_games (наличие 1026-65531 в NFQWS2_PORTS_UDP).
UDP_GAMES_PROFILE = 7

# config_profile_proto_list() — lib/config.sh:359
_PROTO_LIST = {
    1: "tls http",
    2: "tls", 3: "tls", 4: "tls", 8: "tls",
    5: "udp", 6: "udp", 7: "udp",
    9: "http",
}


def proto_list(profile):
    """config_profile_proto_list() — lib/config.sh:359."""
    return _PROTO_LIST.get(int(profile), "")


def profile_proto(profile):
    """profile_proto() — _lib.sh:94: первое слово из proto_list."""
    pl = proto_list(profile)
    return pl.split()[0] if pl else ""


# config_profile_voice_ports() — lib/config.sh:434
VOICE_PORTS = "50000-50099,1400,3478-3481,5349,19294-19344"

# get_yt_cluster_domain() fallback — _lib.sh:154
YT_CLUSTER_FALLBACK = "rr1---sn-5goeenes.googlevideo.com"

# api_check() — _lib.sh:254: (label, target|None)  None → подставить YT-кластер
CHECK_TARGETS = [
    ("YouTube", "https://www.youtube.com/"),
    ("Googlevideo", None),
    ("Blocked Sites", "https://meduza.io"),
    ("Instagram", "https://www.instagram.com/"),
]

# profile_check_json() — _lib.sh:180
PROFILE_CHECK = {
    1: [("YouTube", "https://www.youtube.com/")],
    2: [("Googlevideo", None)],
    3: [("Blocked Sites", "https://meduza.io")],
    4: [("Discord", "https://discord.com/")],
}
UDP_CHECK_MESSAGE = ("Для UDP-профиля быстрая TLS-проверка неприменима. "
                     "Проверьте работу в браузере или приложении.")

# Сообщения об ошибках — дословно из _lib.sh (send_error)
ERR_BAD_PROFILE = "Некорректный профиль"
ERR_BAD_STRATEGY = "Некорректная стратегия"
ERR_STRATEGY_RANGE = "Стратегия вне диапазона"
ERR_NO_PROTO = "Не удалось определить протокол профиля"
ERR_SAVE_STATE = "Не удалось сохранить состояние профиля"
ERR_RESET_STATE = "Не удалось сбросить состояние профиля"
ERR_BAD_ACTION = "Некорректное действие"
ERR_SERVICE = "Не удалось выполнить команду zapret2"

AUTO_MODE_GATED_PROFILES = (1, 2, 3, 4)

# Допустимые эндпоинты для --simulate-error
SIMULATABLE = {"status", "service", "check", "set-lock", "clear-lock", "settings", "domains", "backups"}

RST_GUARD_KEYS = ("1", "2", "3", "4", "8", "9")


# ===========================================================================
# Порт lib/config.sh — чтение/правка конфига
# ===========================================================================

_STRATEGY_RE = re.compile(r"strategy=[0-9]+")


def _read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def config_get_var(cfg_text, var):
    """config_get_var() — lib/config.sh:30: sed -n 's/^\\s*VAR=//p' | head -1."""
    for line in cfg_text.splitlines():
        m = re.match(r"^\s*" + re.escape(var) + r"=(.*)$", line)
        if m:
            return m.group(1)
    return None


def _scan_strategies(line, in_template, tpl, tplmax, active, prof, pid, maxval):
    """scan_strategies() из awk в config_profile_max_strategy — lib/config.sh:281."""
    for m in _STRATEGY_RE.finditer(line):
        # substr(line, RSTART+9, RLENGTH-9): пропускаем "strategy=" (9 символов)
        num = int(m.group(0)[9:])
        if in_template:
            if num > tplmax.get(tpl, 0):
                tplmax[tpl] = num
        else:
            if active and prof == pid and num > maxval:
                maxval = num
    return maxval


def _fallback_max_strategy(profile, cfg_text):
    """Часть для профилей 8/9 — lib/config.sh:235 (блоки #Z2R_FALLBACK_*)."""
    if profile == 9:
        begin, end = "#Z2R_FALLBACK_HTTP_BEGIN", "#Z2R_FALLBACK_HTTP_END"
    else:
        begin, end = "#Z2R_FALLBACK_BEGIN", "#Z2R_FALLBACK_END"
    inblk = False
    in_template = False
    tpl = ""
    tplmax = {}
    maxval = 0
    for line in cfg_text.splitlines():
        if begin in line:
            inblk = True
            continue
        if end in line:
            break
        if not inblk:
            continue
        if re.match(r"^--template=", line):
            in_template = True
            tpl = re.sub(r"^--template=", "", line)
            tpl = re.sub(r"\s.*$", "", tpl)
        else:
            in_template = False
        if re.match(r"^--import([=\s]|$)", line):
            imp = re.sub(r"^--import[=\s]+", "", line)
            imp = re.sub(r"\s.*$", "", imp)
            if tplmax.get(imp, 0) > maxval:
                maxval = tplmax[imp]
        maxval = _scan_strategies(line, in_template, tpl, tplmax,
                                  True, 0, profile, maxval)
    return maxval


def config_profile_max_strategy(profile, cfg_text):
    """config_profile_max_strategy() — lib/config.sh:230 (порт awk 1:1)."""
    pid = int(profile)

    # Профили 8/9 — отдельный fallback-разбор; при успехе возвращаем сразу.
    if pid in (8, 9):
        fb = _fallback_max_strategy(pid, cfg_text)
        if fb and fb > 0:
            return fb

    inopt = False
    prof = 0
    active = False
    in_template = False
    tpl = ""
    tplmax = {}
    maxval = 0

    for line in cfg_text.splitlines():
        if re.match(r'^NFQWS2_OPT="', line):
            inopt = True
        if not inopt:
            continue

        if re.match(r"^--template=", line):
            in_template = True
            tpl = re.sub(r"^--template=", "", line)
            tpl = re.sub(r"\s.*$", "", tpl)
        else:
            # start_profile_if_needed() — lib/config.sh:289
            if (not in_template and not active
                    and re.match(r"^--", line)
                    and not re.match(r"^--new", line)
                    and not re.match(r"^--lua-init", line)
                    and not re.match(r"^--blob=", line)
                    and not re.match(r"^--reasm-disable", line)):
                prof += 1
                active = True

        # import внутри активного профиля подтягивает tplmax шаблона
        if (not in_template and active and prof == pid
                and re.match(r"^--import([=\s]|$)", line)):
            imp = re.sub(r"^--import[=\s]+", "", line)
            imp = re.sub(r"\s.*$", "", imp)
            if tplmax.get(imp, 0) > maxval:
                maxval = tplmax[imp]

        maxval = _scan_strategies(line, in_template, tpl, tplmax,
                                  active, prof, pid, maxval)

        if re.match(r"^--new", line):
            active = False
            in_template = False
            tpl = ""
        if re.match(r'^"$', line):
            break

    return maxval


def config_tls_blob_mode_value(cfg_text):
    """config_tls_blob_mode_value() — lib/config.sh:115."""
    has_maxru = False
    has_default = False
    for line in cfg_text.splitlines():
        if "--lua-desync=" not in line:
            continue
        if "blob=maxru" in line and "strategy=26" not in line:
            has_maxru = True
        if "blob=fake_default_tls" in line and "strategy=26" not in line:
            has_default = True
    if has_maxru and not has_default:
        return "maxru"
    if has_default and not has_maxru:
        return "fake_default_tls"
    if has_default and has_maxru:
        return "mixed"
    return "не определён"


def config_tls_blob_menu_value(cfg_text):
    """config_tls_blob_menu_value() — lib/config.sh:182 (path-agnostic)."""
    mode = config_tls_blob_mode_value(cfg_text)
    if mode == "fake_default_tls":
        return "default"
    if mode == "mixed":
        return "mixed"
    m = re.search(r"--blob=maxru:@/opt/(?:zapret2|zator)/files/fake/(\S+)", cfg_text)
    if m:
        return m.group(1)
    return "неизвестно"


def config_mode_text(mode, cfg_text):
    """config_mode_text() — lib/config.sh:157 (порты, нужные WebUI)."""
    if mode == "flowoffload":
        return config_get_var(cfg_text, "FLOWOFFLOAD") or "неизвестно"
    if mode == "fwtype":
        return config_get_var(cfg_text, "FWTYPE") or "неизвестно"
    if mode == "hostlist":
        for line in cfg_text.splitlines():
            if re.match(r"^MODE_FILTER=autohostlist", line):
                return "авто"
        for line in cfg_text.splitlines():
            if re.match(r"^MODE_FILTER=hostlist", line):
                return "по листам"
        return "неизвестно"
    if mode == "tls_blob_mode":
        return config_tls_blob_mode_value(cfg_text)
    if mode == "tls_blob_menu":
        return config_tls_blob_menu_value(cfg_text)
    if mode == "udp_games":
        # config_mode_text udp_games — lib/config.sh:209.
        # Состояние определяется по наличию 1026-65531 в NFQWS2_PORTS_UDP.
        ports = config_get_var(cfg_text, "NFQWS2_PORTS_UDP") or ""
        if re.search(r"(^|,)1026-65531(,|$)", ports):
            return "Включен"
        if ports:
            return "Выключен"
        return "Неизвестно"
    if mode == "auto_mode":
        # config_mode_text auto_mode — lib/config.sh:248.
        has_on = any(re.match(r"^#Z2R_AUTO_MODE=1$", l) for l in cfg_text.splitlines())
        has_off = any(re.match(r"^#Z2R_AUTO_MODE=0$", l) for l in cfg_text.splitlines())
        if has_on:
            return "включен"
        if has_off:
            return "выключен"
        return "неизвестно"
    if mode == "rst_guard":
        # config_mode_text rst_guard — lib/config.sh:257.
        if "--lua-desync=rst_guard_locked:key=" in cfg_text:
            return "включен"
        return "выключен"
    if mode == "reasm_disable":
        # config_mode_text reasm_disable — lib/config.sh:264.
        inopt = False
        for line in cfg_text.splitlines():
            if re.match(r'^NFQWS2_OPT="', line):
                inopt = True
            elif inopt and re.match(r'^"$', line):
                break
            if inopt and re.match(r"^\s*--reasm-disable", line):
                return "включено"
        return "выключено"
    if mode == "fallback":
        # config_mode_text fallback — lib/config.sh:232.
        if config_mode_text("auto_mode", cfg_text) == "включен":
            return "недоступен"
        blocks = _fallback_block_lines(cfg_text)
        if any(re.match(r"^\s*--skip\s", l) for l in blocks):
            return "выключен"
        if any(re.match(r"^\s*--filter-tcp=", l) for l in blocks):
            return "включен"
        return "неизвестно"
    return "неизвестно"


def _fallback_block_lines(cfg_text):
    """Строки блоков #Z2R_FALLBACK_* (TLS + HTTP) между маркерами."""
    lines = []
    inblk = False
    for line in cfg_text.splitlines():
        if re.match(r"^\s*#Z2R_FALLBACK(_HTTP)?_BEGIN\s*$", line):
            inblk = True
            continue
        if re.match(r"^\s*#Z2R_FALLBACK(_HTTP)?_END\s*$", line):
            inblk = False
            continue
        if inblk:
            lines.append(line)
    return lines


# --- csv-хелперы для голосовых портов (lib/config.sh:369 / 438) ------------

def _csv_contains(csv, token):
    return token in (csv.split(",") if csv else [])


def csv_add_tokens(csv, tokens):
    """csv_add_tokens() — lib/config.sh:384."""
    out = csv or ""
    for tok in tokens.split(","):
        tok = tok.strip()
        if not tok:
            continue
        if not _csv_contains(out, tok):
            out = tok if not out else out + "," + tok
    return out


def csv_remove_tokens(csv, tokens):
    """csv_remove_tokens() — lib/config.sh:406."""
    remove = [t.strip() for t in tokens.split(",") if t.strip()]
    keep = [c for c in (csv or "").split(",") if c and c not in remove]
    return ",".join(keep)


def config_set_var(cfg_text, var, val):
    """config_set_var() — lib/config.sh:38 (in-memory, возвращает новый текст)."""
    lines = cfg_text.splitlines()
    pattern = re.compile(r"^\s*" + re.escape(var) + r"=.*$")
    replaced = False
    for i, line in enumerate(lines):
        if pattern.match(line):
            lines[i] = "{0}={1}".format(var, val)
            replaced = True
            break
    if not replaced:
        lines.append("{0}={1}".format(var, val))
    return "\n".join(lines) + "\n"


def config_profile_voice_ports_apply(cfg_text, state):
    """config_profile_voice_ports_apply() — lib/config.sh:438."""
    cur = config_get_var(cfg_text, "NFQWS2_PORTS_UDP") or ""
    if state == "0":
        new_ports = csv_remove_tokens(cur, VOICE_PORTS)
        if not new_ports:
            new_ports = "443"
    else:  # auto или номер стратегии — порты добавляются
        new_ports = csv_add_tokens(cur, VOICE_PORTS)
    if cur != new_ports:
        cfg_text = config_set_var(cfg_text, "NFQWS2_PORTS_UDP", new_ports)
    return cfg_text


# ===========================================================================
# Порт lib/orchestra_state.sh — lock-файлы и состояние профиля
# ===========================================================================

def _read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read().splitlines()


def profile_state_normalize(s):
    """profile_state_normalize() — orchestra_state.sh:62. None = некорректно."""
    if s in ("", "auto"):
        return "auto"
    if s in ("0", "skip"):
        return "0"
    if re.match(r"^[1-9][0-9]*$", s):
        return s
    return None


def orch_locked_read(lock_file, profile, proto, default):
    """_orch_locked_read() — orchestra_state.sh:9 (TSV: profile\\tproto\\tstrat)."""
    prof = str(profile)
    for line in _read_lines(lock_file):
        if not line:
            continue
        f = line.split("\t")
        if len(f) >= 3 and f[0] == prof and f[1] == proto:
            return f[2]
        # legacy 2-поле: profile\tstrategy — трактуется как tls
        if len(f) == 2 and f[0] == prof and proto == "tls":
            return f[1]
    return default


def orch_locked_state_get(lock_file, profile, proto):
    return orch_locked_read(lock_file, profile, proto, "auto")


def profile_state_stored_get(profile_lock, profile, proto):
    """profile_state_stored_get() — orchestra_state.sh:80 (FS='[ \\t]+')."""
    prof = str(profile)
    for line in _read_lines(profile_lock):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        f = re.split(r"[ \t]+", line.strip())
        if len(f) >= 3 and f[0] == prof and f[1] == proto:
            return f[2]
        if len(f) == 2 and f[0] == prof and proto == "tls":
            return f[1]
    return "auto"


def profile_state_get(profile_lock, lock_file, profile, proto):
    """profile_state_get() / profile_state_display() — orchestra_state.sh:96."""
    stored = profile_state_stored_get(profile_lock, profile, proto)
    if stored != "auto":
        n = profile_state_normalize(stored)
        return n if n is not None else "auto"
    n = profile_state_normalize(orch_locked_state_get(lock_file, profile, proto))
    return n if n is not None else "auto"


def _write_tsv(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write("\t".join(str(x) for x in r) + "\n")
    os.replace(tmp, path)


def orch_locked_set(lock_file, profile, proto, strategy):
    """orch_locked_set() — orchestra_state.sh:28."""
    prof, p, s = str(profile), proto, str(strategy)
    rows = [line.split("\t") for line in _read_lines(lock_file) if line]
    found = False
    for r in rows:
        if r and r[0] == prof and ((len(r) > 1 and r[1] == p) or (len(r) == 2 and p == "tls")):
            r[:] = [prof, p, s]
            found = True
    if not found:
        rows.append([prof, p, s])
    _write_tsv(lock_file, rows)


def orch_locked_clear(lock_file, profile, proto):
    """orch_locked_clear() — orchestra_state.sh:43."""
    prof, p = str(profile), proto
    rows = [line.split("\t") for line in _read_lines(lock_file) if line]
    keep = [r for r in rows
            if not (r and r[0] == prof and ((len(r) > 1 and r[1] == p) or (len(r) == 2 and p == "tls")))]
    _write_tsv(lock_file, keep)


def z2r_normalize_domain(value):
    """z2r_normalize_domain() — z2r.sh:239. Возвращает нормализованный домен или None."""
    d = value.strip()
    if not d:
        return None
    d = d.lower()
    # убрать схему (http://, https://, ...)
    if "://" in d:
        d = d.split("://", 1)[1]
    # убрать userinfo (всё до последнего @)
    if "@" in d:
        d = d.rsplit("@", 1)[1]
    # убрать путь
    d = d.split("/", 1)[0]
    # убрать порт
    d = d.split(":", 1)[0]
    # убрать крайние точки
    d = d.strip(".")
    if not d:
        return None
    # только допустимые символы: a-z 0-9 . -
    if not re.match(r"^[a-z0-9.-]+$", d):
        return None
    # должен быть хотя бы один буквенно-цифровой символ
    if not re.search(r"[a-z0-9]", d):
        return None
    return d


def profile_state_set(profile_lock, profile, proto, state):
    """profile_state_set() — orchestra_state.sh:157 (с предудалением + дописыванием)."""
    prof = str(profile)
    normalized = profile_state_normalize(state)
    if normalized is None:
        return False
    if normalized == "auto":
        profile_state_clear(profile_lock, profile, proto)
        return True
    rows = [re.split(r"[ \t]+", line.strip())
            for line in _read_lines(profile_lock)
            if line.strip() and not line.lstrip().startswith("#")]
    keep = [r for r in rows
            if not (r and r[0] == prof and ((len(r) > 1 and r[1] == proto) or (len(r) == 2 and proto == "tls")))]
    keep.append([prof, proto, normalized])
    _write_tsv(profile_lock, keep)
    return True


def profile_state_clear(profile_lock, profile, proto):
    """profile_state_clear() — orchestra_state.sh:171."""
    prof = str(profile)
    rows = [re.split(r"[ \t]+", line.strip())
            for line in _read_lines(profile_lock)
            if line.strip() and not line.lstrip().startswith("#")]
    keep = [r for r in rows
            if not (r and r[0] == prof and ((len(r) > 1 and r[1] == proto) or (len(r) == 2 and proto == "tls")))]
    _write_tsv(profile_lock, keep)


def profile_state_set_and_apply(state_obj, profile, proto_list_str, state):
    """profile_state_set_and_apply() + profile_config_apply_state() —
    lib/config.sh:535 / 490. Пишет и profile.lock, и orchestra-lock.

    Профили 8/9 (fallback) пишут orchestra-lock в locked.manual.tsv
    (см. profile_config_orch_set — lib/config.sh:461), остальные — в locked.tsv.
    Runtime-выбор стратегии для 8/9 делает circular_locked:key=N, читая manual-лок.
    """
    pl = proto_list_str.split()
    normalized = profile_state_normalize(state)
    if normalized is None:
        return False
    orch_file = (state_obj.lock_manual_file
                 if int(profile) in FALLBACK_PROFILES else state_obj.lock_file)
    for proto in pl:
        if normalized == "auto":
            profile_state_clear(state_obj.profile_lock, profile, proto)
            orch_locked_clear(orch_file, profile, proto)
        else:
            profile_state_set(state_obj.profile_lock, profile, proto, normalized)
            orch_locked_set(orch_file, profile, proto, normalized)
    # Профиль 6: правка голосовых портов в конфиге (config_profile_voice_ports_apply)
    if int(profile) == 6:
        state_obj.cfg_text = config_profile_voice_ports_apply(state_obj.cfg_text, normalized)
        state_obj._save_config()
    return True


# ===========================================================================
# Порт функций для TLS-блоба (lib/actions.sh + webui/cgi-bin/_lib.sh)
# ===========================================================================

def _scan_fake_blobs(fake_dir):
    """Сканирует директорию fake для tls_*.bin / custom_tls.bin (api_tls_blob_get)."""
    blobs = []
    if not os.path.isdir(fake_dir):
        return blobs
    for fname in sorted(os.listdir(fake_dir)):
        if fname.startswith("tls_") and fname.endswith(".bin"):
            blobs.append(fname)
        elif fname == "custom_tls.bin":
            blobs.append(fname)
    return blobs


def config_tls_blob_current(cfg_text):
    """Возвращает текущий blob-файл из --blob=maxru declaration (zapret2|zator)."""
    m = re.search(r"--blob=maxru:@/opt/(?:zapret2|zator)/files/fake/(\S+)", cfg_text)
    return m.group(1) if m else ""


def _apply_tls_blob_default(cfg_text):
    """Переход на встроенный блоб (api_tls_blob_set, value=fake_default_tls):
    в ссылках стратегий blob=maxru -> blob=fake_default_tls (кроме strategy=26).
    Декларация --blob=maxru:@... сохраняется для обратного переключения."""
    lines = []
    for line in cfg_text.splitlines():
        if ("--lua-desync=" in line and "blob=maxru" in line and
                "strategy=26" not in line):
            line = re.sub(r"(blob=)maxru", r"\1fake_default_tls", line)
        lines.append(line)
    return "\n".join(lines) + "\n"


def _apply_tls_blob(cfg_text, blob):
    """Применяет внешний blob-файл (api_tls_blob_set), возвращает новый текст.

    Как в реальном _lib.sh: fake_default_tls -> maxru в ссылках стратегий
    (кроме strategy=26), затем декларация заменяется целиком на канонический
    префикс /opt/zator/files/fake/ (path-agnostic матч старого корня).
    """
    lines = []
    for line in cfg_text.splitlines():
        if ("--lua-desync=" in line and "blob=fake_default_tls" in line and
                "strategy=26" not in line):
            line = re.sub(r"(blob=)fake_default_tls", r"\1maxru", line)
        lines.append(line)
    cfg_text = "\n".join(lines) + "\n"
    return re.sub(r"--blob=maxru:@/opt/(?:zapret2|zator)/files/fake/\S+",
                  "--blob=maxru:@/opt/zator/files/fake/" + blob, cfg_text)


# --- Порт функций для WireGuard-блоба (lib/actions.sh: menu_action_set_wg_blob
#     и menu_action_wg_repeats + webui/cgi-bin/_lib.sh: api_wg_blob_*) --------

def _scan_wg_blobs(fake_dir):
    """Сканирует директорию fake для wg_initial_fake_* (menu_action_set_wg_blob)."""
    blobs = []
    if not os.path.isdir(fake_dir):
        return blobs
    for fname in sorted(os.listdir(fake_dir)):
        if fname.startswith("wg_initial_fake_"):
            blobs.append(fname)
    return blobs


def config_wg_blob_current(cfg_text):
    """Возвращает текущий WG blob-файл из объявления --blob=fakewgblob:@... (zapret2|zator)."""
    m = re.search(r"--blob=fakewgblob:@/opt/(?:zapret2|zator)/files/fake/(\S+)", cfg_text)
    return m.group(1) if m else ""


def config_wg_repeats_current(cfg_text):
    """Возвращает текущее значение repeats из blob=fakewgblob:repeats=N."""
    m = re.search(r"blob=fakewgblob:repeats=([0-9]+)", cfg_text)
    return m.group(1) if m else ""


def _apply_wg_blob(cfg_text, blob):
    """Применяет новый WG blob-файл, возвращает новый текст конфига.

    Эквивалент sed из api_wg_blob_set: декларация заменяется целиком на
    канонический префикс /opt/zator/files/fake/ (path-agnostic матч старого корня).
    """
    return re.sub(r"--blob=fakewgblob:@/opt/(?:zapret2|zator)/files/fake/\S+",
                  lambda m: "--blob=fakewgblob:@/opt/zator/files/fake/" + blob, cfg_text)


def _apply_wg_repeats(cfg_text, repeats):
    """Применяет новое значение repeats, возвращает новый текст конфига.

    Эквивалент sed из menu_action_wg_repeats:
      s#(blob=fakewgblob:repeats=)[0-9]+#\\1<repeats>#g

    ВАЖНО: \\g<1> вместо \\1 — иначе '\\1'+'25'=='\\125' (восьмеричный escape).
    """
    return re.sub(r"(blob=fakewgblob:repeats=)[0-9]+",
                  r"\g<1>" + str(repeats), cfg_text)


def config_wg_state(cfg_text):
    """backup_smart_wg_state() — lib/actions.sh:1287 / _wg_state_get() — _lib.sh.

    Детектор состояния WireGuard в блоке #Z2R_WG_*:
    '1' = включено, '0' = выключено, '' = блока нет.
    """
    inblk = False
    for line in cfg_text.splitlines():
        if re.match(r"^\s*#Z2R_WG_BEGIN\s*$", line):
            inblk = True
            continue
        if re.match(r"^\s*#Z2R_WG_END\s*$", line):
            break
        if not inblk:
            continue
        if re.match(r"^\s*--skip\s+--filter-l7=wireguard\s*$", line):
            return "0"
        if "--filter-l7=wireguard" in line:
            return "1"
    return ""


def _apply_wg_state(cfg_text, want_on):
    """backup_smart_set_wireguard() — lib/actions.sh:1242 / _wg_state_set() — _lib.sh.

    Точечная замена в блоке #Z2R_WG_*: добавляет/убирает --skip перед
    --filter-l7=wireguard. Эквивалент sed:
      вкл: s/^[[:space:]]*--skip[[:space:]]+--filter-l7=wireguard/--filter-l7=wireguard/
      выкл: s/^[[:space:]]*--filter-l7=wireguard/--skip --filter-l7=wireguard/
    """
    lines = cfg_text.splitlines()
    result = []
    inblk = False
    for line in lines:
        if re.match(r"^\s*#Z2R_WG_BEGIN\s*$", line):
            inblk = True
        elif re.match(r"^\s*#Z2R_WG_END\s*$", line):
            inblk = False
        if inblk:
            if want_on:
                line = re.sub(r"^\s*--skip\s+--filter-l7=wireguard",
                              "--filter-l7=wireguard", line)
            else:
                line = re.sub(r"^\s*--filter-l7=wireguard",
                              "--skip --filter-l7=wireguard", line)
        result.append(line)
    return "\n".join(result) + ("\n" if cfg_text.endswith("\n") else "")


# ===========================================================================
# Fallback (безразборный режим) — порт из webui/cgi-bin/_lib.sh
# ===========================================================================

def _fallback_current_strategy(profile, cfg_text):
    """_fallback_current_strategy() — _lib.sh: Получить текущую стратегию для fallback-блока."""
    if profile == 9:
        begin, end = "#Z2R_FALLBACK_HTTP_BEGIN", "#Z2R_FALLBACK_HTTP_END"
    else:
        begin, end = "#Z2R_FALLBACK_BEGIN", "#Z2R_FALLBACK_END"
    inblk = False
    n = 0
    for line in cfg_text.splitlines():
        if re.match(r"^\s*" + re.escape(begin) + r"\s*$", line):
            inblk = True
            continue
        if re.match(r"^\s*" + re.escape(end) + r"\s*$", line):
            break
        if not inblk:
            continue
        if re.match(r"^--filter-tcp=", line):
            n += 1
            if re.match(r"^--skip\s", line):
                continue
            if "--hostlist-domains= --" in line or line.rstrip().endswith("--hostlist-domains="):
                return n
    return 0


def _fallback_set_strategy(profile, strategy, cfg_text):
    """_fallback_set_strategy() — _lib.sh: Установить стратегию для fallback-блока."""
    if profile == 9:
        begin, end = "#Z2R_FALLBACK_HTTP_BEGIN", "#Z2R_FALLBACK_HTTP_END"
    else:
        begin, end = "#Z2R_FALLBACK_BEGIN", "#Z2R_FALLBACK_END"
    lines = cfg_text.splitlines()
    result = []
    inblk = False
    count = 0
    changed = False
    for line in lines:
        if re.match(r"^\s*" + re.escape(begin) + r"\s*$", line):
            inblk = True
            result.append(line)
            continue
        if re.match(r"^\s*" + re.escape(end) + r"\s*$", line):
            inblk = False
            result.append(line)
            continue
        if inblk and re.match(r"^--filter-tcp=", line):
            count += 1
            # Убираем --skip если есть
            line = re.sub(r"^\s*--skip\s+", "", line)
            # Сбрасываем все строки на none.dom
            line = line.replace("--hostlist-domains= --", "--hostlist-domains=none.dom --")
            if line.rstrip().endswith("--hostlist-domains="):
                line = line.rstrip()[:-len("--hostlist-domains=")] + "--hostlist-domains=none.dom"
            # Если это целевая стратегия и target > 0 — активируем
            if strategy > 0 and count == strategy:
                line = line.replace("--hostlist-domains=none.dom --", "--hostlist-domains= --")
                if line.rstrip().endswith("--hostlist-domains=none.dom"):
                    line = line.rstrip()[:-len("--hostlist-domains=none.dom")] + "--hostlist-domains="
                changed = True
            # Если target == 0 — добавляем --skip ко всем строкам
            if strategy == 0:
                line = "--skip " + line
        result.append(line)
    return "\n".join(result) + ("\n" if cfg_text.endswith("\n") else "")


def _fallback_state(cfg_text):
    """_fallback_state() — _lib.sh: config_mode_text fallback (с guard авторотации)."""
    return config_mode_text("fallback", cfg_text)


def _fallback_set_state(cfg_text, want_on):
    """backup_smart_set_fallback() — lib/actions.sh: добавляет/убирает --skip
    в блоках #Z2R_FALLBACK* (no-op при включённой авторотации)."""
    if config_mode_text("auto_mode", cfg_text) == "включен":
        return cfg_text
    lines = cfg_text.splitlines()
    result = []
    inblk = False
    for line in lines:
        if re.match(r"^\s*#Z2R_FALLBACK(_HTTP)?_BEGIN\s*$", line):
            inblk = True
        elif re.match(r"^\s*#Z2R_FALLBACK(_HTTP)?_END\s*$", line):
            inblk = False
        if inblk:
            line = re.sub(r"^\s*--skip\s+", "", line)
            if not want_on and re.match(r"^--.*filter-tcp=", line):
                line = "--skip " + line
        result.append(line)
    return "\n".join(result) + ("\n" if cfg_text.endswith("\n") else "")


def _udp_games_set_skip(cfg_text, want_on):
    """_udp_games_set_skip() — локальная копия backup_smart_set_udp_games
    (lib/actions.sh:1264). Точечная замена в блоке «#Стратегии для игрового UDP»:
    добавляет/убирает --skip перед --filter-udp=1026. Диапазон до ближайшего --new.
    """
    lines = cfg_text.splitlines()
    result = []
    inblk = False
    for line in lines:
        if "#Стратегии для игрового UDP" in line:
            inblk = True
        elif inblk and re.match(r"^\s*--new\s*$", line):
            inblk = False

        if inblk:
            if want_on:
                line = re.sub(r"^--skip\s+--filter-udp=1026", "--filter-udp=1026", line)
            else:
                line = re.sub(r"^--filter-udp=1026", "--skip --filter-udp=1026", line)
        result.append(line)
    return "\n".join(result) + ("\n" if cfg_text.endswith("\n") else "")


# ===========================================================================
# Порт сеттеров lib/actions.sh: RST guard, reasm, QUIC443, hostlist, авторотация
# ===========================================================================

def _apply_rst_guard(cfg_text, want_on):
    """backup_smart_set_rst_guard() — lib/actions.sh."""
    src, dst = ("circular_locked", "rst_guard_locked") if want_on else ("rst_guard_locked", "circular_locked")
    result = []
    in_fb = False
    for line in cfg_text.splitlines():
        if re.match(r"^\s*#Z2R_FALLBACK_BEGIN\s*$", line):
            in_fb = True
        elif re.match(r"^\s*#Z2R_FALLBACK_END\s*$", line):
            in_fb = False
        if in_fb:
            if want_on:
                if re.match(r"^--filter-tcp=443 --filter-l7=tls$", line):
                    line = "--filter-tcp=443"
                elif re.match(r"^--skip --filter-tcp=443 --filter-l7=tls$", line):
                    line = "--skip --filter-tcp=443"
                line = line.replace(
                    "--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello",
                    "--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello,empty")
            else:
                if re.match(r"^--filter-tcp=443$", line):
                    line = "--filter-tcp=443 --filter-l7=tls"
                elif re.match(r"^--skip --filter-tcp=443$", line):
                    line = "--skip --filter-tcp=443 --filter-l7=tls"
                line = line.replace(
                    "--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello,empty",
                    "--payload=tls_client_hello,http_req,http_reply,unknown,tls_server_hello")
        for key in RST_GUARD_KEYS:
            line = line.replace("--lua-desync={0}:key={1}".format(src, key),
                                "--lua-desync={0}:key={1}".format(dst, key))
        result.append(line)
    return "\n".join(result) + ("\n" if cfg_text.endswith("\n") else "")


def _apply_reasm(cfg_text, want_on):
    """backup_smart_set_reasm() — lib/actions.sh: --reasm-disable после NFQWS2_OPT="."""
    lines = cfg_text.splitlines()
    if want_on:
        if any(re.match(r"^\s*--reasm-disable\s*$", l) for l in lines):
            return cfg_text
        result = []
        inserted = False
        for line in lines:
            result.append(line)
            if not inserted and re.match(r'^NFQWS2_OPT="', line):
                result.append("--reasm-disable")
                inserted = True
        return "\n".join(result) + ("\n" if cfg_text.endswith("\n") else "")
    keep = [l for l in lines if not re.match(r"^\s*--reasm-disable\s*$", l)]
    if len(keep) == len(lines):
        return cfg_text
    return "\n".join(keep) + ("\n" if cfg_text.endswith("\n") else "")


def config_quic443_state(cfg_text):
    """backup_smart_quic443_state() — lib/actions.sh: '1'/'0'/'' (блока нет)."""
    inblk = False
    for line in cfg_text.splitlines():
        if re.match(r"^\s*#Z2R_QUIC443_BEGIN\s*$", line):
            inblk = True
            continue
        if re.match(r"^\s*#Z2R_QUIC443_END\s*$", line):
            break
        if not inblk:
            continue
        if re.match(r"^\s*--filter-udp=443\s*$", line):
            return "1"
        if re.match(r"^\s*--skip\s+--filter-udp=443\s*$", line):
            return "0"
    return ""


def config_quic443_state_text(cfg_text):
    """_quic443_state_text() — _lib.sh."""
    return {"1": "включены", "0": "выключены"}.get(config_quic443_state(cfg_text), "неизвестно")


def _apply_quic443(cfg_text, want_on):
    """backup_smart_set_quic443() — lib/actions.sh: --skip перед --filter-udp=443."""
    lines = cfg_text.splitlines()
    result = []
    inblk = False
    for line in lines:
        if re.match(r"^\s*#Z2R_QUIC443_BEGIN\s*$", line):
            inblk = True
        elif re.match(r"^\s*#Z2R_QUIC443_END\s*$", line):
            inblk = False
        if inblk:
            if want_on:
                line = re.sub(r"^\s*--skip\s+--filter-udp=443\s*$", "--filter-udp=443", line)
            else:
                line = re.sub(r"^\s*--filter-udp=443\s*$", "--skip --filter-udp=443", line)
        result.append(line)
    return "\n".join(result) + ("\n" if cfg_text.endswith("\n") else "")


def _apply_hostlist(cfg_text, want_auto):
    """backup_smart_set_hostlist() — lib/actions.sh: MODE_FILTER + <HOSTLIST>."""
    if want_auto:
        cfg_text = re.sub(r"^MODE_FILTER=hostlist", "MODE_FILTER=autohostlist", cfg_text, flags=re.M)
        cfg_text = re.sub(r"(--hostlist=/opt/(?:zapret2|zator)/extra_strats/TCP_RKN_list\.txt)",
                          r"\1 <HOSTLIST>", cfg_text)
    else:
        cfg_text = re.sub(r"^MODE_FILTER=autohostlist", "MODE_FILTER=hostlist", cfg_text, flags=re.M)
        cfg_text = re.sub(r"(--hostlist=/opt/(?:zapret2|zator)/extra_strats/TCP_RKN_list\.txt) <HOSTLIST>",
                          r"\1", cfg_text)
    return cfg_text


def _auto_pair_ids(cfg_text, mode="paired"):
    """config_auto_pair_ids() — lib/config.sh:62. None = невалидная раскладка."""
    lines = cfg_text.splitlines()
    for marker in ("#Z2R_AUTO_STANDARD_BEGIN", "#Z2R_AUTO_STANDARD_END",
                   "#Z2R_AUTO_BEGIN", "#Z2R_AUTO_END"):
        if lines.count(marker) != 1:
            return None
    result = []
    for m in re.finditer(r"^#Z2R_AUTO_STANDARD_(\w+)_BEGIN$", cfg_text, re.M):
        uid = m.group(1)
        if lines.count("#Z2R_AUTO_STANDARD_{0}_BEGIN".format(uid)) != 1:
            return None
        if lines.count("#Z2R_AUTO_STANDARD_{0}_END".format(uid)) != 1:
            return None
        if mode != "standard":
            ab = lines.count("#Z2R_AUTO_{0}_BEGIN".format(uid))
            ae = lines.count("#Z2R_AUTO_{0}_END".format(uid))
            if ab == 0 and ae == 0:
                continue
            if not (ab == 1 and ae == 1):
                return None
        result.append(uid)
    return result or None


def _auto_layout_valid(cfg_text):
    """config_auto_layout_valid() — lib/config.sh:88."""
    standard = _auto_pair_ids(cfg_text, "standard")
    auto = _auto_pair_ids(cfg_text)
    if standard is None or auto is None:
        return False
    if standard != ["1", "2", "3", "4", "8", "3S", "9"]:
        return False
    if auto != ["3", "4", "9"]:
        return False
    return len(re.findall(r"^#Z2R_AUTO_FALLBACK_WAS=[01]$", cfg_text, re.M)) == 1


def _set_auto_mode(cfg_text, enable):
    """config_set_auto_mode() — lib/actions.sh. None = не удалось применить."""
    if enable not in (0, 1) or not _auto_layout_valid(cfg_text):
        return None
    lines = cfg_text.splitlines()
    standard_ids = _auto_pair_ids(cfg_text, "standard")
    auto_ids = _auto_pair_ids(cfg_text)
    is_on = "#Z2R_AUTO_MODE=1" in lines
    is_off = "#Z2R_AUTO_MODE=0" in lines
    if (enable == 1 and is_on) or (enable == 0 and is_off):
        return cfg_text

    def block_sub(prefix, sub_fn):
        inblk = False
        for i, line in enumerate(lines):
            if line == "#{0}_BEGIN".format(prefix):
                inblk = True
                continue
            if line == "#{0}_END".format(prefix):
                inblk = False
                continue
            if inblk:
                lines[i] = sub_fn(line)

    def unskip(line):
        return re.sub(r"^--skip\s+", "", line)

    def skip_tcp(line):
        if re.match(r"^--.*filter-tcp=", line):
            return "--skip " + line
        return line

    if enable == 1:
        fallback_on = 1 if config_mode_text("fallback", cfg_text) == "включен" else 0
        lines = [re.sub(r"^#Z2R_AUTO_FALLBACK_WAS=[01]$",
                        "#Z2R_AUTO_FALLBACK_WAS={0}".format(fallback_on), l) for l in lines]
        for uid in auto_ids:
            block_sub("Z2R_AUTO_{0}".format(uid), unskip)
        for uid in standard_ids:
            block_sub("Z2R_AUTO_STANDARD_{0}".format(uid), lambda l: skip_tcp(unskip(l)))
        lines = [re.sub(r"^#Z2R_AUTO_MODE=0$", "#Z2R_AUTO_MODE=1", l) for l in lines]
    else:
        fallback_was_m = re.search(r"^#Z2R_AUTO_FALLBACK_WAS=([01])$", cfg_text, re.M)
        fallback_was = fallback_was_m.group(1) if fallback_was_m else "0"
        for uid in auto_ids:
            block_sub("Z2R_AUTO_{0}".format(uid), lambda l: skip_tcp(unskip(l)))
        for uid in standard_ids:
            def std_sub(line, uid=uid):
                line = unskip(line)
                if uid in ("8", "9") and fallback_was == "0":
                    line = skip_tcp(line)
                return line
            block_sub("Z2R_AUTO_STANDARD_{0}".format(uid), std_sub)
        lines = [re.sub(r"^#Z2R_AUTO_MODE=1$", "#Z2R_AUTO_MODE=0", l) for l in lines]
    return "\n".join(lines) + ("\n" if cfg_text.endswith("\n") else "")


# ===========================================================================
# Порт портов NFQWS2 (lib/actions.sh: ports_*)
# ===========================================================================

def ports_split(line, anchor):
    """ports_split() — lib/actions.sh: (user, base) по якорю 80/443."""
    user, base = [], []
    started = False
    for t in (line.split(",") if line else []):
        if not started and t == anchor:
            started = True
        if not started:
            if t:
                user.append(t)
        else:
            if t:
                base.append(t)
    if not started:
        return "", line or ""
    return ",".join(user), ",".join(base)


def ports_join(a, b):
    """ports_join() — lib/actions.sh."""
    if a and b:
        return a + "," + b
    return a or b


def ports_validate(token):
    """ports_validate() — lib/actions.sh: порт или диапазон 1-65535."""
    m = re.match(r"^(\d+)(?:-(\d+))?$", token)
    if not m:
        return False
    start = int(m.group(1))
    end = int(m.group(2)) if m.group(2) else start
    if start < 1 or end > 65535 or start > end:
        return False
    return True


def _ports_set_rkn_filter(cfg_text, user):
    """ports_set_rkn_filter() — lib/actions.sh: --filter-tcp блока RKN."""
    tcp_line = config_get_var(cfg_text, "NFQWS2_PORTS_TCP") or ""
    _user, base = ports_split(tcp_line, "80")
    rkn_ports = ports_join(user, base)
    lines = cfg_text.splitlines()
    inblk = False
    for i, line in enumerate(lines):
        m = re.match(r"^#(Z2R_AUTO_STANDARD_3|Z2R_AUTO_3)_(BEGIN|END)$", line)
        if m:
            inblk = m.group(2) == "BEGIN"
            continue
        if inblk:
            line = re.sub(r"^--filter-tcp=.*--filter-l7=tls\s*$",
                          "--filter-tcp={0} --filter-l7=tls".format(rkn_ports), line)
            line = re.sub(r"^--skip --filter-tcp=.*--filter-l7=tls\s*$",
                          "--skip --filter-tcp={0} --filter-l7=tls".format(rkn_ports), line)
            lines[i] = line
    return "\n".join(lines) + ("\n" if cfg_text.endswith("\n") else "")


def ports_apply_add(cfg_text, proto, raw):
    """ports_apply_add() — lib/actions.sh. Возвращает (cfg, added, skipped)."""
    var = "NFQWS2_PORTS_{0}".format(proto.upper())
    anchor = "80" if proto == "tcp" else "443"
    line = config_get_var(cfg_text, var) or ""
    user, base = ports_split(line, anchor)
    raw = re.sub(r"\s+", "", raw or "")
    added, skipped = [], []
    for tok in raw.split(","):
        if not tok:
            continue
        if not ports_validate(tok) or tok in line.split(",") or tok in user.split(","):
            skipped.append(tok)
            continue
        user = ports_join(user, tok)
        added.append(tok)
    if not added:
        return cfg_text, added, skipped
    cfg_text = config_set_var(cfg_text, var, ports_join(user, base))
    if proto == "tcp":
        cfg_text = _ports_set_rkn_filter(cfg_text, user)
    return cfg_text, added, skipped


def ports_apply_remove(cfg_text, proto, token):
    """ports_apply_remove() — lib/actions.sh. None = порта нет в пользовательских."""
    var = "NFQWS2_PORTS_{0}".format(proto.upper())
    anchor = "80" if proto == "tcp" else "443"
    line = config_get_var(cfg_text, var) or ""
    user, base = ports_split(line, anchor)
    if token not in user.split(","):
        return None
    new_user = ",".join([t for t in user.split(",") if t and t != token])
    cfg_text = config_set_var(cfg_text, var, ports_join(new_user, base))
    if proto == "tcp":
        cfg_text = _ports_set_rkn_filter(cfg_text, new_user)
    return cfg_text


# ===========================================================================
# Фейковое состояние роутера
# ===========================================================================

class FakeRouterState:
    """Всё фейковое состояние живёт в self.tmpdir. Потокобезопасно через лок."""

    def __init__(self, config_default_path, service_state, lock_state,
                 check_result, simulate_error, provider, fake_dir, repo_root=None,
                 delay=3.0, status_delay=0.0):
        self.tmpdir = tempfile.mkdtemp(prefix="z2r_fake_")
        self.lock = threading.Lock()

        # Директория с fake-файлами
        self.fake_dir = fake_dir

        # Фейковый config — копия config.default
        self.config_path = os.path.join(self.tmpdir, "config")
        shutil.copyfile(config_default_path, self.config_path)
        self.cfg_text = _read_text(self.config_path)

        # Фейковая orchestra-директория
        self.orch_dir = os.path.join(self.tmpdir, "orchestra")
        os.makedirs(self.orch_dir, exist_ok=True)
        self.lock_file = os.path.join(self.orch_dir, "locked.tsv")
        self.lock_manual_file = os.path.join(self.orch_dir, "locked.manual.tsv")
        for f in (self.lock_file, self.lock_manual_file):
            open(f, "w", encoding="utf-8").close()

        # Фейковый profile.lock
        self.profile_lock = os.path.join(self.tmpdir, "profile.lock")
        open(self.profile_lock, "w", encoding="utf-8").close()

        # Списки доменов: netrogat.txt (копируем из репо), TCP_Custom.txt,
        # TCP_RKN_domains_by_substring.txt и netrogat_substrings.txt (пустые —
        # как в свежем deploy). Пути имитируют layout /opt/zator
        # (см. netrogat_file/custom_rkn_file в lib/strategies.sh).
        self.lists_dir = os.path.join(self.tmpdir, "lists")
        self.extra_strats_dir = os.path.join(self.tmpdir, "extra_strats")
        os.makedirs(self.lists_dir, exist_ok=True)
        os.makedirs(self.extra_strats_dir, exist_ok=True)
        self.netrogat_file = os.path.join(self.lists_dir, "netrogat.txt")
        self.netrogat_substring_file = os.path.join(self.lists_dir, "netrogat_substrings.txt")
        self.custom_rkn_file = os.path.join(self.extra_strats_dir, "TCP_Custom.txt")
        self.rkn_substring_file = os.path.join(self.extra_strats_dir, "TCP_RKN_domains_by_substring.txt")
        src_netrogat = os.path.join(repo_root, "lists", "netrogat.txt") if repo_root else ""
        if repo_root and os.path.isfile(src_netrogat):
            shutil.copyfile(src_netrogat, self.netrogat_file)
        else:
            open(self.netrogat_file, "w", encoding="utf-8").close()
        for f in (self.netrogat_substring_file, self.custom_rkn_file, self.rkn_substring_file):
            open(f, "w", encoding="utf-8").close()

        # Динамические флаги
        self.nfqws2_running = (service_state == "running")
        self.check_result = check_result  # ok | fail | mixed
        self.simulate_error = set(simulate_error or [])
        self.provider = provider
        self.rst_guard_lua = True
        self.backups = []

        # Искусственные задержки (сек) на «медленных» операциях — чтобы
        # тестировать спиннеры/«Обновление...»/«Сохранение и проверка...».
        # zapret2 на реальном устройстве стартует не мгновенно, проверки тоже
        # занимают время. Меняются в рантайме через dev-API.
        self.delays = {
            "service": float(delay),
            "check": float(delay),
            "set-lock": float(delay),
            "clear-lock": float(delay),
            "status": float(status_delay),
            "provider": 0.5,
        }

        # Применяем стартовый сценарий локов
        self._apply_lock_state(lock_state)

    # --- внутреннее -------------------------------------------------------

    def _save_config(self):
        with open(self.config_path, "w", encoding="utf-8") as fh:
            fh.write(self.cfg_text)

    def _apply_lock_state(self, lock_state):
        """Разбор --lock-state: 'none' | 'profile=strat,...' (strat: N|0|auto)."""
        if not lock_state or lock_state == "none":
            return
        for token in lock_state.split(","):
            token = token.strip()
            if not token:
                continue
            if "=" not in token:
                continue
            prof_s, strat = token.split("=", 1)
            prof_s, strat = prof_s.strip(), strat.strip()
            if not re.match(r"^[1-9]$", prof_s):
                continue
            prof = int(prof_s)
            pl = proto_list(prof)
            if not pl:
                continue
            # Записываем как сохранённое состояние (profile.lock + locked.tsv)
            profile_state_set_and_apply(self, prof, pl, strat)

    # --- чтение для api_status -------------------------------------------

    def strategy_locks_status_text(self):
        """strategy_locks_status_text() — _lib.sh:139."""
        for f in (self.lock_file, self.lock_manual_file, self.profile_lock):
            if os.path.exists(f) and os.path.getsize(f) > 0:
                return "Есть"
        return "Нет"

    def profile_json(self, pid, label, desc):
        proto = profile_proto(pid)
        is_fallback = pid in FALLBACK_PROFILES
        is_udp_games = (pid == UDP_GAMES_PROFILE)
        # current_lock читаем из profile.lock + orchestra-lock — как реальный
        # profile_json_fallback → profile_state_display. Для 8/9 orchestra-lock
        # живёт в locked.manual.tsv (profile_config_orch_set); config-блок не
        # хранит выбор стратегии (его делает runtime circular_locked:key=N).
        orch_file = self.lock_manual_file if is_fallback else self.lock_file
        current = profile_state_get(self.profile_lock, orch_file, pid, proto)
        fallback_enabled = (_fallback_state(self.cfg_text) == "включен") if is_fallback else None
        udp_games_enabled = (config_mode_text("udp_games", self.cfg_text) == "Включен") if is_udp_games else None
        maxstrat = config_profile_max_strategy(pid, self.cfg_text)
        result = {
            "profile": pid,
            "label": label,
            "description": desc,
            "current_lock": current,
            "max_strategy": maxstrat,
        }
        if is_fallback:
            result["is_fallback"] = True
            result["fallback_enabled"] = fallback_enabled
        if is_udp_games:
            result["is_udp_games"] = True
            result["udp_games_enabled"] = udp_games_enabled
        return result

    def all_profiles_json(self):
        return [self.profile_json(p, l, d) for (p, l, d) in PROFILES]

    def build_status(self):
        wg_raw = config_wg_state(self.cfg_text)
        if wg_raw == "1":
            wg_state = "включено"
        elif wg_raw == "0":
            wg_state = "выключено"
        else:
            wg_state = "недоступно"
        return {
            "zapret2_running": bool(self.nfqws2_running),
            "strategy_locks_status": self.strategy_locks_status_text(),
            "hostlist_mode": config_mode_text("hostlist", self.cfg_text),
            "fwtype": config_mode_text("fwtype", self.cfg_text),
            "flowoffload": config_mode_text("flowoffload", self.cfg_text),
            "tls_blob_mode": config_mode_text("tls_blob_menu", self.cfg_text),
            "wireguard": wg_state,
            "auto_mode": config_mode_text("auto_mode", self.cfg_text),
            "rst_guard": config_mode_text("rst_guard", self.cfg_text),
            "reasm": config_mode_text("reasm_disable", self.cfg_text),
            "quic443": config_quic443_state_text(self.cfg_text),
            "provider": self.provider,
            "profiles": self.all_profiles_json(),
        }

    # --- генерация результатов проверок ----------------------------------

    def _pair(self, idx):
        """tls12/tls13 по режиму check_result (random — случайно на каждый запрос)."""
        if self.check_result == "random":
            return (1 if random.random() < 0.7 else 0,
                    1 if random.random() < 0.7 else 0)
        if self.check_result == "ok":
            return 1, 1
        if self.check_result == "fail":
            return 0, 0
        # mixed: чередуем, чтобы в UI были и OK, и FAIL
        return (idx % 2), (1 - idx % 2)

    def _domains_check(self, domain):
        return {"results": [self._check_item(domain, "https://{0}/".format(domain), 0)]}

    def _version_detail(self, ok, ver):
        if ver == "1.2":
            why = "важно для ТВ и т.п."
        else:
            why = "важно в основном для всего современного"
        if ok:
            return {
                "code": 200,
                "proto": "HTTP/2",
                "time": "0.8",
                "ip": "203.0.113.1",
                "state": "ok",
                "text": "Есть ответ по TLS {0} ({1}): HTTP/2 200 за 0.8 с".format(ver, why),
            }
        text = ("Нет ответа по TLS {0} ({1}) Таймаут 5сек. "
                "Проверьте доступность вручную. Возможно ошибка теста.").format(ver, why)
        return {"code": 0, "proto": "-", "time": "-", "ip": "-",
                "state": "timeout", "text": text}

    def _download_detail(self):
        return {
            "code": 206,
            "size": 65536,
            "time": "1.2",
            "state": "ok",
            "text": "Данные: получено 65536 байт за 1.2 с (код 206)",
        }

    def _download_zero_detail(self):
        return {
            "code": 200,
            "size": 0,
            "time": "0.5",
            "state": "zero",
            "text": ("Данные: 0 байт — TLS работает, но тело ответа не приходит. "
                     "Проверьте доступность вручную. Возможно ошибка теста."),
        }

    def _download_cut_detail(self):
        return {
            "code": 200,
            "size": 4300,
            "time": "12.0",
            "state": "cut",
            "text": ("Данные оборвались: получено 4300 байт и поток остановился. "
                     "Проверьте доступность вручную. Возможно ошибка теста."),
        }

    def _check_item(self, label, target, idx):
        t12, t13 = self._pair(idx)
        d12 = self._version_detail(t12, "1.2")
        d13 = self._version_detail(t13, "1.3")
        download = None
        if t12 or t13:
            download = self._download_detail()
            if self.check_result == "random":
                r = random.random()
                if r < 0.15:
                    download = self._download_zero_detail()
                elif r < 0.25:
                    download = self._download_cut_detail()
        if not t12 and not t13:
            verdict = "fail"
            text = ("Нет ответа: нет ответа от сервера (таймаут). "
                    "Стратегия, скорее всего, не работает. "
                    "Проверьте доступность вручную. Возможно ошибка теста.")
        elif download is not None and download["state"] == "zero":
            verdict = "fail"
            text = ("TLS работает, но данные не приходят — страница не скачивается. "
                    "Проверьте доступность вручную. Возможно ошибка теста.")
        elif download is not None and download["state"] == "cut":
            verdict = "fail"
            text = ("TLS работает, но поток данных срезается после {0} байт — "
                    "похоже на блокировку по содержимому. "
                    "Проверьте доступность вручную. Возможно ошибка теста.").format(download["size"])
        elif t13:
            verdict = "ok"
            text = "Сайт доступен: TLS работает, данные идут."
        else:
            verdict = "warn"
            text = ("Сайт отвечает только по TLS 1.2 — TLS 1.3 недоступен, "
                    "современные браузеры могут не открыться. Проверьте вручную.")
        return {
            "label": label,
            "target": target,
            "tls12": t12,
            "tls13": t13,
            "verdict": verdict,
            "text": text,
            "tls12_detail": d12,
            "tls13_detail": d13,
            "download": download,
        }

    def build_check(self):
        results = []
        for i, (label, target) in enumerate(CHECK_TARGETS):
            if target is None:
                target = "https://{0}/".format(YT_CLUSTER_FALLBACK)
            results.append(self._check_item(label, target, i))
        return {"results": results}

    def profile_check_json(self, profile):
        """profile_check_json() — _lib.sh:180."""
        pid = int(profile)
        if pid in (5, 6):
            return {"results": [], "message": UDP_CHECK_MESSAGE}
        targets = PROFILE_CHECK.get(pid, [])
        if not targets:
            return {"results": []}
        results = []
        for i, (label, target) in enumerate(targets):
            if target is None:
                target = "https://{0}/".format(YT_CLUSTER_FALLBACK)
            results.append(self._check_item(label, target, i))
        return {"results": results}

    # --- TLS blob -----------------------------------------------------------

    def build_tls_blob_settings(self):
        """api_tls_blob_get() — _lib.sh."""
        current_blob = config_tls_blob_current(self.cfg_text)
        current_mode = config_tls_blob_mode_value(self.cfg_text)
        available_blobs = _scan_fake_blobs(self.fake_dir)
        return {
            "current_mode": current_mode,
            "current_blob": current_blob,
            "available_blobs": available_blobs,
        }

    def apply_tls_blob(self, blob):
        """api_tls_blob_set() — _lib.sh."""
        if blob == "fake_default_tls":
            self.cfg_text = _apply_tls_blob_default(self.cfg_text)
            self._save_config()
            return {"ok": True, "reboot_required": True}
        if not (blob.startswith("tls_") and blob.endswith(".bin")) and blob != "custom_tls.bin":
            raise ValueError("Некорректное значение блоба: {0}".format(blob))
        if not os.path.isfile(os.path.join(self.fake_dir, blob)):
            raise ValueError("Файл блоба не существует: {0}".format(blob))
        if not re.search(r"--blob=maxru:@/opt/(?:zapret2|zator)/files/fake/", self.cfg_text):
            raise ValueError("Строка --blob=maxru не найдена в конфиге")
        self.cfg_text = _apply_tls_blob(self.cfg_text, blob)
        self._save_config()
        return {"ok": True, "reboot_required": True}

    # --- WireGuard blob / repeats -----------------------------------------

    def build_wg_blob_settings(self):
        """api_wg_blob_get() — _lib.sh."""
        current_blob = config_wg_blob_current(self.cfg_text)
        current_repeats = config_wg_repeats_current(self.cfg_text)
        available_blobs = _scan_wg_blobs(self.fake_dir)
        return {
            "current_blob": current_blob,
            "current_repeats": current_repeats,
            "available_blobs": available_blobs,
        }

    def apply_wg_blob(self, blob):
        """api_wg_blob_set() — _lib.sh."""
        # Валидация: только wg_initial_fake_*
        if not blob.startswith("wg_initial_fake_"):
            raise ValueError("Некорректное значение блоба")
        if not os.path.isfile(os.path.join(self.fake_dir, blob)):
            raise ValueError("Файл блоба не существует")
        if not re.search(r"--blob=fakewgblob:@/opt/(?:zapret2|zator)/files/fake/", self.cfg_text):
            raise ValueError("Стратегия WireGuard не найдена в конфиге (нет --blob=fakewgblob:@...)")
        self.cfg_text = _apply_wg_blob(self.cfg_text, blob)
        self._save_config()
        return {"ok": True, "reboot_required": True}

    def apply_wg_repeats(self, repeats):
        """api_wg_repeats_set() — _lib.sh."""
        # Валидация: целое число 2..99 (как в menu_action_wg_repeats)
        if not re.match(r"^[0-9]+$", str(repeats)):
            raise ValueError("Некорректное значение repeats")
        val = int(repeats)
        if val < 2 or val > 99:
            raise ValueError("Значение repeats должно быть от 2 до 99")
        if "blob=fakewgblob:repeats=" not in self.cfg_text:
            raise ValueError("Стратегия WireGuard не найдена в конфиге (нет blob=fakewgblob:repeats=)")
        self.cfg_text = _apply_wg_repeats(self.cfg_text, val)
        self._save_config()
        return {"ok": True, "reboot_required": True}

    def build_wg_state_settings(self):
        """api_wg_state_get() — _lib.sh.

        Состояние определяется по наличию --skip перед --filter-l7=wireguard
        в блоке #Z2R_WG_* — единый источник правды с CLI (backup_smart_wg_state).
        """
        state = config_wg_state(self.cfg_text)
        return {
            "state": state,
            "enabled": state == "1",
        }

    def apply_wg_state(self, enabled):
        """api_wg_state_set() — _lib.sh.

        Повторяет menu_action_toggle_wireguard_fake (lib/actions.sh:340):
        точечно добавляет/убирает --skip перед --filter-l7=wireguard в блоке
        #Z2R_WG_* (backup_smart_set_wireguard).
        """
        want_on = enabled in (1, "1", True)
        if config_wg_state(self.cfg_text) == "":
            raise ValueError("Стратегия WireGuard не найдена в конфиге (нет блока #Z2R_WG_*)")
        self.cfg_text = _apply_wg_state(self.cfg_text, want_on)
        self._save_config()
        return {"ok": True, "reboot_required": True}

    # --- Fallback (безразборный режим) ------------------------------------

    def build_fallback_settings(self):
        """api_fallback_get() — _lib.sh.

        Стратегии TLS (8) и HTTP (9) читаются из profile.lock + locked.manual.tsv
        (profile_state_display), а не из config-блоков: источник правды для
        fallback — orchestra-lock, который читает runtime circular_locked.
        """
        state = _fallback_state(self.cfg_text)
        tls_strat = profile_state_get(self.profile_lock, self.lock_manual_file, 8, "tls")
        http_strat = profile_state_get(self.profile_lock, self.lock_manual_file, 9, "http")
        tls_max = config_profile_max_strategy(8, self.cfg_text)
        http_max = config_profile_max_strategy(9, self.cfg_text)
        return {
            "state": state,
            "tls_strategy": tls_strat,
            "http_strategy": http_strat,
            "tls_max": tls_max,
            "http_max": http_max,
        }

    def apply_fallback_state(self, enabled):
        """api_fallback_state_set() — _lib.sh (guard авторотации + общий сеттер)."""
        want_on = enabled in (1, "1", True)
        if config_mode_text("auto_mode", self.cfg_text) == "включен":
            raise ConflictError("Безразборный режим недоступен при включённой авторотации TCP/HTTP. "
                                "Сначала выключите авторотацию.")
        self.cfg_text = _fallback_set_state(self.cfg_text, want_on)
        self._save_config()
        return {"ok": True, "reboot_required": True}

    def build_udp_games_settings(self):
        """api_udp_games_get() — _lib.sh.

        Состояние определяется через config_mode_text udp_games (наличие
        1026-65531 в NFQWS2_PORTS_UDP) — единый источник правды с CLI.
        """
        state = config_mode_text("udp_games", self.cfg_text)
        ports = config_get_var(self.cfg_text, "NFQWS2_PORTS_UDP") or ""
        return {
            "state": state,
            "enabled": state == "Включен",
            "ports": ports,
        }

    def apply_udp_games_state(self, enabled):
        """api_udp_games_set() — _lib.sh.

        Повторяет menu_action_toggle_udp_range (lib/actions.sh:175):
        меняет ОБА механизма — NFQWS2_PORTS_UDP (добавление/удаление
        1026-65531) и --skip в блоке игрового UDP (_udp_games_set_skip).
        """
        want_on = enabled in (1, "1", True)
        current_ports = config_get_var(self.cfg_text, "NFQWS2_PORTS_UDP") or ""
        if want_on:
            new_ports = csv_add_tokens(current_ports or "443", "1026-65531")
            self.cfg_text = config_set_var(self.cfg_text, "NFQWS2_PORTS_UDP", new_ports)
            self.cfg_text = _udp_games_set_skip(self.cfg_text, True)
        else:
            new_ports = csv_remove_tokens(current_ports, "1026-65531") or "443"
            self.cfg_text = config_set_var(self.cfg_text, "NFQWS2_PORTS_UDP", new_ports)
            self.cfg_text = _udp_games_set_skip(self.cfg_text, False)
        self._save_config()
        return {"ok": True, "reboot_required": True}

    def apply_fallback_strategy(self, profile, strategy):
        """api_fallback_strategy_set() — _lib.sh.

        Фиксация стратегии fallback (8/9) — через orchestra-lock
        (profile_state_set_and_apply → profile.lock + locked.manual.tsv), единый
        механизм с set-lock.cgi. Runtime-выбор делает circular_locked:key=N.
        """
        profile = int(profile)
        if profile not in (8, 9):
            raise ValueError("Некорректный профиль")
        if not re.match(r"^[0-9]+$", str(strategy)):
            raise ValueError("Некорректная стратегия")
        strat = int(strategy)
        max_strat = config_profile_max_strategy(profile, self.cfg_text)
        if strat != 0 and strat > max_strat:
            raise ValueError("Стратегия вне диапазона (макс: {0})".format(max_strat))
        pl = proto_list(profile)
        if not pl:
            raise ValueError("Не удалось определить протокол профиля")
        if not profile_state_set_and_apply(self, profile, pl, str(strat)):
            raise ValueError("Не удалось сохранить стратегию")
        return {"ok": True, "reboot_required": True}

    # --- Режимы (авторотация, hostlist, RST guard, reasm, QUIC443) -------

    def build_mode_settings(self, setting):
        """api_*_get() — _lib.sh."""
        if setting == "auto_mode":
            s = config_mode_text("auto_mode", self.cfg_text)
            return {"state": s, "enabled": s == "включен"}
        if setting == "hostlist":
            s = config_mode_text("hostlist", self.cfg_text)
            return {"state": s, "auto": s == "авто"}
        if setting == "rst_guard":
            s = config_mode_text("rst_guard", self.cfg_text)
            return {"state": s, "enabled": s == "включен", "lua_available": bool(self.rst_guard_lua)}
        if setting == "reasm":
            s = config_mode_text("reasm_disable", self.cfg_text)
            return {"state": s, "enabled": s == "включено"}
        if setting == "quic443":
            return {"state": config_quic443_state_text(self.cfg_text),
                    "enabled": config_quic443_state(self.cfg_text) == "1"}
        raise ValueError("Неизвестная настройка")

    def apply_mode_setting(self, setting, value):
        """api_*_set() — _lib.sh: переиспользуют сеттеры lib/actions.sh."""
        if value not in ("0", "1"):
            raise ValueError("Некорректное значение: {0}".format(value))
        want_on = value == "1"

        if setting == "auto_mode":
            if want_on and _fallback_state(self.cfg_text) == "включен":
                raise ConflictError("Авторотация недоступна при включённом безразборном режиме. "
                                    "Сначала выключите безразборный режим.")
            if not _auto_layout_valid(self.cfg_text):
                raise ValueError("В config не найдены маркеры авторежима. "
                                 "Обновите конфиг через CLI (пункт 5 главного меню).")
            new = _set_auto_mode(self.cfg_text, int(value))
            if new is None:
                raise ValueError("Не удалось переключить авторотацию")
            self.cfg_text = new
            self._save_config()
            restarted = bool(self.nfqws2_running)
            return {"ok": True, "restarted": restarted,
                    "state": config_mode_text("auto_mode", self.cfg_text)}

        if setting == "hostlist":
            self.cfg_text = _apply_hostlist(self.cfg_text, want_on)
            self._save_config()
            return {"ok": True, "reboot_required": True,
                    "state": config_mode_text("hostlist", self.cfg_text)}

        if setting == "rst_guard":
            if want_on and not self.rst_guard_lua:
                raise ValueError("Файл rst-guard.lua отсутствует на устройстве. "
                                 "Включите защиту один раз через CLI (пункт 18).")
            self.cfg_text = _apply_rst_guard(self.cfg_text, want_on)
            self._save_config()
            return {"ok": True, "reboot_required": True,
                    "state": config_mode_text("rst_guard", self.cfg_text)}

        if setting == "reasm":
            self.cfg_text = _apply_reasm(self.cfg_text, want_on)
            self._save_config()
            return {"ok": True, "reboot_required": True,
                    "state": config_mode_text("reasm_disable", self.cfg_text)}

        if setting == "quic443":
            if not config_quic443_state(self.cfg_text):
                raise ValueError("Блок QUIC (UDP443) не найден в конфиге. "
                                 "Обновите конфиг через CLI (пункт 5 главного меню).")
            self.cfg_text = _apply_quic443(self.cfg_text, want_on)
            self._save_config()
            return {"ok": True, "reboot_required": True,
                    "state": config_quic443_state_text(self.cfg_text)}

        raise ValueError("Неизвестная настройка")

    # --- Порты NFQWS2 ------------------------------------------------------

    def build_ports_settings(self):
        """api_ports_get() — _lib.sh."""
        def proto_json(proto):
            line = config_get_var(self.cfg_text, "NFQWS2_PORTS_{0}".format(proto.upper())) or ""
            user, base = ports_split(line, "80" if proto == "tcp" else "443")
            return {"full": line, "user": [t for t in user.split(",") if t], "base": base}
        return {"tcp": proto_json("tcp"), "udp": proto_json("udp")}

    def apply_ports_add(self, proto, value):
        """api_ports_add() — _lib.sh."""
        if proto not in ("tcp", "udp"):
            raise ValueError("Некорректный протокол: {0}".format(proto))
        self.cfg_text, added, skipped = ports_apply_add(self.cfg_text, proto, value or "")
        self._save_config()
        if not added:
            raise ValueError("Ничего не добавлено (некорректные значения или дубликаты): {0}".format(",".join(skipped)))
        return {"ok": True, "added": ",".join(added), "skipped": ",".join(skipped),
                "reboot_required": True}

    def apply_ports_remove(self, proto, value):
        """api_ports_remove() — _lib.sh."""
        if proto not in ("tcp", "udp"):
            raise ValueError("Некорректный протокол: {0}".format(proto))
        if proto == "udp" and value == "1026-65531":
            raise ValueError("Диапазон 1026-65531 управляется переключателем игрового UDP "
                             "на вкладке Настройки")
        new = ports_apply_remove(self.cfg_text, proto, value or "")
        if new is None:
            raise ValueError("Порт не найден среди добавленных: {0}".format(value))
        self.cfg_text = new
        self._save_config()
        return {"ok": True, "reboot_required": True}

    # --- Провайдер ----------------------------------------------------------

    def build_provider_settings(self):
        """api_provider_get() — _lib.sh."""
        return {"provider": self.provider}

    def apply_provider_set(self, name, city):
        """api_provider_set() — _lib.sh: provider_set_manual."""
        name = (name or "").replace("\n", "").replace("|", "")
        city = (city or "").replace("\n", "").replace("|", "")
        if not name.strip():
            raise ValueError("Укажите название провайдера")
        self.provider = "{0} - {1}".format(name, city) if city.strip() else name
        return {"ok": True, "provider": self.provider}

    def apply_provider_redetect(self):
        """api_provider_redetect() — _lib.sh: provider_force_redetect (эмуляция ASN-детекта)."""
        self.provider = "Ufanet - Podolsk"
        return {"ok": True, "provider": self.provider}

    # --- Бэкапы --------------------------------------------------------------

    def build_backups_list(self):
        """api_backups_list() — _lib.sh."""
        return {"items": list(self.backups)}

    def apply_backup_create(self):
        """api_backups_create() — _lib.sh: backup_create_core (эмуляция архива)."""
        name = "z2r_backup_{0}.tar".format(time.strftime("%Y%m%d_%H%M%S"))
        self.backups.insert(0, {
            "name": name,
            "size": 16384 + 512 * len(self.backups),
            "date": time.strftime("%Y-%m-%d %H:%M:%S"),
        })
        return {"ok": True, "name": name}

    def apply_backup_delete(self, name):
        """api_backups_delete() — _lib.sh: backup_delete_core."""
        for i, item in enumerate(self.backups):
            if item["name"] == name:
                del self.backups[i]
                return {"ok": True, "name": name}
        return None

    def apply_backup_import(self, orig, size):
        """api_backups_upload() — _lib.sh: backup_import_core (эмуляция архива)."""
        names = [b["name"] for b in self.backups]
        if re.match(r"^z2r_backup_\d{8}_\d{6}\.tar$", orig) and orig not in names:
            name = orig
        else:
            ts = time.strftime("%Y%m%d_%H%M%S")
            name = "z2r_backup_{0}.tar".format(ts)
            n = 0
            while name in names:
                n += 1
                name = "z2r_backup_{0}_{1}.tar".format(ts, n)
        self.backups.insert(0, {
            "name": name,
            "size": size,
            "date": time.strftime("%Y-%m-%d %H:%M:%S"),
        })
        return {"ok": True, "name": name}

    # --- Управление доменами ----------------------------------------------
    # Порт webui/cgi-bin/_lib.sh: api_domains_list / api_domains_action.
    # Эмулирует четыре списка (см. lib/strategies.sh):
    #   netrogat.txt, netrogat_substrings.txt, TCP_Custom.txt (+ locked.tsv
    #   стратегий), TCP_RKN_domains_by_substring.txt.

    def _domains_resolve(self, name):
        """Маппинг имени списка -> (path, kind, title, description). ValueError если неизвестно."""
        if name == "netrogat":
            return (self.netrogat_file, "domain",
                    "Исключения (netrogat.txt)",
                    "Домены, исключаемые из обработки zapret2 (--hostlist-exclude).")
        if name == "custom_rkn":
            return (self.custom_rkn_file, "domain",
                    "TCP_Custom (RKN-домены)",
                    "Кастомные домены под RKN-стратегию. Для каждого можно зафиксировать номер стратегии.")
        if name == "substring":
            return (self.rkn_substring_file, "substring",
                    "Подстроки (TCP_RKN_domains_by_substring)",
                    "Подстроки имени домена для RKN. Без нормализации — как есть.\n"
                    "Добавьте часть имени домена, и все домены с таким текстом будут обрабатываться стратегией РКН.\n"
                    "Например, если добавить cdn, стратегия РКН будет применяться к:\n"
                    "cdn-1.mysite.com, mycdn.com и другим доменам, в названии которых есть cdn.\n"
                    "Примеры корректного ввода: cdn, media, static, assets")
        if name == "netrogat_substring":
            return (self.netrogat_substring_file, "substring",
                    "Подстроки исключений (netrogat_substrings)",
                    "Подстроки-исключения (netrogat_substrings.txt). Без нормализации — как есть.\n"
                    "Добавьте часть имени домена, и все домены с таким текстом будут исключены из обработки —\n"
                    "аналог netrogat.txt, но по части имени.\n"
                    "Например, если добавить bank, исключены будут sber-bank.ru, banki.ru\n"
                    "и другие домены, в названии которых есть bank.")
        raise ValueError("Неизвестный список")

    def build_domains_list(self, name):
        """api_domains_list() — _lib.sh."""
        path, kind, title, desc = self._domains_resolve(name)
        is_custom_rkn = (name == "custom_rkn")
        if is_custom_rkn:
            max_strat = config_profile_max_strategy(3, self.cfg_text)
            if not isinstance(max_strat, int) or max_strat <= 0:
                max_strat = 19
        else:
            max_strat = 0

        items = []
        for line in _read_lines(path):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if is_custom_rkn:
                raw = orch_locked_read(self.lock_file, line, "tls", "0")
                strat = int(raw) if re.match(r"^[0-9]+$", str(raw)) else 0
                items.append({"value": line, "strategy": strat})
            else:
                items.append({"value": line})

        return {
            "list": name,
            "title": title,
            "description": desc,
            "kind": kind,
            "is_custom_rkn": is_custom_rkn,
            "max_strategy": max_strat,
            "items": items,
        }

    def _domain_list_add(self, path, domain):
        """_domain_list_add() — _lib.sh (с дедупликацией grep -Fixq)."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if not os.path.exists(path):
            open(path, "w", encoding="utf-8").close()
        existing = set(_read_lines(path))
        if domain in existing:
            return False  # дубликат
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(domain + "\n")
        return True

    def _domain_list_remove(self, path, domain):
        """_domain_list_remove() — _lib.sh (grep -Fxv → tmp → mv)."""
        if not os.path.exists(path):
            return
        keep = [ln for ln in _read_lines(path) if ln != domain]
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            for ln in keep:
                fh.write(ln + "\n")
        os.replace(tmp, path)

    def _custom_rkn_remove_domain(self, domain):
        """_custom_rkn_remove_domain() — _lib.sh: удалить домен + чистка locked.tsv (tls/http/udp)."""
        self._domain_list_remove(self.custom_rkn_file, domain)
        orch_locked_clear(self.lock_file, domain, "tls")
        orch_locked_clear(self.lock_file, domain, "http")
        orch_locked_clear(self.lock_file, domain, "udp")

    def apply_domains_action(self, name, action, domain, strategy):
        """api_domains_action() — _lib.sh. ValueError → 400 в handler."""
        path, kind, _title, _desc = self._domains_resolve(name)

        if name in ("custom_rkn", "substring") and action in ("add", "import"):
            if config_mode_text("hostlist", self.cfg_text) == "авто":
                raise ConflictError("Автосбор списков включён: домены RKN zapret2 определяет автоматически. "
                                    "Выключите автосбор в настройках, чтобы пополнять список вручную.")

        if action == "add":
            if not domain:
                raise ValueError("Не указан домен")
            if kind == "domain":
                norm = z2r_normalize_domain(domain)
                if norm is None:
                    raise ValueError("Некорректный домен: {0}".format(domain))
            else:
                norm = domain.strip()
                if not norm:
                    raise ValueError("Пустая подстрока")
            added = self._domain_list_add(path, norm)
            resp = {"ok": True, "duplicate": not added}
            if name == "custom_rkn":
                resp["check"] = self._domains_check(norm)
            return resp

        if action == "remove":
            if not domain:
                raise ValueError("Не указан домен")
            if name == "custom_rkn":
                self._custom_rkn_remove_domain(domain)
            else:
                self._domain_list_remove(path, domain)
            return {"ok": True}

        if action == "import":
            if not domain:
                raise ValueError("Пустой импорт")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if not os.path.exists(path):
                open(path, "w", encoding="utf-8").close()
            existing = set(_read_lines(path))
            added = duplicates = skipped = 0
            for raw_line in domain.split("\n"):
                line = raw_line.strip()
                if not line or line.startswith("#"):
                    skipped += 1
                    continue
                if kind == "domain":
                    norm = z2r_normalize_domain(line)
                    if norm is None:
                        skipped += 1
                        continue
                else:
                    norm = line
                if norm in existing:
                    duplicates += 1
                    continue
                with open(path, "a", encoding="utf-8") as fh:
                    fh.write(norm + "\n")
                existing.add(norm)
                added += 1
            return {"ok": True, "added": added, "duplicates": duplicates, "skipped": skipped}

        if action == "clear":
            cleared = 0
            if name == "custom_rkn":
                for line in _read_lines(path):
                    if not line.strip() or line.lstrip().startswith("#"):
                        continue
                    orch_locked_clear(self.lock_file, line, "tls")
                    orch_locked_clear(self.lock_file, line, "http")
                    orch_locked_clear(self.lock_file, line, "udp")
                    cleared += 1
            open(path, "w", encoding="utf-8").close()
            return {"ok": True, "cleared": cleared}

        if action == "set_strategy":
            if name != "custom_rkn":
                raise ValueError("Стратегия применяется только к TCP_Custom")
            if not domain:
                raise ValueError("Не указан домен")
            existing = set(_read_lines(path))
            if domain not in existing:
                raise ValueError("Домена нет в списке")
            if not re.match(r"^[0-9]+$", str(strategy)):
                raise ValueError("Некорректная стратегия")
            strat = int(strategy)
            max_strat = config_profile_max_strategy(3, self.cfg_text)
            if not isinstance(max_strat, int) or max_strat <= 0:
                max_strat = 19
            if strat < 1 or strat > max_strat:
                raise ValueError("Стратегия вне диапазона (1..{0})".format(max_strat))
            orch_locked_set(self.lock_file, domain, "tls", strat)
            return {"ok": True, "strategy": strat, "check": self._domains_check(domain)}

        if action == "clear_strategy":
            if name != "custom_rkn":
                raise ValueError("Стратегия применяется только к TCP_Custom")
            if not domain:
                raise ValueError("Не указан домен")
            orch_locked_clear(self.lock_file, domain, "tls")
            return {"ok": True}

        if action == "check":
            if name != "custom_rkn":
                raise ValueError("Проверка применяется только к TCP_Custom")
            if not domain:
                raise ValueError("Не указан домен")
            return {"ok": True, "check": self._domains_check(domain)}

        raise ValueError("Неизвестное действие: {0}".format(action))

    # --- dev-снимок -------------------------------------------------------

    def dev_snapshot(self):
        locks = {}
        for pid, _, _ in PROFILES:
            proto = profile_proto(pid)
            orch_file = self.lock_manual_file if pid in FALLBACK_PROFILES else self.lock_file
            locks[str(pid)] = profile_state_get(self.profile_lock, orch_file, pid, proto)
        return {
            "nfqws2_running": bool(self.nfqws2_running),
            "check_result": self.check_result,
            "simulate_error": sorted(self.simulate_error),
            "provider": self.provider,
            "rst_guard_lua": bool(self.rst_guard_lua),
            "locks": locks,
            "wireguard": config_wg_state(self.cfg_text),
            "auto_mode": config_mode_text("auto_mode", self.cfg_text),
            "fallback": config_mode_text("fallback", self.cfg_text),
            "backups": len(self.backups),
            "delays": dict(self.delays),
            "tmpdir": self.tmpdir,
            "config_path": self.config_path,
            "orch_dir": self.orch_dir,
        }


# ===========================================================================
# HTTP-обработчик
# ===========================================================================

# (status_code, reason) для send_error — соответствуют CGI Status-строкам
_HTTP_STATUS = {
    200: (200, "OK"),
    400: (400, "Bad Request"),
    409: (409, "Conflict"),
    500: (500, "Internal Server Error"),
}


class ConflictError(ValueError):
    """Конфликт состояния (409): например, fallback при включённой авторотации."""


class FakeRouterHandler(BaseHTTPRequestHandler):
    server_version = "z2r-fake-router/1.0"
    protocol_version = "HTTP/1.1"

    # --- helpers ----------------------------------------------------------

    @property
    def state(self):
        return self.server.router_state

    def _log(self, msg):
        print("[fake-router] {0}".format(msg), flush=True)

    def _sleep_for(self, category):
        """Искусственная задержка операции (симуляция медленного роутера).

        Вызывается ВНЕ state.lock, чтобы не блокировать параллельные запросы
        (например, одновременный опрос /status во время долгого service start).
        """
        d = self.state.delays.get(category, 0.0)
        if d and d > 0:
            time.sleep(d)

    def _send_json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        reason = _HTTP_STATUS.get(code, (code, ""))[1]
        self.send_response(code, reason)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_error_json(self, code, message):
        self._send_json({"error": message}, code)

    def _read_params(self, body_raw=None):
        """parse_params() — _lib.sh:58: query (GET) или тело (POST).

        Тело POST уже прочитано в do_POST и передаётся через body_raw, чтобы
        не читать rfile повторно (повторный read блокируется до таймаута).
        """
        parsed = urlparse(self.path)
        params = {k: v[-1] for k, v in parse_qs(parsed.query, keep_blank_values=True).items()}
        if body_raw is not None:
            raw = body_raw.decode("utf-8", "replace")
            for k, v in parse_qs(raw, keep_blank_values=True).items():
                params[k] = v[-1]
        return parsed, params

    def _serve_static(self, relpath):
        """Отдаёт реальные файлы из webui/ как есть."""
        webui_root = self.server.webui_root
        # Нормализуем путь и не даём выйти за пределы webui/
        safe = os.path.normpath(os.path.join(webui_root, relpath))
        if not safe.startswith(os.path.abspath(webui_root)):
            self._send_json({"error": "forbidden"}, 403)
            return
        if not os.path.isfile(safe):
            self._send_json({"error": "not found: {0}".format(relpath)}, 404)
            return
        ext = os.path.splitext(safe)[1].lower()
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".json": "application/json; charset=utf-8",
            ".svg": "image/svg+xml",
            ".png": "image/png",
            ".ico": "image/x-icon",
        }.get(ext, "application/octet-stream")
        with open(safe, "rb") as fh:
            body = fh.read()
        self.send_response(200, "OK")
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    # --- маршрутизация CGI ------------------------------------------------

    def _dispatch_cgi(self, endpoint, body_raw=None):
        """Общий диспетчер для /cgi-bin/*.cgi. endpoint: status|set-lock|..."""
        parsed, params = self._read_params(body_raw)
        with self.state.lock:
            snapshot = self.state.dev_snapshot()
            running = snapshot["nfqws2_running"]
            locks = snapshot["locks"]

        # --simulate-error: эндпоинт падает 500
        if endpoint in self.state.simulate_error:
            self._log("{0} {1} -> 500 (simulate-error)".format(
                self.command, parsed.path))
            self._send_error_json(500, "Симуляция ошибки эндпоинта '{0}'".format(endpoint))
            return

        if endpoint == "status":
            self._sleep_for("status")
            self._log("GET {0} | nfqws2={1} locks={2}".format(
                parsed.path, running, locks))
            with self.state.lock:
                self._send_json(self.state.build_status())
            return

        if endpoint == "check":
            self._sleep_for("check")
            self._log("{0} {1} | check_result={2}".format(
                self.command, parsed.path, self.state.check_result))
            with self.state.lock:
                self._send_json(self.state.build_check())
            return

        if endpoint == "service":
            self._handle_service(params, parsed)
            return

        if endpoint == "set-lock":
            self._handle_set_lock(params, parsed)
            return

        if endpoint == "clear-lock":
            self._handle_clear_lock(params, parsed)
            return

        if endpoint == "settings":
            self._handle_settings(params, parsed)
            return

        if endpoint == "domains":
            self._handle_domains(params, parsed)
            return

        if endpoint == "backups":
            self._handle_backups(params, parsed, body_raw)
            return

        self._send_error_json(404, "Неизвестный эндпоинт: {0}".format(endpoint))

    # --- обработчики эндпоинтов ------------------------------------------

    def _handle_service(self, params, parsed):
        # api_service() — _lib.sh:244
        action = params.get("action", "")
        if action not in ("start", "stop", "restart"):
            self._log("{0} {1} | action='{2}' -> 400".format(
                self.command, parsed.path, action))
            self._send_error_json(400, ERR_BAD_ACTION)
            return
        # zapret2 стартует/останавливается не мгновенно — задержка вне блокировки
        self._sleep_for("service")
        with self.state.lock:
            # Эмулируем init-скрипт: меняем состояние nfqws2
            if action == "start":
                self.state.nfqws2_running = True
            elif action == "stop":
                self.state.nfqws2_running = False
            elif action == "restart":
                self.state.nfqws2_running = True
            self._log("{0} {1} | action={2} -> nfqws2={3}".format(
                self.command, parsed.path, action, self.state.nfqws2_running))
            self._send_json({"ok": True})

    def _handle_set_lock(self, params, parsed):
        # api_set_lock() — _lib.sh:214
        profile = params.get("profile", "")
        strategy = params.get("strategy", "")
        if not re.match(r"^[1-9]$", profile):
            self._send_error_json(400, ERR_BAD_PROFILE)
            return
        if not re.match(r"^[0-9]+$", strategy):
            self._send_error_json(400, ERR_BAD_STRATEGY)
            return
        if int(profile) in AUTO_MODE_GATED_PROFILES and \
                config_mode_text("auto_mode", self.state.cfg_text) == "включен":
            self._log("{0} {1} | profile={2} -> 409 (auto mode)".format(
                self.command, parsed.path, profile))
            self._send_error_json(
                409, "Профиль {0} управляется авторотацией TCP/HTTP. "
                     "Сначала выключите авторотацию.".format(profile))
            return
        # Валидация диапазона (чтение cfg_text атомарно благодаря GIL — можно
        # вне блокировки); затем искусственная задержка apply+check.
        maxstrat = config_profile_max_strategy(int(profile), self.state.cfg_text)
        strat = int(strategy)
        if strat != 0 and not (1 <= strat <= (maxstrat or 0)):
            self._send_error_json(400, ERR_STRATEGY_RANGE)
            return
        pl = proto_list(int(profile))
        if not pl:
            self._send_error_json(400, ERR_NO_PROTO)
            return
        self._sleep_for("set-lock")
        with self.state.lock:
            ok = profile_state_set_and_apply(self.state, int(profile), pl, strategy)
            if not ok:
                self._send_error_json(500, ERR_SAVE_STATE)
                return
            # Профиль 6: restart (эмуляция)
            if int(profile) == 6:
                self.state.nfqws2_running = True
            check_json = self.state.profile_check_json(int(profile))
            self._log("{0} {1} | profile={2} strategy={3} -> ok (max={4})".format(
                self.command, parsed.path, profile, strategy, maxstrat))
            self._send_json({"ok": True, "check": check_json})

    def _handle_clear_lock(self, params, parsed):
        # api_clear_lock() — _lib.sh:232
        profile = params.get("profile", "")
        if not re.match(r"^[1-9]$", profile):
            self._send_error_json(400, ERR_BAD_PROFILE)
            return
        if int(profile) in AUTO_MODE_GATED_PROFILES and \
                config_mode_text("auto_mode", self.state.cfg_text) == "включен":
            self._send_error_json(
                409, "Профиль {0} управляется авторотацией TCP/HTTP. "
                     "Сначала выключите авторотацию.".format(profile))
            return
        pl = proto_list(int(profile))
        if not pl:
            self._send_error_json(400, ERR_NO_PROTO)
            return
        self._sleep_for("clear-lock")
        with self.state.lock:
            ok = profile_state_set_and_apply(self.state, int(profile), pl, "auto")
            if not ok:
                self._send_error_json(500, ERR_RESET_STATE)
                return
            if int(profile) == 6:
                self.state.nfqws2_running = True
            self._log("{0} {1} | profile={2} -> cleared (auto)".format(
                self.command, parsed.path, profile))
            self._send_json({"ok": True})

    def _handle_settings(self, params, parsed):
        """Обработчик endpoint /cgi-bin/settings.cgi.

        GET  ?setting=wg_blob  -> настройки WireGuard (blob + repeats)
        GET  ?setting=wg_state -> состояние WireGuard (вкл/выкл)
        GET  (без параметра)   -> настройки TLS-блоба (обратная совместимость)
        POST setting=tls_blob  -> смена TLS-блоба
        POST setting=wg_blob   -> смена WG-блоба
        POST setting=wg_repeats-> смена WG repeats
        POST setting=wg_state  -> вкл/выкл стратегии WireGuard
        """
        setting = params.get("setting", "")

        if self.command == "GET":
            with self.state.lock:
                if setting == "wg_blob":
                    self._log("GET {0} | wg_blob settings".format(parsed.path))
                    self._send_json(self.state.build_wg_blob_settings())
                elif setting == "wg_state":
                    self._log("GET {0} | wg_state settings".format(parsed.path))
                    self._send_json(self.state.build_wg_state_settings())
                elif setting == "fallback":
                    self._log("GET {0} | fallback settings".format(parsed.path))
                    self._send_json(self.state.build_fallback_settings())
                elif setting == "udp-games":
                    self._log("GET {0} | udp-games settings".format(parsed.path))
                    self._send_json(self.state.build_udp_games_settings())
                elif setting in ("auto_mode", "hostlist", "rst_guard", "reasm", "quic443"):
                    self._log("GET {0} | mode settings {1}".format(parsed.path, setting))
                    self._send_json(self.state.build_mode_settings(setting))
                elif setting == "ports":
                    self._log("GET {0} | ports settings".format(parsed.path))
                    self._send_json(self.state.build_ports_settings())
                elif setting == "provider":
                    self._log("GET {0} | provider settings".format(parsed.path))
                    self._send_json(self.state.build_provider_settings())
                else:
                    self._log("GET {0} | tls_blob settings".format(parsed.path))
                    self._send_json(self.state.build_tls_blob_settings())
            return

        if self.command == "POST":
            if setting == "tls_blob":
                blob = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_tls_blob(blob)
                        self._log("POST {0} | tls_blob={1}".format(parsed.path, blob))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting == "wg_blob":
                blob = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_wg_blob(blob)
                        self._log("POST {0} | wg_blob={1}".format(parsed.path, blob))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting == "wg_repeats":
                repeats = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_wg_repeats(repeats)
                        self._log("POST {0} | wg_repeats={1}".format(parsed.path, repeats))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting == "wg_state":
                value = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_wg_state(value)
                        self._log("POST {0} | wg_state={1}".format(parsed.path, value))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting == "fallback_state":
                value = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_fallback_state(value)
                        self._log("POST {0} | fallback_state={1}".format(parsed.path, value))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(409 if isinstance(e, ConflictError) else 400, str(e))
                return
            if setting == "fallback_strategy":
                profile = params.get("profile", "")
                strategy = params.get("strategy", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_fallback_strategy(profile, strategy)
                        self._log("POST {0} | fallback_strategy profile={1} strategy={2}".format(
                            parsed.path, profile, strategy))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting == "udp_games_state":
                value = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_udp_games_state(value)
                        self._log("POST {0} | udp_games_state={1}".format(parsed.path, value))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting in ("auto_mode_state", "hostlist_state", "rst_guard_state",
                           "reasm_state", "quic443_state"):
                value = params.get("value", "")
                mode = setting[:-len("_state")]
                try:
                    with self.state.lock:
                        result = self.state.apply_mode_setting(mode, value)
                        self._log("POST {0} | {1}={2}".format(parsed.path, setting, value))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(409 if isinstance(e, ConflictError) else 400, str(e))
                return
            if setting == "ports_add":
                proto = params.get("proto", "")
                value = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_ports_add(proto, value)
                        self._log("POST {0} | ports_add proto={1} value={2}".format(
                            parsed.path, proto, value))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting == "ports_remove":
                proto = params.get("proto", "")
                value = params.get("value", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_ports_remove(proto, value)
                        self._log("POST {0} | ports_remove proto={1} value={2}".format(
                            parsed.path, proto, value))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting == "provider_set":
                name = params.get("name", "")
                city = params.get("city", "")
                try:
                    with self.state.lock:
                        result = self.state.apply_provider_set(name, city)
                        self._log("POST {0} | provider_set name={1!r} city={2!r}".format(
                            parsed.path, name, city))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            if setting == "provider_redetect":
                self._sleep_for("provider")
                try:
                    with self.state.lock:
                        result = self.state.apply_provider_redetect()
                        self._log("POST {0} | provider_redetect".format(parsed.path))
                        self._send_json(result)
                except ValueError as e:
                    self._send_error_json(400, str(e))
                return
            self._send_error_json(400, "Неизвестная настройка")
            return

        self._send_error_json(405, "Метод не поддерживается")

    def _handle_domains(self, params, parsed):
        """Обработчик endpoint /cgi-bin/domains.cgi (api_domains_* из _lib.sh).

        GET  ?list=netrogat|custom_rkn|substring            -> содержимое списка
        POST action=add|remove|import|clear|set_strategy|clear_strategy
        """
        name = params.get("list", "")

        if self.command == "GET":
            try:
                with self.state.lock:
                    result = self.state.build_domains_list(name)
                    self._log("GET {0} | domains list={1}".format(parsed.path, name))
                    self._send_json(result)
            except ValueError as e:
                self._send_error_json(400, str(e))
            return

        if self.command == "POST":
            action = params.get("action", "")
            domain = params.get("domain", "")
            strategy = params.get("strategy", "")
            try:
                with self.state.lock:
                    result = self.state.apply_domains_action(name, action, domain, strategy)
                    self._log("POST {0} | domains list={1} action={2}".format(
                        parsed.path, name, action))
                    self._send_json(result)
            except ValueError as e:
                self._send_error_json(409 if isinstance(e, ConflictError) else 400, str(e))
            return

        self._send_error_json(405, "Метод не поддерживается")

    def _handle_backups(self, params, parsed, body_raw=None):
        """Обработчик endpoint /cgi-bin/backups.cgi (api_backups_* из _lib.sh).

        GET                  -> список архивов
        GET  action=download -> скачивание архива (бинарный tar)
        POST action=create   -> создание нового бэкапа
        POST action=delete   -> удаление архива
        POST ?action=upload  -> импорт архива (raw tar в теле)
        """
        if self.command == "GET":
            if params.get("action", "") == "download":
                self._backup_download(params, parsed)
                return
            with self.state.lock:
                self._log("GET {0} | backups list".format(parsed.path))
                self._send_json(self.state.build_backups_list())
            return

        if self.command == "POST":
            if "action=upload" in (parsed.query or ""):
                self._backup_upload(params, parsed, body_raw)
                return
            action = params.get("action", "")
            if action == "create":
                with self.state.lock:
                    result = self.state.apply_backup_create()
                    self._log("POST {0} | backups create -> {1}".format(parsed.path, result["name"]))
                    self._send_json(result)
                return
            if action == "delete":
                self._backup_delete(params, parsed)
                return
            self._send_error_json(400, "Неизвестное действие")
            return

        self._send_error_json(405, "Метод не поддерживается")

    def _backup_download(self, params, parsed):
        name = params.get("name", "")
        if not name:
            self._send_error_json(400, "Не указано имя файла")
            return
        with self.state.lock:
            item = next((b for b in self.state.backups if b["name"] == name), None)
        if item is None:
            self._send_error_json(404, "Бэкап не найден")
            return
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tf:
            data = b"# fake z2r config\n"
            info = tarfile.TarInfo("config")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        body = buf.getvalue()
        self._log("GET {0} | backups download -> {1} ({2} bytes)".format(parsed.path, name, len(body)))
        self.send_response(200, "OK")
        self.send_header("Content-Type", "application/x-tar")
        self.send_header("Content-Disposition", "attachment; filename=\"{0}\"".format(name))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _backup_delete(self, params, parsed):
        name = params.get("name", "")
        if not name:
            self._send_error_json(400, "Не указано имя файла")
            return
        with self.state.lock:
            result = self.state.apply_backup_delete(name)
            if result is None:
                self._send_error_json(404, "Бэкап не найден")
                return
            self._log("POST {0} | backups delete -> {1}".format(parsed.path, name))
            self._send_json(result)

    def _backup_upload(self, params, parsed, body_raw):
        body = body_raw or b""
        if not body:
            self._send_error_json(400, "Пустой файл")
            return
        if len(body) > 32 * 1024 * 1024:
            self._send_error_json(413, "Файл слишком большой (максимум 32 МБ)")
            return
        if len(body) < 512 or body[257:262] != b"ustar":
            self._send_error_json(400, "Файл не является архивом бэкапа")
            return
        with self.state.lock:
            result = self.state.apply_backup_import(params.get("name", ""), len(body))
            self._log("POST {0} | backups upload -> {1} ({2} bytes)".format(
                parsed.path, result["name"], len(body)))
            self._send_json(result)

    # --- dev-эндпоинт (управление фейк-состоянием в рантайме) ------------

    def _handle_dev(self, parsed, params, body_raw):
        if parsed.path == "/__dev/state" and self.command == "GET":
            with self.state.lock:
                self._send_json(self.state.dev_snapshot())
            return
        if parsed.path == "/__dev/state" and self.command == "POST":
            try:
                payload = json.loads(body_raw.decode("utf-8")) if body_raw else {}
            except (ValueError, UnicodeDecodeError):
                self._send_error_json(400, "Невалидный JSON")
                return
            with self.state.lock:
                if "nfqws2_running" in payload:
                    self.state.nfqws2_running = bool(payload["nfqws2_running"])
                if "check_result" in payload:
                    self.state.check_result = payload["check_result"]
                if "provider" in payload:
                    self.state.provider = payload["provider"]
                if "rst_guard_lua" in payload:
                    self.state.rst_guard_lua = bool(payload["rst_guard_lua"])
                if "simulate_error" in payload:
                    self.state.simulate_error = set(payload["simulate_error"] or [])
                if "lock_state" in payload:
                    # сброс текущих локов и применение новых
                    open(self.state.profile_lock, "w", encoding="utf-8").close()
                    open(self.state.lock_file, "w", encoding="utf-8").close()
                    self.state._apply_lock_state(payload["lock_state"])
                # Задержки: "delay" (число) задаёт service/check/set-lock/clear-lock
                # разом; "status_delay" (число) — только status; "delays" (dict)
                # — точечный перебор по категориям.
                if "delay" in payload:
                    for k in ("service", "check", "set-lock", "clear-lock"):
                        self.state.delays[k] = float(payload["delay"])
                if "status_delay" in payload:
                    self.state.delays["status"] = float(payload["status_delay"])
                if "delays" in payload and isinstance(payload["delays"], dict):
                    for k, v in payload["delays"].items():
                        if k in self.state.delays:
                            self.state.delays[k] = float(v)
                self._log("POST /__dev/state | updated -> {0}".format(
                    self.state.dev_snapshot()))
                self._send_json(self.state.dev_snapshot())
            return
        self._send_error_json(404, "Неизвестный dev-эндпоинт")

    # --- HTTP entry points ------------------------------------------------

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/__dev/state":
            self._handle_dev(parsed, {}, b"")
            return
        if path.startswith("/cgi-bin/") and path.endswith(".cgi"):
            endpoint = path[len("/cgi-bin/"):-len(".cgi")]
            self._dispatch_cgi(endpoint)
            return
        # Статика: '/' -> index.html
        relpath = path.lstrip("/")
        if relpath == "":
            relpath = "index.html"
        self._serve_static(relpath)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        length = int(self.headers.get("Content-Length", 0) or 0)
        body_raw = self.rfile.read(length) if length else b""
        if path == "/__dev/state":
            self._handle_dev(parsed, {}, body_raw)
            return
        if path.startswith("/cgi-bin/") and path.endswith(".cgi"):
            endpoint = path[len("/cgi-bin/"):-len(".cgi")]
            self._dispatch_cgi(endpoint, body_raw)
            return
        self._send_error_json(404, "Не найдено: {0}".format(path))

    def log_message(self, fmt, *args):
        # Подавляем дефолтный шум access-лога; свой лог пишем в хендлерах.
        pass


# ===========================================================================
# CLI / main
# ===========================================================================

def _default_webui_root():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, os.pardir))


def _default_repo_root():
    return os.path.abspath(os.path.join(_default_webui_root(), os.pardir))


def _parse_args(argv):
    p = argparse.ArgumentParser(
        description="Фейковый dev-сервер zapret2 WebUI (имитация роутера). "
                    "Только stdlib. Не трогает /opt/zapret2.")
    p.add_argument("--port", type=int, default=8099,
                   help="Порт HTTP (по умолчанию 8099, НЕ 17682, чтобы не "
                        "конфликтовать с реальным WebUI на устройстве)")
    p.add_argument("--host", default="127.0.0.1", help="Адрес привязки")
    p.add_argument("--webui-root", default=None,
                   help="Каталог со статикой webui (по умолчанию ../ от скрипта)")
    p.add_argument("--config", default=None,
                   help="Путь к config.default (по умолчанию <repo>/config.default)")
    p.add_argument("--service-state", choices=["running", "stopped"],
                   default="running", help="Состояние nfqws2 при старте")
    p.add_argument("--lock-state", default="none",
                   help="Стартовые локи: 'none' или 'profile=strat,...' "
                        "(strat: N|0|auto), напр. '2=5,4=0,6=12'")
    p.add_argument("--check-result", choices=["ok", "fail", "mixed", "random"],
                   default="ok", help="Результаты TLS-проверок в /check, set-lock и "
                   "domains (custom_rkn); random — случайно на каждый запрос "
                   "(около 70% успеха), чтобы периодически ловить ошибки")
    p.add_argument("--simulate-error", default="",
                   help="Эндпоинты, отдающие 500 (через запятую): "
                        + ",".join(sorted(SIMULATABLE)))
    p.add_argument("--provider", default="Не определён",
                   help="Строка провайдера (только для лога/dev-состояния; "
                        "в реальном WebUI этого поля нет)")
    p.add_argument("--delay", type=float, default=3.0, metavar="SECONDS",
                   help="Искусственная задержка (сек) на медленных операциях "
                        "(service/check/set-lock/clear-lock) — чтобы тестировать "
                        "спиннеры. По умолчанию 3.0")
    p.add_argument("--status-delay", type=float, default=0.0, metavar="SECONDS",
                   help="Задержка (сек) для /status (по умолчанию 0 — статус "
                        "быстрый; задайте >0 для теста спиннера «Обновление...»)")
    return p.parse_args(argv)


def main(argv=None):
    args = _parse_args(argv or sys.argv[1:])

    # На Windows консоль часто cp866/cp1251: русский текст в логах не должен
    # ронять сервер кодировкой. Переводим stdout/stderr в UTF-8 (с заменой
    # непредставимых символов). Python 3.7+.
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (ValueError, OSError):
                pass

    webui_root = args.webui_root or _default_webui_root()
    config_path = args.config or os.path.join(_default_repo_root(), "config.default")
    fake_dir = os.path.join(_default_repo_root(), "fake")
    repo_root = _default_repo_root()

    if not os.path.isdir(webui_root):
        sys.exit("webui-root не найден: {0}".format(webui_root))
    if not os.path.isfile(os.path.join(webui_root, "index.html")):
        sys.exit("index.html не найден в webui-root: {0}".format(webui_root))
    if not os.path.isfile(config_path):
        sys.exit("config.default не найден: {0}".format(config_path))
    if not os.path.isdir(fake_dir):
        sys.exit("Директория fake не найден: {0}".format(fake_dir))

    sim_errors = [s.strip() for s in args.simulate_error.split(",") if s.strip()]
    bad = [s for s in sim_errors if s not in SIMULATABLE]
    if bad:
        sys.exit("Неизвестные --simulate-error: {0}. Допустимо: {1}".format(
            ",".join(bad), ",".join(sorted(SIMULATABLE))))

    state = FakeRouterState(
        config_default_path=config_path,
        service_state=args.service_state,
        lock_state=args.lock_state,
        check_result=args.check_result,
        simulate_error=sim_errors,
        provider=args.provider,
        fake_dir=fake_dir,
        repo_root=repo_root,
        delay=args.delay,
        status_delay=args.status_delay,
    )

    httpd = ThreadingHTTPServer((args.host, args.port), FakeRouterHandler)
    httpd.router_state = state
    httpd.webui_root = os.path.abspath(webui_root)

    print("=" * 64, flush=True)
    print("z2r fake-router WebUI dev-server", flush=True)
    print("  Фронтенд:      http://{0}:{1}/".format(args.host, args.port), flush=True)
    print("  webui-root:    {0}".format(httpd.webui_root), flush=True)
    print("  config:        {0}".format(config_path), flush=True)
    print("  tmp-состояние: {0}".format(state.tmpdir), flush=True)
    print("  Сценарий:      service={1} check={2} locks={3!r} errors={4}".format(
        args.port, args.service_state, args.check_result,
        args.lock_state, sim_errors or "нет"), flush=True)
    print("  Задержки:      delay={1}s (service/check/set-lock/clear-lock) "
          "status={2}s".format(args.port, args.delay, args.status_delay), flush=True)
    print("  dev-API:       GET/POST http://{0}:{1}/__dev/state".format(
        args.host, args.port), flush=True)
    print("  Остановить:    Ctrl+C", flush=True)
    print("=" * 64, flush=True)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[fake-router] остановлен пользователем", flush=True)
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
