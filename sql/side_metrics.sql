PRAGMA yt.InferSchema = '1';
PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;

DECLARE $input1 AS String;   -- склеенный прогон: winner, tov_winner, answer_source_1/2
DECLARE $output1 AS String;  -- метрика по семьям + проверка ориентации сторон
DECLARE $output2 AS String;  -- диагностика: какая ветка нормализации сработала
DECLARE $output3 AS String;  -- что реально лежит в исходных колонках

-- Все стороны считаем в координатах ТАБЛИЦЫ:
--     left  == answer_1 == answer_source_1
--     right == answer_2 == answer_source_2
--
-- Разница с прошлой версией в том, что теперь у нормализации есть режим ($kind),
-- и режимы не смешиваются:
--
--   'label' — вердикт джаджа (tov_winner). Это ПОЗИЦИЯ в промпте: model_1 / model_2 /
--             tie. На answer_source_1/2 такой вердикт не смотрит вообще, поэтому
--             метрика модели больше не зависит от того, правильно ли заполнены
--             источники. Вердикт обратного прохода должен быть уже развёрнут
--             (model_winner_reversed_normalized), иначе стороны поменяются местами —
--             это ловит проверка ориентации в $output1.
--
--   'name'  — золото (winner). Это ИМЯ модели, сторону получаем сравнением с
--             источниками. Позиционные ярлыки в этом режиме не применяются, чтобы
--             модель с именем вида "model_1" не уехала налево просто по названию.
--
--   'auto'  — сначала имя, потом ярлык. Для колонок, где встречается и то и другое.
--
-- Вторая половина ответа — правило, по которому сторона получена. По нему видно,
-- каким строкам верить: by_name / by_label / literal — разрешено точно,
-- no_source / same_source / unmatched — сторону определить нечем.

$script = @@#py
import re
from yql.typing import *

_SEP = re.compile(r"[\s\-]+")
_DUP = re.compile(r"_+")


def _canon(x):
    """Пробелы и дефисы приводим к подчёркиванию: 'Model 1' и 'model-1' — одно и то же."""
    s = str(x or "").strip().lower()
    s = _SEP.sub("_", s)
    s = _DUP.sub("_", s)
    return s.strip("_")


# позиционные ярлыки: описывают МЕСТО в паре, а не модель
_LEFT_LABELS = {"left", "first", "a", "1", "m1", "answer_1", "model_1"}
_RIGHT_LABELS = {"right", "second", "b", "2", "m2", "answer_2", "model_2"}
# skip и пустую строку считаем ничьёй — так же, как error_breakdown.sql
_DRAW_LABELS = {"draw", "tie", "equal", "skip"}
_BOTH_BAD_LABELS = {"both_bad", "bothbad", "both_worse"}


def resolve_side(
    verdict: Optional[Utf8],
    source_1: Optional[Utf8],
    source_2: Optional[Utf8],
    kind: Optional[Utf8]
) -> Optional[Utf8]:
    """Возвращает 'сторона:правило'.

    Сторона: left | right | draw | both_bad | unknown.
    Режим kind: 'label' | 'name' | 'auto'.
    """
    w = _canon(verdict)
    a = _canon(source_1)
    b = _canon(source_2)
    k = _canon(kind) or "auto"

    if not w:
        return "unknown:empty_verdict"
    if w in _DRAW_LABELS:
        return "draw:literal"
    if w in _BOTH_BAD_LABELS:
        return "both_bad:literal"

    # по имени модели: работает, только если источники различимы
    if k in ("name", "auto") and a and b and a != b:
        if w == a:
            return "left:by_name"
        if w == b:
            return "right:by_name"

    # по позиционному ярлыку: источники не нужны
    if k in ("label", "auto"):
        if w in _LEFT_LABELS:
            return "left:by_label"
        if w in _RIGHT_LABELS:
            return "right:by_label"

    # сторону определить нечем — причину сохраняем, гадать не будем
    if not a or not b:
        return "unknown:no_source"
    if a == b:
        return "unknown:same_source"
    return "unknown:unmatched"


def row_family(source_1: Optional[Utf8], source_2: Optional[Utf8]) -> Optional[Utf8]:
    a = _canon(source_1)
    b = _canon(source_2)

    def is_vlm(t):
        return bool(re.search(r"32b_yavlm|alicevlm", t) or t.startswith("v7"))

    def is_neuro(t):
        return bool(
            re.search(r"neuro|mandarin", t)
            or t.startswith("nap_")
            or t.startswith("sft_rewrite")
            or t.startswith("grpo_")
            or t.startswith("tov_sft")
            or t.startswith("одуванчик")
        )

    if is_vlm(a) or is_vlm(b):
        return "vlm"
    if is_neuro(a) or is_neuro(b):
        return "neuro"
    return "other"
@@;

$resolve = Python3::resolve_side($script);
$family = Python3::row_family($script);

$side_of = ($x) -> { RETURN COALESCE(ListHead(String::SplitToList(CAST($x AS String), ':')), 'unknown') };
$rule_of = ($x) -> { RETURN COALESCE(ListLast(String::SplitToList(CAST($x AS String), ':')), 'unknown') };

$flip_side = ($s) -> {
    RETURN CASE $s WHEN 'left' THEN 'right' WHEN 'right' THEN 'left' ELSE $s END;
};

-- ничья и both_bad считаются одним классом: обе означают "разницы нет"
$score_half = ($golden, $model) -> {
    RETURN CASE
        WHEN $golden == $model THEN 1.0
        WHEN $golden IN ('draw', 'both_bad') AND $model IN ('draw', 'both_bad') THEN 1.0
        WHEN $golden IN ('draw', 'both_bad') OR  $model IN ('draw', 'both_bad') THEN 0.5
        ELSE 0.0
    END;
};

$score_strict = ($golden, $model) -> {
    RETURN CASE
        WHEN $golden == $model THEN 1.0
        WHEN $golden IN ('draw', 'both_bad') AND $model IN ('draw', 'both_bad') THEN 1.0
        ELSE 0.0
    END;
};

$raw = (
    SELECT
        CAST(winner AS Utf8)           AS winner_u,
        CAST(tov_winner AS Utf8)       AS tov_winner_u,
        CAST(answer_source_1 AS Utf8)  AS source_1,
        CAST(answer_source_2 AS Utf8)  AS source_2
    FROM $input1
);

$resolved = (
    SELECT
        $family(source_1, source_2)                                            AS family,
        $resolve(winner_u,     source_1, source_2, CAST('name'  AS Utf8))      AS g,
        $resolve(tov_winner_u, source_1, source_2, CAST('label' AS Utf8))      AS m
    FROM $raw
);

$sided = (
    SELECT
        family,
        $side_of(g) AS golden_side,
        $rule_of(g) AS golden_rule,
        $side_of(m) AS model_side,
        $rule_of(m) AS model_rule
    FROM $resolved
);

$scored = (
    SELECT
        family,
        golden_side,
        golden_rule,
        model_side,
        model_rule,
        -- обе стороны известны: строка попадает в метрику
        IF(usable, $score_half(golden_side, model_side))               AS s_half,
        IF(usable, $score_strict(golden_side, model_side))             AS s_strict,
        -- та же метрика под гипотезой "стороны перевёрнуты"
        IF(usable, $score_half(golden_side, $flip_side(model_side)))   AS s_half_flipped,
        IF(usable, $score_strict(golden_side, $flip_side(model_side))) AS s_strict_flipped,
        -- решительные строки: ни золото, ни модель не сказали "ничья".
        -- Только на них видно, не перепутаны ли лево и право.
        IF(golden_side IN ('left', 'right') AND model_side IN ('left', 'right'),
           IF(golden_side == model_side, 1.0, 0.0))                    AS decisive_hit
    FROM (
        SELECT
            s.*,
            s.golden_side != 'unknown' AND s.model_side != 'unknown' AS usable
        FROM $sided AS s
    )
);

-- Проверка ориентации. Если на решительных строках модель попадает заметно реже
-- половины — стороны развёрнуты: скорее всего в метрику приехал сырой
-- model_winner_reversed вместо model_winner_reversed_normalized.
$orientation = ($hit, $n) -> {
    RETURN CASE
        WHEN $n IS NULL OR $n < 30      THEN 'мало решительных строк для вывода'
        WHEN $hit >= 0.55               THEN 'ок: стороны совпадают'
        WHEN $hit <= 0.45               THEN 'ВНИМАНИЕ: стороны похоже перевёрнуты'
        ELSE                                 'сигнала нет: модель на уровне монетки'
    END;
};

$agg = (
    SELECT
        COALESCE(family, 'all')                     AS family,
        COUNT(*)                                    AS rows_total,
        COUNT(s_half)                               AS cnt,
        AVG(s_half)                                 AS quality_with_half,
        AVG(s_strict)                               AS quality_strict,
        AVG(s_half_flipped)                         AS quality_with_half_flipped,
        AVG(s_strict_flipped)                       AS quality_strict_flipped,
        COUNT(decisive_hit)                         AS decisive_cnt,
        AVG(decisive_hit)                           AS decisive_hit_rate,
        COUNT_IF(golden_side == 'unknown')          AS skipped_golden,
        COUNT_IF(model_side == 'unknown')           AS skipped_model,
        COUNT_IF(golden_rule == 'same_source')      AS golden_same_source,
        COUNT_IF(golden_rule == 'unmatched')        AS golden_unmatched,
        COUNT_IF(golden_rule == 'no_source')        AS golden_no_source,
        COUNT_IF(model_rule == 'unmatched')         AS model_unmatched
    FROM $scored
    GROUP BY ROLLUP(family)
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    family,
    quality_with_half,
    quality_strict,
    quality_with_half_flipped,
    quality_strict_flipped,
    $orientation(decisive_hit_rate, decisive_cnt) AS orientation_check,
    decisive_hit_rate,
    decisive_cnt,
    cnt,
    rows_total,
    skipped_golden,
    skipped_model,
    golden_same_source,
    golden_unmatched,
    golden_no_source,
    model_unmatched
FROM $agg
ORDER BY family;

-- Разбор по веткам: видно, сколько строк разрешено по имени, сколько по ярлыку
-- и на чём нормализация сдалась.
INSERT INTO $output2 WITH TRUNCATE
SELECT
    family,
    golden_rule,
    model_rule,
    golden_side,
    model_side,
    COUNT(*) AS cnt
FROM $scored
GROUP BY family, golden_rule, model_rule, golden_side, model_side
ORDER BY cnt DESC;

-- Сырые значения как есть: сюда смотрим, если непонятно, что лежит в источниках
-- и совпадает ли имя победителя хоть с одним из них.
INSERT INTO $output3 WITH TRUNCATE
SELECT
    winner_u                          AS winner_raw,
    tov_winner_u                      AS tov_winner_raw,
    source_1                          AS answer_source_1,
    source_2                          AS answer_source_2,
    COUNT(*)                          AS cnt
FROM $raw
GROUP BY winner_u, tov_winner_u, source_1, source_2
ORDER BY cnt DESC
LIMIT 500;
