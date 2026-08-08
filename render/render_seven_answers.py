"""Рендер для просмотра и ранжирования 7 ответов на один диалог.

Колонки строки:
    answer_1 .. answer_7   — тексты ответов (utf8)
    model_1  .. model_7    — имена моделей (utf8)
    dialog_2               — диалог: [{"role": ..., "content": ...}, ...]
    dialog_1               — запасной диалог, если dialog_2 пуст
    instruct               — системная инструкция (опционально)
    query_1                — последний запрос пользователя (опционально)

Что умеет разметка:
    * имя модели над ответом — кнопка: клик прячет/возвращает ответ;
    * панель из 7 кнопок под ответами (прилипает к низу экрана) — то же самое,
      выключенная модель гаснет;
    * под каждым ответом два ряда мест 1..7 — отдельно для ToV и для ПА,
      места могут повторяться;
    * снизу автоматически строятся две шкалы победителей: места сортируются
      по возрастанию и сжимаются к первому, даже если первое не проставлено
      (например 3, 2, 5 → 1-е, 2-е, 3-е места);
    * общий комментарий и один итоговый JSON с кнопками «скопировать»/«скачать».

Локальная проверка:
    python render/render_seven_answers.py --demo out.html
    python render/render_seven_answers.py rows.jsonl out_dir/
"""

import ast
import html as html_lib
import json
import os
import re
import sys

SLOTS = ["answer_%d" % i for i in range(1, 8)]
MODEL_KEYS = ["model_%d" % i for i in range(1, 8)]


# --------------------------------------------------------------------------- #
# Разбор входных данных
# --------------------------------------------------------------------------- #

def _parens_to_braces(s):
    """Меняет круглые скобки на фигурные, не трогая скобки внутри строк."""
    out = []
    in_str = False
    quote = ""
    escaped = False
    for ch in s:
        if in_str:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                in_str = False
            continue
        if ch in "\"'":
            in_str = True
            quote = ch
            out.append(ch)
        elif ch == "(":
            out.append("{")
        elif ch == ")":
            out.append("}")
        else:
            out.append(ch)
    return "".join(out)


def _coerce(raw):
    """Приводит колонку к питоновскому объекту: JSON, python-literal или как есть."""
    if raw is None:
        return None
    if isinstance(raw, (list, dict)):
        return raw
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except Exception:
            return None
    if not isinstance(raw, str):
        return None

    s = raw.strip()
    if not s:
        return None

    for loader in (json.loads, ast.literal_eval):
        try:
            return loader(s)
        except Exception:
            pass

    # Формат из превьюшки таблицы, где словари показаны круглыми скобками:
    #   [ ( "content": "...", "role": "user" ), ... ]
    repaired = _parens_to_braces(s)
    for loader in (json.loads, ast.literal_eval):
        try:
            return loader(repaired)
        except Exception:
            pass
    return None


def parse_dialog(raw):
    """Достаёт список реплик [{'role': ..., 'content': ...}] из колонки диалога."""
    data = _coerce(raw)
    if isinstance(data, dict):
        for key in ("dialog", "messages", "turns", "content"):
            if key in data:
                data = data[key]
                break
    if not isinstance(data, list):
        return []

    turns = []
    for item in data:
        if isinstance(item, dict):
            role = str(item.get("role") or item.get("author") or "user")
            content = item.get("content")
            if content is None:
                content = item.get("text", "")
            if isinstance(content, (list, dict)):
                content = json.dumps(content, ensure_ascii=False, indent=2)
            turns.append({"role": role, "content": str(content)})
        elif isinstance(item, (list, tuple)) and len(item) == 2:
            turns.append({"role": str(item[0]), "content": str(item[1])})
        elif isinstance(item, str):
            turns.append({"role": "user", "content": item})
    return turns


def collect_answers(row):
    """Собирает непустые ответы вместе с именами моделей."""
    answers = []
    for idx, (slot, mkey) in enumerate(zip(SLOTS, MODEL_KEYS), start=1):
        text = row.get(slot)
        if text is None:
            continue
        text = str(text)
        if not text.strip():
            continue
        model = row.get(mkey)
        model = str(model).strip() if model is not None and str(model).strip() else "модель %d" % idx
        answers.append({"slot": slot, "num": idx, "model": model, "content": text})
    return answers


# --------------------------------------------------------------------------- #
# Шаблон
# --------------------------------------------------------------------------- #

_HTML_HEAD = r"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>7 ответов — TITLE_PLACEHOLDER</title>
<style>
:root {
  --bg:           #f7f5f2;
  --surface:      #ffffff;
  --surface-2:    #faf9f7;
  --border:       #e8e4de;
  --border-light: #f0ede8;
  --ink:          #1c1917;
  --ink-2:        #57534e;
  --ink-3:        #a8a29e;
  --teal:         #0d9488;
  --teal-light:   #f0fdfa;
  --teal-border:  #99f6e4;
  --teal-mid:     #2dd4bf;
  --rose:         #e11d48;
  --rose-light:   #fff1f2;
  --rose-border:  #fecdd3;
  --indigo:       #4f46e5;
  --indigo-light: #eef2ff;
  --indigo-border:#c7d2fe;
  --amber:        #d97706;
  --amber-light:  #fef3c7;
  --amber-border: #fde68a;
  --radius:    14px;
  --radius-sm:  8px;
  --radius-xs:  5px;
  --shadow:    0 1px 3px rgba(0,0,0,.06), 0 1px 2px rgba(0,0,0,.04);
}
* { box-sizing: border-box; margin: 0; padding: 0 }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Inter', sans-serif;
  font-size: 14px;
  line-height: 1.55;
  background: var(--bg);
  color: var(--ink);
  -webkit-font-smoothing: antialiased;
}
.page { max-width: 1220px; margin: 0 auto; padding: 26px 22px 190px }

.page-eyebrow {
  font-size: 11px; font-weight: 700; letter-spacing: .1em;
  text-transform: uppercase; color: var(--ink-3); margin-bottom: 10px;
}
.meta-strip { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 18px; align-items: center }
.chip {
  display: inline-flex; align-items: center; gap: 5px;
  padding: 5px 13px; border-radius: 999px;
  font-size: 12px; font-weight: 500;
  background: var(--surface); border: 1px solid var(--border);
  color: var(--ink-2); box-shadow: var(--shadow); white-space: nowrap;
}
.chip b { color: var(--ink); font-weight: 700 }
.chip.hi { background: var(--teal-light); border-color: var(--teal-border); color: var(--teal) }

.card {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius); box-shadow: var(--shadow);
  margin-bottom: 18px; overflow: hidden;
}
.card-head {
  display: flex; align-items: center; gap: 8px;
  padding: 11px 18px; border-bottom: 1px solid var(--border-light);
  font-size: 11px; font-weight: 700; letter-spacing: .08em;
  text-transform: uppercase; color: var(--ink-3); background: var(--surface-2);
}
.card-head .right { margin-left: auto; display: flex; gap: 6px; text-transform: none; letter-spacing: 0 }

details.instruct summary {
  cursor: pointer; padding: 11px 18px; background: var(--surface-2);
  font-size: 11px; font-weight: 700; letter-spacing: .08em;
  text-transform: uppercase; color: var(--ink-3); user-select: none;
}
details.instruct[open] summary { border-bottom: 1px solid var(--border-light) }
details.instruct .instruct-body {
  padding: 14px 18px; white-space: pre-wrap; font-size: 13px;
  line-height: 1.6; color: var(--ink-2); max-height: 320px; overflow-y: auto;
}

/* Диалог */
.dialog-turns { padding: 18px 20px; display: flex; flex-direction: column; gap: 13px }
.turn { display: flex; flex-direction: column; gap: 4px; align-items: flex-start }
.turn-who {
  font-size: 10px; font-weight: 700; text-transform: uppercase;
  letter-spacing: .08em; padding: 0 4px;
}
.turn-who.user { color: var(--indigo) }
.turn-who.assistant { color: var(--teal) }
.bubble {
  display: inline-block; max-width: 88%;
  padding: 11px 16px; border-radius: 14px;
  font-size: 14px; line-height: 1.7; word-break: break-word;
  border-top-left-radius: 3px;
}
.turn.user .bubble { background: var(--indigo-light); border: 1px solid var(--indigo-border); white-space: pre-wrap }
.turn.assistant .bubble { background: var(--teal-light); border: 1px solid var(--teal-border) }
.turn.last-user .bubble { box-shadow: 0 0 0 3px rgba(79,70,229,.15) }
.no-turns { color: var(--ink-3); font-style: italic; font-size: 13px; padding: 4px 0 }

/* Markdown */
.md h2, .md h3 { font-size: 14px; font-weight: 700; margin: 12px 0 5px; color: var(--ink) }
.md h2:first-child, .md h3:first-child { margin-top: 0 }
.md p { margin: 0 0 8px }
.md p:last-child { margin-bottom: 0 }
.md ul, .md ol { margin: 4px 0 8px 18px; display: flex; flex-direction: column; gap: 3px }
.md li { line-height: 1.6 }
.md strong { font-weight: 700 }
.md em { font-style: italic }
.md hr { border: none; border-top: 1px solid var(--border); margin: 10px 0 }
.md code {
  background: var(--surface-2); border: 1px solid var(--border);
  border-radius: 3px; padding: 0 4px; font-family: ui-monospace, monospace; font-size: 12.5px;
}
.md a { color: var(--teal) }

.divider {
  display: flex; align-items: center; gap: 10px; margin: 24px 0 14px;
  font-size: 11px; font-weight: 700; letter-spacing: .09em;
  text-transform: uppercase; color: var(--ink-3);
}
.divider::before, .divider::after { content: ''; flex: 1; height: 1px; background: var(--border) }

/* Ответы */
.answers { display: flex; flex-direction: column; gap: 14px }
.answers.cols2 { display: grid; grid-template-columns: 1fr 1fr; align-items: start }
@media (max-width: 900px) { .answers.cols2 { grid-template-columns: 1fr } }

.ans {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius); box-shadow: var(--shadow); overflow: hidden;
}
.ans-head {
  display: flex; align-items: center; gap: 9px;
  padding: 9px 14px; background: var(--surface-2);
  border-bottom: 1px solid var(--border-light);
}
.ans-num {
  display: inline-flex; align-items: center; justify-content: center;
  width: 22px; height: 22px; border-radius: 50%;
  background: var(--ink); color: #fff; font-size: 11px; font-weight: 800; flex-shrink: 0;
}
.model-btn {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 4px 12px; border-radius: 999px;
  border: 1px solid var(--teal-border); background: var(--teal-light);
  color: var(--teal); font: inherit; font-size: 12.5px; font-weight: 700;
  cursor: pointer; transition: background .12s, border-color .12s, color .12s;
  max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.model-btn:hover { border-color: var(--teal); background: #fff }
.model-btn::after { content: '✕'; font-size: 10px; opacity: .55 }
.ans-head .place-tags { margin-left: auto; display: flex; gap: 5px; flex-shrink: 0 }
.place-tag {
  display: none; align-items: center; gap: 4px;
  padding: 2px 9px; border-radius: 999px;
  font-size: 10.5px; font-weight: 800; letter-spacing: .04em; text-transform: uppercase;
}
.place-tag.on { display: inline-flex }
.place-tag.tov { background: var(--teal-light); color: var(--teal); border: 1px solid var(--teal-border) }
.place-tag.pa  { background: var(--indigo-light); color: var(--indigo); border: 1px solid var(--indigo-border) }

.ans-body { padding: 14px 16px; font-size: 14px; line-height: 1.7 }
.ans-ranks {
  display: flex; flex-direction: column; gap: 6px;
  padding: 10px 14px 12px; border-top: 1px solid var(--border-light); background: var(--surface-2);
}
.rank-row { display: flex; align-items: center; gap: 5px; flex-wrap: wrap }
.rank-lbl {
  width: 42px; flex-shrink: 0;
  font-size: 10px; font-weight: 800; letter-spacing: .06em; text-transform: uppercase;
}
.rank-lbl.tov { color: var(--teal) }
.rank-lbl.pa { color: var(--indigo) }
.rk {
  min-width: 28px; padding: 3px 0 4px;
  border: 1px solid var(--border); border-radius: var(--radius-xs);
  background: var(--surface); color: var(--ink-2);
  font: inherit; font-size: 12px; font-weight: 700; line-height: 1.2;
  text-align: center; cursor: pointer; transition: all .12s;
}
.rk:hover { border-color: var(--teal-mid) }
.rank-row.tov .rk.on { background: var(--teal); border-color: var(--teal); color: #fff }
.rank-row.pa  .rk.on { background: var(--indigo); border-color: var(--indigo); color: #fff }
.rk.clr { color: var(--ink-3); min-width: 26px }
.rk.clr:hover { border-color: var(--rose-border); background: var(--rose-light); color: var(--rose) }

/* Выключенный ответ */
.ans.off { opacity: .5 }
.ans.off .ans-body, .ans.off .ans-ranks { display: none }
.ans.off .model-btn {
  background: var(--surface); border-color: var(--border);
  color: var(--ink-3); text-decoration: line-through;
}
.ans.off .model-btn::after { content: '↩' }
.ans.off .ans-num { background: var(--border); color: var(--ink-3) }

/* Панель моделей снизу */
.dock {
  position: sticky; bottom: 0; z-index: 40;
  margin: 16px -22px -190px; padding: 10px 22px 12px;
  background: rgba(255,255,255,.94);
  backdrop-filter: blur(8px);
  border-top: 1px solid var(--border);
  box-shadow: 0 -4px 14px rgba(0,0,0,.05);
}
.dock-inner { max-width: 1220px; margin: 0 auto; display: flex; flex-direction: column; gap: 8px }
.dock-row { display: flex; flex-wrap: wrap; align-items: center; gap: 6px }
.dock-lbl {
  font-size: 10px; font-weight: 800; letter-spacing: .07em;
  text-transform: uppercase; color: var(--ink-3); margin-right: 4px;
}
.tgl {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 5px 12px; border-radius: 999px;
  border: 1px solid var(--teal-border); background: var(--teal-light);
  color: var(--teal); font: inherit; font-size: 12px; font-weight: 700;
  cursor: pointer; transition: all .12s; max-width: 240px;
}
.tgl .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--teal); flex-shrink: 0 }
.tgl .nm { overflow: hidden; text-overflow: ellipsis; white-space: nowrap }
.tgl:hover { border-color: var(--teal) }
.tgl.off { background: var(--surface-2); border-color: var(--border); color: var(--ink-3) }
.tgl.off .dot { background: var(--border) }
.tgl.off .nm { text-decoration: line-through }
.mini {
  padding: 5px 11px; border: 1px solid var(--border); border-radius: 999px;
  background: var(--surface); color: var(--ink-2);
  font: inherit; font-size: 11.5px; font-weight: 600; cursor: pointer;
}
.mini:hover { border-color: var(--teal-mid); background: #fff }

/* Шкалы победителей */
.podium { display: flex; flex-direction: column; gap: 10px; padding: 14px 16px }
.pod-row { display: flex; align-items: flex-start; gap: 10px; flex-wrap: wrap }
.pod-lbl {
  flex-shrink: 0; padding: 3px 10px; border-radius: var(--radius-xs);
  font-size: 10.5px; font-weight: 800; letter-spacing: .07em; text-transform: uppercase;
}
.pod-lbl.tov { background: var(--teal); color: #fff }
.pod-lbl.pa { background: var(--indigo); color: #fff }
.pod-line { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; font-size: 13px }
.pod-empty { color: var(--ink-3); font-style: italic; font-size: 12.5px }
.pod-grp {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 4px 11px; border-radius: 999px;
  background: var(--surface-2); border: 1px solid var(--border);
}
.pod-grp .pl {
  display: inline-flex; align-items: center; justify-content: center;
  min-width: 18px; height: 18px; padding: 0 5px; border-radius: 999px;
  background: var(--ink); color: #fff; font-size: 10px; font-weight: 800;
}
.pod-grp.first { background: var(--amber-light); border-color: var(--amber-border) }
.pod-grp.first .pl { background: var(--amber) }
.pod-grp .nm { font-weight: 600 }
.pod-grp .sep { color: var(--ink-3) }
.pod-arrow { color: var(--ink-3); font-weight: 700 }

textarea {
  width: 100%; min-height: 80px; resize: vertical;
  border: 1.5px solid var(--border); border-radius: var(--radius-sm);
  padding: 10px 13px; font-size: 14px; font-family: inherit; line-height: 1.6;
  color: var(--ink); background: var(--surface-2);
  transition: border-color .15s, box-shadow .15s;
}
textarea:focus { outline: none; border-color: var(--teal); background: #fff; box-shadow: 0 0 0 3px rgba(13,148,136,.1) }

.json-head {
  background: #1c1917; color: #e7e5e4; padding: 10px 18px;
  font-size: 12px; font-weight: 700; display: flex; align-items: center; gap: 8px;
}
.json-head .btns { margin-left: auto; display: flex; gap: 6px }
.copy-btn {
  background: var(--teal); color: #fff; border: none; border-radius: var(--radius-xs);
  padding: 5px 14px; font: inherit; font-size: 12px; font-weight: 700; cursor: pointer;
  transition: background .12s, transform .08s;
}
.copy-btn:hover { background: #0f766e }
.copy-btn:active { transform: scale(.97) }
.copy-btn.ok { background: #16a34a }
.copy-btn.ghost { background: #44403c }
.copy-btn.ghost:hover { background: #57534e }
pre#json-out {
  padding: 14px 18px; font-size: 12px; line-height: 1.65;
  white-space: pre-wrap; word-break: break-word;
  background: #fafaf9; max-height: 320px; overflow-y: auto;
  border-top: 1px solid var(--border-light);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}
</style>
</head>
<body>
<div class="page">
  <div class="page-eyebrow">Сравнение 7 ответов</div>
  <div class="meta-strip" id="meta-strip"></div>

  <div class="card" id="instruct-card" style="display:none">
    <details class="instruct">
      <summary>⚙ Инструкция</summary>
      <div class="instruct-body" id="instruct-body"></div>
    </details>
  </div>

  <div class="card">
    <div class="card-head"><span>💬</span> Диалог</div>
    <div class="dialog-turns" id="dialog-turns"></div>
  </div>

  <div class="divider">Ответы</div>
  <div class="card-head" style="border:1px solid var(--border);border-radius:var(--radius);margin-bottom:12px">
    <span id="ans-counter">0 из 0 показано</span>
    <span class="right">
      <button class="mini" id="btn-cols">В две колонки</button>
      <button class="mini" id="btn-md">Markdown: вкл</button>
    </span>
  </div>
  <div class="answers" id="answers"></div>

  <div class="divider">Победители</div>
  <div class="card">
    <div class="podium">
      <div class="pod-row">
        <span class="pod-lbl tov">ToV</span>
        <div class="pod-line" id="pod-tov"></div>
      </div>
      <div class="pod-row">
        <span class="pod-lbl pa">ПА</span>
        <div class="pod-line" id="pod-pa"></div>
      </div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><span>📝</span> Общий комментарий</div>
    <div style="padding:14px 16px"><textarea id="comment" placeholder="Что важного не влезло в места: чем победитель лучше, за что штрафовали остальных…"></textarea></div>
  </div>

  <div class="card">
    <div class="json-head">
      <span>Результат (JSON)</span>
      <span class="btns">
        <button class="copy-btn ghost" id="download-btn">⬇ Скачать</button>
        <button class="copy-btn" id="copy-btn">📋 Скопировать</button>
      </span>
    </div>
    <pre id="json-out"></pre>
  </div>

  <div class="dock">
    <div class="dock-inner">
      <div class="dock-row" id="dock-models"><span class="dock-lbl">Модели</span></div>
      <div class="dock-row">
        <button class="mini" id="btn-all">Показать все</button>
        <button class="mini" id="btn-none">Скрыть все</button>
        <button class="mini" id="btn-reset">Сбросить места</button>
      </div>
    </div>
  </div>
</div>
"""

_HTML_SCRIPT = r"""
<script>
var DATA = DATA_JSON_PLACEHOLDER;

/* ------------------------------ markdown ------------------------------ */
function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function inlineFmt(s) {
  s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>');
  return s;
}

function mdToHtml(md) {
  if (!md) return '';
  var lines = String(md).split('\n');
  var out = [], listTag = null;

  function closeList() { if (listTag) { out.push('</' + listTag + '>'); listTag = null; } }
  function openList(tag) { if (listTag !== tag) { closeList(); out.push('<' + tag + '>'); listTag = tag; } }

  for (var i = 0; i < lines.length; i++) {
    var line = esc(lines[i].replace(/\s+$/, ''));
    if (/^(---+|\*\*\*+|___+)$/.test(line.trim())) { closeList(); out.push('<hr>'); continue; }
    var hm = line.match(/^(#{1,6})\s+(.+)/);
    if (hm) {
      closeList();
      var tag = hm[1].length <= 2 ? 'h2' : 'h3';
      out.push('<' + tag + '>' + inlineFmt(hm[2]) + '</' + tag + '>');
      continue;
    }
    var om = line.match(/^\s*\d+[.)]\s+(.+)/);
    if (om) { openList('ol'); out.push('<li>' + inlineFmt(om[1]) + '</li>'); continue; }
    var um = line.match(/^\s*[-*•]\s+(.+)/);
    if (um) { openList('ul'); out.push('<li>' + inlineFmt(um[1]) + '</li>'); continue; }
    if (line.trim() === '') { closeList(); continue; }
    closeList();
    out.push('<p>' + inlineFmt(line) + '</p>');
  }
  closeList();
  return out.join('\n');
}

function plain(t) { return '<div style="white-space:pre-wrap">' + esc(t) + '</div>'; }

/* ------------------------------ состояние ----------------------------- */
var ANSWERS = DATA.answers || [];
var HIDDEN  = {};                       // slot -> true
var RANKS   = { tov: {}, pa: {} };      // scale -> slot -> место 1..7
var MD_ON   = true;
var SCALES  = [{ key: 'tov', label: 'ToV' }, { key: 'pa', label: 'ПА' }];

/* ------------------------------- шапка -------------------------------- */
(function () {
  var strip = document.getElementById('meta-strip');
  var chips = [];
  if (DATA.title) chips.push({ text: DATA.title, hi: true });
  chips.push({ text: '📦 ответов: ' + ANSWERS.length });
  if (DATA.query) chips.push({ text: '❓ ' + DATA.query });
  chips.forEach(function (c) {
    var d = document.createElement('div');
    d.className = 'chip' + (c.hi ? ' hi' : '');
    d.textContent = c.text.length > 120 ? c.text.slice(0, 119) + '…' : c.text;
    d.title = c.text;
    strip.appendChild(d);
  });

  if (DATA.instruct) {
    document.getElementById('instruct-card').style.display = '';
    document.getElementById('instruct-body').textContent = DATA.instruct;
  }
})();

/* ------------------------------- диалог ------------------------------- */
(function () {
  var wrap = document.getElementById('dialog-turns');
  var turns = DATA.dialog || [];
  if (!turns.length) { wrap.innerHTML = '<div class="no-turns">Диалог пуст</div>'; return; }
  var lastUser = -1;
  turns.forEach(function (t, i) { if (t.role === 'user') lastUser = i; });

  wrap.innerHTML = turns.map(function (t, i) {
    var r = t.role === 'user' ? 'user' : 'assistant';
    var who = r === 'user' ? 'Пользователь' : 'Ассистент';
    var body = r === 'user' ? esc(t.content || '') : '<div class="md">' + mdToHtml(t.content || '') + '</div>';
    return '<div class="turn ' + r + (i === lastUser ? ' last-user' : '') + '">' +
             '<div class="turn-who ' + r + '">' + who + '</div>' +
             '<div class="bubble">' + body + '</div>' +
           '</div>';
  }).join('');
})();

/* ------------------------------- ответы ------------------------------- */
(function () {
  var wrap = document.getElementById('answers');
  if (!ANSWERS.length) { wrap.innerHTML = '<div class="card"><div style="padding:16px" class="no-turns">Ответов нет</div></div>'; return; }

  ANSWERS.forEach(function (a) {
    var card = document.createElement('div');
    card.className = 'ans';
    card.id = 'ans-' + a.slot;

    var head = document.createElement('div');
    head.className = 'ans-head';

    var num = document.createElement('span');
    num.className = 'ans-num';
    num.textContent = a.num;
    head.appendChild(num);

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'model-btn';
    btn.title = a.model + ' — клик, чтобы спрятать ответ';
    btn.textContent = a.model;
    btn.addEventListener('click', function () { toggle(a.slot); });
    head.appendChild(btn);

    var tags = document.createElement('span');
    tags.className = 'place-tags';
    SCALES.forEach(function (s) {
      var tag = document.createElement('span');
      tag.className = 'place-tag ' + s.key;
      tag.id = 'tag-' + s.key + '-' + a.slot;
      tags.appendChild(tag);
    });
    head.appendChild(tags);
    card.appendChild(head);

    var body = document.createElement('div');
    body.className = 'ans-body md';
    body.id = 'body-' + a.slot;
    body.innerHTML = mdToHtml(a.content);
    card.appendChild(body);

    var ranks = document.createElement('div');
    ranks.className = 'ans-ranks';
    SCALES.forEach(function (s) {
      var row = document.createElement('div');
      row.className = 'rank-row ' + s.key;

      var lbl = document.createElement('span');
      lbl.className = 'rank-lbl ' + s.key;
      lbl.textContent = s.label;
      row.appendChild(lbl);

      for (var p = 1; p <= 7; p++) {
        (function (place) {
          var b = document.createElement('button');
          b.type = 'button';
          b.className = 'rk';
          b.dataset.scale = s.key;
          b.dataset.slot = a.slot;
          b.dataset.place = String(place);
          b.textContent = place;
          b.title = s.label + ': ' + place + '-е место';
          b.addEventListener('click', function () { setRank(s.key, a.slot, place); });
          row.appendChild(b);
        })(p);
      }

      var clr = document.createElement('button');
      clr.type = 'button';
      clr.className = 'rk clr';
      clr.textContent = '✕';
      clr.title = 'Снять место';
      clr.addEventListener('click', function () { setRank(s.key, a.slot, null); });
      row.appendChild(clr);

      ranks.appendChild(row);
    });
    card.appendChild(ranks);
    wrap.appendChild(card);
  });
})();

/* ------------------------- панель моделей снизу ------------------------ */
(function () {
  var dock = document.getElementById('dock-models');
  ANSWERS.forEach(function (a) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'tgl';
    b.id = 'tgl-' + a.slot;
    b.title = a.model;
    var dot = document.createElement('span');
    dot.className = 'dot';
    var nm = document.createElement('span');
    nm.className = 'nm';
    nm.textContent = a.num + '. ' + a.model;
    b.appendChild(dot);
    b.appendChild(nm);
    b.addEventListener('click', function () { toggle(a.slot); });
    dock.appendChild(b);
  });
})();

/* ------------------------------ действия ------------------------------ */
function toggle(slot) {
  if (HIDDEN[slot]) delete HIDDEN[slot]; else HIDDEN[slot] = true;
  render();
}

function setRank(scale, slot, place) {
  if (place === null || RANKS[scale][slot] === place) delete RANKS[scale][slot];
  else RANKS[scale][slot] = place;
  render();
}

document.getElementById('btn-all').addEventListener('click', function () { HIDDEN = {}; render(); });
document.getElementById('btn-none').addEventListener('click', function () {
  ANSWERS.forEach(function (a) { HIDDEN[a.slot] = true; });
  render();
});
document.getElementById('btn-reset').addEventListener('click', function () {
  RANKS = { tov: {}, pa: {} };
  render();
});
document.getElementById('btn-cols').addEventListener('click', function () {
  var on = document.getElementById('answers').classList.toggle('cols2');
  this.textContent = on ? 'В одну колонку' : 'В две колонки';
});
document.getElementById('btn-md').addEventListener('click', function () {
  MD_ON = !MD_ON;
  this.textContent = 'Markdown: ' + (MD_ON ? 'вкл' : 'выкл');
  ANSWERS.forEach(function (a) {
    var el = document.getElementById('body-' + a.slot);
    el.innerHTML = MD_ON ? mdToHtml(a.content) : plain(a.content);
  });
});
document.getElementById('comment').addEventListener('input', updateJson);

/* --------------------------- шкала победителей ------------------------- */
/* Места сортируются по возрастанию и сжимаются к первому: проставленные
   3, 5, 5, 6 превращаются в 1-е, 2-е (двое), 3-е. Равные места — через «/». */
function podium(scale) {
  var byPlace = {};
  ANSWERS.forEach(function (a) {
    var p = RANKS[scale][a.slot];
    if (!p) return;
    (byPlace[p] = byPlace[p] || []).push(a);
  });
  return Object.keys(byPlace)
    .map(Number)
    .sort(function (x, y) { return x - y; })
    .map(function (p, i) {
      return { place: i + 1, raw: p, items: byPlace[p] };
    });
}

function renderPodium(scale, hostId) {
  var host = document.getElementById(hostId);
  host.textContent = '';
  var groups = podium(scale);
  if (!groups.length) {
    var e = document.createElement('span');
    e.className = 'pod-empty';
    e.textContent = 'места не проставлены';
    host.appendChild(e);
    return;
  }
  groups.forEach(function (g, gi) {
    if (gi) {
      var arrow = document.createElement('span');
      arrow.className = 'pod-arrow';
      arrow.textContent = '—';
      host.appendChild(arrow);
    }
    var grp = document.createElement('span');
    grp.className = 'pod-grp' + (g.place === 1 ? ' first' : '');
    var pl = document.createElement('span');
    pl.className = 'pl';
    pl.textContent = g.place;
    grp.appendChild(pl);
    g.items.forEach(function (a, ai) {
      if (ai) {
        var sep = document.createElement('span');
        sep.className = 'sep';
        sep.textContent = '/';
        grp.appendChild(sep);
      }
      var nm = document.createElement('span');
      nm.className = 'nm';
      nm.textContent = a.model;
      nm.title = a.slot + ' · выставлено ' + g.raw;
      grp.appendChild(nm);
    });
    host.appendChild(grp);
  });
}

function podiumText(scale) {
  return podium(scale).map(function (g) {
    return g.items.map(function (a) { return a.model; }).join(' / ');
  }).join(' — ');
}

/* ------------------------------- отрисовка ----------------------------- */
function render() {
  var shown = 0;
  ANSWERS.forEach(function (a) {
    var off = !!HIDDEN[a.slot];
    if (!off) shown++;
    document.getElementById('ans-' + a.slot).classList.toggle('off', off);
    var tgl = document.getElementById('tgl-' + a.slot);
    if (tgl) tgl.classList.toggle('off', off);

    SCALES.forEach(function (s) {
      var tag = document.getElementById('tag-' + s.key + '-' + a.slot);
      var p = RANKS[s.key][a.slot];
      tag.classList.toggle('on', !!p);
      tag.textContent = s.label + ' ' + (p || '');
    });

    document.querySelectorAll('#ans-' + a.slot + ' .rk').forEach(function (b) {
      if (!b.dataset.place) return;
      b.classList.toggle('on', RANKS[b.dataset.scale][a.slot] === Number(b.dataset.place));
    });
  });

  document.getElementById('ans-counter').textContent = shown + ' из ' + ANSWERS.length + ' показано';
  renderPodium('tov', 'pod-tov');
  renderPodium('pa', 'pod-pa');
  updateJson();
}

/* --------------------------------- JSON -------------------------------- */
function getResult() {
  var models = {};
  ANSWERS.forEach(function (a) { models[a.slot] = a.model; });

  function scaleBlock(scale) {
    var ranks = {};
    ANSWERS.forEach(function (a) {
      var p = RANKS[scale][a.slot];
      if (p) ranks[a.slot] = p;
    });
    return {
      ranks: ranks,
      order: podium(scale).map(function (g) {
        return {
          place: g.place,
          raw_place: g.raw,
          slots: g.items.map(function (a) { return a.slot; }),
          models: g.items.map(function (a) { return a.model; })
        };
      }),
      line: podiumText(scale)
    };
  }

  return {
    title: DATA.title || null,
    query: DATA.query || null,
    models: models,
    hidden: ANSWERS.filter(function (a) { return HIDDEN[a.slot]; }).map(function (a) { return a.slot; }),
    tov: scaleBlock('tov'),
    pa: scaleBlock('pa'),
    comment: document.getElementById('comment').value.trim()
  };
}

function updateJson() {
  document.getElementById('json-out').textContent = JSON.stringify(getResult(), null, 2);
}

document.getElementById('copy-btn').addEventListener('click', function () {
  var b = this;
  navigator.clipboard.writeText(JSON.stringify(getResult())).then(function () {
    b.textContent = '✅ Скопировано';
    b.classList.add('ok');
    setTimeout(function () { b.textContent = '📋 Скопировать'; b.classList.remove('ok'); }, 1800);
  });
});

document.getElementById('download-btn').addEventListener('click', function () {
  var blob = new Blob([JSON.stringify(getResult(), null, 2)], { type: 'application/json' });
  var url = URL.createObjectURL(blob);
  var a = document.createElement('a');
  a.href = url;
  a.download = (DATA.title ? String(DATA.title).replace(/[^\w.-]+/g, '_').slice(0, 60) : 'ranking') + '.json';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
});

render();
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------- #
# Сборка
# --------------------------------------------------------------------------- #

def build_html(row):
    dialog = parse_dialog(row.get("dialog_2"))
    if not dialog:
        dialog = parse_dialog(row.get("dialog_1"))

    query = row.get("query_1")
    query = str(query).strip() if query else ""
    if not query:
        for turn in reversed(dialog):
            if turn["role"] == "user":
                query = turn["content"]
                break

    instruct = row.get("instruct")
    instruct = str(instruct) if instruct else ""

    title = row.get("instruct_id") or row.get("id") or query[:60]

    data = {
        "title": str(title) if title else "",
        "query": query,
        "instruct": instruct,
        "dialog": dialog,
        "answers": collect_answers(row),
    }

    html = _HTML_HEAD.replace("TITLE_PLACEHOLDER", html_lib.escape(data["title"]), 1)
    html += _HTML_SCRIPT.replace(
        "DATA_JSON_PLACEHOLDER",
        json.dumps(data, ensure_ascii=False).replace("</", "<\\/"),
        1,
    )
    return html


def main(in1=None, in2=None, in3=None, mr_tables=None, **kwargs):
    """Точка входа для операции: на каждую строку — отрендеренная html-страница."""
    results = []
    for row in (in1 or []):
        results.append({
            "instruct_id": row.get("instruct_id", row.get("id", "")),
            "html": build_html(row),
        })
    return results, []


# --------------------------------------------------------------------------- #
# Локальный запуск
# --------------------------------------------------------------------------- #

_DEMO_ROW = {
    "instruct_id": "demo-1",
    "instruct": "Отвечай дружелюбно, без канцелярита, не выдумывай личный опыт.",
    "query_1": "расскажи подробнее",
    "dialog_2": json.dumps([
        {"role": "user", "content": "расскажи лебединое озеро спящая красавица дон-кихот"},
        {"role": "assistant", "content": "Кратко о сюжетах этих балетов:\n\n**Лебединое озеро**\nПринц Зигфрид встречает Одетту…"},
        {"role": "user", "content": "расскажи сюжет балетных спектаклей в большом театре"},
        {"role": "assistant", "content": "Конечно.\n\n**Лебединое озеро** — история о принце Зигфриде и заколдованной Одетте."},
        {"role": "user", "content": "расскажи подробнее"},
    ], ensure_ascii=False),
    "model_1": "baseline",
    "model_2": "sft-v3",
    "model_3": "sft-v4",
    "model_4": "rl-tov-1",
    "model_5": "rl-tov-2",
    "model_6": "prod",
    "model_7": "prod-hotfix",
}
for _i in range(1, 8):
    _DEMO_ROW["answer_%d" % _i] = (
        "Вариант **%d**.\n\n"
        "- Первый акт: знакомство с героями\n"
        "- Второй акт: сцена у озера\n\n"
        "Если интересно, могу разобрать *музыкальные темы* по актам." % _i
    )


def _cli(argv):
    if not argv:
        print(__doc__)
        return 1

    if argv[0] == "--demo":
        out = argv[1] if len(argv) > 1 else "demo.html"
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(build_html(_DEMO_ROW))
        print("написано: %s" % out)
        return 0

    src = argv[0]
    dst = argv[1] if len(argv) > 1 else "rendered"
    os.makedirs(dst, exist_ok=True)
    written = 0
    with open(src, encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            name = str(row.get("instruct_id") or row.get("id") or i)
            name = re.sub(r"[^\w.-]+", "_", name)[:80]
            path = os.path.join(dst, "%s.html" % name)
            with open(path, "w", encoding="utf-8") as out:
                out.write(build_html(row))
            written += 1
    print("написано страниц: %d в %s" % (written, dst))
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
