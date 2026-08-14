PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;
PRAGMA yt.InferSchema = "1";

DECLARE $input1 AS String;  -- agg: строка на задание
DECLARE $input2 AS String;  -- суммаризация по пулу
DECLARE $output1 AS String;
DECLARE $output2 AS String;

$str = ($x) -> (nvl(Yson::ConvertToString($x), ""));

$round2 = ($x) -> (
    CAST(Math::Round(CAST($x AS Double) * 100.0) AS Double) / 100.0
);

-- Настоящее имя модели приходит своей колонкой. Пустое значит «не проставили» —
-- тогда остаёмся на имени прогона, как раньше оставались на producer_name.
$real_or_producer = ($real, $producer) -> (
    CAST(
        IF(COALESCE(CAST($real AS String), "") != "", CAST($real AS String), CAST($producer AS String))
        AS String
    )
);

$input2_prepared = (
    SELECT
        CAST(pool_id AS String) AS pool_id,
        CAST(pool_summarization AS String) AS pool_summarization
    FROM $input2
);

-- Агрегат под имена, которых метрики ждут исторически: победитель там теперь
-- winner, пул лежит в markup_metadata, а перекрытие — это длина списка
-- разметчиков задания, отдельной колонки под него больше нет.
$agg_src = (
    SELECT
        a.*,
        a.winner AS source_winner,
        a.winner_agreement AS source_winner_agreement,
        a.winner_strength AS source_winner_strength,
        CAST(IF(a.assignment_ids IS NULL, 0u, ListLength(a.assignment_ids)) AS Int64) AS task_count,
        $str(a.markup_metadata.pool_id) AS pool_id
    WITHOUT a.winner, a.winner_agreement, a.winner_strength
    FROM $input1 AS a
);

-- 0 - Исходные данные (без маппинга)
$input1_prep = (
    SELECT
        0 AS is_mapped,
        a.*,
        CAST($str(a.metadata.models.model_1) AS String) AS meta_model_1,
        CAST($str(a.metadata.models.model_2) AS String) AS meta_model_2,
        CAST($str(a.metadata.models.model_prod) AS String) AS meta_model_prod,
        CAST($str(a.metadata.models.model_test) AS String) AS meta_model_test
    FROM $agg_src AS a
);

-- 1 - Данные с заменой на настоящее имя модели.
-- Отдельная таблица соответствий больше не нужна: real_source_A/B приходят
-- колонками рядом с source_A/B, и подмена идёт построчно.
$input1_mapped = (
    SELECT
        1 AS is_mapped,
        a.*,
        $real_or_producer(a.real_source_A, a.source_A) AS source_A,
        $real_or_producer(a.real_source_B, a.source_B) AS source_B,

        CAST(CASE
            WHEN a.source_winner = a.source_A THEN $real_or_producer(a.real_source_A, a.source_A)
            WHEN a.source_winner = a.source_B THEN $real_or_producer(a.real_source_B, a.source_B)
            ELSE CAST(a.source_winner AS String)
        END AS String) AS source_winner,

        CAST(CASE
            WHEN a.diff_pa_winner = a.source_A THEN $real_or_producer(a.real_source_A, a.source_A)
            WHEN a.diff_pa_winner = a.source_B THEN $real_or_producer(a.real_source_B, a.source_B)
            ELSE CAST(a.diff_pa_winner AS String)
        END AS String) AS diff_pa_winner,

        CAST(CASE
            WHEN $str(a.metadata.models.model_1) = a.source_A THEN $real_or_producer(a.real_source_A, a.source_A)
            WHEN $str(a.metadata.models.model_1) = a.source_B THEN $real_or_producer(a.real_source_B, a.source_B)
            ELSE $str(a.metadata.models.model_1)
        END AS String) AS meta_model_1,

        CAST(CASE
            WHEN $str(a.metadata.models.model_2) = a.source_A THEN $real_or_producer(a.real_source_A, a.source_A)
            WHEN $str(a.metadata.models.model_2) = a.source_B THEN $real_or_producer(a.real_source_B, a.source_B)
            ELSE $str(a.metadata.models.model_2)
        END AS String) AS meta_model_2,

        CAST(CASE
            WHEN $str(a.metadata.models.model_prod) = a.source_A THEN $real_or_producer(a.real_source_A, a.source_A)
            WHEN $str(a.metadata.models.model_prod) = a.source_B THEN $real_or_producer(a.real_source_B, a.source_B)
            ELSE $str(a.metadata.models.model_prod)
        END AS String) AS meta_model_prod,

        CAST(CASE
            WHEN $str(a.metadata.models.model_test) = a.source_A THEN $real_or_producer(a.real_source_A, a.source_A)
            WHEN $str(a.metadata.models.model_test) = a.source_B THEN $real_or_producer(a.real_source_B, a.source_B)
            ELSE $str(a.metadata.models.model_test)
        END AS String) AS meta_model_test
    WITHOUT a.source_A, a.source_B, a.source_winner, a.diff_pa_winner
    FROM $agg_src AS a
);

-- Объединяем оба набора данных в одну таблицу
$combined_input = (
    SELECT * FROM $input1_prep
    UNION ALL
    SELECT * FROM $input1_mapped
);

$pair_info = (
    SELECT is_mapped, COUNT(DISTINCT AsTuple(
        CASE WHEN source_A <= source_B THEN source_A ELSE source_B END,
        CASE WHEN source_A <= source_B THEN source_B ELSE source_A END
    )) AS cnt
    FROM $combined_input
    GROUP BY is_mapped
);

$all_rows = (
    SELECT
        a.*,
        CASE WHEN a.source_A <= a.source_B THEN a.source_A ELSE a.source_B END AS norm_m1,
        CASE WHEN a.source_A <= a.source_B THEN a.source_B ELSE a.source_A END AS norm_m2,

        CASE WHEN p.cnt <= 1 THEN
            COALESCE(
                IF(a.meta_model_1 != "", a.meta_model_1, NULL),
                IF(a.meta_model_prod != "", a.meta_model_prod, NULL),
                ""
            )
        ELSE (CASE WHEN a.source_A <= a.source_B THEN a.source_A ELSE a.source_B END) END AS _target_m1,

        CASE WHEN p.cnt <= 1 THEN
            COALESCE(
                IF(a.meta_model_2 != "", a.meta_model_2, NULL),
                IF(a.meta_model_test != "", a.meta_model_test, NULL),
                ""
            )
        ELSE (CASE WHEN a.source_A <= a.source_B THEN a.source_B ELSE a.source_A END) END AS _target_m2
    FROM $combined_input AS a
    INNER JOIN $pair_info AS p ON a.is_mapped = p.is_mapped
);

-- ДУБЛИРУЕМ ДАННЫЕ: добавляем те же строки, но с norm_m1 = "ALL" и norm_m2 = "ALL"
$all_rows_extended = (
    SELECT * FROM $all_rows
    UNION ALL
    SELECT a.*,
        "ALL" AS norm_m1,
        "ALL" AS norm_m2
    WITHOUT a.norm_m1, a.norm_m2
    FROM $all_rows AS a
);

$active_rows = (
    SELECT *
    FROM $all_rows_extended
    WHERE COALESCE(skip, false) = false
);

$active_labeled = (
    SELECT
        a.*,
        CASE WHEN a.source_winner = a._target_m1 THEN 1 ELSE 0 END AS winner_is_m1,
        CASE WHEN a.source_winner = a._target_m2 THEN 1 ELSE 0 END AS winner_is_m2,
        CASE WHEN a.source_winner = "draw" THEN 1 ELSE 0 END AS winner_is_draw,
        CASE WHEN a.source_winner = "both_bad" THEN 1 ELSE 0 END AS winner_is_bad,

        CASE WHEN a.diff_pa_winner = a._target_m1 THEN 1 ELSE 0 END AS diff_pa_is_m1,
        CASE WHEN a.diff_pa_winner = a._target_m2 THEN 1 ELSE 0 END AS diff_pa_is_m2,
        CASE WHEN a.diff_pa_winner = "draw" THEN 1 ELSE 0 END AS diff_pa_is_draw,
        CASE WHEN a.diff_pa_winner = "both_bad" THEN 1 ELSE 0 END AS diff_pa_is_bad,

        CASE
            WHEN a.source_winner = a._target_m1 THEN 1.0
            WHEN a.source_winner = a._target_m2 THEN 0.0
            WHEN a.source_winner = "draw" OR a.source_winner = "both_bad" THEN 0.5
            ELSE NULL
        END AS winner_score,

        CASE
            WHEN a.diff_pa_winner = a._target_m1 THEN 1.0
            WHEN a.diff_pa_winner = a._target_m2 THEN 0.0
            WHEN a.diff_pa_winner = "draw" OR a.diff_pa_winner = "both_bad" THEN 0.5
            ELSE NULL
        END AS diff_pa_score
    FROM $active_rows AS a
);

$pool = (
    SELECT
        is_mapped, norm_m1, norm_m2,
        SOME(pool_id) AS pool_id,
        COUNT(*) AS accepted,
        SUM(CASE WHEN COALESCE(skip, false) THEN 1 ELSE 0 END) AS skip_cnt,
        AVG(CAST(task_count AS Double)) AS avg_overlap,
        SOME(markers) AS markers,
        SOME(checkboxes) AS checkboxes,

        -- Парсинг названий старым способом для замены заглушек ALL
        SOME(COALESCE(
            IF(meta_model_1 != "", meta_model_1, NULL),
            IF(meta_model_prod != "", meta_model_prod, NULL),
            ""
        )) AS orig_model_1,

        SOME(COALESCE(
            IF(meta_model_2 != "", meta_model_2, NULL),
            IF(meta_model_test != "", meta_model_test, NULL),
            ""
        )) AS orig_model_2

    FROM $all_rows_extended
    GROUP BY is_mapped, norm_m1, norm_m2
);

$winner_counts = (
    SELECT
        is_mapped, norm_m1, norm_m2,
        SUM(winner_is_m1) AS w_m1, SUM(winner_is_m2) AS w_m2, SUM(winner_is_draw) AS w_draw, SUM(winner_is_bad) AS w_bad,
        SUM(CASE WHEN winner_is_m1 = 1 OR winner_is_m2 = 1 OR winner_is_draw = 1 OR winner_is_bad = 1 THEN 1 ELSE 0 END) AS w_total,
        SUM(CASE WHEN source_winner_strength = "strong" AND source_winner = _target_m1 THEN 1 ELSE 0 END) AS model_1_strong,
        SUM(CASE WHEN source_winner_strength = "strong" AND source_winner = _target_m2 THEN 1 ELSE 0 END) AS model_2_strong,
        SUM(CASE WHEN source_winner_strength = "strong" AND source_winner = "draw" THEN 1 ELSE 0 END) AS draw_strong,
        SUM(CASE WHEN source_winner_strength = "strong" AND source_winner = "both_bad" THEN 1 ELSE 0 END) AS both_bad_strong,
        SUM(CASE WHEN source_winner_strength = "weak" AND source_winner = _target_m1 THEN 1 ELSE 0 END) AS model_1_weak,
        SUM(CASE WHEN source_winner_strength = "weak" AND source_winner = _target_m2 THEN 1 ELSE 0 END) AS model_2_weak,
        SUM(CASE WHEN source_winner_strength = "weak" AND source_winner = "draw" THEN 1 ELSE 0 END) AS draw_weak,
        SUM(CASE WHEN source_winner_strength = "weak" AND source_winner = "both_bad" THEN 1 ELSE 0 END) AS both_bad_weak,
        AVG(CASE WHEN source_winner_agreement IS NULL AND task_count = 1 THEN 1.0 ELSE source_winner_agreement END) AS consistency
    FROM $active_labeled
    GROUP BY is_mapped, norm_m1, norm_m2
);

$diff_pa_counts = (
    SELECT
        is_mapped, norm_m1, norm_m2,
        SUM(diff_pa_is_m1) AS w_m1, SUM(diff_pa_is_m2) AS w_m2, SUM(diff_pa_is_draw) AS w_draw, SUM(diff_pa_is_bad) AS w_bad,
        SUM(CASE WHEN diff_pa_is_m1 = 1 OR diff_pa_is_m2 = 1 OR diff_pa_is_draw = 1 OR diff_pa_is_bad = 1 THEN 1 ELSE 0 END) AS w_total,
        SUM(CASE WHEN diff_pa_winner_strength = "strong" AND diff_pa_winner = _target_m1 THEN 1 ELSE 0 END) AS model_1_strong,
        SUM(CASE WHEN diff_pa_winner_strength = "strong" AND diff_pa_winner = _target_m2 THEN 1 ELSE 0 END) AS model_2_strong,
        SUM(CASE WHEN diff_pa_winner_strength = "strong" AND diff_pa_winner = "draw" THEN 1 ELSE 0 END) AS draw_strong,
        SUM(CASE WHEN diff_pa_winner_strength = "strong" AND diff_pa_winner = "both_bad" THEN 1 ELSE 0 END) AS both_bad_strong,
        SUM(CASE WHEN diff_pa_winner_strength = "weak" AND diff_pa_winner = _target_m1 THEN 1 ELSE 0 END) AS model_1_weak,
        SUM(CASE WHEN diff_pa_winner_strength = "weak" AND diff_pa_winner = _target_m2 THEN 1 ELSE 0 END) AS model_2_weak,
        SUM(CASE WHEN diff_pa_winner_strength = "weak" AND diff_pa_winner = "draw" THEN 1 ELSE 0 END) AS draw_weak,
        SUM(CASE WHEN diff_pa_winner_strength = "weak" AND diff_pa_winner = "both_bad" THEN 1 ELSE 0 END) AS both_bad_weak,
        AVG(CASE WHEN diff_pa_winner_agreement IS NULL AND task_count = 1 THEN 1.0 ELSE diff_pa_winner_agreement END) AS diff_pa_consistency
    FROM $active_labeled
    GROUP BY is_mapped, norm_m1, norm_m2
);

$winner_p = (
    SELECT is_mapped, norm_m1, norm_m2, SUM(winner_score) AS s, SUM(CASE WHEN winner_score IS NOT NULL THEN 1 ELSE 0 END) AS n
    FROM $active_labeled
    GROUP BY is_mapped, norm_m1, norm_m2
);

$diff_pa_p = (
    SELECT is_mapped, norm_m1, norm_m2, SUM(diff_pa_score) AS s, SUM(CASE WHEN diff_pa_score IS NOT NULL THEN 1 ELSE 0 END) AS n
    FROM $active_labeled
    GROUP BY is_mapped, norm_m1, norm_m2
);

$all_mapped = (
    SELECT
        r.is_mapped AS is_mapped, r.norm_m1 AS norm_m1, r.norm_m2 AS norm_m2,
        CASE WHEN r.source_A = r._target_m1 THEN r.checkboxes_A WHEN r.source_B = r._target_m1 THEN r.checkboxes_B ELSE NULL END AS cb_m1,
        CASE WHEN r.source_A = r._target_m2 THEN r.checkboxes_A WHEN r.source_B = r._target_m2 THEN r.checkboxes_B ELSE NULL END AS cb_m2,
        CASE WHEN r.source_A = r._target_m1 THEN r.pointwise_A WHEN r.source_B = r._target_m1 THEN r.pointwise_B ELSE NULL END AS pw_m1,
        CASE WHEN r.source_A = r._target_m2 THEN r.pointwise_A WHEN r.source_B = r._target_m2 THEN r.pointwise_B ELSE NULL END AS pw_m2
    FROM $all_rows_extended AS r
);

/* === CHECKBOXES === */
$cb_m1_flat = (
    SELECT x.is_mapped AS is_mapped, x.norm_m1 AS norm_m1, x.norm_m2 AS norm_m2, CAST(x.items.0 AS String) AS cb_key, COALESCE(Yson::ConvertToBool(x.items.1), false) AS cb_true
    FROM (SELECT m.is_mapped AS is_mapped, m.norm_m1 AS norm_m1, m.norm_m2 AS norm_m2, DictItems(Yson::ConvertToDict(m.cb_m1)) AS items FROM $all_mapped AS m WHERE m.cb_m1 IS NOT NULL) AS x FLATTEN BY (items)
);
$cb_m1_key = (SELECT is_mapped, norm_m1, norm_m2, cb_key, SUM(CASE WHEN cb_true THEN 1 ELSE 0 END) AS true_cnt FROM $cb_m1_flat GROUP BY is_mapped, norm_m1, norm_m2, cb_key);
$cb_m1_pct = (
    SELECT k.is_mapped AS is_mapped, k.norm_m1 AS norm_m1, k.norm_m2 AS norm_m2, Yson::From(ToDict(AGGREGATE_LIST(AsTuple(k.cb_key, CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(k.true_cnt AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END)))) AS checkboxes_model_1_pct
    FROM $cb_m1_key AS k INNER JOIN $pool AS p ON k.is_mapped = p.is_mapped AND k.norm_m1 = p.norm_m1 AND k.norm_m2 = p.norm_m2 GROUP BY k.is_mapped, k.norm_m1, k.norm_m2, p.accepted
);

$cb_m2_flat = (
    SELECT x.is_mapped AS is_mapped, x.norm_m1 AS norm_m1, x.norm_m2 AS norm_m2, CAST(x.items.0 AS String) AS cb_key, COALESCE(Yson::ConvertToBool(x.items.1), false) AS cb_true
    FROM (SELECT m.is_mapped AS is_mapped, m.norm_m1 AS norm_m1, m.norm_m2 AS norm_m2, DictItems(Yson::ConvertToDict(m.cb_m2)) AS items FROM $all_mapped AS m WHERE m.cb_m2 IS NOT NULL) AS x FLATTEN BY (items)
);
$cb_m2_key = (SELECT is_mapped, norm_m1, norm_m2, cb_key, SUM(CASE WHEN cb_true THEN 1 ELSE 0 END) AS true_cnt FROM $cb_m2_flat GROUP BY is_mapped, norm_m1, norm_m2, cb_key);
$cb_m2_pct = (
    SELECT k.is_mapped AS is_mapped, k.norm_m1 AS norm_m1, k.norm_m2 AS norm_m2, Yson::From(ToDict(AGGREGATE_LIST(AsTuple(k.cb_key, CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(k.true_cnt AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END)))) AS checkboxes_model_2_pct
    FROM $cb_m2_key AS k INNER JOIN $pool AS p ON k.is_mapped = p.is_mapped AND k.norm_m1 = p.norm_m1 AND k.norm_m2 = p.norm_m2 GROUP BY k.is_mapped, k.norm_m1, k.norm_m2, p.accepted
);

/* === POINTWISE DICTIONARIES === */
/* overall отдельной колонкой не приходит: агрегат кладёт его обычным ключом
   словаря, поэтому он разворачивается вместе с остальными критериями. */
$pw_m1_flat = (
    SELECT x.is_mapped AS is_mapped, x.norm_m1 AS norm_m1, x.norm_m2 AS norm_m2, CAST(x.items.0 AS String) AS pw_key, CAST(Yson::ConvertToDouble(x.items.1) AS Double) AS pw_val
    FROM (SELECT m.is_mapped AS is_mapped, m.norm_m1 AS norm_m1, m.norm_m2 AS norm_m2, DictItems(Yson::ConvertToDict(m.pw_m1)) AS items FROM $all_mapped AS m WHERE m.pw_m1 IS NOT NULL AND NOT Yson::IsList(m.pw_m1)) AS x FLATTEN BY (items)
);
$pw_m1_agg = (SELECT is_mapped, norm_m1, norm_m2, pw_key, AVG(pw_val) AS avg_val FROM $pw_m1_flat GROUP BY is_mapped, norm_m1, norm_m2, pw_key);
$pw_m1_final = (SELECT k.is_mapped AS is_mapped, k.norm_m1 AS norm_m1, k.norm_m2 AS norm_m2, Yson::From(ToDict(AGGREGATE_LIST(AsTuple(k.pw_key, $round2(k.avg_val))))) AS pointwise_model_1_avg FROM $pw_m1_agg AS k GROUP BY k.is_mapped, k.norm_m1, k.norm_m2);

$pw_m2_flat = (
    SELECT x.is_mapped AS is_mapped, x.norm_m1 AS norm_m1, x.norm_m2 AS norm_m2, CAST(x.items.0 AS String) AS pw_key, CAST(Yson::ConvertToDouble(x.items.1) AS Double) AS pw_val
    FROM (SELECT m.is_mapped AS is_mapped, m.norm_m1 AS norm_m1, m.norm_m2 AS norm_m2, DictItems(Yson::ConvertToDict(m.pw_m2)) AS items FROM $all_mapped AS m WHERE m.pw_m2 IS NOT NULL AND NOT Yson::IsList(m.pw_m2)) AS x FLATTEN BY (items)
);
$pw_m2_agg = (SELECT is_mapped, norm_m1, norm_m2, pw_key, AVG(pw_val) AS avg_val FROM $pw_m2_flat GROUP BY is_mapped, norm_m1, norm_m2, pw_key);
$pw_m2_final = (SELECT k.is_mapped AS is_mapped, k.norm_m1 AS norm_m1, k.norm_m2 AS norm_m2, Yson::From(ToDict(AGGREGATE_LIST(AsTuple(k.pw_key, $round2(k.avg_val))))) AS pointwise_model_2_avg FROM $pw_m2_agg AS k GROUP BY k.is_mapped, k.norm_m1, k.norm_m2);


/* === ФИНАЛЬНАЯ ТАБЛИЦА С ДАННЫМИ === */
$final_metrics = (
    SELECT
        p.is_mapped AS is_mapped,
        p.norm_m1 AS _norm_m1,

        -- Пара, по которой посчитан срез. У общей строки пары нет, поэтому там
        -- вместо заглушки ALL стоят имена из входных колонок прогона.
        Yson::From(ToDict(AsList(
            AsTuple("model_1", CASE WHEN p.norm_m1 = "ALL" THEN p.orig_model_1 ELSE p.norm_m1 END),
            AsTuple("model_2", CASE WHEN p.norm_m2 = "ALL" THEN p.orig_model_2 ELSE p.norm_m2 END)
        ))) AS models_mapping,

        -- Уровень подсчёта отдельной колонкой:
        --   input       — одна общая строка по всему прогону, имена моделей как
        --                 они пришли на вход;
        --   source      — попарно по source_A/source_B, каждая с каждой;
        --   real_source — то же попарно, но по настоящим именам моделей.
        CASE
            WHEN p.is_mapped = 0 AND p.norm_m1 = "ALL" THEN "input"
            WHEN p.is_mapped = 0 AND p.norm_m1 != "ALL" THEN "source"
            WHEN p.is_mapped = 1 AND p.norm_m1 != "ALL" THEN "real_source"
            ELSE ""
        END AS level,

        i2.pool_summarization AS pool_summarization,
        p.accepted AS accepted, p.avg_overlap AS avg_overlap,
        p.markers AS markers, p.checkboxes AS checkboxes,
        c1.checkboxes_model_1_pct AS checkboxes_model_1_pct,
        c2.checkboxes_model_2_pct AS checkboxes_model_2_pct,
        pm1.pointwise_model_1_avg AS pointwise_1,
        pm2.pointwise_model_2_avg AS pointwise_2,
        w.consistency AS consistency,
        CASE WHEN COALESCE(wp.n, 0) < 2 THEN 1.0 ELSE 1.0 - Math::Erf(Abs((wp.s / CAST(wp.n AS Double)) - 0.5) / Math::Sqrt(0.5 / CAST(wp.n AS Double))) END AS p_value,

        Yson::From(ToDict(AsList(
            AsTuple("model_1_strong", COALESCE(w.model_1_strong, 0)), AsTuple("model_2_strong", COALESCE(w.model_2_strong, 0)),
            AsTuple("draw_strong", COALESCE(w.draw_strong, 0)), AsTuple("both_bad_strong", COALESCE(w.both_bad_strong, 0)),
            AsTuple("model_1_weak", COALESCE(w.model_1_weak, 0)), AsTuple("model_2_weak", COALESCE(w.model_2_weak, 0)),
            AsTuple("draw_weak", COALESCE(w.draw_weak, 0)), AsTuple("both_bad_weak", COALESCE(w.both_bad_weak, 0))
        ))) AS strength_abs,

        Yson::From(ToDict(AsList(
            AsTuple("model_1_strong", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.model_1_strong,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("model_2_strong", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.model_2_strong,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("draw_strong", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.draw_strong,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("both_bad_strong", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.both_bad_strong,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("model_1_weak", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.model_1_weak,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("model_2_weak", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.model_2_weak,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("draw_weak", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.draw_weak,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("both_bad_weak", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.both_bad_weak,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END)
        ))) AS strength_pct,

        CASE WHEN COALESCE(w.w_total,0) > 0 THEN (CAST(w.w_m1 AS Double) + 0.5 * CAST(w.w_draw AS Double) + 0.5 * CAST(w.w_bad AS Double)) / CAST(w.w_total AS Double) ELSE NULL END AS winrate_model_1,
        CASE WHEN COALESCE(w.w_total,0) > 0 THEN (CAST(w.w_m2 AS Double) + 0.5 * CAST(w.w_draw AS Double) + 0.5 * CAST(w.w_bad AS Double)) / CAST(w.w_total AS Double) ELSE NULL END AS winrate_model_2,

        Yson::From(ToDict(AsList(
            AsTuple("model_1", COALESCE(w.w_m1,0)), AsTuple("model_2", COALESCE(w.w_m2,0)),
            AsTuple("draw", COALESCE(w.w_draw,0)), AsTuple("both_bad", COALESCE(w.w_bad,0)), AsTuple("skip", COALESCE(p.skip_cnt,0))
        ))) AS wins_abs,

        Yson::From(ToDict(AsList(
            AsTuple("model_1", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.w_m1,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("model_2", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.w_m2,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("draw", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.w_draw,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("both_bad", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(w.w_bad,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("skip", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(p.skip_cnt,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END)
        ))) AS wins_pct,

        d.diff_pa_consistency AS diff_pa_consistency,
        CASE WHEN COALESCE(dp.n, 0) < 2 THEN 1.0 ELSE 1.0 - Math::Erf(Abs((dp.s / CAST(dp.n AS Double)) - 0.5) / Math::Sqrt(0.5 / CAST(dp.n AS Double))) END AS diff_pa_p_value,

        Yson::From(ToDict(AsList(
            AsTuple("model_1_strong", COALESCE(d.model_1_strong, 0)), AsTuple("model_2_strong", COALESCE(d.model_2_strong, 0)),
            AsTuple("draw_strong", COALESCE(d.draw_strong, 0)), AsTuple("both_bad_strong", COALESCE(d.both_bad_strong, 0)),
            AsTuple("model_1_weak", COALESCE(d.model_1_weak, 0)), AsTuple("model_2_weak", COALESCE(d.model_2_weak, 0)),
            AsTuple("draw_weak", COALESCE(d.draw_weak, 0)), AsTuple("both_bad_weak", COALESCE(d.both_bad_weak, 0))
        ))) AS diff_pa_strength_abs,

        Yson::From(ToDict(AsList(
            AsTuple("model_1_strong", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.model_1_strong,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("model_2_strong", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.model_2_strong,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("draw_strong", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.draw_strong,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("both_bad_strong", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.both_bad_strong,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("model_1_weak", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.model_1_weak,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("model_2_weak", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.model_2_weak,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("draw_weak", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.draw_weak,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("both_bad_weak", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.both_bad_weak,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END)
        ))) AS diff_pa_strength_pct,

        CASE WHEN COALESCE(d.w_total,0) > 0 THEN (CAST(d.w_m1 AS Double) + 0.5 * CAST(d.w_draw AS Double) + 0.5 * CAST(d.w_bad AS Double)) / CAST(d.w_total AS Double) ELSE NULL END AS diff_pa_winrate_model_1,
        CASE WHEN COALESCE(d.w_total,0) > 0 THEN (CAST(d.w_m2 AS Double) + 0.5 * CAST(d.w_draw AS Double) + 0.5 * CAST(d.w_bad AS Double)) / CAST(d.w_total AS Double) ELSE NULL END AS diff_pa_winrate_model_2,

        Yson::From(ToDict(AsList(
            AsTuple("model_1", COALESCE(d.w_m1,0)), AsTuple("model_2", COALESCE(d.w_m2,0)),
            AsTuple("draw", COALESCE(d.w_draw,0)), AsTuple("both_bad", COALESCE(d.w_bad,0)), AsTuple("skip", COALESCE(p.skip_cnt,0))
        ))) AS diff_pa_wins_abs,

        Yson::From(ToDict(AsList(
            AsTuple("model_1", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.w_m1,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("model_2", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.w_m2,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("draw", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.w_draw,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("both_bad", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(d.w_bad,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END),
            AsTuple("skip", CASE WHEN p.accepted > 0 THEN $round2(100.0 * CAST(COALESCE(p.skip_cnt,0) AS Double) / CAST(p.accepted AS Double)) ELSE 0.0 END)
        ))) AS diff_pa_wins_pct
    FROM $pool AS p
    LEFT JOIN $winner_counts AS w ON p.is_mapped = w.is_mapped AND p.norm_m1 = w.norm_m1 AND p.norm_m2 = w.norm_m2
    LEFT JOIN $diff_pa_counts AS d ON p.is_mapped = d.is_mapped AND p.norm_m1 = d.norm_m1 AND p.norm_m2 = d.norm_m2
    LEFT JOIN $winner_p AS wp ON p.is_mapped = wp.is_mapped AND p.norm_m1 = wp.norm_m1 AND p.norm_m2 = wp.norm_m2
    LEFT JOIN $diff_pa_p AS dp ON p.is_mapped = dp.is_mapped AND p.norm_m1 = dp.norm_m1 AND p.norm_m2 = dp.norm_m2
    LEFT JOIN $cb_m1_pct AS c1 ON p.is_mapped = c1.is_mapped AND p.norm_m1 = c1.norm_m1 AND p.norm_m2 = c1.norm_m2
    LEFT JOIN $cb_m2_pct AS c2 ON p.is_mapped = c2.is_mapped AND p.norm_m1 = c2.norm_m1 AND p.norm_m2 = c2.norm_m2
    LEFT JOIN $pw_m1_final AS pm1 ON p.is_mapped = pm1.is_mapped AND p.norm_m1 = pm1.norm_m1 AND p.norm_m2 = pm1.norm_m2
    LEFT JOIN $pw_m2_final AS pm2 ON p.is_mapped = pm2.is_mapped AND p.norm_m1 = pm2.norm_m1 AND p.norm_m2 = pm2.norm_m2
    LEFT JOIN $input2_prepared AS i2 ON CAST(p.pool_id AS String) = i2.pool_id
);

-- 1. Выгружаем общую строку по прогону в $output1.
-- Уровень тут всегда один и тот же, поэтому колонки level в этом выходе нет.
INSERT INTO $output1
SELECT
    t.*
WITHOUT t.is_mapped, t._norm_m1, t.level
FROM $final_metrics AS t
WHERE is_mapped = 0 AND _norm_m1 = "ALL";

-- 2. Выгружаем все три уровня во второй выход $output2:
-- общая строка по входным именам, попарно по source и попарно по real_source.
INSERT INTO $output2
SELECT
    t.*
WITHOUT t.is_mapped, t._norm_m1
FROM $final_metrics AS t
WHERE (is_mapped = 0 AND _norm_m1 = "ALL")
   OR (is_mapped = 0 AND _norm_m1 != "ALL")
   OR (is_mapped = 1 AND _norm_m1 != "ALL");
