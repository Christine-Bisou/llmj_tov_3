PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

-- Подмена маркера language_errors в готовой разметке.
--
-- $input1 — выход отдельного прохода по речевым ошибкам: for_join + dst,
--           где dst — JSON с model_1_markers / model_2_markers, внутри которых
--           у language_errors лежат is_present и explanation.
--           model_1 относится к ответу A, model_2 — к ответу B.
-- $input2 — разметка: for_join + колонки raw_tov_markup и agg_tov_markup.
--
-- На выходе — та же схема, что у $input2 (agg_tov_markup, answers,
-- input_final_messages, input_meta, input_render_data, raw_tov_markup),
-- но внутри raw_tov_markup и agg_tov_markup у каждого ответа
-- заменены флаг language_errors и его обоснование:
--   checkboxes_A/checkboxes_B -> tov_minus_language_errors
--   markers_A/markers_B       -> имя маркера в списке (или объект с is_present/explanation)
--   comment_A/comment_B       -> explanation
--   comments_A/comments_B     -> explanation в каждый элемент списка
-- Остальные поля разметки не трогаем.

DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

$script = @@#py
import json
import cyson

CHECKBOX_KEY = 'tov_minus_language_errors'
MARKER_NAME = 'language_errors'
NAME_KEYS = ('name', 'marker', 'id', 'key', 'code')


def _clean(s):
    if s is None:
        return None
    if isinstance(s, bytes):
        s = s.decode('utf-8', errors='ignore')
    else:
        s = str(s)
    s = s.strip()
    if s.startswith('```json'):
        s = s[7:]
    elif s.startswith('```'):
        s = s[3:]
    if s.endswith('```'):
        s = s[:-3]
    return s.strip()


def _text(v):
    if v is None:
        return ''
    if isinstance(v, bytes):
        return v.decode('utf-8', errors='ignore')
    if isinstance(v, bool):
        return ''
    return str(v)


# cyson отдаёт строки байтами, json — str. Ниже ключи сравниваются со str,
# поэтому нормализуем один раз на входе, а не в каждой проверке.
def _decode(node):
    if isinstance(node, bytes):
        return node.decode('utf-8', errors='ignore')
    if isinstance(node, dict):
        return dict((_decode(k), _decode(v)) for k, v in node.items())
    if isinstance(node, list):
        return [_decode(v) for v in node]
    return node


# Разметка может прийти и строкой с JSON, и нативным yson — принимаем оба.
def _load_any(s):
    if s is None:
        return None
    raw = s if isinstance(s, bytes) else str(s).encode('utf-8')
    try:
        return _decode(json.loads(_clean(raw), strict=False))
    except Exception:
        pass
    try:
        return _decode(cyson.loads(raw))
    except Exception:
        return None


# Терпим к тому, что модель могла вернуть строку вместо булева
# и что ключа может не быть вовсе.
def _as_bool(val):
    if isinstance(val, bool):
        return val
    if isinstance(val, str):
        return val.strip().lower() in ('true', 'yes', '1')
    return bool(val)


def _marker_node(data, markers_key):
    markers = data.get(markers_key) or {}
    if not isinstance(markers, dict):
        return {}
    node = markers.get(MARKER_NAME) or {}
    return node if isinstance(node, dict) else {}


# Возвращает {ok, p1, p2, why1, why2}. ok=false означает, что ответ не
# распарсился: без этого флага сломанный JSON молча проставил бы «ошибок нет»
# во всю разметку, не оставив следа.
#
# Докстринг — это сигнатура для YQL, и ничего кроме неё там быть не может:
# любой лишний текст падает как "Expected end of string" при выводе типа.
def parse_language_errors(s):
    """
    (String?) -> Yson?
    """
    empty = {'ok': False, 'p1': False, 'p2': False, 'why1': '', 'why2': ''}
    s = _clean(s)
    if not s:
        return cyson.dumps(empty)
    try:
        data = json.loads(s, strict=False)
        if not isinstance(data, dict):
            raise ValueError('not an object')
        n1 = _marker_node(data, 'model_1_markers')
        n2 = _marker_node(data, 'model_2_markers')
        return cyson.dumps({
            'ok': True,
            'p1': _as_bool(n1.get('is_present', False)),
            'p2': _as_bool(n2.get('is_present', False)),
            'why1': _text(n1.get('explanation')),
            'why2': _text(n2.get('explanation')),
        })
    except Exception:
        return cyson.dumps(empty)


def _patch_markers(value, flag, why):
    # список имён сработавших маркеров
    if isinstance(value, list) and all(isinstance(i, str) for i in value):
        out = [i for i in value if i != MARKER_NAME]
        if flag:
            out.append(MARKER_NAME)
        return out
    # список объектов вида {name, is_present, explanation}
    if isinstance(value, list):
        found = False
        for item in value:
            if isinstance(item, dict) and any(_text(item.get(k)) == MARKER_NAME for k in NAME_KEYS):
                item['is_present'] = flag
                item['explanation'] = why
                found = True
        if not found and flag:
            value.append({'name': MARKER_NAME, 'is_present': flag, 'explanation': why})
        return value
    # словарь маркеров {language_errors: {is_present, explanation}}
    if isinstance(value, dict):
        node = value.get(MARKER_NAME)
        if isinstance(node, dict):
            node['is_present'] = flag
            node['explanation'] = why
        else:
            value[MARKER_NAME] = {'is_present': flag, 'explanation': why}
        return value
    return value


# Идём по всей структуре и правим поля, у которых суффикс говорит о стороне
# (_A / _B). Так один обход покрывает и raw_tov_markup с его raw_outputs,
# и agg_tov_markup, и не зависит от уровня вложенности чекбоксов.
def _walk(node, flags, whys):
    if isinstance(node, list):
        for item in node:
            _walk(item, flags, whys)
        return
    if not isinstance(node, dict):
        return
    for key in list(node.keys()):
        value = node[key]
        side = key[-1] if len(key) > 2 and key[-2:] in ('_A', '_B') else None
        if side is None:
            _walk(value, flags, whys)
            continue
        base = key[:-2]
        flag, why = flags[side], whys[side]
        if base == 'checkboxes' and isinstance(value, dict):
            value[CHECKBOX_KEY] = flag
        elif base == 'markers':
            node[key] = _patch_markers(value, flag, why)
        elif base == 'comment':
            node[key] = why
        elif base == 'comments':
            node[key] = [why for _ in value] if isinstance(value, list) else why
        else:
            _walk(value, flags, whys)


# flag_a is NULL — судейского вердикта по строке нет (не сматчилось по ключу
# или ответ не распарсился): возвращаем разметку как есть, ничего не подменяя.
# Если не разобралась сама разметка — NULL: чинить её тут нечем, и лучше это
# увидеть в выходе, чем протащить дальше полуподменённый объект.
def patch_markup(markup, flag_a, flag_b, why_a, why_b):
    """
    (String?, Bool?, Bool?, String?, String?) -> Yson?
    """
    data = _load_any(markup)
    if data is None:
        return None
    if flag_a is None and flag_b is None:
        return cyson.dumps(data)
    flags = {'A': _as_bool(flag_a), 'B': _as_bool(flag_b)}
    whys = {'A': _text(why_a), 'B': _text(why_b)}
    _walk(data, flags, whys)
    return cyson.dumps(data)
@@;

$parse_le = Python3::parse_language_errors($script);
$patch = Python3::patch_markup($script);

$le = (
    SELECT
        CAST(p.for_join AS String)      AS join_key,
        $parse_le(CAST(p.dst AS String)) AS le
    FROM $input1 AS p
    WHERE p.for_join IS NOT NULL
);

-- На ключ ожидается одна строка судейского прохода; SOME страхует от дублей,
-- чтобы джойн не размножил строки разметки.
$le_one = (
    SELECT
        join_key,
        SOME(le) AS le
    FROM $le
    GROUP BY join_key
);

-- LEFT JOIN, а не INNER: строки разметки без судейского вердикта должны
-- доехать до выхода нетронутыми, а не молча исчезнуть.
$joined = (
    SELECT
        m.*,
        IF(Yson::LookupBool(l.le, 'ok') ?? false, Yson::LookupBool(l.le, 'p1') ?? false) AS le_a,
        IF(Yson::LookupBool(l.le, 'ok') ?? false, Yson::LookupBool(l.le, 'p2') ?? false) AS le_b,
        Yson::LookupString(l.le, 'why1') ?? '' AS why_a,
        Yson::LookupString(l.le, 'why2') ?? '' AS why_b
    FROM $input2 AS m
    LEFT JOIN $le_one AS l
    ON CAST(m.for_join AS String) = l.join_key
);

-- Схема выхода повторяет схему разметки: только эти шесть колонок, все Yson.
-- for_join нужен лишь для джойна и до выхода не доезжает.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    $patch(CAST(j.agg_tov_markup AS String), j.le_a, j.le_b, j.why_a, j.why_b) AS agg_tov_markup,
    j.answers                                                                  AS answers,
    j.input_final_messages                                                     AS input_final_messages,
    j.input_meta                                                               AS input_meta,
    j.input_render_data                                                        AS input_render_data,
    $patch(CAST(j.raw_tov_markup AS String), j.le_a, j.le_b, j.why_a, j.why_b) AS raw_tov_markup
FROM $joined AS j;
