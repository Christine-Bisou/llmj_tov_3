PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;
DECLARE $output1 AS String;

-- Вход: склеенная таблица с колонками
--   has_memory_A / has_memory_B              — судья упомянул память
--   memory_markers_A_str / ..._B_str         — "direct.template_phrases, reverse.template_phrases"
--   tov_flag                                 — разметка: "да" / "нет"
--   tov_markers                              — "Навязчивое повторение, Машинная формулировка"
--
-- Предсказание: has_memory_A OR has_memory_B. Правда: tov_flag = "да".
--
-- Выход — одна длинная таблица, разделы в колонке section:
--   quality      — rows / TP / FP / FN / TN / precision / recall / f1 / accuracy
--   tov_marker   — сколько раз встретилась причина в tov_markers (value — доля строк с флагом)
--   judge_marker — сколько раз судья назвал маркер (value — доля строк, где он что-то назвал)
--   pair         — пересечение причины и маркера судьи (value — доля внутри своей причины)
--
-- В разделе pair строка с двумя причинами и двумя маркерами даёт четыре пары:
-- это кросс-таблица, а не соответствие один-к-одному.

-- ===================== разбор строк =====================

-- "a, b, c" -> ['a', 'b', 'c']. Пустые куски выкидываем.
$split = ($s) -> {
    RETURN ListFilter(
        ListMap(
            String::SplitToList(COALESCE(CAST($s AS String), ''), ','),
            ($x) -> { RETURN String::Strip($x); }
        ),
        ($x) -> { RETURN $x != ''; }
    );
};

-- "reverse.template_phrases" -> "template_phrases": проход для сопоставления не нужен.
$strip_pass = ($m) -> {
    RETURN IF(String::Contains($m, '.'), ListLast(String::SplitToList($m, '.')), $m);
};

$lower = ($v) -> {
    RETURN CAST(Unicode::ToLower(CAST(String::Strip(COALESCE(CAST($v AS String), '')) AS Utf8)) AS String);
};

$rows = (
    SELECT
        $lower(t.tov_flag) IN ('да', 'yes', 'true', '1')                    AS gold,
        COALESCE(t.has_memory_A, false) OR COALESCE(t.has_memory_B, false)  AS pred,

        -- если tov_markers лежит списком (Yson), замени на:
        -- Yson::ConvertToStringList(t.tov_markers)
        $split(t.tov_markers)                                               AS tov_list,

        ListSort(ListUniq(ListMap(
            ListExtend($split(t.memory_markers_A_str), $split(t.memory_markers_B_str)),
            $strip_pass
        )))                                                                 AS judge_list
    FROM $input1 AS t
);

-- ===================== раздел quality =====================

$conf = (
    SELECT
        CAST(COUNT(*) AS Int64)                        AS rows_total,
        CAST(COUNT_IF(pred AND gold) AS Int64)         AS tp,
        CAST(COUNT_IF(pred AND NOT gold) AS Int64)     AS fp,
        CAST(COUNT_IF(NOT pred AND gold) AS Int64)     AS fn,
        CAST(COUNT_IF(NOT pred AND NOT gold) AS Int64) AS tn
    FROM $rows
);

$metrics = (
    SELECT
        c.*,
        IF(c.tp + c.fp > 0, 1.0 * c.tp / (c.tp + c.fp), 0.0) AS prec,
        IF(c.tp + c.fn > 0, 1.0 * c.tp / (c.tp + c.fn), 0.0) AS rec
    FROM $conf AS c
);

$quality = (
    SELECT
        'quality' AS section,
        m.name    AS name_1,
        ''        AS name_2,
        m.cnt     AS cnt,
        m.val     AS value
    FROM (
        SELECT AsList(
            AsStruct('rows'      AS name, rows_total AS cnt, CAST(rows_total AS Double) AS val),
            AsStruct('TP'        AS name, tp         AS cnt, CAST(tp AS Double)         AS val),
            AsStruct('FP'        AS name, fp         AS cnt, CAST(fp AS Double)         AS val),
            AsStruct('FN'        AS name, fn         AS cnt, CAST(fn AS Double)         AS val),
            AsStruct('TN'        AS name, tn         AS cnt, CAST(tn AS Double)         AS val),
            AsStruct('precision' AS name, 0L         AS cnt, prec                       AS val),
            AsStruct('recall'    AS name, 0L         AS cnt, rec                        AS val),
            AsStruct('f1'        AS name, 0L         AS cnt,
                     IF(prec + rec > 0, 2.0 * prec * rec / (prec + rec), 0.0)           AS val),
            AsStruct('accuracy'  AS name, 0L         AS cnt,
                     IF(rows_total > 0, 1.0 * (tp + tn) / rows_total, 0.0)              AS val)
        ) AS metrics
        FROM $metrics
    )
    FLATTEN LIST BY (metrics AS m)
);

-- ===================== разделы с маркерами =====================

-- Строки, где хоть одна сторона что-то нашла. Пустую сторону подписываем явно,
-- иначе FN и FP просто исчезнут из кросс-таблицы.
$marked = (
    SELECT
        IF(ListLength(tov_list)   > 0, tov_list,   AsList('(пусто в tov_markers)'))  AS tov_list,
        IF(ListLength(judge_list) > 0, judge_list, AsList('(судья не назвал)'))      AS judge_list
    FROM $rows
    WHERE gold OR pred
);

-- Скаляр: сколько всего строк ушло в разбор маркеров.
$marked_total = (SELECT CAST(COUNT(*) AS Int64) FROM $marked);

$tov_dist = (
    SELECT
        'tov_marker'                                                        AS section,
        tov_marker                                                          AS name_1,
        ''                                                                  AS name_2,
        CAST(COUNT(*) AS Int64)                                             AS cnt,
        IF($marked_total > 0, 1.0 * COUNT(*) / $marked_total, 0.0)          AS value
    FROM $marked
    FLATTEN LIST BY (tov_list AS tov_marker)
    GROUP BY tov_marker
);

$judge_dist = (
    SELECT
        'judge_marker'                                                      AS section,
        judge_marker                                                        AS name_1,
        ''                                                                  AS name_2,
        CAST(COUNT(*) AS Int64)                                             AS cnt,
        IF($marked_total > 0, 1.0 * COUNT(*) / $marked_total, 0.0)          AS value
    FROM $marked
    FLATTEN LIST BY (judge_list AS judge_marker)
    GROUP BY judge_marker
);

-- Кросс-таблица: два FLATTEN подряд, потому что один FLATTEN по двум колонкам
-- склеил бы списки попарно, а нужны все сочетания.
$e1 = (
    SELECT tov_marker AS tov_marker, judge_list AS judge_list
    FROM $marked
    FLATTEN LIST BY (tov_list AS tov_marker)
);

$e2 = (
    SELECT tov_marker AS tov_marker, judge_marker AS judge_marker
    FROM $e1
    FLATTEN LIST BY (judge_list AS judge_marker)
);

$pair_cnt = (
    SELECT tov_marker AS tov_marker, judge_marker AS judge_marker, CAST(COUNT(*) AS Int64) AS cnt
    FROM $e2
    GROUP BY tov_marker, judge_marker
);

$tov_tot = (
    SELECT tov_marker AS tov_marker, CAST(COUNT(*) AS Int64) AS total
    FROM $e2
    GROUP BY tov_marker
);

$pairs = (
    SELECT
        'pair'                       AS section,
        p.tov_marker                 AS name_1,
        p.judge_marker               AS name_2,
        p.cnt                        AS cnt,
        1.0 * p.cnt / t.total        AS value
    FROM $pair_cnt AS p
    INNER JOIN $tov_tot AS t
    ON p.tov_marker = t.tov_marker
);

-- ===================== выход =====================

$all = (
    SELECT section, name_1, name_2, cnt, value FROM $quality
    UNION ALL
    SELECT section, name_1, name_2, cnt, value FROM $tov_dist
    UNION ALL
    SELECT section, name_1, name_2, cnt, value FROM $judge_dist
    UNION ALL
    SELECT section, name_1, name_2, cnt, value FROM $pairs
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    section,
    name_1,
    name_2,
    cnt,
    value
FROM $all
ORDER BY section, cnt DESC, name_1, name_2;
