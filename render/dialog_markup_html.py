import json
import html as html_lib

def get_combined_dialog(bt_info_raw, full_dialog_raw):
    dialog = []

    # 1. Достаем контекст (вопросы и промежуточные ответы) из bt_info
    if isinstance(bt_info_raw, str):
        try:
            bt_info_raw = json.loads(bt_info_raw)
        except Exception:
            bt_info_raw = {}

    if isinstance(bt_info_raw, dict):
        ctx = bt_info_raw.get("dialog_from_summarizer_context", [])
        if isinstance(ctx, str):
            try:
                ctx = json.loads(ctx)
            except Exception:
                ctx = []

        if isinstance(ctx, list):
            for t in ctx:
                if isinstance(t, dict):
                    dialog.append({
                        "role": str(t.get("role", "user")),
                        "content": str(t.get("content", ""))
                    })

    # 2. Достаем финальный ответ ассистента из соседней колонки full_dialog
    if isinstance(full_dialog_raw, str):
        try:
            full_dialog_raw = json.loads(full_dialog_raw)
        except Exception:
            full_dialog_raw = []

    if isinstance(full_dialog_raw, list):
        for t in full_dialog_raw:
            # Находим реплику ассистента и приклеиваем в конец
            if isinstance(t, dict) and str(t.get("role")) == "assistant":
                dialog.append({
                    "role": "assistant",
                    "content": str(t.get("content", ""))
                })

    return dialog


# Шаблон собирается конкатенацией — никакого str.format(),
# поэтому фигурные скобки в CSS/JS не нужно экранировать вообще.
_HTML_HEAD = """<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Разметка — INSTRUCT_ID_PLACEHOLDER</title>
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
  --radius:    14px;
  --radius-sm:  8px;
  --radius-xs:  5px;
  --shadow:    0 1px 3px rgba(0,0,0,.06), 0 1px 2px rgba(0,0,0,.04);
  --panel-w:  282px;
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
.page {
  max-width: 1160px;
  margin: 0 auto;
  padding: 28px 24px 56px;
}
/* Пока панель маркеров развернута — освобождаем ей место справа */
@media (max-width: 1520px) {
  body.mk-open .page { max-width: none; margin: 0; padding-right: calc(var(--panel-w) + 30px); }
}
@media (max-width: 860px) {
  body.mk-open .page { padding-right: 24px; }
}

/* Шапка */
.page-eyebrow {
  font-size: 11px;
  font-weight: 700;
  letter-spacing: .1em;
  text-transform: uppercase;
  color: var(--ink-3);
  margin-bottom: 10px;
}
.meta-strip {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-bottom: 22px;
  align-items: center;
}
.chip {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 5px 13px;
  border-radius: 999px;
  font-size: 12px;
  font-weight: 500;
  background: var(--surface);
  border: 1px solid var(--border);
  color: var(--ink-2);
  box-shadow: var(--shadow);
  white-space: nowrap;
}
.chip b { color: var(--ink); font-weight: 700 }
.chip.hi { background: var(--teal-light); border-color: var(--teal-border); color: var(--teal); }
.chip.hi b { color: var(--teal) }
.chip.unknown { color: var(--ink-3); font-style: italic; }

/* Диалог */
.dialog-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  margin-bottom: 24px;
  overflow: hidden;
}
.dialog-card-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 11px 18px;
  border-bottom: 1px solid var(--border-light);
  font-size: 11px;
  font-weight: 700;
  letter-spacing: .08em;
  text-transform: uppercase;
  color: var(--ink-3);
  background: var(--surface-2);
}
.dialog-turns {
  padding: 20px 22px;
  display: flex;
  flex-direction: column;
  gap: 14px;
}
.turn { display: flex; flex-direction: column; gap: 4px }
.turn-who { font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: .08em; padding: 0 4px; }
.turn-who.user { color: var(--indigo) }
.turn-who.assistant { color: var(--teal) }
.bubble {
  display: inline-block;
  max-width: 82%;
  padding: 11px 16px;
  border-radius: 14px;
  font-size: 14px;
  line-height: 1.7;
  word-break: break-word;
}
.turn.user { align-items: flex-start }
.turn.assistant { align-items: flex-start }
.turn.user .bubble {
  background: var(--indigo-light);
  border: 1px solid var(--indigo-border);
  border-top-left-radius: 3px;
  white-space: pre-wrap;
}
.turn.assistant .bubble {
  background: var(--teal-light);
  border: 1px solid var(--teal-border);
  border-top-left-radius: 3px;
}

/* Markdown */
.bubble h2, .bubble h3 { font-size: 14px; font-weight: 700; margin: 12px 0 5px; color: var(--ink); }
.bubble h2:first-child, .bubble h3:first-child { margin-top: 0 }
.bubble p { margin: 0 0 8px }
.bubble p:last-child { margin-bottom: 0 }
.bubble ul, .bubble ol { margin: 4px 0 8px 18px; display: flex; flex-direction: column; gap: 3px; }
.bubble li { line-height: 1.6 }
.bubble strong { font-weight: 700 }
.bubble em { font-style: italic }
.bubble hr { border: none; border-top: 1px solid var(--border); margin: 10px 0; }
.bubble a { color: var(--teal); text-decoration: none; font-size: 12px; opacity: .75; }
.bubble a:hover { opacity: 1; text-decoration: underline }
.bubble .src-link {
  display: inline-block;
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: 3px;
  padding: 0 4px;
  font-size: 11px;
  color: var(--ink-3);
  font-family: monospace;
  line-height: 1.4;
  vertical-align: middle;
  margin: 0 1px;
}
.no-turns { color: var(--ink-3); font-style: italic; font-size: 13px; padding: 4px 0; }

/* Метки прямо в диалоге */
mark.mk {
  background: var(--amber-light);
  color: inherit;
  border-bottom: 2px solid var(--amber);
  border-radius: 3px;
  padding: 1px 0;
  cursor: pointer;
}
mark.mk:hover { background: #fde68a }
mark.mk[data-sec="pa"] { background: var(--indigo-light); border-bottom-color: var(--indigo); }
mark.mk[data-sec="pa"]:hover { background: #e0e7ff }
mark.mk .mk-tag {
  display: inline-block;
  max-width: 210px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  vertical-align: 2px;
  margin-left: 5px;
  padding: 0 5px;
  border-radius: 3px;
  background: var(--amber);
  color: #fff;
  font-size: 9.5px;
  font-weight: 800;
  line-height: 1.5;
  letter-spacing: .03em;
  text-transform: uppercase;
}
mark.mk[data-sec="pa"] .mk-tag { background: var(--indigo) }
mark.mk .mk-tag::after { content: ' ✕'; opacity: .7 }
mark.mk.flash { box-shadow: 0 0 0 3px rgba(217,119,6,.35) }

/* Плашка-маркер справа сверху */
.mk-panel {
  position: fixed;
  top: 14px;
  right: 14px;
  z-index: 60;
  width: var(--panel-w);
  max-height: calc(100vh - 28px);
  display: flex;
  flex-direction: column;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: 0 10px 30px rgba(0,0,0,.10), 0 2px 6px rgba(0,0,0,.06);
  overflow: hidden;
}
.mk-panel.collapsed { width: auto }
.mk-panel.collapsed .mk-hint,
.mk-panel.collapsed .mk-scroll,
.mk-panel.collapsed .mk-foot { display: none }
.mk-head {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 10px 12px;
  background: var(--surface-2);
  border-bottom: 1px solid var(--border-light);
  font-size: 11px;
  font-weight: 700;
  letter-spacing: .07em;
  text-transform: uppercase;
  color: var(--ink-2);
  cursor: pointer;
  user-select: none;
  white-space: nowrap;
}
.mk-head .mk-total {
  margin-left: auto;
  background: var(--teal);
  color: #fff;
  border-radius: 999px;
  padding: 1px 8px;
  font-size: 10px;
  font-weight: 800;
}
.mk-head .mk-total.zero { background: var(--border); color: var(--ink-3) }
.mk-head .mk-caret { color: var(--ink-3); font-size: 10px }
.mk-hint {
  padding: 8px 12px;
  font-size: 11px;
  line-height: 1.45;
  color: var(--ink-3);
  background: var(--surface-2);
  border-bottom: 1px solid var(--border-light);
}
.mk-hint.armed { background: var(--teal-light); color: var(--teal); font-weight: 600 }
.mk-hint q { font-style: italic }
.mk-scroll { overflow-y: auto; padding: 9px 10px 12px }
.mk-sec {
  margin: 12px 0 7px;
  padding: 3px 9px;
  border-radius: var(--radius-xs);
  background: var(--ink);
  color: #fff;
  font-size: 10px;
  font-weight: 800;
  letter-spacing: .08em;
  text-transform: uppercase;
}
.mk-sec:first-child { margin-top: 0 }
.mk-grp {
  margin: 9px 0 4px;
  font-size: 10px;
  font-weight: 700;
  letter-spacing: .06em;
  text-transform: uppercase;
  color: var(--ink-3);
}
.mk-btn {
  display: flex;
  align-items: center;
  gap: 6px;
  width: 100%;
  margin-bottom: 4px;
  padding: 5px 8px;
  border: 1px solid var(--border);
  border-radius: var(--radius-xs);
  background: var(--surface-2);
  color: var(--ink-2);
  font: inherit;
  font-size: 11.5px;
  line-height: 1.35;
  text-align: left;
  cursor: pointer;
  transition: background .12s, border-color .12s;
}
.mk-btn:hover { background: #fff; border-color: var(--teal-mid) }
.mk-btn.on { background: var(--teal-light); border-color: var(--teal); color: var(--ink); font-weight: 600 }
.mk-btn .t { flex: 1; overflow: hidden; text-overflow: ellipsis }
.mk-btn .n {
  flex-shrink: 0;
  min-width: 17px;
  padding: 0 5px;
  border-radius: 999px;
  background: var(--teal);
  color: #fff;
  font-size: 10px;
  font-weight: 800;
  text-align: center;
}
.mk-foot { display: flex; gap: 6px; padding: 8px 10px; background: var(--surface-2); border-top: 1px solid var(--border-light) }
.mk-foot button {
  flex: 1;
  padding: 6px 8px;
  border: 1px solid var(--border);
  border-radius: var(--radius-xs);
  background: var(--surface);
  color: var(--ink-2);
  font: inherit;
  font-size: 11px;
  font-weight: 600;
  cursor: pointer;
}
.mk-foot button:hover { border-color: var(--rose-border); background: var(--rose-light); color: var(--rose) }

.divider {
  display: flex;
  align-items: center;
  gap: 10px;
  margin: 22px 0 14px;
  font-size: 11px;
  font-weight: 700;
  letter-spacing: .09em;
  text-transform: uppercase;
  color: var(--ink-3);
}
.divider::before, .divider::after { content: ''; flex: 1; height: 1px; background: var(--border); }

/* Формы */
.form-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  margin-bottom: 12px;
  overflow: hidden;
}
.form-head {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 11px 18px;
  background: var(--surface-2);
  border-bottom: 1px solid var(--border-light);
  font-size: 13px;
  font-weight: 700;
  color: var(--ink);
}
.step-badge {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: var(--teal);
  color: #fff;
  font-size: 11px;
  font-weight: 800;
  flex-shrink: 0;
}
.form-sub { font-size: 11px; font-weight: 500; color: var(--ink-3); margin-left: 2px; }
.form-body { padding: 16px 18px }

/* Опции */
.opts { display: flex; flex-direction: column; gap: 6px }
.opts-row { display: flex; flex-direction: row; flex-wrap: wrap; gap: 6px; margin-bottom: 12px; }
.opts-row .opt { flex: 1; min-width: 140px; }
.opt {
  position: relative;
  display: flex;
  flex-direction: column;
  padding: 10px 14px;
  border-radius: var(--radius-sm);
  cursor: pointer;
  background: var(--surface-2);
  border: 1px solid var(--border);
  transition: all .15s ease;
  user-select: none;
}
.opt:hover { border-color: var(--teal-mid); }
.opt input[type=radio], .opt input[type=checkbox] { position: absolute; opacity: 0; pointer-events: none; }
.opt:has(input:checked) {
  background: var(--teal-light);
  border-color: var(--teal);
  box-shadow: 0 0 0 1px var(--teal);
}
.opt.mk-hit { box-shadow: 0 0 0 3px rgba(45,212,191,.45) }
.opt-lbl { font-weight: 600; font-size: 14px; color: var(--ink); line-height: 1.3; }
.opt-desc { font-size: 12px; color: var(--ink-2); margin-top: 4px; line-height: 1.45; }
.opt-lbl.danger { color: var(--rose); }
.opt-marks {
  display: none;
  margin-top: 6px;
  padding-top: 6px;
  border-top: 1px dashed var(--border);
  font-size: 11.5px;
  line-height: 1.5;
  color: var(--ink-2);
}
.opt-marks.on { display: block }
.opt-marks .q { display: block; margin-top: 2px }
.opt-marks .q::before { content: '“'; color: var(--ink-3) }
.opt-marks .q::after  { content: '”'; color: var(--ink-3) }

/* Колонки проблем */
.issue-groups {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 18px;
}
@media(max-width: 680px) { .issue-groups { grid-template-columns: 1fr } }
.group-title {
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: .07em;
  color: var(--ink-2);
  padding: 5px 10px;
  margin-bottom: 8px;
  border-left: 3px solid var(--teal-mid);
  background: var(--teal-light);
  border-radius: 0 var(--radius-xs) var(--radius-xs) 0;
}
.sub-title {
  font-size: 12px;
  font-weight: 700;
  color: var(--ink);
  margin: 16px 0 6px;
}
.sub-title:first-child { margin-top: 0; }

textarea {
  width: 100%;
  min-height: 72px;
  resize: vertical;
  border: 1.5px solid var(--border);
  border-radius: var(--radius-sm);
  padding: 10px 13px;
  font-size: 14px;
  font-family: inherit;
  line-height: 1.6;
  color: var(--ink);
  background: var(--surface-2);
  transition: border-color .15s, box-shadow .15s;
}
textarea:focus { outline: none; border-color: var(--teal); background: #fff; box-shadow: 0 0 0 3px rgba(13,148,136,.1); }

.comment-block {
  margin-top: 24px;
  padding-top: 16px;
  border-top: 1px solid var(--border-light);
}
.required-star {
  color: var(--rose);
  font-weight: bold;
}

/* JSON */
.json-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  box-shadow: var(--shadow);
  overflow: hidden;
  margin-bottom: 20px;
}
.json-head {
  background: #1c1917;
  color: #e7e5e4;
  padding: 10px 18px;
  font-size: 12px;
  font-weight: 700;
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.copy-btn {
  background: var(--teal);
  color: #fff;
  border: none;
  border-radius: var(--radius-xs);
  padding: 5px 16px;
  font-size: 12px;
  font-weight: 700;
  cursor: pointer;
  transition: background .12s, transform .08s;
}
.copy-btn:hover { background: #0f766e }
.copy-btn:active { transform: scale(.97) }
.copy-btn.ok { background: #16a34a }
pre#json-out {
  padding: 14px 18px;
  font-size: 12px;
  line-height: 1.65;
  white-space: pre-wrap;
  word-break: break-word;
  background: #fafaf9;
  max-height: 300px;
  overflow-y: auto;
  border-top: 1px solid var(--border-light);
}
.val-msg {
  font-size: 12px;
  font-weight: 600;
  color: var(--rose);
  padding: 7px 18px 8px;
  background: var(--rose-light);
  border-top: 1px solid var(--rose-border);
  display: none;
}
.val-msg.on { display: block }
</style>
</head>
<body class="mk-open">
<aside class="mk-panel" id="mk-panel">
  <div class="mk-head" id="mk-head">
    <span>🖍</span><span class="mk-head-title">Маркеры</span>
    <span class="mk-total zero" id="mk-total">0</span>
    <span class="mk-caret" id="mk-caret">▸</span>
  </div>
  <div class="mk-hint" id="mk-hint">Выдели фрагмент в диалоге и нажми метку — галочка ниже проставится сама</div>
  <div class="mk-scroll" id="mk-scroll"></div>
  <div class="mk-foot"><button type="button" id="mk-clear">Снять все метки</button></div>
</aside>
<div class="page">
  <div class="page-eyebrow">Разметка диалога</div>
  <div class="meta-strip" id="meta-strip"><div class="chip hi"><b>INSTRUCT_ID_PLACEHOLDER</b></div></div>
  <div class="dialog-card">
    <div class="dialog-card-head"><span>💬</span> Диалог</div>
    <div class="dialog-turns" id="dialog-turns"></div>
  </div>

  <div class="divider">Разметка</div>

  <div class="form-card">
    <div class="form-head"><span class="step-badge">1</span> Скип — нужно ли оценивать?</div>
    <div class="form-body">
      <div class="opts">
        <label class="opt"><input type="radio" name="skip" value="none" checked><div class="opt-lbl">Нет скипа — оцениваю дальше</div></label>
        <label class="opt"><input type="radio" name="skip" value="roleplay"><div class="opt-lbl">Ролевой / игровой сценарий</div><div class="opt-desc">Пользователь явно в роли, художественный или игровой контекст</div></label>
        <label class="opt"><input type="radio" name="skip" value="nonsense"><div class="opt-lbl">Бессмыслица / технический артефакт</div><div class="opt-desc">Бред, поломанный ввод, невозможно осмысленно оценить</div></label>
      </div>
    </div>
  </div>

  <div id="eval-section">
    <div class="form-card" data-section="tov" data-section-title="ToV">
      <div class="form-head">
        <span class="step-badge">2</span> Tone of Voice (ToV)
        <span class="form-sub">мультивыбор</span>
      </div>
      <div class="form-body">
        <div class="issue-groups">
          <div>
            <div class="group-title">Ясность</div>
            <div class="opts">
              <label class="opt"><input type="checkbox" name="tov_issue" value="clarity_level"><div class="opt-lbl">Не соответствует уровню пользователя</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="clarity_lexicon"><div class="opt-lbl">Есть сложная лексика</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="clarity_heavy"><div class="opt-lbl">Тяжелые конструкции</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="clarity_long"><div class="opt-lbl">Затянутость</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="clarity_brackets"><div class="opt-lbl">Много скобок</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="clarity_bad_intro"><div class="opt-lbl">Плохое вступление</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="clarity_artifacts"><div class="opt-lbl">Выбросы / технические артефакты</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="clarity_abstract_headers"><div class="opt-lbl">Абстрактные заголовки</div></label>
            </div>

            <div class="group-title" style="margin-top: 18px;">Качество языка</div>
            <div class="opts">
              <label class="opt"><input type="checkbox" name="tov_issue" value="lang_templates"><div class="opt-lbl">Шаблоны</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="lang_errors"><div class="opt-lbl">Речевые ошибки</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="lang_bureaucratese"><div class="opt-lbl">Канцелярит</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="lang_swap"><div class="opt-lbl">Свап ты/вы или рода</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="lang_emojis"><div class="opt-lbl">Лишние или шаблонные смайлики</div></label>
            </div>
          </div>

          <div>
            <div class="group-title">Живость</div>
            <div class="opts">
              <label class="opt"><input type="checkbox" name="tov_issue" value="alive_oversubject"><div class="opt-lbl">Перебарщивает с субъектностью</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="alive_decorate"><div class="opt-lbl">Можно было украсить текст</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="alive_no_voice"><div class="opt-lbl">Не хватает голоса модели</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="alive_dry"><div class="opt-lbl">Недостаточная повествовательность / сухо написано</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="alive_overstory"><div class="opt-lbl">Перебор с повествовательностью / надо было четче</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="alive_lie"><div class="opt-lbl">Вранье про эмпирический опыт</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="alive_machine"><div class="opt-lbl">Машинно выглядит</div></label>
            </div>

            <div class="group-title" style="margin-top: 18px;">Коннект</div>
            <div class="opts">
              <label class="opt"><input type="checkbox" name="tov_issue" value="connect_fam"><div class="opt-lbl">Панибратство / модель сильно ощущает себя сильно ближе к пользователю чем ей позволено</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="connect_stuffy"><div class="opt-lbl">Сильно душно для диалога</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="connect_loose"><div class="opt-lbl">Сильно развязно для диалога</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="connect_slang"><div class="opt-lbl">Можно было использовать сленг</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="connect_bad_empathy"><div class="opt-lbl">Неуместная эмпатия</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="connect_wrong_emotion"><div class="opt-lbl">Неправильно считываемые эмоции</div></label>
              <label class="opt"><input type="checkbox" name="tov_issue" value="connect_preach"><div class="opt-lbl">Модель назидает, ставит себя выше пользователя</div></label>
            </div>
          </div>
        </div>

        <div class="comment-block">
          <div class="sub-title" style="margin-top: 0; margin-bottom: 8px;">Комментарий по ToV (обязательно) <span class="required-star">*</span></div>
          <textarea id="tov_comment" placeholder="Детали, примеры — дополнить всё, что не легло в галочки"></textarea>
        </div>
      </div>
    </div>

    <div class="form-card" data-section="pa" data-section-title="Проактивность">
      <div class="form-head">
        <span class="step-badge">3</span> Проактивность (ПА)
      </div>
      <div class="form-body">

        <div class="sub-title">Наличие проактивности:</div>
        <div class="opts-row">
          <label class="opt"><input type="radio" name="pa_presence" value="yes"><div class="opt-lbl">Присутствует</div></label>
          <label class="opt"><input type="radio" name="pa_presence" value="some"><div class="opt-lbl">Присутствует (не в каждом ответе)</div></label>
          <label class="opt"><input type="radio" name="pa_presence" value="no"><div class="opt-lbl">Нет проактивности</div></label>
        </div>

        <div class="sub-title">Нужна ли проактивность в диалоге?</div>
        <div class="opts-row">
          <label class="opt"><input type="radio" name="pa_need" value="yes"><div class="opt-lbl">Точно да</div></label>
          <label class="opt"><input type="radio" name="pa_need" value="maybe"><div class="opt-lbl">Скорее да</div></label>
          <label class="opt"><input type="radio" name="pa_need" value="no"><div class="opt-lbl">Скорее нет / нет</div></label>
        </div>

        <div class="sub-title" style="margin-top: 24px;">Проблемы с ПА (мультивыбор, если есть хоть одна проблема):</div>
        <div class="issue-groups">
          <div>
            <div class="group-title">Критичные</div>
            <div class="opts">
              <label class="opt"><input type="checkbox" name="pa_issue" value="crit_context"><div class="opt-lbl danger">Искажает / игнорирует контекст</div></label>
              <label class="opt"><input type="checkbox" name="pa_issue" value="crit_impossible"><div class="opt-lbl danger">Невыполнимое</div><div class="opt-desc">Обещает то, чего модель не умеет</div></label>
              <label class="opt"><input type="checkbox" name="pa_issue" value="crit_rude"><div class="opt-lbl danger">Грубая / опасная</div></label>
            </div>

            <div class="group-title" style="margin-top: 18px;">Контекст и структура</div>
            <div class="opts">
              <label class="opt"><input type="checkbox" name="pa_issue" value="ctx_weak"><div class="opt-lbl">Слабая потеря контекста</div><div class="opt-desc">Предложение натянутое, догадаться можно с натяжкой</div></label>
              <label class="opt"><input type="checkbox" name="pa_issue" value="ctx_overload"><div class="opt-lbl">Перегружена</div><div class="opt-desc">Много вопросов/вариантов за раз или разнонаправленные</div></label>
              <label class="opt"><input type="checkbox" name="pa_issue" value="ctx_monotone"><div class="opt-lbl">Однообразные ПА</div><div class="opt-desc">Не хватает разнообразия конструкций по диалогу</div></label>
            </div>
          </div>

          <div>
            <div class="group-title">Польза и импульс</div>
            <div class="opts">
              <label class="opt"><input type="checkbox" name="pa_issue" value="use_intrusive"><div class="opt-lbl">Неуместная / навязчивая</div><div class="opt-desc">ПА не нужна или лезет в смежную тему</div></label>
              <label class="opt"><input type="checkbox" name="pa_issue" value="use_level"><div class="opt-lbl">Не по уровню / интенту</div><div class="opt-desc">Не учитывает, что юзер уже знает, или не про реальную задачу</div></label>
              <label class="opt"><input type="checkbox" name="pa_issue" value="use_abstract"><div class="opt-lbl">Абстрактная / шаблонная</div><div class="opt-desc">Нет направления, пустая детализация</div></label>
              <label class="opt"><input type="checkbox" name="pa_issue" value="use_boring"><div class="opt-lbl">Неинтересная / слабый импульс</div><div class="opt-desc">На такую ПА не хочется отвечать, банальная</div></label>
            </div>

            <div class="group-title" style="margin-top: 18px;">Форма и язык</div>
            <div class="opts">
              <label class="opt"><input type="checkbox" name="pa_issue" value="form_machine"><div class="opt-lbl">Машинная / роботная</div><div class="opt-desc">Синтаксически шаблонные фразы</div></label>
              <label class="opt"><input type="checkbox" name="pa_issue" value="form_tactless"><div class="opt-lbl">Бестактная / перебор</div><div class="opt-desc">Панибратство, кринж-юмор, неуместные эмодзи</div></label>
              <label class="opt"><input type="checkbox" name="pa_issue" value="form_errors"><div class="opt-lbl">Ошибки языка / неграмотность</div><div class="opt-desc">Орфография, пунктуация, тавтология, кальки</div></label>
            </div>
          </div>
        </div>

        <div class="comment-block">
          <div class="sub-title" style="margin-top: 0; margin-bottom: 8px;">Комментарий по Проактивности (необязательно)</div>
          <textarea id="pa_comment" placeholder="Уточнения, если нужно..."></textarea>
        </div>
      </div>
    </div>
  </div>

  <div class="json-card">
    <div class="json-head">
      <span>Результат разметки (JSON)</span>
      <button class="copy-btn" id="copy-btn" onclick="copyJson()">📋 Скопировать</button>
    </div>
    <div class="val-msg" id="val-msg"></div>
    <pre id="json-out"></pre>
  </div>
</div>
"""

_HTML_SCRIPT = """
<script>
const DATA = DATA_JSON_PLACEHOLDER;

function mdToHtml(md) {
  if (!md) return '';
  const lines = md.split('\\n');
  const out   = [];
  let inUl    = false;

  function closeUl() { if (inUl) { out.push('</ul>'); inUl = false; } }
  function esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
  function inlineFmt(s) {
    s = s.replace(/\\[```([^`]+)```\\]\\(([^)]+)\\)/g, function(_, t, u) { return '<a href="' + u + '" class="src-link" target="_blank">' + esc(t) + '</a>'; });
    s = s.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, function(_, t, u) { return '<a href="' + u + '" target="_blank">' + esc(t) + '</a>'; });
    s = s.replace(/\\*\\*([^*]+)\\*\\*/g, '<strong>$1</strong>');
    s = s.replace(/(?<!\\*)\\*(?!\\*)([^*]+)\\*(?!\\*)/g, '<em>$1</em>');
    return s;
  }

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/\\s+$/, '');
    if (/^---+$/.test(line.trim())) { closeUl(); out.push('<hr>'); continue; }
    var hm = line.match(/^(#{2,3})\\s+(.+)/);
    if (hm) {
      closeUl();
      var tag = hm[1].length === 2 ? 'h2' : 'h3';
      out.push('<' + tag + '>' + inlineFmt(hm[2]) + '</' + tag + '>');
      continue;
    }
    var lm = line.match(/^[\\*\\-]\\s+(.+)/);
    if (lm) {
      if (!inUl) { out.push('<ul>'); inUl = true; }
      out.push('<li>' + inlineFmt(lm[1]) + '</li>');
      continue;
    }
    if (line.trim() === '') { closeUl(); continue; }
    closeUl();
    out.push('<p>' + inlineFmt(line) + '</p>');
  }
  closeUl();
  return out.join('\\n');
}

(function() {
  var ui = DATA.user_info || {};
  var strip = document.getElementById('meta-strip');
  var genderLabel = ui.gender ? (ui.gender === 'male' ? '\\ud83d\\udc68 \\u041c\\u0443\\u0436\\u0441\\u043a\\u043e\\u0439' : ui.gender === 'female' ? '\\ud83d\\udc69 \\u0416\\u0435\\u043d\\u0441\\u043a\\u0438\\u0439' : ui.gender) : null;
  var chips = [
    { val: genderLabel, fallback: '\\ud83d\\udc64 \\u041f\\u043e\\u043b \\u043d\\u0435\\u0438\\u0437\\u0432\\u0435\\u0441\\u0442\\u0435\\u043d' },
    { val: ui.age ? '\\ud83c\\udf82 ' + ui.age : null, fallback: '\\ud83c\\udf82 \\u0412\\u043e\\u0437\\u0440\\u0430\\u0441\\u0442 \\u043d\\u0435\\u0438\\u0437\\u0432\\u0435\\u0441\\u0442\\u0435\\u043d' },
    { val: (ui.has_memory === 1 || ui.has_memory === true) ? '\\ud83e\\udde0 \\u041f\\u0430\\u043c\\u044f\\u0442\\u044c \\u0435\\u0441\\u0442\\u044c' : '\\ud83e\\udde0 \\u041f\\u0430\\u043c\\u044f\\u0442\\u0438 \\u043d\\u0435\\u0442', fallback: null },
    { val: ui.platform ? '\\ud83d\\udda5 ' + ui.platform : null, fallback: '\\ud83d\\udda5 \\u041f\\u043b\\u0430\\u0442\\u0444\\u043e\\u0440\\u043c\\u0430 \\u043d\\u0435\\u0438\\u0437\\u0432\\u0435\\u0441\\u0442\\u043d\\u0430' },
    { val: ui.input_type ? '\\u2328 ' + ui.input_type : null, fallback: '\\u2328 \\u0422\\u0438\\u043f \\u0432\\u0432\\u043e\\u0434\\u0430 \\u043d\\u0435\\u0438\\u0437\\u0432\\u0435\\u0441\\u0442\\u0435\\u043d' },
  ];
  chips.forEach(function(c) {
    var text = c.val || c.fallback;
    var div = document.createElement('div');
    div.className = 'chip' + ((!c.val && c.fallback) ? ' unknown' : '');
    div.textContent = text;
    strip.appendChild(div);
  });
})();

(function() {
  var wrap = document.getElementById('dialog-turns');
  var turns = DATA.dialog || [];
  if (!turns.length) { wrap.innerHTML = '<div class="no-turns">\\u0414\\u0438\\u0430\\u043b\\u043e\\u0433 \\u043f\\u0443\\u0441\\u0442</div>'; return; }
  wrap.innerHTML = turns.map(function(t, i) {
    var r = t.role === 'user' ? 'user' : 'assistant';
    var who = r === 'user' ? '\\u041f\\u043e\\u043b\\u044c\\u0437\\u043e\\u0432\\u0430\\u0442\\u0435\\u043b\\u044c' : '\\u0410\\u043b\\u0438\\u0441\\u0430';
    var content = r === 'assistant' ? mdToHtml(t.content || '') : (t.content || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    return '<div class="turn ' + r + '" data-idx="' + i + '" data-role="' + r + '"><div class="turn-who ' + r + '">' + who + '</div><div class="bubble">' + content + '</div></div>';
  }).join('');
})();

/* ---------------------------------------------------------------
   Плашка-маркер: выделяешь кусок диалога → жмешь метку в панели →
   фрагмент подсвечивается, галочка снизу прожимается сама,
   JSON пересобирается вместе со списком меток.
   --------------------------------------------------------------- */

var MARKERS = [];   // {id, code, label, section, role, turn, quote}
var MK_DEFS = {};   // code -> {label, section, input}
var MK_BTNS = {};   // code -> кнопка в панели
var MK_SEQ  = 0;
var mkRange = null; // последнее валидное выделение внутри диалога

function mkShort(s, n) { return s.length > n ? s.slice(0, n - 1).trim() + '\\u2026' : s; }

function mkTurnOf(node) {
  var el = node && node.nodeType === 3 ? node.parentNode : node;
  return el && el.closest ? el.closest('#dialog-turns .turn') : null;
}

function mkRangeOk(r) {
  if (!r || r.collapsed) return false;
  var a = mkTurnOf(r.startContainer), b = mkTurnOf(r.endContainer);
  return !!a && a === b && !r.toString().trim() === false;
}

function mkCount(code) {
  return MARKERS.filter(function(m) { return m.code === code; }).length;
}

/* Панель собирается из самой формы — списки не дублируются */
(function buildPanel() {
  var host = document.getElementById('mk-scroll');
  document.querySelectorAll('#eval-section .form-card').forEach(function(card) {
    var section = card.getAttribute('data-section');
    var groups  = card.querySelectorAll('.group-title');
    if (!section || !groups.length) return;

    var secEl = document.createElement('div');
    secEl.className = 'mk-sec';
    secEl.textContent = card.getAttribute('data-section-title') || section;
    host.appendChild(secEl);

    groups.forEach(function(gt) {
      var opts = gt.nextElementSibling;
      if (!opts || !opts.classList.contains('opts')) return;
      var boxes = opts.querySelectorAll('input[type=checkbox]');
      if (!boxes.length) return;

      var grpEl = document.createElement('div');
      grpEl.className = 'mk-grp';
      grpEl.textContent = gt.textContent.trim();
      host.appendChild(grpEl);

      boxes.forEach(function(inp) {
        var lblEl = inp.parentNode.querySelector('.opt-lbl');
        var label = lblEl ? lblEl.textContent.trim() : inp.value;
        MK_DEFS[inp.value] = { label: label, section: section, input: inp };

        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'mk-btn';
        btn.title = label;
        var t = document.createElement('span');
        t.className = 't';
        t.textContent = mkShort(label, 44);
        var n = document.createElement('span');
        n.className = 'n';
        n.style.display = 'none';
        n.textContent = '0';
        btn.appendChild(t);
        btn.appendChild(n);
        btn.addEventListener('click', function() { mkClick(inp.value); });
        host.appendChild(btn);
        MK_BTNS[inp.value] = btn;
      });
    });
  });
})();

function mkClick(code) {
  var def = MK_DEFS[code];
  if (!def) return;

  if (mkRangeOk(mkRange)) {
    mkApply(mkRange, code);
    mkRange = null;
    var sel = window.getSelection();
    if (sel) sel.removeAllRanges();
  } else if (def.input.checked) {
    // без выделения: есть метки — прыгаем к ним, нет — просто снимаем галочку
    if (mkCount(code)) { mkScrollTo(code); return; }
    def.input.checked = false;
  } else {
    def.input.checked = true;
    mkBlink(def.input.parentNode);
  }
  mkSync();
  updateJson();
}

function mkApply(range, code) {
  var def  = MK_DEFS[code];
  var turn = mkTurnOf(range.startContainer);
  var m, frag;
  try {
    frag = range.extractContents();
  } catch (e) {
    return;
  }
  m = document.createElement('mark');
  m.className = 'mk';
  m.dataset.code = code;
  m.dataset.sec  = def.section;
  m.dataset.id   = String(++MK_SEQ);
  m.appendChild(frag);

  var quote = m.textContent.trim();

  var tag = document.createElement('span');
  tag.className = 'mk-tag';
  tag.textContent = mkShort(def.label, 30);
  m.appendChild(tag);
  m.title = def.label + ' \\u2014 \\u043a\\u043b\\u0438\\u043a, \\u0447\\u0442\\u043e\\u0431\\u044b \\u0441\\u043d\\u044f\\u0442\\u044c';
  m.addEventListener('click', function(ev) { ev.preventDefault(); ev.stopPropagation(); mkRemove(m); });

  range.insertNode(m);

  MARKERS.push({
    id:      m.dataset.id,
    code:    code,
    label:   def.label,
    section: def.section,
    role:    turn ? turn.getAttribute('data-role') : null,
    turn:    turn ? Number(turn.getAttribute('data-idx')) : null,
    quote:   quote
  });

  def.input.checked = true;
  mkBlink(def.input.parentNode);
}

function mkRemove(m) {
  var id = m.dataset.id, code = m.dataset.code, parent = m.parentNode;
  var tag = m.querySelector('.mk-tag');
  if (tag) m.removeChild(tag);
  while (m.firstChild) parent.insertBefore(m.firstChild, m);
  parent.removeChild(m);
  parent.normalize();

  MARKERS = MARKERS.filter(function(x) { return x.id !== id; });
  if (!mkCount(code) && MK_DEFS[code]) MK_DEFS[code].input.checked = false;
  mkSync();
  updateJson();
}

function mkRemoveAll(code) {
  Array.prototype.slice.call(document.querySelectorAll('mark.mk')).forEach(function(m) {
    if (!code || m.dataset.code === code) mkRemove(m);
  });
}

function mkScrollTo(code) {
  var list = document.querySelectorAll('mark.mk[data-code="' + code + '"]');
  if (!list.length) return;
  var m = list[0];
  m.scrollIntoView({ behavior: 'smooth', block: 'center' });
  m.classList.add('flash');
  setTimeout(function() { m.classList.remove('flash'); }, 900);
}

function mkBlink(optEl) {
  if (!optEl || !optEl.classList) return;
  optEl.classList.add('mk-hit');
  setTimeout(function() { optEl.classList.remove('mk-hit'); }, 700);
}

/* Кнопки панели, счетчики и цитаты под галочками */
function mkSync() {
  Object.keys(MK_DEFS).forEach(function(code) {
    var def = MK_DEFS[code], btn = MK_BTNS[code], n = mkCount(code);
    if (btn) {
      btn.classList.toggle('on', def.input.checked);
      var badge = btn.querySelector('.n');
      badge.textContent = String(n);
      badge.style.display = n ? '' : 'none';
    }
    var opt = def.input.parentNode;
    var box = opt.querySelector('.opt-marks');
    if (!box) {
      box = document.createElement('div');
      box.className = 'opt-marks';
      opt.appendChild(box);
    }
    var quotes = MARKERS.filter(function(m) { return m.code === code; });
    box.classList.toggle('on', quotes.length > 0);
    box.textContent = '';
    quotes.forEach(function(m) {
      var q = document.createElement('span');
      q.className = 'q';
      q.textContent = mkShort(m.quote, 120);
      box.appendChild(q);
    });
  });

  var total = document.getElementById('mk-total');
  total.textContent = String(MARKERS.length);
  total.classList.toggle('zero', MARKERS.length === 0);
}

/* Ловим выделение внутри диалога и держим его — клик по панели его сбрасывает */
function mkCatchSelection() {
  var sel = window.getSelection();
  var hint = document.getElementById('mk-hint');
  if (sel && sel.rangeCount) {
    var r = sel.getRangeAt(0);
    if (mkRangeOk(r)) {
      mkRange = r.cloneRange();
      hint.classList.add('armed');
      hint.textContent = '\\u0412\\u044b\\u0434\\u0435\\u043b\\u0435\\u043d\\u043e: \\u00ab' + mkShort(r.toString().trim(), 60) + '\\u00bb \\u2014 \\u0432\\u044b\\u0431\\u0435\\u0440\\u0438 \\u043c\\u0435\\u0442\\u043a\\u0443';
      return;
    }
  }
  mkRange = null;
  hint.classList.remove('armed');
  hint.textContent = '\\u0412\\u044b\\u0434\\u0435\\u043b\\u0438 \\u0444\\u0440\\u0430\\u0433\\u043c\\u0435\\u043d\\u0442 \\u0432 \\u0434\\u0438\\u0430\\u043b\\u043e\\u0433\\u0435 \\u0438 \\u043d\\u0430\\u0436\\u043c\\u0438 \\u043c\\u0435\\u0442\\u043a\\u0443 \\u2014 \\u0433\\u0430\\u043b\\u043e\\u0447\\u043a\\u0430 \\u043d\\u0438\\u0436\\u0435 \\u043f\\u0440\\u043e\\u0441\\u0442\\u0430\\u0432\\u0438\\u0442\\u0441\\u044f \\u0441\\u0430\\u043c\\u0430';
}

document.getElementById('dialog-turns').addEventListener('mouseup', function() {
  setTimeout(mkCatchSelection, 0);
});
document.addEventListener('keyup', function(e) {
  if (e.shiftKey || e.key === 'Shift') setTimeout(mkCatchSelection, 0);
});

/* Сворачивание плашки */
(function() {
  var panel = document.getElementById('mk-panel');
  document.getElementById('mk-head').addEventListener('click', function() {
    var collapsed = panel.classList.toggle('collapsed');
    document.body.classList.toggle('mk-open', !collapsed);
    document.getElementById('mk-caret').textContent = collapsed ? '\\u25c2' : '\\u25b8';
  });
  if (window.innerWidth < 860) document.getElementById('mk-head').click();
})();

document.getElementById('mk-clear').addEventListener('click', function() {
  mkRemoveAll(null);
});

/* Снятая вручную галочка убирает свои метки из диалога */
document.querySelectorAll('input[name=tov_issue], input[name=pa_issue]').forEach(function(inp) {
  inp.addEventListener('change', function() {
    if (!inp.checked && mkCount(inp.value)) mkRemoveAll(inp.value);
    mkSync();
  });
});

document.querySelectorAll('input[name=skip]').forEach(function(r) {
  r.addEventListener('change', function() {
    var off = r.value !== 'none';
    document.getElementById('eval-section').style.display = off ? 'none' : '';
    document.getElementById('mk-panel').style.display = off ? 'none' : '';
    updateJson();
  });
});

function getFormData() {
  var sv = document.querySelector('input[name=skip]:checked').value;
  var isSkip = sv !== 'none';
  var paPres = document.querySelector('input[name=pa_presence]:checked');
  var paNeed = document.querySelector('input[name=pa_need]:checked');

  return {
    instruct_id: DATA.instruct_id,
    skip:        isSkip,
    skip_reason: isSkip ? sv : null,
    tov_issues:  isSkip ? [] : Array.from(document.querySelectorAll('input[name=tov_issue]:checked')).map(function(c) { return c.value; }),
    tov_comment: isSkip ? "" : document.getElementById('tov_comment').value.trim(),
    pa_presence: isSkip ? null : (paPres ? paPres.value : null),
    pa_need:     isSkip ? null : (paNeed ? paNeed.value : null),
    pa_issues:   isSkip ? [] : Array.from(document.querySelectorAll('input[name=pa_issue]:checked')).map(function(c) { return c.value; }),
    pa_comment:  isSkip ? "" : document.getElementById('pa_comment').value.trim(),
    markers:     isSkip ? [] : MARKERS.map(function(m) {
      return { code: m.code, label: m.label, section: m.section, role: m.role, turn: m.turn, quote: m.quote };
    }),
  };
}

function validate(o) {
  if (!o.skip) {
    if (!o.tov_comment) return 'Комментарий по ToV обязателен (Шаг 2)';
    if (!o.pa_presence) return 'Укажите наличие проактивности (Шаг 3)';
    if (!o.pa_need) return 'Укажите, нужна ли проактивность (Шаг 3)';
  }
  return null;
}

function updateJson() {
  var o = getFormData();
  document.getElementById('json-out').textContent = JSON.stringify(o, null, 2);
  var e = validate(o), m = document.getElementById('val-msg');
  if (e) { m.textContent = '\\u26a0 ' + e; m.classList.add('on'); }
  else   { m.textContent = '';             m.classList.remove('on'); }
}

document.querySelectorAll('input[type=checkbox], input[type=radio]').forEach(function(c) {
  c.addEventListener('change', updateJson);
});
document.getElementById('tov_comment').addEventListener('input', updateJson);
document.getElementById('pa_comment').addEventListener('input', updateJson);
mkSync();
updateJson();

function copyJson() {
  var o = getFormData(), e = validate(o);
  if (e) { var m = document.getElementById('val-msg'); m.textContent = '\\u26a0 ' + e; m.classList.add('on'); return; }
  navigator.clipboard.writeText(JSON.stringify(o)).then(function() {
    var b = document.getElementById('copy-btn');
    b.textContent = '\\u2705 \\u0421\\u043a\\u043e\\u043f\\u0438\\u0440\\u043e\\u0432\\u0430\\u043d\\u043e';
    b.classList.add('ok');
    setTimeout(function() { b.textContent = '\\ud83d\\udccb \\u0421\\u043a\\u043e\\u043f\\u0438\\u0440\\u043e\\u0432\\u0430\\u0442\\u044c'; b.classList.remove('ok'); }, 2000);
  });
}
</script>
"""


def build_html(row):
    # Забираем обе колонки из строки!
    bt_info = row.get("bt_info")
    full_dialog = row.get("full_dialog")

    # Склеиваем диалог новой функцией
    dialog = get_combined_dialog(bt_info, full_dialog)

    instruct_id = html_lib.escape(str(row.get("instruct_id", "")))

    user_info = {
        "gender":     row.get("gender"),
        "age":        row.get("age"),
        "has_memory": row.get("has_memory"),
        "platform":   row.get("platform"),
        "input_type": row.get("input_type"),
    }

    data = {
        "instruct_id": row.get("instruct_id", ""),
        "dialog":      dialog,
        "user_info":   user_info,
    }

    data_json = json.dumps(data, ensure_ascii=False)

    html = _HTML_HEAD.replace("INSTRUCT_ID_PLACEHOLDER", instruct_id, 2)
    html += _HTML_SCRIPT.replace("DATA_JSON_PLACEHOLDER", data_json, 1)

    return html

def main(in1, in2, in3, mr_tables, **kwargs):
    results = []
    for row in (in1 or []):
        rendered = build_html(row)
        results.append({
            "instruct_id": row.get("instruct_id", ""),
            "html":        rendered,
        })
    return results, []
