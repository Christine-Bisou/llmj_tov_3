-- Качество прохода по речевым ошибкам против золота.
-- Парсинг ответа джаджа и подсчёт метрик объединены в один скрипт: промежуточная
-- таблица с разобранными маркерами не нужна, маркер здесь ровно один.
--
-- Вход:  таблица с колонками dst (сырой ответ модели), golden_a_checkboxes,
--        golden_b_checkboxes.
-- Выход: одна строка с матрицей ошибок и метриками по tov_minus_language_errors.

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '2';

DECLARE $input1 AS String;
DECLARE $output1 AS String;

$script = @@#py
import json
import cyson


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


def _flag(data, markers_key):
    """
    Достаёт is_present у language_errors. Терпим к тому, что модель могла
    вернуть строку вместо булева и что ключа может не быть вовсе.
    """
    markers = data.get(markers_key) or {}
    if not isinstance(markers, dict):
        return False
    node = markers.get('language_errors') or {}
    if not isinstance(node, dict):
        return False
    val = node.get('is_present', False)
    if isinstance(val, bool):
        return val
    if isinstance(val, str):
        return val.strip().lower() in ('true', 'yes', '1')
    return bool(val)


def parse_language_errors(s):
    """
    (String?) -> Yson?
    Возвращает {ok, p1, p2}. ok=false означает, что ответ не распарсился:
    без этого флага сломанный JSON молча засчитался бы как «ошибок нет»
    и просадил бы recall, не оставив следа в метриках.
    """
    s = _clean(s)
    if not s:
        return cyson.dumps({'ok': False, 'p1': False, 'p2': False})
    try:
        data = json.loads(s, strict=False)
        if not isinstance(data, dict):
            raise ValueError('not an object')
        return cyson.dumps({
            'ok': True,
            'p1': _flag(data, 'model_1_markers'),
            'p2': _flag(data, 'model_2_markers'),
        })
    except Exception:
        return cyson.dumps({'ok': False, 'p1': False, 'p2': False})
@@;

$parse_le = Python3::parse_language_errors($script);

-- Строки без золота в метрики не берём: с ними отсутствующий чекбокс
-- превратился бы в честный «золотой false» и разбавил бы выборку.
$parsed = (
    SELECT
        $parse_le(t.dst)      AS le,
        t.golden_a_checkboxes AS ga,
        t.golden_b_checkboxes AS gb
    FROM $input1 AS t
    WHERE t.golden_a_checkboxes IS NOT NULL
      AND t.golden_b_checkboxes IS NOT NULL
);

-- Пара ответов раскладывается в две независимые единицы оценки.
$rows = (
    SELECT
        Yson::LookupBool(le, 'ok') ?? false AS ok,
        AsList(
            <|
                side: 'A',
                g: Yson::LookupBool(ga, 'tov_minus_language_errors') ?? false,
                p: Yson::LookupBool(le, 'p1') ?? false
            |>,
            <|
                side: 'B',
                g: Yson::LookupBool(gb, 'tov_minus_language_errors') ?? false,
                p: Yson::LookupBool(le, 'p2') ?? false
            |>
        ) AS pair
    FROM $parsed
);

$flat = (
    SELECT
        ok,
        pair.side AS side,
        pair.g    AS golden,
        pair.p    AS pred
    FROM $rows
    FLATTEN BY pair
);

$confusion = (
    SELECT
        SUM(IF(golden AND pred, 1, 0))         AS TP,
        SUM(IF(NOT golden AND pred, 1, 0))     AS FP,
        SUM(IF(golden AND NOT pred, 1, 0))     AS FN,
        SUM(IF(NOT golden AND NOT pred, 1, 0)) AS TN,
        COUNT(*)                               AS answers_total,
        SUM(IF(NOT ok, 1, 0))                  AS parse_failed
    FROM $flat
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    'tov_minus_language_errors' AS marker,

    TP, FP, FN, TN,

    (1.0 * TP) / MAX_OF(1.0, 1.0 * (TP + FP))                AS Precision,
    (1.0 * TP) / MAX_OF(1.0, 1.0 * (TP + FN))                AS Recall,
    (1.0 * (TP + TN)) / MAX_OF(1.0, 1.0 * answers_total)     AS Accuracy,
    (2.0 * TP) / MAX_OF(1.0, 2.0 * TP + FP + FN)             AS F1_Score,

    -- Базовые ставки: без них P/R не читаются. golden_rate — доля ответов,
    -- где ошибка есть в золоте; pred_rate — доля, где её нашла модель.
    TP + FN                                                   AS golden_positives,
    TP + FP                                                   AS predicted_positives,
    (1.0 * (TP + FN)) / MAX_OF(1.0, 1.0 * answers_total)      AS golden_rate,
    (1.0 * (TP + FP)) / MAX_OF(1.0, 1.0 * answers_total)      AS pred_rate,

    answers_total,
    parse_failed
FROM $confusion;
