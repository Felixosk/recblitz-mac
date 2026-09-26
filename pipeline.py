#!/usr/bin/env python3
"""RecBlitz pipeline: Transkript -> Markdown-Notiz + optional Google Doc (Drive).

Zwei Modi:
  pipeline.py <audio>                                   Whisper-Fallback (transkribiert selbst)
  pipeline.py --text <txt> --audio <m4a> --duration <s> Text kommt von Apple Speech (App)
  pipeline.py --detect-lang <audio>                     nur Spracherkennung (whisper-tiny)
  pipeline.py --selftest                                prüft die reine Logik

Letzte stdout-Zeile ist immer ein JSON-Resultat für die App:
  {ok, title, doc_url, doc_error, obsidian_path, obsidian_error, video_url,
   video_error, preview, text, error}

Die App setzt RECBLITZ_HOME (Arbeitsordner mit config.json und Logs) und
RECBLITZ_LANG (de/en, Sprache von Überschriften und Zusammenfassung).
"""
import datetime
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

HOME_DIR = os.environ.get("RECBLITZ_HOME") or os.path.expanduser(
    "~/Library/Application Support/RecBlitz")
LOG_DIR = os.path.join(HOME_DIR, "logs")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "pipeline.log")
LANG = "de" if os.environ.get("RECBLITZ_LANG", "en").startswith("de") else "en"

# Voreinstellungen für alles, was in config.json fehlen darf. Eine frische
# Installation hat gar keine Datei, und genau dann muss es trotzdem laufen.
DEFAULTS = {
    "language": "de-DE" if LANG == "de" else "en-US",
    "model": "mlx-community/whisper-large-v3-turbo",
    "summarize": True,
    "obsidian_enabled": True,
    "vault_notes_dir": "~/Documents/RecBlitz",
    "drive_enabled": False,
    "drive_remote": "gdrive:",
    "drive_folder": "RecBlitz",
    "drive_folder_id": "",
    "video_folder_id": "",
    "video_public": True,
    # Optional: eigener Webdienst, der eine Drive-Datei freigibt
    # (GET <url>?action=setPublic&fileId=<id> -> {"success": true, "link": ...}).
    # Leer = `rclone link`, das dasselbe ohne Zusatzdienst erledigt.
    "share_script_url": "",
}

TEXT = {
    "de": {"summary": "Zusammenfassung", "steps": "Nächste Schritte", "transcript": "Transkript",
           "watch": "Bildschirmaufnahme ansehen", "voice_note": "Sprachnotiz",
           "meta": "Sprachnotiz vom {date} · {dur} min · {words} Wörter · {engine}",
           "engine_apple": "Apple Speech (auf dem Mac)", "engine_whisper": "Whisper (lokal)",
           "summary_lang": "auf Deutsch",
           "no_rclone": "rclone ist nicht installiert (brew install rclone, dann rclone config)",
           "no_whisper": "Whisper fehlt (pip3 install mlx-whisper). Auf macOS 26 transkribiert die App ohne Whisper.",
           "empty": "Leeres Transkript (nichts erkannt)",
           "nothing_saved": "Nichts gespeichert: Markdown und Google Drive sind beide aus. Das Transkript lässt sich im Panel kopieren."},
    "en": {"summary": "Summary", "steps": "Next steps", "transcript": "Transcript",
           "watch": "Watch the screen recording", "voice_note": "Voice note",
           "meta": "Voice note from {date} · {dur} min · {words} words · {engine}",
           "engine_apple": "Apple Speech (on-device)", "engine_whisper": "Whisper (local)",
           "summary_lang": "in English",
           "no_rclone": "rclone is not installed (brew install rclone, then rclone config)",
           "no_whisper": "Whisper is missing (pip3 install mlx-whisper). On macOS 26 the app transcribes without it.",
           "empty": "Empty transcript (nothing recognised)",
           "nothing_saved": "Nothing saved: Markdown and Google Drive are both off. You can still copy the transcript from the panel."},
}


def T(key):
    return TEXT[LANG][key]


def log(msg):
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a") as f:
        f.write(f"[{stamp}] {msg}\n")


class Timer:
    def __init__(self):
        self.t0 = time.time()

    def lap(self, label):
        log(f"  {label}: {time.time() - self.t0:.1f}s")
        self.t0 = time.time()


def load_config():
    cfg = dict(DEFAULTS)
    try:
        with open(os.path.join(HOME_DIR, "config.json")) as f:
            cfg.update(json.load(f))
    except (OSError, ValueError):
        pass
    return cfg


# ---------------------------------------------------------------- Transkription

def _import_whisper():
    try:
        import mlx_whisper  # noqa: optional, nur für Rückfall und Auto-Sprache
        return mlx_whisper
    except ImportError:
        raise RuntimeError(T("no_whisper"))


def transcribe_whisper(audio_path, cfg):
    """Fallback-Engine. Returns (text, segments), segments [(start, end, text)]."""
    model = cfg.get("model") or DEFAULTS["model"]
    setting = cfg.get("language") or DEFAULTS["language"]
    lang = None if setting == "auto" else setting.split("-")[0]
    mlx_whisper = _import_whisper()
    result = mlx_whisper.transcribe(audio_path, path_or_hf_repo=model, language=lang)
    segs = [(s["start"], s["end"], s["text"]) for s in result.get("segments", [])]
    return result.get("text", "").strip(), segs


def detect_language(audio_path):
    """Erkennt die gesprochene Sprache auf den ersten 30s via whisper-tiny (~1s).
    Druckt {"language": "de"} als JSON."""
    mlx_whisper = _import_whisper()
    with tempfile.TemporaryDirectory() as td:
        clip = os.path.join(td, "clip.wav")
        subprocess.run(["ffmpeg", "-y", "-i", audio_path, "-t", "30",
                        "-ar", "16000", "-ac", "1", clip],
                       check=True, capture_output=True)
        result = mlx_whisper.transcribe(clip, path_or_hf_repo="mlx-community/whisper-tiny")
    return result.get("language")


def paragraphs_from_segments(segments):
    """Whisper-Segmente -> Absätze: Sprechpause >= 1.2s = neuer Absatz."""
    paras, cur, last_end = [], [], None
    for start, end, text in segments:
        if last_end is not None and start - last_end >= 1.2 and cur:
            paras.append(" ".join(cur))
            cur = []
        cur.append(text.strip())
        last_end = end
    if cur:
        paras.append(" ".join(cur))
    return [re.sub(r"\s+", " ", p).strip() for p in paras if p.strip()]


def paragraphs_from_text(text):
    """Fließtext (Apple Speech) -> Absätze à ~3 Sätze."""
    sentences = re.split(r"(?<=[.!?])\s+", text.strip())
    paras = []
    for i in range(0, len(sentences), 3):
        p = " ".join(sentences[i:i + 3]).strip()
        if p:
            paras.append(p)
    return paras or [text.strip()]


# ---------------------------------------------------------------- Zusammenfassung

def summarize_with_claude(text, cfg):
    """Titel + optional Zusammenfassung + Nächste Schritte via Claude CLI.

    Der TITEL wird immer angefragt, unabhängig vom Zusammenfassungs-Schalter:
    er ist der Dateiname und damit das, was ein Empfänger des Links zuerst
    sieht. Die ersten fünf Transkript-Wörter ergaben Namen wie "Digga wir
    folgen uns irgendwie" (Rückmeldung 01.08.).

    Returns (title:str|None, summary:str|None, steps:list)."""
    words = len(text.split())
    if words < 12:                       # zu wenig Substanz für irgendwas
        return None, None, []
    exe = shutil.which("claude") or os.path.expanduser("~/.claude/local/claude")
    if not os.path.exists(exe):
        log("  claude CLI nicht gefunden, Titel/Zusammenfassung übersprungen")
        return None, None, []

    want_summary = cfg.get("summarize", True) and words >= 40
    lang = T("summary_lang")
    if want_summary:
        schema = ('{"title": "one sentence, max 60 characters", '
                  '"summary": "2-4 sentences", '
                  '"next_steps": ["…", "…"]}')
        extra = "next_steps only with concrete action items, otherwise an empty list. "
    else:
        schema = '{"title": "one sentence, max 60 characters"}'
        extra = ""
    prompt = (
        "You receive the transcript of a voice note or screen recording. "
        "Reply with JSON ONLY, no Markdown fences, schema: " + schema + ". "
        f"Write every value {lang}. "
        "title is ONE short sentence that sums up the content. It becomes the "
        "file name and is the first thing a recipient sees. No date, no quotes, "
        "no trailing punctuation, do not repeat the first words. " + extra +
        "\n\nTRANSCRIPT:\n" + text[:12000]
    )
    try:
        r = subprocess.run(
            [exe, "-p", "--model", "claude-haiku-4-5-20251001"],
            input=prompt, capture_output=True, text=True, timeout=120)
        raw = r.stdout.strip()
        raw = re.sub(r"^```(json)?|```$", "", raw, flags=re.M).strip()
        m = re.search(r"\{.*\}", raw, flags=re.S)
        data = json.loads(m.group(0)) if m else {}
        return (clean_title(data.get("title")),
                data.get("summary") or None,
                list(data.get("next_steps") or []))
    except Exception as e:  # noqa: alles hier ist optional
        log(f"  Titel/Zusammenfassung fehlgeschlagen: {type(e).__name__}: {e}")
        return None, None, []


def clean_title(raw):
    """Macht aus Claudes Satz einen brauchbaren Datei- und Doc-Namen.
    macOS mag kein ':' und '/' in Dateinamen, Drive stolpert über beides."""
    if not raw or not isinstance(raw, str):
        return None
    t = " ".join(raw.split())
    t = re.sub(r'[:/\\|<>*?"]', " ", t)
    t = re.sub(r"\s+", " ", t).strip(" .-")
    if len(t) > 70:
        t = t[:70].rsplit(" ", 1)[0]
    return t or None


# ---------------------------------------------------------------- Ausgabe

def make_title(text, now, ai_title=None):
    """Claudes Satz gewinnt; die ersten fünf Wörter sind nur noch der Notnagel,
    wenn die CLI fehlt oder die Aufnahme zu kurz für eine Aussage ist."""
    if ai_title:
        return f"{ai_title} - {now.strftime('%Y-%m-%d %H.%M')} - RecBlitz"
    words = re.findall(r"[\wÄÖÜäöüß']+", text)[:5]
    slug = " ".join(words) or T("voice_note")
    if len(slug) > 45:
        slug = slug[:45].rsplit(" ", 1)[0]
    # kein ":" im Namen (macOS-Dateiname)
    return f"{slug} - {now.strftime('%Y-%m-%d %H.%M')} - RecBlitz"


def drive_ready(cfg):
    """(bereit, Grund). Drive ist optional: ohne Schalter oder ohne rclone gibt
    es eben nur die Markdown-Notiz, das ist kein Fehler der Aufnahme."""
    if not cfg.get("drive_enabled"):
        return False, None
    if not shutil.which("rclone"):
        return False, T("no_rclone")
    return True, None


def rclone_target(cfg, folder_id=None):
    """Returns (remote_path, extra_flags)."""
    remote = cfg.get("drive_remote") or "gdrive:"
    folder_id = (folder_id if folder_id is not None else cfg.get("drive_folder_id", "")).strip()
    if folder_id:
        return remote, ["--drive-root-folder-id", folder_id]
    return f"{remote}{cfg.get('drive_folder') or 'RecBlitz'}", []


def upload_google_doc(title, sections, cfg):
    """HTML nach Drive, Drive konvertiert zu Google Doc. Returns doc_url.

    rclone braucht dafür `copy` (Ordner mit genau einer Datei) plus
    --drive-import-formats html, mit `copyto` scheitert die Konvertierung."""
    target, flags = rclone_target(cfg)
    doc_html = "<html><body>" + "".join(sections) + "</body></html>"

    with tempfile.TemporaryDirectory() as td:
        with open(os.path.join(td, title + ".html"), "w") as f:
            f.write(doc_html)
        cmd = ["rclone", "copy", td, target,
               "--drive-import-formats", "html", "--drive-allow-import-name-change"] + flags
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            # Ordner fehlt evtl. (nur im Namens-Modus möglich) -> anlegen + retry
            subprocess.run(["rclone", "mkdir", target] + flags, capture_output=True, text=True)
            subprocess.run(cmd, check=True, capture_output=True, text=True)

    # Konvertierte Docs tauchen mit Export-Endung (.docx) auf, deshalb per Präfix.
    ls = subprocess.run(["rclone", "lsjson", target, "--files-only",
                         "--include", f"{title}*"] + flags,
                        check=True, capture_output=True, text=True)
    for entry in json.loads(ls.stdout):
        if entry.get("Name", "").startswith(title) and entry.get("ID"):
            return f"https://docs.google.com/document/d/{entry['ID']}/edit"
    return None


def set_public(file_id, remote_file, flags, cfg):
    """Datei auf "Jeder mit dem Link" stellen. rclone lädt nur hoch und setzt
    KEINE Freigabe, ohne diesen Schritt landet jeder Empfänger des Links auf
    "Zugriff anfordern" (verifiziert 31.07.: HTTP 401 vorher, 200 danach).

    Weg 1: eigener Webdienst aus der Konfiguration (share_script_url).
    Weg 2: `rclone link`, das in Drive genau diese Freigabe anlegt.
    Returns (share_link, error)."""
    script = (cfg.get("share_script_url") or "").strip()
    if script:
        url = f"{script}?action=setPublic&fileId={urllib.parse.quote(file_id)}"
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                data = json.loads(r.read().decode())
            if data.get("success"):
                return data.get("link"), None
            return None, f"share: {data.get('error', 'unknown')}"
        except Exception as e:  # noqa: Freigabe darf den Rest nie killen
            return None, f"share failed: {type(e).__name__}"
    try:
        r = subprocess.run(["rclone", "link", remote_file] + flags,
                           capture_output=True, text=True, timeout=120)
        link = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
        if r.returncode == 0 and link.startswith("http"):
            return link, None
        detail = (r.stderr or "").strip().splitlines()[-1:] or ["?"]
        return None, f"rclone link: {detail[0]}"
    except Exception as e:  # noqa
        return None, f"rclone link: {type(e).__name__}"


def upload_video(video_path, title, cfg):
    """Screencast nach Drive laden und den Freigabe-Link zurückgeben.

    Eigener Ordner falls konfiguriert (video_folder_id), sonst derselbe wie für
    die Docs. Screencasts sind schnell hunderte MB, deshalb ist der getrennte
    Ordner die Empfehlung. Returns (url, error)."""
    if not video_path or not os.path.exists(video_path):
        return None, None

    size_mb = os.path.getsize(video_path) / (1024 * 1024)
    folder_id = (cfg.get("video_folder_id") or cfg.get("drive_folder_id") or "").strip()
    target, flags = rclone_target(cfg, folder_id)

    name = title + os.path.splitext(video_path)[1]
    log(f"  Video-Upload: {size_mb:.0f} MB -> Drive")
    try:
        # rclone copyto benennt beim Kopieren um, damit Video und Doc denselben
        # Namen tragen und im Ordner nebeneinander stehen.
        #
        # Fortschritt: rclone schreibt seine Statistik nach stderr. Wir lesen sie
        # zeilenweise mit und geben Prozente als eigene JSON-Zeilen nach stdout
        # weiter, die App zeigt sie an statt nur eines drehenden Kreises.
        remote_file = f"{target}/{name}"
        cmd = ["rclone", "copyto", video_path, remote_file,
               "--stats", "1s", "--stats-one-line", "--stats-log-level", "NOTICE"] + flags
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, text=True)
        # NUR VORWÄRTS und erst am Ende 100. Gemessen (01.08.): rclone meldete
        # 87, 98, 100 und danach wieder 50, es setzt Übertragungen intern neu
        # an. Eine rückwärts springende Anzeige sieht nach Fehler aus, und ein
        # vorzeitiges "100 %" bei danach noch laufendem Upload erst recht.
        shown = -1
        deadline = time.time() + 3600
        for line in proc.stderr:
            m = re.search(r"(\d+)%", line)
            if m:
                pct = min(99, int(m.group(1)))
                if pct > shown:
                    shown = pct
                    print(json.dumps({"progress": pct}), flush=True)
            if time.time() > deadline:
                proc.kill()
                raise subprocess.TimeoutExpired(cmd, 3600)
        if proc.wait() != 0:
            raise subprocess.CalledProcessError(proc.returncode, cmd, stderr="rclone upload failed")
        print(json.dumps({"progress": 100}), flush=True)
        ls = subprocess.run(["rclone", "lsjson", target, "--files-only",
                             "--include", name] + flags,
                            check=True, capture_output=True, text=True)
        for entry in json.loads(ls.stdout):
            if entry.get("Name") == name and entry.get("ID"):
                plain = f"https://drive.google.com/file/d/{entry['ID']}/view"
                if not cfg.get("video_public", True):
                    return plain, None
                shared, err = set_public(entry["ID"], remote_file, flags, cfg)
                if shared:
                    log("  Video öffentlich freigegeben")
                    return shared, None
                # Freigabe gescheitert: Link trotzdem zurückgeben, aber sagen,
                # dass Empfänger ihn nicht öffnen können.
                return plain, err
        return None, "video uploaded, but no link found"
    except subprocess.TimeoutExpired:
        return None, "video upload took longer than 1h"
    except subprocess.CalledProcessError as e:
        detail = (e.stderr or "").strip().splitlines()[-1:] or [str(e)]
        return None, f"video upload failed: {detail[0]}"


def build_sections(title, meta_line, summary, steps, paras, video_url=None):
    """HTML-Gliederung: Video, Zusammenfassung, Nächste Schritte, Transkript."""
    esc = html.escape
    s = [f"<h1>{esc(title)}</h1>", f"<p><i>{esc(meta_line)}</i></p>"]
    if video_url:
        # Ganz oben: bei einem Screencast ist das Video die Hauptsache, das
        # Transkript der Beifang.
        s.append(f'<p>🎬 <a href="{esc(video_url)}">{esc(T("watch"))}</a></p>')
    if summary:
        s.append(f"<h2>{T('summary')}</h2>")
        s.append(f"<p>{esc(summary)}</p>")
    if steps:
        s.append(f"<h2>{T('steps')}</h2>")
        s.append("<ul>" + "".join(f"<li>{esc(x)}</li>" for x in steps) + "</ul>")
    s.append(f"<h2>{T('transcript')}</h2>")
    s.extend(f"<p>{esc(p)}</p>" for p in paras)
    return s


def write_markdown(title, meta_line, summary, steps, paras, doc_url, cfg, video_url=None):
    """Markdown-Kopie in den Notizordner (z. B. einen Obsidian-Vault).
    Returns (path, error)."""
    if not cfg.get("obsidian_enabled", True):
        return None, None
    target_dir = os.path.expanduser(cfg.get("vault_notes_dir") or DEFAULTS["vault_notes_dir"])
    try:
        os.makedirs(target_dir, exist_ok=True)
        path = os.path.join(target_dir, title + ".md")
        lines = ["---",
                 f"created: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M')}",
                 "source: RecBlitz",
                 f"google_doc: {doc_url or ''}",
                 f"video: {video_url or ''}",
                 "---", "", f"# {title}", "", f"*{meta_line}*", ""]
        if video_url:
            lines += [f"🎬 [{T('watch')}](<{video_url}>)", ""]
        if summary:
            lines += [f"## {T('summary')}", "", summary, ""]
        if steps:
            lines += [f"## {T('steps')}", ""] + [f"- {x}" for x in steps] + [""]
        lines += [f"## {T('transcript')}", ""]
        for p in paras:
            lines += [p, ""]
        with open(path, "w") as f:
            f.write("\n".join(lines))
        return path, None
    except OSError as e:
        return None, f"folder not writable ({e.strerror or e})"


# ---------------------------------------------------------------- Main

def parse_args(argv):
    """Returns dict: {mode, audio, text_file, duration, video}."""
    if "--text" in argv:
        def val(flag, default=None):
            return argv[argv.index(flag) + 1] if flag in argv else default
        return {"mode": "text", "text_file": val("--text"),
                "audio": val("--audio", ""), "duration": int(val("--duration", "0")),
                "video": val("--video", "")}
    return {"mode": "audio", "audio": argv[1], "text_file": None, "duration": 0, "video": ""}


def selftest():
    """Reine Logik ohne Netz, ohne Whisper, ohne rclone. Exit 1 bei Fehler."""
    fails = []
    def expect(cond, what):
        if not cond:
            fails.append(what)
    expect(clean_title('Plan: "Q4" / Budget.') == "Plan Q4 Budget", "clean_title")
    expect(clean_title(None) is None, "clean_title None")
    now = datetime.datetime(2026, 9, 25, 20, 41)
    expect(make_title("Hallo das ist ein kurzer Test", now) ==
           "Hallo das ist ein kurzer - 2026-09-25 20.41 - RecBlitz", "make_title fallback")
    expect(make_title("x", now, "Neuer Titel").startswith("Neuer Titel - "), "make_title ai")
    expect(paragraphs_from_text("A. B. C. D.") == ["A. B. C.", "D."], "paragraphs_from_text")
    expect(paragraphs_from_segments([(0, 1, "a"), (1.1, 2, "b"), (4, 5, "c")]) == ["a b", "c"],
           "paragraphs_from_segments")
    cfg = dict(DEFAULTS)
    expect(drive_ready(cfg) == (False, None), "drive off by default")
    expect(rclone_target({"drive_remote": "gd:", "drive_folder_id": "X1"}) ==
           ("gd:", ["--drive-root-folder-id", "X1"]), "rclone_target id")
    expect(rclone_target({"drive_remote": "gd:", "drive_folder": "Notes"}) == ("gd:Notes", []),
           "rclone_target name")
    with tempfile.TemporaryDirectory() as td:
        cfg["vault_notes_dir"] = td
        p, err = write_markdown("T", "meta", "S", ["x"], ["para"], None, cfg)
        expect(err is None and p and open(p).read().count("## ") == 3, "write_markdown")
    if fails:
        for f in fails:
            print("FAIL:", f)
        sys.exit(1)
    print("pipeline selftest OK")


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "error": "no arguments"}))
        sys.exit(1)
    if sys.argv[1] == "--selftest":
        selftest()
        return
    if sys.argv[1] == "--detect-lang":
        try:
            lang = detect_language(sys.argv[2])
            log(f"Sprach-Erkennung: {lang}")
            print(json.dumps({"language": lang}))
        except Exception as e:
            log(f"Sprach-Erkennung fehlgeschlagen: {e}")
            print(json.dumps({"language": None}))
        return
    args = parse_args(sys.argv)
    cfg = load_config()
    now = datetime.datetime.now()
    timer = Timer()
    log(f"Start ({args['mode']}): {args['audio'] or args['text_file']}")

    try:
        if args["mode"] == "text":
            with open(args["text_file"]) as f:
                text = f.read().strip()
            paras = paragraphs_from_text(text)
            duration = args["duration"]
            engine = T("engine_apple")
        else:
            text, segments = transcribe_whisper(args["audio"], cfg)
            paras = paragraphs_from_segments(segments) or [text]
            duration = int(segments[-1][1]) if segments else 0
            engine = T("engine_whisper")
            timer.lap("whisper")
        if not text:
            raise RuntimeError(T("empty"))

        # Claude ZUERST: der Titel benennt die Dateien, muss also vor dem
        # Upload feststehen. Ein Video gleich unter dem richtigen Namen
        # hochzuladen ist mehr wert als ein paar Sekunden Parallelität.
        ai_title, summary, steps = summarize_with_claude(text, cfg)
        timer.lap("titel+zusammenfassung")

        title = make_title(text, now, ai_title)
        meta_line = T("meta").format(
            date=now.strftime("%d.%m.%Y, %H:%M" if LANG == "de" else "%Y-%m-%d, %H:%M"),
            dur=f"{duration // 60}:{duration % 60:02d}", words=len(text.split()), engine=engine)

        ready, doc_err = drive_ready(cfg)
        video_url, video_err = None, None
        doc_url = None
        video_path = args.get("video") or ""
        if ready:
            video_url, video_err = upload_video(video_path, title, cfg)
            if video_path:
                timer.lap("video-upload")
            try:
                sections = build_sections(title, meta_line, summary, steps, paras, video_url)
                doc_url = upload_google_doc(title, sections, cfg)
            except subprocess.CalledProcessError as e:
                detail = (e.stderr or "").strip().splitlines()[-1:] or [str(e)]
                doc_err = f"rclone: {detail[0]}"
            timer.lap("drive-upload")

        # Ohne Drive bleibt ein Screencast lokal, die Notiz verlinkt die Datei.
        note_video = video_url or (f"file://{urllib.parse.quote(video_path)}"
                                   if video_path and os.path.exists(video_path) else None)
        md_path, md_err = write_markdown(title, meta_line, summary, steps, paras,
                                         doc_url, cfg, note_video)
        timer.lap("markdown")

        if not doc_url and not md_path:
            # Nirgends gespeichert: das ist dann doch ein Fehler, sonst ginge
            # die Aufnahme still verloren.
            raise RuntimeError(doc_err or md_err or T("nothing_saved"))

        preview = text[:160] + ("…" if len(text) > 160 else "")
        log(f"Fertig: {title} doc={doc_url} doc_err={doc_err} video={video_url} "
            f"video_err={video_err} md={md_path} md_err={md_err}")
        print(json.dumps({"ok": True, "title": title, "doc_url": doc_url, "doc_error": doc_err,
                          "video_url": video_url, "video_error": video_err,
                          "obsidian_path": md_path, "obsidian_error": md_err,
                          "preview": preview, "text": text, "error": None},
                         ensure_ascii=False))
    except subprocess.CalledProcessError as e:
        detail = (e.stderr or "").strip().splitlines()[-1:] or [str(e)]
        log(f"FEHLER (subprocess): {e} · {detail}")
        print(json.dumps({"ok": False, "error": f"{e.cmd[0]}: {detail[0]}"}, ensure_ascii=False))
        sys.exit(1)
    except Exception as e:  # noqa: Ergebnis-JSON ist der Fehlerkanal zur App
        log(f"FEHLER: {type(e).__name__}: {e}")
        print(json.dumps({"ok": False, "error": f"{e}"}, ensure_ascii=False))
        sys.exit(1)


if __name__ == "__main__":
    main()
