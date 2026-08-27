DECLARE $input1 AS String;
DECLARE $output1 AS String;

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';
PRAGMA yt.MaxRowWeight = "128M";

-- Вход — таблица прогона прокачки. Используем из неё только две колонки:
--   input_final_messages (Yson) — контекст запроса: system-блоки промпта,
--                                 блоки памяти (у них есть extra_info.memory_type)
--                                 и сами реплики диалога;
--   answers              (Yson) — список ответов, у каждого свой final_messages.
-- Остальные колонки (instruct_id, request_id, session_id, experiment_name,
-- input_meta, output_meta, input_render_data, final_messages) просто проносим
-- через t.* — их не трогаем.

$template = cast(FileContent("prompt_template.txt") as Utf8);

$script = @@#py
import json
from yql.typing import *
from jinja2 import Template


ROLE_RU = {'user': 'Пользователь', 'assistant': 'Алиса'}


def _s(v):
    if v is None:
        return ''
    if isinstance(v, (bytes, bytearray)):
        return bytes(v).decode('utf-8', errors='replace')
    return str(v)


def _load(node):
    """Yson приходит сюда уже как JSON-строка (Yson::SerializeJson в SQL).
    Байты и готовые структуры тоже переживаем — на случай другой проводки."""
    if node is None:
        return None
    if isinstance(node, (bytes, bytearray, str)):
        text = _s(node).strip()
        if not text:
            return None
        try:
            return json.loads(text)
        except Exception:
            return None
    return node


def _get(node, key):
    """Ключи после json.loads — строки, после cyson.loads были бы байтами.
    Проверяем оба варианта, иначе extra_info молча теряется."""
    if not isinstance(node, dict):
        return None
    if key in node:
        return node[key]
    return node.get(key.encode('utf-8'))


def _messages(node):
    """Список сообщений: сам список, либо обёртка вида {'messages': [...]}."""
    if isinstance(node, list):
        return node
    for key in ('final_messages', 'messages'):
        found = _get(node, key)
        if isinstance(found, list):
            return found
    return []


def _text(content):
    """content бывает строкой или списком частей (текст + картинки)."""
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict):
                if _s(_get(item, 'type')) == 'image_url':
                    parts.append('[картинка]')
                else:
                    parts.append(_s(_get(item, 'text')))
            else:
                parts.append(_s(item))
        return ' '.join(p for p in parts if p).strip()
    return _s(content).strip()


def _memory_type(m):
    return _s(_get(_get(m, 'extra_info'), 'memory_type'))


def _answer_text(answers):
    """Текст ответа прокачки: последний assistant у первого ответа, где он есть."""
    if isinstance(answers, dict):
        answers = [answers]
    for a in (answers or []):
        for m in reversed(_messages(a)):
            if _s(_get(m, 'role')) == 'assistant':
                text = _text(_get(m, 'content'))
                if text:
                    return text
    return ''


def _render_memory(fm):
    out = []
    for m in _messages(fm):
        if not _memory_type(m):
            continue
        content = _text(_get(m, 'content'))
        if content:
            out.append(content)
    return '\n\n'.join(out)


def _render_dialog(fm):
    """Только реплики пользователя и Алисы. system-блоки (промпт, память) пропускаем."""
    out = []
    for m in _messages(fm):
        role = _s(_get(m, 'role'))
        if role not in ROLE_RU:
            continue
        content = _text(_get(m, 'content'))
        if not content:
            continue
        out.append('%s: %s' % (ROLE_RU[role], content))
    return '\n\n'.join(out)


def build_infer_dialog(
    template: Optional[Utf8],
    input_fm: Optional[Utf8],
    answers: Optional[Utf8],
) -> Optional[Utf8]:
    ctx = _load(input_fm) or []
    rendered = Template(_s(template)).render(
        memory=_render_memory(ctx) or '(память пуста)',
        dialog=_render_dialog(ctx),
        answer=_answer_text(_load(answers)),
    )
    return json.dumps([{'role': 'user', 'content': rendered}], ensure_ascii=False)


def answer_text(answers: Optional[Utf8]) -> Optional[Utf8]:
    return _answer_text(_load(answers))


def memory_text(input_fm: Optional[Utf8]) -> Optional[Utf8]:
    return _render_memory(_load(input_fm))


def dialog_text(input_fm: Optional[Utf8]) -> Optional[Utf8]:
    return _render_dialog(_load(input_fm))


def n_memory_blocks(input_fm: Optional[Utf8]) -> Int64:
    return sum(1 for m in _messages(_load(input_fm)) if _memory_type(m))
@@;

$build_infer_dialog = Python3::build_infer_dialog($script);
$answer_text        = Python3::answer_text($script);
$memory_text        = Python3::memory_text($script);
$dialog_text        = Python3::dialog_text($script);
$n_memory_blocks    = Python3::n_memory_blocks($script);

-- Yson отдаём в питон уже как JSON: cyson.loads вернул бы ключи байтами,
-- и extra_info.memory_type перестал бы находиться. Сериализуем один раз на строку.
$prepared = (
    SELECT
        t.*,
        Yson::SerializeJson(Yson::From(t.input_final_messages)) AS fm_json,
        Yson::SerializeJson(Yson::From(t.answers))              AS answers_json
    FROM $input1 AS t
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    -- новые колонки идут ДО p.*: WITHOUT обязан закрывать список
    $answer_text(p.answers_json)                AS answer_text,
    $memory_text(p.fm_json)                     AS memory_text,
    $dialog_text(p.fm_json)                     AS dialog_text,
    $n_memory_blocks(p.fm_json)                 AS n_memory_blocks,
    Yson::ParseJson(
        $build_infer_dialog($template, p.fm_json, p.answers_json)
    )                                           AS infer_dialog,
    p.*,
    WITHOUT IF EXISTS
        p.fm_json, p.answers_json,
        p.answer_text, p.memory_text, p.dialog_text, p.n_memory_blocks, p.infer_dialog
FROM $prepared AS p;
