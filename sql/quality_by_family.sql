PRAGMA yt.InferSchema = '1';
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Качество вердикта в разрезе семейств моделей.
--
-- golden = golden_winner (имя модели-победителя из разметки)
-- model  = tov_winner    (то, что поставил джадж)
-- Обе стороны нормализуются в left / right / draw / both_bad через source_A и source_B.
--
-- Метрики:
--   quality_strict    — совпадение вердиктов (draw и both_bad считаем одним и тем же)
--   quality_with_half — то же, но «ничья против выбора» засчитывается за половину
--
-- Строки, где сторону определить нельзя, в метрики не идут и видны
-- в skipped_model / skipped_golden.

$norm_side = Python3::norm_side(
    Callable<(Utf8?, Utf8?, Utf8?)->Utf8>,
@@
def _n(x):
    return " ".join(str(x or "").strip().lower().split())

_DRAW     = {"draw", "tie", "equal", "conflict"}
_BOTH_BAD = {"both_bad", "bothbad", "both_worse"}
# 'answer_a' / 'answer_b' — то, что реально лежит в golden_winner
_LEFT     = {"left", "first", "a", "1", "answer_1", "answer_a", "model_1"}
_RIGHT    = {"right", "second", "b", "2", "answer_2", "answer_b", "model_2"}

def norm_side(w, s1, s2):
    w, a, b = _n(w), _n(s1), _n(s2)
    if not w:
        return "unknown"
    if w in _DRAW:
        return "draw"
    if w in _BOTH_BAD:
        return "both_bad"
    if w in _LEFT:
        return "left"
    if w in _RIGHT:
        return "right"
    if a and b and a == b:
        return "unknown"   # одна модель с обеих сторон — сторону не определить
    if w == a:
        return "left"
    if w == b:
        return "right"
    return "unknown"
@@
);

$row_family = Python3::row_family(
    Callable<(Utf8?, Utf8?)->Utf8>,
@@
import re

def _is_vlm(t):
    return bool(re.search(r"32b_yavlm|alicevlm", t) or t.startswith("v7"))

def _is_neuro(t):
    return bool(
        re.search(r"neuro|mandarin", t)
        or t.startswith("nap_")
        or t.startswith("sft_rewrite")
        or t.startswith("grpo_")
        or t.startswith("tov_sft")
        or t.startswith("одуванчик")
    )

def row_family(s1, s2):
    a = str(s1 or "").strip().lower()
    b = str(s2 or "").strip().lower()
    if _is_vlm(a) or _is_vlm(b):
        return "vlm"
    if _is_neuro(a) or _is_neuro(b):
        return "neuro"
    return "other"
@@
);

$score_half = ($golden, $model) -> {
    RETURN CASE
        WHEN $golden == $model THEN 1.0
        WHEN ($golden == 'draw'     AND $model  == 'both_bad')
          OR ($golden == 'both_bad' AND $model  == 'draw')     THEN 1.0
        WHEN ($golden IN ('draw', 'both_bad') AND $model  NOT IN ('draw', 'both_bad'))
          OR ($model  IN ('draw', 'both_bad') AND $golden NOT IN ('draw', 'both_bad')) THEN 0.5
        ELSE 0.0
    END;
};

$score_strict = ($golden, $model) -> {
    RETURN CASE
        WHEN $golden == $model THEN 1.0
        WHEN ($golden == 'draw'     AND $model  == 'both_bad')
          OR ($golden == 'both_bad' AND $model  == 'draw')     THEN 1.0
        ELSE 0.0
    END;
};

$sided = (
    SELECT
        $row_family(
            CAST(source_A AS Utf8?),
            CAST(source_B AS Utf8?)
        ) AS family,
        $norm_side(
            CAST(golden_winner AS Utf8?),
            CAST(source_A AS Utf8?),
            CAST(source_B AS Utf8?)
        ) AS golden_side,
        $norm_side(
            CAST(tov_winner AS Utf8?),
            CAST(source_A AS Utf8?),
            CAST(source_B AS Utf8?)
        ) AS model_side
    FROM $input1
);

$scored = (
    SELECT
        family,
        golden_side,
        model_side,
        CASE WHEN golden_side != 'unknown' AND model_side != 'unknown'
             THEN $score_half(golden_side, model_side)
             ELSE Nothing(Double?) END AS s_half,
        CASE WHEN golden_side != 'unknown' AND model_side != 'unknown'
             THEN $score_strict(golden_side, model_side)
             ELSE Nothing(Double?) END AS s_strict
    FROM $sided
);

INSERT INTO $output1 WITH TRUNCATE
SELECT * FROM (
    SELECT
        family,
        CAST(SUM(s_half)   AS Double) / CAST(COUNT_IF(s_half IS NOT NULL) AS Double) AS quality_with_half,
        CAST(SUM(s_strict) AS Double) / CAST(COUNT_IF(s_strict IS NOT NULL) AS Double) AS quality_strict,
        COUNT_IF(s_half IS NOT NULL)       AS cnt,
        COUNT(*)                           AS rows_total,
        COUNT_IF(model_side == 'unknown')  AS skipped_model,
        COUNT_IF(golden_side == 'unknown') AS skipped_golden
    FROM $scored
    WHERE family != 'other'
    GROUP BY family
)

UNION ALL

SELECT * FROM (
    SELECT
        'all' AS family,
        CAST(SUM(s_half)   AS Double) / CAST(COUNT_IF(s_half IS NOT NULL) AS Double) AS quality_with_half,
        CAST(SUM(s_strict) AS Double) / CAST(COUNT_IF(s_strict IS NOT NULL) AS Double) AS quality_strict,
        COUNT_IF(s_half IS NOT NULL)       AS cnt,
        COUNT(*)                           AS rows_total,
        COUNT_IF(model_side == 'unknown')  AS skipped_model,
        COUNT_IF(golden_side == 'unknown') AS skipped_golden
    FROM $scored
);
