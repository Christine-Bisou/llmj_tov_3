"""Рендер для просмотра и ранжирования 7 ответов на один диалог.

Колонки строки:
    answer_1 .. answer_7   — тексты ответов (utf8)
    model_1  .. model_7    — имена моделей (utf8)
    dialog_2               — диалог: [{"role": ..., "content": ...}, ...]
    dialog_1               — запасной диалог, если dialog_2 пуст

Как выглядит страница:
    * диалог: пользователь справа, ассистент слева;
    * над ответами — ряд кнопок с именами моделей, кнопка гасит свой ответ;
    * ответы стоят в один ряд, по колонке на модель, markdown отрисован;
    * под ответами два ряда медалей — ToV и ПА; медаль стоит ровно по центру
      своей колонки, клик открывает выбор места 1..7 (места могут повторяться);
    * ниже сами собой строятся две шкалы победителей: места сортируются по
      возрастанию и сжимаются к первому, даже если первое не проставлено
      (например 3, 2, 5 → 1-е, 2-е, 3-е места);
    * два комментария — ToV слева, ПА справа — и один итоговый JSON
      с кнопками «скопировать»/«скачать».

Рендерятся только строки, где заполнены все 7 ответов; неполные уходят
во второй выход `main()` (и просто пропускаются в CLI).

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
  --pink:         #db2777;
  --pink-light:   #fdf2f8;
  --pink-border:  #fbcfe8;
  --pink-mid:     #f472b6;
  --rose:         #e11d48;
  --rose-light:   #fff1f2;
  --rose-border:  #fecdd3;
  --indigo:       #4f46e5;
  --indigo-light: #eef2ff;
  --indigo-border:#c7d2fe;
  --amber:        #d97706;
  --amber-light:  #fef3c7;
  --amber-border: #fde68a;
  --gold:         #d4a017;
  --silver:       #9aa0a6;
  --bronze:       #b06a2c;
  --radius:    14px;
  --radius-sm:  8px;
  --radius-xs:  5px;
  --shadow:    0 1px 3px rgba(0,0,0,.06), 0 1px 2px rgba(0,0,0,.04);
  --label-w:   58px;
  --col-min:  230px;
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
.page { max-width: 1600px; margin: 0 auto; padding: 20px 20px 60px }

.card {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius); box-shadow: var(--shadow);
  margin-bottom: 16px; overflow: hidden;
}
.card-head {
  display: flex; align-items: center; gap: 8px;
  padding: 10px 16px; border-bottom: 1px solid var(--border-light);
  font-size: 11px; font-weight: 700; letter-spacing: .08em;
  text-transform: uppercase; color: var(--ink-3); background: var(--surface-2);
}
.card-head .right { margin-left: auto; display: flex; gap: 6px; text-transform: none; letter-spacing: 0 }

/* Комментарии: ToV слева, ПА справа */
.comments {
  display: grid; grid-template-columns: 1fr 1fr;
  gap: 14px; padding: 14px 16px;
}
@media (max-width: 760px) { .comments { grid-template-columns: 1fr } }
.comment-col { display: flex; flex-direction: column; gap: 6px }
.comment-lbl {
  align-self: flex-start; padding: 3px 10px; border-radius: var(--radius-xs);
  font-size: 10.5px; font-weight: 800; letter-spacing: .07em; text-transform: uppercase;
}
.comment-lbl.tov { background: var(--pink); color: #fff }
.comment-lbl.pa { background: var(--indigo); color: #fff }

/* Диалог: ассистент слева, пользователь справа */
.dialog-turns { padding: 16px 18px; display: flex; flex-direction: column; gap: 12px }
.turn { display: flex; flex-direction: column; gap: 4px }
.turn.assistant { align-items: flex-start }
.turn.user { align-items: flex-end }
.turn-who {
  font-size: 10px; font-weight: 700; text-transform: uppercase;
  letter-spacing: .08em; padding: 0 4px;
}
.turn.user .turn-who { color: var(--indigo) }
.turn.assistant .turn-who { color: var(--pink) }
.bubble {
  display: inline-block; max-width: 78%;
  padding: 10px 15px; border-radius: 14px;
  font-size: 14px; line-height: 1.7; word-break: break-word;
}
.turn.user .bubble {
  background: var(--indigo-light); border: 1px solid var(--indigo-border);
  border-top-right-radius: 3px; white-space: pre-wrap; text-align: left;
}
.turn.assistant .bubble {
  background: var(--pink-light); border: 1px solid var(--pink-border);
  border-top-left-radius: 3px;
}
.turn.last-user .bubble { box-shadow: 0 0 0 3px rgba(79,70,229,.15) }
.no-turns { color: var(--ink-3); font-style: italic; font-size: 13px; padding: 4px 0 }

/* Markdown */
.md h1, .md h2, .md h3 { font-size: 14px; font-weight: 700; margin: 12px 0 5px; color: var(--ink) }
.md h1:first-child, .md h2:first-child, .md h3:first-child { margin-top: 0 }
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
.md pre {
  background: var(--surface-2); border: 1px solid var(--border);
  border-radius: var(--radius-xs); padding: 8px 10px; margin: 6px 0;
  overflow-x: auto; font-family: ui-monospace, monospace; font-size: 12.5px; line-height: 1.5;
}
.md pre code { background: none; border: none; padding: 0 }
.md blockquote {
  margin: 6px 0; padding: 2px 0 2px 10px;
  border-left: 3px solid var(--border); color: var(--ink-2);
}
.md a { color: var(--pink) }
.md-table-wrap { overflow-x: auto; margin: 8px 0; -webkit-overflow-scrolling: touch }
.md-table-wrap::-webkit-scrollbar { height: 6px }
.md-table-wrap::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px }
.md table { border-collapse: collapse; width: 100%; font-size: 12.5px; line-height: 1.5 }
.md th, .md td {
  border: 1px solid var(--border); padding: 5px 7px;
  text-align: left; vertical-align: top;
  min-width: 52px; overflow-wrap: break-word;
}
.md th { background: var(--pink-light); color: var(--ink); font-weight: 700 }
.md tbody tr:nth-child(even) { background: var(--surface-2) }

/* Панель включения моделей */
.toggles { display: flex; flex-wrap: wrap; gap: 6px; padding: 10px 14px; align-items: center }
.tgl {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 5px 12px; border-radius: 999px;
  border: 1px solid var(--pink-border); background: var(--pink-light);
  color: var(--pink); font: inherit; font-size: 12px; font-weight: 700;
  cursor: pointer; transition: all .12s; max-width: 260px;
}
.tgl .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--pink); flex-shrink: 0 }
.tgl .nm { overflow: hidden; text-overflow: ellipsis; white-space: nowrap }
.tgl:hover { border-color: var(--pink) }
.tgl.off { background: var(--surface-2); border-color: var(--border); color: var(--ink-3) }
.tgl.off .dot { background: var(--border) }
.tgl.off .nm { text-decoration: line-through }
.mini {
  padding: 5px 11px; border: 1px solid var(--border); border-radius: 999px;
  background: var(--surface); color: var(--ink-2);
  font: inherit; font-size: 11.5px; font-weight: 600; cursor: pointer;
}
.mini:hover { border-color: var(--pink-mid); background: #fff }

/* Ряд ответов + ряды медалей */
.board-wrap { overflow-x: auto; padding: 0 14px 14px }
.board { min-width: 100%; display: flex; flex-direction: column; gap: 10px }
.brow { display: flex; gap: 10px; align-items: stretch }
.blabel {
  flex: 0 0 var(--label-w); width: var(--label-w);
  display: flex; align-items: center; justify-content: flex-end;
  padding-right: 2px; font-size: 10.5px; font-weight: 800;
  letter-spacing: .06em; text-transform: uppercase;
}
.blabel.tov { color: var(--pink) }
.blabel.pa  { color: var(--indigo) }
.bcell { flex: 1 1 0; min-width: var(--col-min); display: flex; justify-content: center }

.ans {
  flex: 1 1 0; min-width: var(--col-min);
  display: flex; flex-direction: column;
  background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius); overflow: hidden;
}
.ans-head {
  display: flex; align-items: center; gap: 8px;
  padding: 8px 12px; background: var(--surface-2);
  border-bottom: 1px solid var(--border-light);
}
.ans-num {
  display: inline-flex; align-items: center; justify-content: center;
  width: 20px; height: 20px; border-radius: 50%;
  background: var(--ink); color: #fff; font-size: 10.5px; font-weight: 800; flex-shrink: 0;
}
.ans-name {
  font-size: 12.5px; font-weight: 700; color: var(--ink);
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.ans-body {
  padding: 12px 14px; font-size: 13.5px; line-height: 1.65;
  max-height: 62vh; overflow-y: auto;
}
.ans.off { display: none }
.bcell.off { display: none }

/* Медали */
.medal {
  position: relative;
  display: inline-flex; align-items: center; justify-content: center;
  width: 40px; height: 40px; border-radius: 50%;
  border: 2px solid var(--border); background: var(--surface);
  font: inherit; font-size: 16px; cursor: pointer;
  transition: transform .1s, border-color .12s, background .12s;
}
.medal:hover { border-color: var(--pink-mid) }
.medal:active { transform: scale(.94) }
.medal .pl { font-size: 16px; font-weight: 800; color: var(--ink) }
.medal.set { background: var(--surface-2) }
.medal.p1 { border-color: var(--gold);   background: #fffaf0 }
.medal.p1 .pl { color: var(--gold) }
.medal.p2 { border-color: var(--silver); background: #f7f8f9 }
.medal.p2 .pl { color: var(--silver) }
.medal.p3 { border-color: var(--bronze); background: #fdf6f0 }
.medal.p3 .pl { color: var(--bronze) }
.medal.pn { border-color: var(--ink-3) }

/* Всплывашка выбора места */
.pick {
  position: absolute; z-index: 80; display: none;
  padding: 8px; border-radius: var(--radius-sm);
  background: var(--surface); border: 1px solid var(--border);
  box-shadow: 0 10px 26px rgba(0,0,0,.14);
}
.pick.on { display: block }
.pick-lbl {
  font-size: 10px; font-weight: 800; letter-spacing: .06em;
  text-transform: uppercase; color: var(--ink-3); margin-bottom: 6px; text-align: center;
}
.pick-row { display: flex; gap: 4px }
.pick-row button {
  width: 30px; height: 30px; border-radius: var(--radius-xs);
  border: 1px solid var(--border); background: var(--surface-2);
  font: inherit; font-size: 13px; font-weight: 700; color: var(--ink-2); cursor: pointer;
}
.pick-row button:hover { border-color: var(--pink-mid); background: #fff }
.pick-row button.on { background: var(--pink); border-color: var(--pink); color: #fff }
.pick-row button.clr { color: var(--ink-3) }
.pick-row button.clr:hover { border-color: var(--rose-border); background: var(--rose-light); color: var(--rose) }

/* Шкалы победителей */
.podium { display: flex; flex-direction: column; gap: 10px; padding: 14px 16px }
.pod-row { display: flex; align-items: flex-start; gap: 10px; flex-wrap: wrap }
.pod-lbl {
  flex-shrink: 0; padding: 3px 10px; border-radius: var(--radius-xs);
  font-size: 10.5px; font-weight: 800; letter-spacing: .07em; text-transform: uppercase;
}
.pod-lbl.tov { background: var(--pink); color: #fff }
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
  width: 100%; min-height: 120px; resize: vertical;
  border: 1.5px solid var(--border); border-radius: var(--radius-sm);
  padding: 10px 13px; font-size: 14px; font-family: inherit; line-height: 1.6;
  color: var(--ink); background: var(--surface-2);
  transition: border-color .15s, box-shadow .15s;
}
textarea:focus { outline: none; border-color: var(--pink); background: #fff; box-shadow: 0 0 0 3px rgba(219,39,119,.12) }

.json-head {
  background: #1c1917; color: #e7e5e4; padding: 10px 16px;
  font-size: 12px; font-weight: 700; display: flex; align-items: center; gap: 8px;
}
.json-head .btns { margin-left: auto; display: flex; gap: 6px }
.copy-btn {
  background: var(--pink); color: #fff; border: none; border-radius: var(--radius-xs);
  padding: 5px 14px; font: inherit; font-size: 12px; font-weight: 700; cursor: pointer;
  transition: background .12s, transform .08s;
}
.copy-btn:hover { background: #be185d }
.copy-btn:active { transform: scale(.97) }
.copy-btn.ok { background: #9d174d }
.copy-btn.ghost { background: #44403c }
.copy-btn.ghost:hover { background: #57534e }
pre#json-out {
  padding: 14px 16px; font-size: 12px; line-height: 1.65;
  white-space: pre-wrap; word-break: break-word;
  background: #fafaf9; max-height: 300px; overflow-y: auto;
  border-top: 1px solid var(--border-light);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
}
</style>
</head>
<body>
<div class="page">

  <div class="card">
    <div class="card-head"><span>💬</span> Диалог</div>
    <div class="dialog-turns" id="dialog-turns"></div>
  </div>

  <div class="card">
    <div class="card-head">
      <span>📦</span> Ответы
      <span class="right">
        <span id="ans-counter" style="font-size:11px;color:var(--ink-3);align-self:center"></span>
        <button class="mini" id="btn-all">Показать все</button>
        <button class="mini" id="btn-none">Скрыть все</button>
        <button class="mini" id="btn-reset">Сбросить места</button>
      </span>
    </div>
    <div class="toggles" id="toggles"></div>
    <div class="board-wrap">
      <div class="board">
        <div class="brow" id="row-answers"><div class="blabel"></div></div>
        <div class="brow" id="row-tov"><div class="blabel tov">ToV</div></div>
        <div class="brow" id="row-pa"><div class="blabel pa">ПА</div></div>
      </div>
    </div>
  </div>

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
    <div class="card-head"><span>📝</span> Комментарии</div>
    <div class="comments">
      <div class="comment-col">
        <div class="comment-lbl tov">ToV</div>
        <textarea id="comment-tov" placeholder="Напишите плюсы, недостатки, восхищения и недовольства — всё, что думаете об ответах"></textarea>
      </div>
      <div class="comment-col">
        <div class="comment-lbl pa">ПА</div>
        <textarea id="comment-pa" placeholder="Напишите плюсы, недостатки, восхищения и недовольства — всё, что думаете об ответах"></textarea>
      </div>
    </div>
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
</div>

<div class="pick" id="pick">
  <div class="pick-lbl" id="pick-lbl"></div>
  <div class="pick-row" id="pick-row"></div>
</div>
"""

_HTML_SCRIPT = r"""
<script>
var DATA = DATA_JSON_PLACEHOLDER;

/* ------------------------------ markdown ------------------------------ */
function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

var MD_REFS = {};                       // ссылки вида [1]: https://... из текущего текста

function inlineFmt(s) {
  s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  s = s.replace(/\[([^\]]+)\]\[([^\]]*)\]/g, function (m, text, id) {
    var url = MD_REFS[(id || text).trim().toLowerCase()];
    return url ? '<a href="' + url + '" target="_blank" rel="noopener">' + text + '</a>' : m;
  });
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/__([^_]+)__/g, '<strong>$1</strong>');
  s = s.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>');
  return s;
}

/* ------------------------------- таблицы ------------------------------ */
/* Ряд режем по «|», крайние палки не обязательны, «\|» — просто символ. */
function splitRow(raw) {
  var s = raw.trim().replace(/^\|/, '').replace(/\|$/, '');
  var cells = [], cur = '';
  for (var i = 0; i < s.length; i++) {
    var ch = s.charAt(i);
    if (ch === '\\' && s.charAt(i + 1) === '|') { cur += '|'; i++; continue; }
    if (ch === '|') { cells.push(cur); cur = ''; continue; }
    cur += ch;
  }
  cells.push(cur);
  return cells.map(function (c) { return c.trim(); });
}

function isTableRow(raw) {
  return raw.indexOf('|') >= 0 && splitRow(raw).length >= 2;
}

/* Строка-разделитель ---|:---:|---: задаёт выравнивание колонок. */
function tableAligns(raw) {
  if (!raw || raw.indexOf('|') < 0) return null;
  var cells = splitRow(raw);
  if (cells.length < 2) return null;
  var aligns = [];
  for (var i = 0; i < cells.length; i++) {
    var c = cells[i];
    if (!/^:?-+:?$/.test(c)) return null;
    var l = c.charAt(0) === ':', r = c.charAt(c.length - 1) === ':';
    aligns.push(l && r ? 'center' : (r ? 'right' : (l ? 'left' : '')));
  }
  return aligns;
}

function tableCell(tag, text, align) {
  var a = align ? ' style="text-align:' + align + '"' : '';
  return '<' + tag + a + '>' + inlineFmt(esc(text || '')) + '</' + tag + '>';
}

function renderTable(head, aligns, body) {
  var ncol = Math.max(head.length, aligns.length), c, r;
  var th = [];
  for (c = 0; c < ncol; c++) th.push(tableCell('th', head[c], aligns[c]));
  var rows = [];
  for (r = 0; r < body.length; r++) {
    var td = [];
    for (c = 0; c < ncol; c++) td.push(tableCell('td', body[r][c], aligns[c]));
    rows.push('<tr>' + td.join('') + '</tr>');
  }
  return '<div class="md-table-wrap"><table><thead><tr>' + th.join('') + '</tr></thead>'
       + (rows.length ? '<tbody>' + rows.join('') + '</tbody>' : '')
       + '</table></div>';
}

function mdToHtml(md) {
  if (!md) return '';
  var lines = String(md).split('\n');
  var out = [], listTag = null, inCode = false, codeBuf = [];

  /* Сноски [1]: https://... собираем заранее и в текст не пускаем. */
  MD_REFS = {};
  var skip = {};
  for (var d = 0; d < lines.length; d++) {
    var dm = lines[d].match(/^\s{0,3}\[([^\]]+)\]:\s*<?([^>\s]+)>?\s*$/);
    if (dm) {
      MD_REFS[dm[1].trim().toLowerCase()] = esc(dm[2]).replace(/"/g, '%22');
      skip[d] = true;
    }
  }

  function closeList() { if (listTag) { out.push('</' + listTag + '>'); listTag = null; } }
  function openList(tag) { if (listTag !== tag) { closeList(); out.push('<' + tag + '>'); listTag = tag; } }

  for (var i = 0; i < lines.length; i++) {
    var raw = lines[i].replace(/\s+$/, '');

    if (/^\s*```/.test(raw)) {
      if (inCode) { out.push('<pre><code>' + esc(codeBuf.join('\n')) + '</code></pre>'); codeBuf = []; inCode = false; }
      else { closeList(); inCode = true; }
      continue;
    }
    if (inCode) { codeBuf.push(raw); continue; }
    if (skip[i]) continue;

    /* Таблица: шапка + разделитель. Пустые строки между рядами не мешают. */
    if (isTableRow(raw)) {
      var j = i + 1;
      while (j < lines.length && lines[j].trim() === '') j++;
      var aligns = j < lines.length ? tableAligns(lines[j]) : null;
      if (aligns) {
        closeList();
        var body = [], k = j + 1;
        while (k < lines.length) {
          var look = k;
          while (look < lines.length && lines[look].trim() === '') look++;
          /* Соседний ряд достаточно узнать по палке, после пустой строки — строже. */
          var ok = look < lines.length && !skip[look]
                && (look === k ? lines[look].indexOf('|') >= 0 : isTableRow(lines[look]));
          if (!ok) break;
          body.push(splitRow(lines[look]));
          k = look + 1;
        }
        out.push(renderTable(splitRow(raw), aligns, body));
        i = k - 1;
        continue;
      }
    }

    var line = esc(raw);
    if (/^(---+|\*\*\*+|___+)$/.test(line.trim())) { closeList(); out.push('<hr>'); continue; }

    var hm = line.match(/^(#{1,6})\s+(.+)/);
    if (hm) {
      closeList();
      var tag = hm[1].length <= 2 ? 'h2' : 'h3';
      out.push('<' + tag + '>' + inlineFmt(hm[2]) + '</' + tag + '>');
      continue;
    }
    var qm = line.match(/^\s*&gt;\s?(.*)/);
    if (qm) { closeList(); out.push('<blockquote>' + inlineFmt(qm[1]) + '</blockquote>'); continue; }

    var om = line.match(/^\s*\d+[.)]\s+(.+)/);
    if (om) { openList('ol'); out.push('<li>' + inlineFmt(om[1]) + '</li>'); continue; }
    var um = line.match(/^\s*[-*•]\s+(.+)/);
    if (um) { openList('ul'); out.push('<li>' + inlineFmt(um[1]) + '</li>'); continue; }

    if (line.trim() === '') { closeList(); continue; }
    closeList();
    out.push('<p>' + inlineFmt(line) + '</p>');
  }
  if (inCode && codeBuf.length) out.push('<pre><code>' + esc(codeBuf.join('\n')) + '</code></pre>');
  closeList();
  return out.join('\n');
}

/* ------------------------------ состояние ----------------------------- */
var ANSWERS = DATA.answers || [];
var HIDDEN  = {};                       // slot -> true
var RANKS   = { tov: {}, pa: {} };      // scale -> slot -> место 1..7
var SCALES  = [{ key: 'tov', label: 'ToV' }, { key: 'pa', label: 'ПА' }];
var MAX_PLACE = 7;

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

/* ------------------- кнопки моделей, ответы, медали ------------------- */
(function () {
  var toggles = document.getElementById('toggles');
  var rowAns  = document.getElementById('row-answers');
  var rows    = { tov: document.getElementById('row-tov'), pa: document.getElementById('row-pa') };

  if (!ANSWERS.length) {
    rowAns.insertAdjacentHTML('beforeend', '<div class="bcell no-turns">Ответов нет</div>');
    return;
  }

  ANSWERS.forEach(function (a) {
    // кнопка включения
    var t = document.createElement('button');
    t.type = 'button';
    t.className = 'tgl';
    t.id = 'tgl-' + a.slot;
    t.title = a.model;
    var dot = document.createElement('span');
    dot.className = 'dot';
    var nm = document.createElement('span');
    nm.className = 'nm';
    nm.textContent = a.num + '. ' + a.model;
    t.appendChild(dot);
    t.appendChild(nm);
    t.addEventListener('click', function () { toggle(a.slot); });
    toggles.appendChild(t);

    // колонка ответа
    var card = document.createElement('div');
    card.className = 'ans';
    card.id = 'ans-' + a.slot;

    var head = document.createElement('div');
    head.className = 'ans-head';
    var num = document.createElement('span');
    num.className = 'ans-num';
    num.textContent = a.num;
    var name = document.createElement('span');
    name.className = 'ans-name';
    name.textContent = a.model;
    name.title = a.model;
    head.appendChild(num);
    head.appendChild(name);
    card.appendChild(head);

    var body = document.createElement('div');
    body.className = 'ans-body md';
    body.innerHTML = mdToHtml(a.content);
    card.appendChild(body);
    rowAns.appendChild(card);

    // медали под колонкой
    SCALES.forEach(function (s) {
      var cell = document.createElement('div');
      cell.className = 'bcell';
      cell.id = 'cell-' + s.key + '-' + a.slot;

      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'medal';
      b.id = 'medal-' + s.key + '-' + a.slot;
      b.title = s.label + ' · ' + a.model + ' — выбрать место';
      b.innerHTML = '<span class="pl">🏅</span>';
      b.addEventListener('click', function (ev) {
        ev.stopPropagation();
        openPicker(s.key, a, b);
      });

      cell.appendChild(b);
      rows[s.key].appendChild(cell);
    });
  });
})();

/* ---------------------------- выбор места ----------------------------- */
var PICK = document.getElementById('pick');
var PICK_LBL = document.getElementById('pick-lbl');
var PICK_ROW = document.getElementById('pick-row');
var pickCtx = null;

function openPicker(scale, answer, anchor) {
  if (pickCtx && pickCtx.scale === scale && pickCtx.slot === answer.slot && PICK.classList.contains('on')) {
    closePicker();
    return;
  }
  pickCtx = { scale: scale, slot: answer.slot };
  PICK_LBL.textContent = (scale === 'tov' ? 'ToV' : 'ПА') + ' · ' + answer.model;
  PICK_ROW.textContent = '';

  var current = RANKS[scale][answer.slot];
  for (var p = 1; p <= MAX_PLACE; p++) {
    (function (place) {
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = place;
      if (current === place) b.className = 'on';
      b.addEventListener('click', function (ev) {
        ev.stopPropagation();
        setRank(scale, answer.slot, place);
        closePicker();
      });
      PICK_ROW.appendChild(b);
    })(p);
  }
  var clr = document.createElement('button');
  clr.type = 'button';
  clr.className = 'clr';
  clr.textContent = '✕';
  clr.title = 'Снять место';
  clr.addEventListener('click', function (ev) {
    ev.stopPropagation();
    setRank(scale, answer.slot, null);
    closePicker();
  });
  PICK_ROW.appendChild(clr);

  PICK.classList.add('on');
  var r = anchor.getBoundingClientRect();
  var w = PICK.offsetWidth, h = PICK.offsetHeight;
  var left = r.left + window.scrollX + r.width / 2 - w / 2;
  left = Math.max(8, Math.min(left, window.scrollX + document.documentElement.clientWidth - w - 8));
  var top = r.bottom + window.scrollY + 8;
  if (r.bottom + h + 16 > window.innerHeight) top = r.top + window.scrollY - h - 8;
  PICK.style.left = left + 'px';
  PICK.style.top = top + 'px';
}

function closePicker() {
  PICK.classList.remove('on');
  pickCtx = null;
}

document.addEventListener('click', function (ev) {
  if (PICK.classList.contains('on') && !PICK.contains(ev.target)) closePicker();
});
document.addEventListener('keydown', function (ev) { if (ev.key === 'Escape') closePicker(); });
window.addEventListener('resize', closePicker);

/* ------------------------------ действия ------------------------------ */
function toggle(slot) {
  if (HIDDEN[slot]) delete HIDDEN[slot]; else HIDDEN[slot] = true;
  closePicker();
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
document.getElementById('comment-tov').addEventListener('input', updateJson);
document.getElementById('comment-pa').addEventListener('input', updateJson);

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
      document.getElementById('cell-' + s.key + '-' + a.slot).classList.toggle('off', off);
      var b = document.getElementById('medal-' + s.key + '-' + a.slot);
      var p = RANKS[s.key][a.slot];
      b.className = 'medal' + (p ? ' set p' + (p <= 3 ? p : 'n') : '');
      b.querySelector('.pl').textContent = p ? p : '🏅';
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
      line: podiumText(scale),
      comment: document.getElementById('comment-' + scale).value.trim()
    };
  }

  return {
    title: DATA.title || null,
    models: models,
    hidden: ANSWERS.filter(function (a) { return HIDDEN[a.slot]; }).map(function (a) { return a.slot; }),
    tov: scaleBlock('tov'),
    pa: scaleBlock('pa')
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

    title = row.get("instruct_id") or row.get("id") or query[:60]

    data = {
        "title": str(title) if title else "",
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


def has_all_answers(row):
    """True, если заполнены все семь ответов."""
    return len(collect_answers(row)) == len(SLOTS)


def main(in1=None, in2=None, in3=None, mr_tables=None, **kwargs):
    """Точка входа для операции: на каждую строку — отрендеренная html-страница.

    Рендерятся только строки, где заполнены все 7 ответов. Неполные строки
    уходят во второй выход, чтобы они не пропадали молча.
    """
    results = []
    skipped = []
    for row in (in1 or []):
        row_id = row.get("instruct_id", row.get("id", ""))
        answers = collect_answers(row)
        if len(answers) < len(SLOTS):
            skipped.append({
                "instruct_id": row_id,
                "filled": len(answers),
                "empty_slots": [s for s in SLOTS if s not in {a["slot"] for a in answers}],
            })
            continue
        results.append({
            "instruct_id": row_id,
            "html": build_html(row),
        })
    return results, skipped


# --------------------------------------------------------------------------- #
# Локальный запуск
# --------------------------------------------------------------------------- #

_DEMO_ROW = {
    "instruct_id": "demo-1",
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
        "## Вариант %d\n\n"
        "Если коротко, то сюжет держится на трёх сценах.\n\n"
        "- **Первый акт** — знакомство с героями\n"
        "- **Второй акт** — сцена у озера\n"
        "- Третий акт — бал и развязка\n\n"
        "> Музыка Чайковского здесь работает как отдельный герой.\n\n"
        "Спектакль | Что особенного | По времени |\n\n"
        "| --- | --- | :---: |\n\n"
        "| Лебединое озеро | Белый акт и 32 фуэте ([Большой][1]) | ⚠️ 2 ч 45 мин |\n\n"
        "| Спящая красавица | Пышные декорации, много детей в зале | ❌ 3 ч 10 мин |\n\n"
        "| Дон Кихот | Живой темп, испанские танцы | ✅ 2 ч 20 мин |\n\n"
        "Если интересно, могу разобрать *музыкальные темы* по актам.\n\n"
        "[1]: https://bolshoi.ru/\n" % _i
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
    skipped = 0
    with open(src, encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if not has_all_answers(row):
                skipped += 1
                continue
            name = str(row.get("instruct_id") or row.get("id") or i)
            name = re.sub(r"[^\w.-]+", "_", name)[:80]
            path = os.path.join(dst, "%s.html" % name)
            with open(path, "w", encoding="utf-8") as out:
                out.write(build_html(row))
            written += 1
    print("написано страниц: %d в %s (пропущено неполных: %d)" % (written, dst, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
