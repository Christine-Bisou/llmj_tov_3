PRAGMA yt.InferSchema = "100";
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;
PRAGMA Yson.AutoConvert;
PRAGMA SimpleColumns;

DECLARE $input1 AS String; -- Основная базовая таблица (аггрегация из 1 этапа)
DECLARE $input2 AS String; -- Таблица с task_summarization
DECLARE $input3 AS String; -- Таблица с ответами джаджа (LLM-судья)
DECLARE $input4 AS String; -- Изначальная таблица
DECLARE $output1 AS String; -- Агрегат по заданию плоскими колонками
DECLARE $output2 AS String; -- Вход 4 как есть + agg_tov_markup / raw_tov_markup

$str_yson = ($x) -> (
    COALESCE(Yson::ConvertToString(Just(Yson::From($x))), "")
);

$str_string = ($x) -> (
    COALESCE(CAST($x AS String), "")
);

$empty_dict = Just(Yson::From(ToDict(AsList())));
$empty_list = Just(Yson::From(AsList()));

$parse_opts = Yson::Options(false AS Strict);
$conv_opts = Yson::Options(true AS AutoConvert, false AS Strict);

-- Маркера ясности больше не существует, поэтому clarity из чекбоксов не забираем
-- ни в агрегат, ни в поразметчиковый raw_outputs. В pointwise clarity остаётся:
-- там это отдельный критерий оценки, а не маркер.
$is_clarity_key = ($key) -> (
    COALESCE(String::Contains(String::AsciiToLower($key), "clarity"), False)
);

$clean_json = ($s) -> (
    String::Strip(
        String::ReplaceAll(
            String::ReplaceAll(COALESCE(CAST($s AS String), "{}"), "```json", ""),
            "```",
            ""
        )
    )
);

$build_judge_answer = ($s) -> {
    $root = Yson::ParseJson($clean_json($s), $parse_opts);
    $ece = Yson::Lookup($root, "editor_comment_evaluation", $parse_opts);
    $details = Yson::Lookup($ece, "evaluation_details", $parse_opts);

    RETURN AsStruct(
        AsStruct(
            Yson::LookupInt64($ece, "overall_score", $conv_opts) AS overall_score,
            AsStruct(
                Yson::LookupString($details, "why_this_score", $parse_opts) AS why_this_score,
                Yson::LookupString($details, "what_to_improve", $parse_opts) AS what_to_improve
            ) AS evaluation_details,
            Yson::LookupString($ece, "final_verdict", $parse_opts) AS final_verdict
        ) AS editor_comment_evaluation
    );
};

$extract_worker_checkboxes = ($cb_yson, $idx) -> {
    $cb_node = CAST($cb_yson AS Yson);
    RETURN IF(
        $cb_node IS NULL,
        $empty_dict,
        IF(
            Yson::IsDict($cb_node),
            Just(Yson::From(ToDict(
                ListMap(
                    ListFilter(
                        DictItems(Yson::ConvertToDict($cb_node)),
                        ($kv) -> { RETURN NOT $is_clarity_key(CAST($kv.0 AS String)); }
                    ),
                    ($kv) -> {
                        RETURN AsTuple(
                            CAST($kv.0 AS String),
                            Just(Yson::From(
                                IF(
                                    Yson::IsList($kv.1),
                                    COALESCE(Yson::ConvertToBool(Yson::ConvertToList($kv.1)[$idx]), false),
                                    COALESCE(Yson::ConvertToBool($kv.1), false)
                                )
                            ))
                        );
                    }
                )
            ))),
            $empty_dict
        )
    );
};

-- Оценки лежат словарём критерий -> список по разметчикам, поэтому достаём
-- значение по индексу разметчика. Если оценки нет, в первом этапе там уже 0.
$extract_worker_pointwise = ($pw_yson, $idx) -> {
    $pw_node = CAST($pw_yson AS Yson);
    RETURN IF(
        $pw_node IS NULL,
        $empty_dict,
        IF(
            Yson::IsDict($pw_node),
            Just(Yson::From(ToDict(
                ListMap(
                    DictItems(Yson::ConvertToDict($pw_node)),
                    ($kv) -> {
                        RETURN AsTuple(
                            CAST($kv.0 AS String),
                            Just(Yson::From(
                                IF(
                                    Yson::IsList($kv.1),
                                    COALESCE(Yson::ConvertToDouble(Yson::ConvertToList($kv.1)[$idx]), 0.0),
                                    COALESCE(Yson::ConvertToDouble($kv.1), 0.0)
                                )
                            ))
                        );
                    }
                )
            ))),
            $empty_dict
        )
    );
};

$extract_worker_annotations = ($annotations_yson, $idx) -> {
    $a_node = CAST($annotations_yson AS Yson);
    RETURN IF(
        $a_node IS NULL OR NOT Yson::IsList($a_node),
        $empty_list,
        Just(
            COALESCE(
                Yson::ConvertToList($a_node)[$idx],
                Just(Yson::From(AsList()))
            )
        )
    );
};

-- ==========================================================
-- ПОДГОТОВКА ТАБЛИЦ
-- ==========================================================

$judge_parsed = (
    SELECT
        t.assignment_id AS assignment_id,
        Just(Yson::From(ToDict(AsList(
            AsTuple("editor_comment_evaluation", Just(Yson::From(t.parsed.editor_comment_evaluation)))
        )))) AS comment_judge
    FROM (
        SELECT
            CAST(assignment_id AS String) AS assignment_id,
            $build_judge_answer(judge_answer) AS parsed
        FROM $input3
    ) AS t
);

$prep = (
    SELECT
        $str_yson(metadata.instruct_id) AS group_key,
        answer_A,
        answer_B,
        source_A,
        source_B,
        real_source_A,
        real_source_B,
        rownum,
        -- Тикет и корзину достаём из markup_metadata, а не отдельными
        -- колонками: в словаре они есть всегда, а колонки появились позже.
        $str_yson(markup_metadata.ticket) AS ticket,
        $str_yson(markup_metadata.basket_table) AS basket_table,
        assignment_ids,
        metadata,
        markers,
        annotations,
        checkboxes,
        markup_metadata,
        checkboxes_A,
        checkboxes_B,
        pointwise_A,
        pointwise_B,
        diff_pa,
        diff_pa_winner,
        direct_speech_A,
        direct_speech_B,
        general_comments,
        comments_A,
        comments_B,
        dialog,
        skip,
        source_winner,
        task_id,
        worker_ids,
        pool_id,
        project_id,
        editors_markup_dts,
        ListFromRange(0u, CAST(ListLength(assignment_ids) AS Uint64)) AS idxs
    FROM $input1
    WHERE $str_yson(metadata.instruct_id) != ""
);

$input2_prep = (
    SELECT
        $str_yson(metadata.instruct_id) AS group_key,
        task_summarization
    FROM $input2
    WHERE $str_yson(metadata.instruct_id) != ""
);

$input2_map = (
    SELECT
        group_key,
        SOME(task_summarization) AS task_summarization
    FROM $input2_prep
    GROUP BY group_key
);

$input4_prep = (
    SELECT
        $str_yson(input_meta.instruct_id) AS group_key,
        Just(answers) AS answers,
        Just(input_final_messages) AS input_final_messages, -- ДОБАВЛЕН Just()
        Just(input_meta) AS input_meta,                     -- ДОБАВЛЕН Just()
        Just(input_render_data) AS input_render_data
    FROM $input4
    WHERE $str_yson(input_meta.instruct_id) != ""
);
-- ==========================================================
-- СБОРКА AGG СТАРОЙ МАТЕМАТИКОЙ
-- ==========================================================

$rows = (
    SELECT
        p.group_key AS group_key,
        p.source_A AS source_A,
        p.source_B AS source_B,
        p.idxs AS idx,
        CAST(COALESCE(p.source_winner[p.idxs], "") AS String) AS sw_raw,
        CAST(COALESCE(p.diff_pa_winner[p.idxs], "") AS String) AS dp_raw,
        COALESCE(p.skip[p.idxs], false) AS skip_vote,
        COALESCE(p.diff_pa[p.idxs], false) AS diff_pa_vote,
        COALESCE(p.direct_speech_A[p.idxs], false) AS dsA_vote,
        COALESCE(p.direct_speech_B[p.idxs], false) AS dsB_vote,
        p.checkboxes_A AS cbA_yson,
        p.checkboxes_B AS cbB_yson
    FROM $prep AS p
    FLATTEN LIST BY (idxs)
);

$rows_norm = (
    SELECT
        r.*,
        CASE
            WHEN r.diff_pa_vote
                 AND (
                     r.dp_raw = r.source_A
                     OR r.dp_raw = r.source_B
                     OR r.dp_raw = "draw"
                     OR r.dp_raw = "both_bad"
                 )
            THEN r.dp_raw
            ELSE r.sw_raw
        END AS dp_eff_raw
    FROM $rows AS r
);

-- ==========================================================
-- ЧЕКБОКСЫ A АГГ
-- ==========================================================

$cbA_items = (
    SELECT
        x.group_key AS group_key,
        x.idx AS idx,
        CAST(x.items.0 AS String) AS cb_key,
        Just(x.items.1) AS cb_item
    FROM (
        SELECT
            rn.group_key AS group_key,
            rn.idx AS idx,
            DictItems(Yson::ConvertToDict(rn.cbA_yson)) AS items
        FROM $rows_norm AS rn
        WHERE rn.cbA_yson IS NOT NULL
          AND NOT Yson::IsList(rn.cbA_yson)
    ) AS x
    FLATTEN LIST BY (items)
    WHERE NOT $is_clarity_key(CAST(x.items.0 AS String))
);

$cbA_norm = (
    SELECT
        a.group_key AS group_key,
        a.cb_key AS cb_key,
        COALESCE(Yson::ConvertToBool(a.cb_item), false) AS cb_val
    FROM $cbA_items AS a
    WHERE Yson::IsBool(a.cb_item)

    UNION ALL

    SELECT
        a.group_key AS group_key,
        a.cb_key AS cb_key,
        COALESCE(Yson::ConvertToBool(a.vals[a.idx]), false) AS cb_val
    FROM (
        SELECT
            group_key,
            idx,
            cb_key,
            Yson::ConvertToList(cb_item) AS vals
        FROM $cbA_items
        WHERE Yson::IsList(cb_item)
    ) AS a
    WHERE CAST(ListLength(a.vals) AS Uint64) > a.idx
);

$cbA_instr = (
    SELECT
        k.group_key AS group_key,
        Just(Yson::From(ToDict(AGGREGATE_LIST(AsTuple(k.cb_key, k.cb_or))))) AS checkboxes_A
    FROM (
        SELECT
            n.group_key AS group_key,
            n.cb_key AS cb_key,
            MAX(CAST(n.cb_val AS Uint8)) > 0 AS cb_or
        FROM $cbA_norm AS n
        GROUP BY n.group_key, n.cb_key
    ) AS k
    GROUP BY k.group_key
);

$cbA_false_instr = (
    SELECT
        k.group_key AS group_key,
        Just(Yson::From(ToDict(AGGREGATE_LIST(AsTuple(k.cb_key, false))))) AS checkboxes_A
    FROM (
        SELECT
            n.group_key AS group_key,
            n.cb_key AS cb_key,
            MAX(CAST(n.cb_val AS Uint8)) > 0 AS cb_or
        FROM $cbA_norm AS n
        GROUP BY n.group_key, n.cb_key
    ) AS k
    GROUP BY k.group_key
);

-- ==========================================================
-- ЧЕКБОКСЫ B АГГ
-- ==========================================================

$cbB_items = (
    SELECT
        x.group_key AS group_key,
        x.idx AS idx,
        CAST(x.items.0 AS String) AS cb_key,
        Just(x.items.1) AS cb_item
    FROM (
        SELECT
            rn.group_key AS group_key,
            rn.idx AS idx,
            DictItems(Yson::ConvertToDict(rn.cbB_yson)) AS items
        FROM $rows_norm AS rn
        WHERE rn.cbB_yson IS NOT NULL
          AND NOT Yson::IsList(rn.cbB_yson)
    ) AS x
    FLATTEN LIST BY (items)
    WHERE NOT $is_clarity_key(CAST(x.items.0 AS String))
);

$cbB_norm = (
    SELECT
        a.group_key AS group_key,
        a.cb_key AS cb_key,
        COALESCE(Yson::ConvertToBool(a.cb_item), false) AS cb_val
    FROM $cbB_items AS a
    WHERE Yson::IsBool(a.cb_item)

    UNION ALL

    SELECT
        a.group_key AS group_key,
        a.cb_key AS cb_key,
        COALESCE(Yson::ConvertToBool(a.vals[a.idx]), false) AS cb_val
    FROM (
        SELECT
            group_key,
            idx,
            cb_key,
            Yson::ConvertToList(cb_item) AS vals
        FROM $cbB_items
        WHERE Yson::IsList(cb_item)
    ) AS a
    WHERE CAST(ListLength(a.vals) AS Uint64) > a.idx
);

$cbB_instr = (
    SELECT
        k.group_key AS group_key,
        Just(Yson::From(ToDict(AGGREGATE_LIST(AsTuple(k.cb_key, k.cb_or))))) AS checkboxes_B
    FROM (
        SELECT
            n.group_key AS group_key,
            n.cb_key AS cb_key,
            MAX(CAST(n.cb_val AS Uint8)) > 0 AS cb_or
        FROM $cbB_norm AS n
        GROUP BY n.group_key, n.cb_key
    ) AS k
    GROUP BY k.group_key
);

$cbB_false_instr = (
    SELECT
        k.group_key AS group_key,
        Just(Yson::From(ToDict(AGGREGATE_LIST(AsTuple(k.cb_key, false))))) AS checkboxes_B
    FROM (
        SELECT
            n.group_key AS group_key,
            n.cb_key AS cb_key,
            MAX(CAST(n.cb_val AS Uint8)) > 0 AS cb_or
        FROM $cbB_norm AS n
        GROUP BY n.group_key, n.cb_key
    ) AS k
    GROUP BY k.group_key
);

-- ==========================================================
-- POINTWISE A АГГ
-- ==========================================================
-- Первый этап отдаёт словарь критерий -> список оценок по разметчикам, где 0
-- значит «критерий не оценили». Разворачиваем словарь в пары, разворачиваем
-- список оценок и берём среднее по ненулевым: иначе один неоценивший
-- разметчик тянул бы средний балл вниз. Если критерий не оценил никто и там
-- одни нули, средним остаётся 0 — критерий не должен исчезать из словаря.
-- overall отдельного разбора не требует: он лежит там же обычным ключом.

$pwA_dict_items = (
    SELECT
        x.group_key AS group_key,
        x.items AS kv
    FROM (
        SELECT
            p.group_key AS group_key,
            DictItems(Yson::ConvertToDict(p.pointwise_A)) AS items
        FROM $prep AS p
        WHERE p.pointwise_A IS NOT NULL
          AND Yson::IsDict(p.pointwise_A)
    ) AS x
    FLATTEN LIST BY (items)
);

$pwA_flat_vals = (
    SELECT
        x.group_key AS group_key,
        CAST(x.kv.0 AS String) AS pw_key,
        CAST(Yson::ConvertToDouble(x.vals) AS Double) AS pw_val
    FROM (
        SELECT
            d.group_key AS group_key,
            d.kv AS kv,
            Yson::ConvertToList(d.kv.1) AS vals
        FROM $pwA_dict_items AS d
        WHERE Yson::IsList(d.kv.1)
    ) AS x
    FLATTEN LIST BY (vals)
);

$pwA_agg = (
    SELECT
        group_key,
        pw_key,
        COALESCE(AVG(IF(pw_val != 0.0, pw_val, NULL)), 0.0) AS pw_avg
    FROM $pwA_flat_vals
    GROUP BY group_key, pw_key
);

$pwA_instr = (
    SELECT
        k.group_key AS group_key,
        Just(Yson::From(ToDict(AGGREGATE_LIST(AsTuple(k.pw_key, k.pw_avg))))) AS pointwise_A
    FROM $pwA_agg AS k
    GROUP BY k.group_key
);

-- ==========================================================
-- POINTWISE B АГГ
-- ==========================================================

$pwB_dict_items = (
    SELECT
        x.group_key AS group_key,
        x.items AS kv
    FROM (
        SELECT
            p.group_key AS group_key,
            DictItems(Yson::ConvertToDict(p.pointwise_B)) AS items
        FROM $prep AS p
        WHERE p.pointwise_B IS NOT NULL
          AND Yson::IsDict(p.pointwise_B)
    ) AS x
    FLATTEN LIST BY (items)
);

$pwB_flat_vals = (
    SELECT
        x.group_key AS group_key,
        CAST(x.kv.0 AS String) AS pw_key,
        CAST(Yson::ConvertToDouble(x.vals) AS Double) AS pw_val
    FROM (
        SELECT
            d.group_key AS group_key,
            d.kv AS kv,
            Yson::ConvertToList(d.kv.1) AS vals
        FROM $pwB_dict_items AS d
        WHERE Yson::IsList(d.kv.1)
    ) AS x
    FLATTEN LIST BY (vals)
);

$pwB_agg = (
    SELECT
        group_key,
        pw_key,
        COALESCE(AVG(IF(pw_val != 0.0, pw_val, NULL)), 0.0) AS pw_avg
    FROM $pwB_flat_vals
    GROUP BY group_key, pw_key
);

$pwB_instr = (
    SELECT
        k.group_key AS group_key,
        Just(Yson::From(ToDict(AGGREGATE_LIST(AsTuple(k.pw_key, k.pw_avg))))) AS pointwise_B
    FROM $pwB_agg AS k
    GROUP BY k.group_key
);

-- ==========================================================
-- БУЛЕВЫ ФЛАГИ АГГ
-- ==========================================================

$flags_instr = (
    SELECT
        rn.group_key AS group_key,
        CASE
            WHEN COUNT(*) = 2 THEN SUM(CASE WHEN rn.diff_pa_vote THEN 1 ELSE 0 END) >= 1
            ELSE 2 * SUM(CASE WHEN rn.diff_pa_vote THEN 1 ELSE 0 END) > COUNT(*)
        END AS diff_pa,
        CASE
            WHEN COUNT(*) = 2 THEN SUM(CASE WHEN rn.dsA_vote THEN 1 ELSE 0 END) >= 1
            ELSE 2 * SUM(CASE WHEN rn.dsA_vote THEN 1 ELSE 0 END) > COUNT(*)
        END AS direct_speech_A,
        CASE
            WHEN COUNT(*) = 2 THEN SUM(CASE WHEN rn.dsB_vote THEN 1 ELSE 0 END) >= 1
            ELSE 2 * SUM(CASE WHEN rn.dsB_vote THEN 1 ELSE 0 END) > COUNT(*)
        END AS direct_speech_B
    FROM $rows_norm AS rn
    GROUP BY rn.group_key
);

-- ==========================================================
-- СОГЛАСИЕ И СИЛА АГГ
-- ==========================================================

$votes = (
    SELECT
        rn.group_key AS group_key,
        SOME(rn.source_A) AS source_A,
        SOME(rn.source_B) AS source_B,
        SUM(CASE WHEN rn.skip_vote THEN 1 ELSE 0 END) AS skip_yes,
        COUNT(*) AS skip_n,
        SUM(CASE WHEN rn.sw_raw = rn.source_A THEN 1 ELSE 0 END) AS sw_A,
        SUM(CASE WHEN rn.sw_raw = rn.source_B THEN 1 ELSE 0 END) AS sw_B,
        SUM(CASE WHEN rn.sw_raw = "draw" THEN 1 ELSE 0 END) AS sw_dr,
        SUM(CASE WHEN rn.sw_raw = "both_bad" THEN 1 ELSE 0 END) AS sw_bb,
        SUM(CASE WHEN rn.sw_raw = rn.source_A OR rn.sw_raw = rn.source_B OR rn.sw_raw = "draw" OR rn.sw_raw = "both_bad" THEN 1 ELSE 0 END) AS sw_n,
        SUM(CASE WHEN rn.dp_eff_raw = rn.source_A THEN 1 ELSE 0 END) AS dp_A,
        SUM(CASE WHEN rn.dp_eff_raw = rn.source_B THEN 1 ELSE 0 END) AS dp_B,
        SUM(CASE WHEN rn.dp_eff_raw = "draw" THEN 1 ELSE 0 END) AS dp_dr,
        SUM(CASE WHEN rn.dp_eff_raw = "both_bad" THEN 1 ELSE 0 END) AS dp_bb,
        SUM(CASE WHEN rn.dp_eff_raw = rn.source_A OR rn.dp_eff_raw = rn.source_B OR rn.dp_eff_raw = "draw" OR rn.dp_eff_raw = "both_bad" THEN 1 ELSE 0 END) AS dp_n
    FROM $rows_norm AS rn
    GROUP BY rn.group_key
);

$agg = (
    SELECT
        v.group_key AS group_key,

        CASE
            WHEN v.skip_n = 2 THEN v.skip_yes >= 1
            ELSE 2 * v.skip_yes > v.skip_n
        END AS skip,

        CASE
            WHEN v.sw_n = 0 THEN NULL
            WHEN v.sw_n = 1 THEN 1.0
            ELSE (
                (
                    ((v.sw_A * (v.sw_A - 1)) / 2)
                    + ((v.sw_B * (v.sw_B - 1)) / 2)
                    + ((v.sw_dr * (v.sw_dr - 1)) / 2)
                    + ((v.sw_bb * (v.sw_bb - 1)) / 2)
                    + (v.sw_dr * v.sw_bb)
                    + 0.5 * (
                        v.sw_A * v.sw_dr
                        + v.sw_B * v.sw_dr
                        + v.sw_A * v.sw_bb
                        + v.sw_B * v.sw_bb
                    )
                ) / CAST((v.sw_n * (v.sw_n - 1)) / 2 AS Double)
            )
        END AS winner_agreement,

        CASE
            WHEN v.dp_n = 0 THEN NULL
            WHEN v.dp_n = 1 THEN 1.0
            ELSE (
                (
                    ((v.dp_A * (v.dp_A - 1)) / 2)
                    + ((v.dp_B * (v.dp_B - 1)) / 2)
                    + ((v.dp_dr * (v.dp_dr - 1)) / 2)
                    + ((v.dp_bb * (v.dp_bb - 1)) / 2)
                    + (v.dp_dr * v.dp_bb)
                    + 0.5 * (
                        v.dp_A * v.dp_dr
                        + v.dp_B * v.dp_dr
                        + v.dp_A * v.dp_bb
                        + v.dp_B * v.dp_bb
                    )
                ) / CAST((v.dp_n * (v.dp_n - 1)) / 2 AS Double)
            )
        END AS diff_pa_winner_agreement,

        CASE
            WHEN (
                CASE
                    WHEN v.skip_n = 2 THEN v.skip_yes >= 1
                    ELSE 2 * v.skip_yes > v.skip_n
                END
            ) OR v.sw_n = 0 THEN NULL
            WHEN 2 * v.sw_A > v.sw_n THEN v.source_A
            WHEN 2 * v.sw_B > v.sw_n THEN v.source_B
            WHEN 2 * v.sw_dr > v.sw_n THEN "draw"
            WHEN 2 * v.sw_bb > v.sw_n THEN "both_bad"
            ELSE
                CASE
                    WHEN v.sw_bb > 0 THEN "both_bad"
                    WHEN v.sw_n = 2 AND v.sw_A = 1 AND (v.sw_dr = 1 OR v.sw_bb = 1) THEN v.source_A
                    WHEN v.sw_n = 2 AND v.sw_B = 1 AND (v.sw_dr = 1 OR v.sw_bb = 1) THEN v.source_B
                    WHEN v.sw_dr > 0 THEN "draw"
                    WHEN v.sw_n = 2 AND v.sw_A = 1 AND v.sw_B = 1 THEN "draw"
                    ELSE "both_bad"
                END
        END AS winner_internal,

        CASE
            WHEN (
                CASE
                    WHEN v.skip_n = 2 THEN v.skip_yes >= 1
                    ELSE 2 * v.skip_yes > v.skip_n
                END
            ) OR v.dp_n = 0 THEN NULL
            WHEN 2 * v.dp_A > v.dp_n THEN v.source_A
            WHEN 2 * v.dp_B > v.dp_n THEN v.source_B
            WHEN 2 * v.dp_dr > v.dp_n THEN "draw"
            WHEN 2 * v.dp_bb > v.dp_n THEN "both_bad"
            ELSE
                CASE
                    WHEN v.dp_bb > 0 THEN "both_bad"
                    WHEN v.dp_n = 2 AND v.dp_A = 1 AND (v.dp_dr = 1 OR v.dp_bb = 1) THEN v.source_A
                    WHEN v.dp_n = 2 AND v.dp_B = 1 AND (v.dp_dr = 1 OR v.dp_bb = 1) THEN v.source_B
                    WHEN v.dp_dr > 0 THEN "draw"
                    WHEN v.dp_n = 2 AND v.dp_A = 1 AND v.dp_B = 1 THEN "draw"
                    ELSE "both_bad"
                END
        END AS diff_pa_winner_internal,

        CASE
            WHEN (
                CASE
                    WHEN v.skip_n = 2 THEN v.skip_yes >= 1
                    ELSE 2 * v.skip_yes > v.skip_n
                END
            ) OR v.sw_n = 0 THEN NULL
            WHEN v.sw_n = 1 THEN "strong"
            WHEN (
                (
                    ((v.sw_A * (v.sw_A - 1)) / 2)
                    + ((v.sw_B * (v.sw_B - 1)) / 2)
                    + ((v.sw_dr * (v.sw_dr - 1)) / 2)
                    + ((v.sw_bb * (v.sw_bb - 1)) / 2)
                    + (v.sw_dr * v.sw_bb)
                    + 0.5 * (
                        v.sw_A * v.sw_dr
                        + v.sw_B * v.sw_dr
                        + v.sw_A * v.sw_bb
                        + v.sw_B * v.sw_bb
                    )
                ) / CAST((v.sw_n * (v.sw_n - 1)) / 2 AS Double)
            ) >= 2.0 / 3.0 THEN "strong"
            ELSE "weak"
        END AS winner_strength,

        CASE
            WHEN (
                CASE
                    WHEN v.skip_n = 2 THEN v.skip_yes >= 1
                    ELSE 2 * v.skip_yes > v.skip_n
                END
            ) OR v.dp_n = 0 THEN NULL
            WHEN v.dp_n = 1 THEN "strong"
            WHEN (
                (
                    ((v.dp_A * (v.dp_A - 1)) / 2)
                    + ((v.dp_B * (v.dp_B - 1)) / 2)
                    + ((v.dp_dr * (v.dp_dr - 1)) / 2)
                    + ((v.dp_bb * (v.dp_bb - 1)) / 2)
                    + (v.dp_dr * v.dp_bb)
                    + 0.5 * (
                        v.dp_A * v.dp_dr
                        + v.dp_B * v.dp_dr
                        + v.dp_A * v.dp_bb
                        + v.dp_B * v.dp_bb
                    )
                ) / CAST((v.dp_n * (v.dp_n - 1)) / 2 AS Double)
            ) >= 2.0 / 3.0 THEN "strong"
            ELSE "weak"
        END AS diff_pa_winner_strength

    FROM $votes AS v
);

$metadata_rows = (
    SELECT
        group_key,
        SOME(answer_A) AS answer_A,
        SOME(answer_B) AS answer_B,
        SOME(source_A) AS source_A,
        SOME(source_B) AS source_B,
        SOME(real_source_A) AS real_source_A,
        SOME(real_source_B) AS real_source_B,
        SOME(rownum) AS rownum,
        SOME(ticket) AS ticket,
        SOME(basket_table) AS basket_table,
        SOME(assignment_ids) AS assignment_ids,
        SOME(metadata) AS metadata,
        SOME(markers) AS markers,
        SOME(annotations) AS annotations,
        SOME(checkboxes) AS checkboxes,
        SOME(markup_metadata) AS markup_metadata,
        SOME(task_id) AS task_id,
        SOME(worker_ids) AS worker_ids,
        SOME(pool_id) AS pool_id,
        SOME(project_id) AS project_id,
        SOME(general_comments) AS general_comments,
        SOME(comments_A) AS comments_A,
        SOME(comments_B) AS comments_B,
        SOME(dialog) AS dialog
    FROM $prep
    GROUP BY group_key
);

-- ==========================================================
-- СБОРКА RAW_OUTPUTS ДЛЯ RAW_TOV_MARKUP
-- ==========================================================

$workers_flat = (
    SELECT
        p.group_key AS group_key,
        CAST(COALESCE(p.worker_ids[p.idxs], "") AS String) AS worker_id,

        Just(Yson::From(ToDict(AsList(
            AsTuple("worker_id", Just(Yson::From(CAST(COALESCE(p.worker_ids[p.idxs], "") AS String)))),
            AsTuple("assignment_id", Just(Yson::From(CAST(p.assignment_ids[p.idxs] AS String)))),
            AsTuple("assignment_link", Just(Yson::From("https://yang.yandex-team.ru/task/" || CAST(p.pool_id AS String) || "/" || CAST(p.assignment_ids[p.idxs] AS String)))),

            AsTuple("annotations", COALESCE($extract_worker_annotations(p.annotations, p.idxs), $empty_list)),
            AsTuple("checkboxes_A", COALESCE($extract_worker_checkboxes(p.checkboxes_A, p.idxs), $empty_dict)),
            AsTuple("checkboxes_B", COALESCE($extract_worker_checkboxes(p.checkboxes_B, p.idxs), $empty_dict)),
            AsTuple("pointwise_A", COALESCE($extract_worker_pointwise(p.pointwise_A, p.idxs), $empty_dict)),
            AsTuple("pointwise_B", COALESCE($extract_worker_pointwise(p.pointwise_B, p.idxs), $empty_dict)),

            AsTuple("comment_A", Just(Yson::From($str_yson(p.comments_A[p.idxs])))),
            AsTuple("comment_B", Just(Yson::From($str_yson(p.comments_B[p.idxs])))),
            AsTuple("general_comment", Just(Yson::From($str_yson(p.general_comments[p.idxs])))),
            AsTuple("comment_judge", COALESCE(j.comment_judge, $empty_dict)),

            AsTuple("diff_pa", Just(Yson::From(p.diff_pa[p.idxs]))),
            AsTuple("diff_pa_winner", Just(Yson::From(CAST(COALESCE(p.diff_pa_winner[p.idxs], "") AS String)))),
            AsTuple("direct_speech_A", Just(Yson::From(p.direct_speech_A[p.idxs]))),
            AsTuple("direct_speech_B", Just(Yson::From(p.direct_speech_B[p.idxs]))),
            AsTuple("markup_dt", Just(Yson::From(CAST(COALESCE(p.editors_markup_dts[p.idxs], "") AS String)))),
            AsTuple("skip", Just(Yson::From(p.skip[p.idxs]))),
            -- ИЗМЕНЕНО: source_winner -> winner
            AsTuple("winner", Just(Yson::From(CAST(COALESCE(p.source_winner[p.idxs], "") AS String))))
        )))) AS raw_output_item
    FROM $prep AS p
    FLATTEN LIST BY (idxs)
    LEFT JOIN $judge_parsed AS j
        ON CAST(p.assignment_ids[p.idxs] AS String) = j.assignment_id
);

$raw_outputs_by_worker = (
    SELECT
        group_key,
        worker_id,
        SOME(CAST(raw_output_item AS String)) AS raw_output_str
    FROM $workers_flat
    WHERE worker_id != ""
    GROUP BY group_key, worker_id
);

$raw_outputs_agg = (
    SELECT
        group_key,
        Just(Yson::From(
            ListMap(
                AGGREGATE_LIST(raw_output_str),
                ($s) -> { RETURN Yson::Parse(COALESCE($s, "{}")); }
            )
        )) AS raw_outputs
    FROM $raw_outputs_by_worker
    GROUP BY group_key
);

-- ==========================================================
-- СБОРКА MARKUP
-- ==========================================================

$result_markup = (
    SELECT
        m.group_key AS group_key,

        -- Плоский агрегат по заданию: то же, что в словаре, но колонками.
        -- Комментарии сюда не идут — они поразметчиковые, сворачивать их не во
        -- что; за ними в raw_tov_markup.
        $str_string(m.task_id) AS task_id,
        m.rownum AS rownum,
        m.pool_id AS pool_id,
        m.project_id AS project_id,
        m.ticket AS ticket,
        m.basket_table AS basket_table,

        m.answer_A AS answer_A,
        m.answer_B AS answer_B,
        m.source_A AS source_A,
        m.source_B AS source_B,
        m.real_source_A AS real_source_A,
        m.real_source_B AS real_source_B,

        m.worker_ids AS worker_ids,
        m.assignment_ids AS assignment_ids,

        COALESCE(a.skip, false) AS skip,
        a.winner_internal AS winner,
        a.winner_agreement AS winner_agreement,
        a.winner_strength AS winner_strength,

        CASE WHEN COALESCE(a.skip, false) THEN false ELSE f.diff_pa END AS diff_pa,
        a.diff_pa_winner_internal AS diff_pa_winner,
        a.diff_pa_winner_agreement AS diff_pa_winner_agreement,
        a.diff_pa_winner_strength AS diff_pa_winner_strength,

        CASE WHEN COALESCE(a.skip, false) THEN false ELSE f.direct_speech_A END AS direct_speech_A,
        CASE WHEN COALESCE(a.skip, false) THEN false ELSE f.direct_speech_B END AS direct_speech_B,

        COALESCE(
            CASE
                WHEN COALESCE(a.skip, false) THEN cA0.checkboxes_A
                ELSE cA.checkboxes_A
            END,
            $empty_dict
        ) AS checkboxes_A,
        COALESCE(
            CASE
                WHEN COALESCE(a.skip, false) THEN cB0.checkboxes_B
                ELSE cB.checkboxes_B
            END,
            $empty_dict
        ) AS checkboxes_B,

        COALESCE(pwA.pointwise_A, $empty_dict) AS pointwise_A,
        COALESCE(pwB.pointwise_B, $empty_dict) AS pointwise_B,

        COALESCE(m.markers, $empty_list) AS markers,
        COALESCE(m.checkboxes, $empty_dict) AS checkboxes,
        COALESCE(m.markup_metadata, $empty_dict) AS markup_metadata,
        i2.task_summarization AS task_summarization,

        Just(Yson::From(ToDict(AsList(
            AsTuple("answer_A", Just(Yson::From(m.answer_A))),
            AsTuple("answer_B", Just(Yson::From(m.answer_B))),
            AsTuple("task_id", Just(Yson::From($str_string(m.task_id)))),
            AsTuple("ticket", Just(Yson::From(m.ticket))),
            AsTuple("basket_table", Just(Yson::From(m.basket_table))),
            AsTuple("pool_id", Just(Yson::From(m.pool_id))),
            AsTuple("project_id", Just(Yson::From(m.project_id))),
            -- Обвязка задания собрана первым этапом, здесь идёт как есть.
            AsTuple("markup_metadata", COALESCE(m.markup_metadata, $empty_dict)),
            AsTuple("worker_ids", Just(Yson::From(m.worker_ids))),

            AsTuple(
                "checkboxes_A",
                COALESCE(
                    CASE
                        WHEN COALESCE(a.skip, false) THEN cA0.checkboxes_A
                        ELSE cA.checkboxes_A
                    END,
                    $empty_dict
                )
            ),
            AsTuple(
                "checkboxes_B",
                COALESCE(
                    CASE
                        WHEN COALESCE(a.skip, false) THEN cB0.checkboxes_B
                        ELSE cB.checkboxes_B
                    END,
                    $empty_dict
                )
            ),
            -- У пропущенного задания оценок нет, поэтому там пустой словарь.
            AsTuple(
                "pointwise_A",
                COALESCE(
                    CASE
                        WHEN COALESCE(a.skip, false) THEN $empty_dict
                        ELSE pwA.pointwise_A
                    END,
                    $empty_dict
                )
            ),
            AsTuple(
                "pointwise_B",
                COALESCE(
                    CASE
                        WHEN COALESCE(a.skip, false) THEN $empty_dict
                        ELSE pwB.pointwise_B
                    END,
                    $empty_dict
                )
            ),
            AsTuple("comments_A", Just(Yson::From(m.comments_A))),
            AsTuple("comments_B", Just(Yson::From(m.comments_B))),
            AsTuple("diff_pa", Just(Yson::From(CASE WHEN COALESCE(a.skip, false) THEN false ELSE f.diff_pa END))),
            AsTuple("diff_pa_winner", Just(Yson::From(a.diff_pa_winner_internal))),
            AsTuple("diff_pa_winner_agreement", Just(Yson::From(a.diff_pa_winner_agreement))),
            AsTuple("diff_pa_winner_strength", Just(Yson::From(a.diff_pa_winner_strength))),
            AsTuple("direct_speech_A", Just(Yson::From(CASE WHEN COALESCE(a.skip, false) THEN false ELSE f.direct_speech_A END))),
            AsTuple("direct_speech_B", Just(Yson::From(CASE WHEN COALESCE(a.skip, false) THEN false ELSE f.direct_speech_B END))),
            AsTuple("general_comments", Just(Yson::From(m.general_comments))),
            AsTuple(
                "annotations",
                COALESCE(
                    CASE
                        WHEN COALESCE(a.skip, false) THEN Just(Yson::From(AsList()))
                        ELSE m.annotations
                    END,
                    Just(Yson::From(AsList()))
                )
            ),
            AsTuple("source_A", Just(Yson::From(m.source_A))),
            AsTuple("source_B", Just(Yson::From(m.source_B))),
            AsTuple("real_source_A", Just(Yson::From(m.real_source_A))),
            AsTuple("real_source_B", Just(Yson::From(m.real_source_B))),

            -- ИЗМЕНЕНО: убрана приставка source_
            AsTuple("winner", Just(Yson::From(a.winner_internal))),
            AsTuple("winner_agreement", Just(Yson::From(a.winner_agreement))),
            AsTuple("winner_strength", Just(Yson::From(a.winner_strength))),

            AsTuple("skip", Just(Yson::From(a.skip))),
            AsTuple("task_summarization", Just(Yson::From(i2.task_summarization)))
        )))) AS tov_markup,

        Just(Yson::From(ToDict(AsList(
            AsTuple("task_id", Just(Yson::From($str_string(m.task_id)))),
            AsTuple("ticket", Just(Yson::From(m.ticket))),
            AsTuple("basket_table", Just(Yson::From(m.basket_table))),
            AsTuple("pool_id", Just(Yson::From(m.pool_id))),
            AsTuple("project_id", Just(Yson::From(m.project_id))),
            AsTuple("markup_metadata", COALESCE(m.markup_metadata, $empty_dict)),

            AsTuple("answer_A", Just(Yson::From(m.answer_A))),
            AsTuple("answer_B", Just(Yson::From(m.answer_B))),
            AsTuple("source_A", Just(Yson::From(m.source_A))),
            AsTuple("source_B", Just(Yson::From(m.source_B))),
            AsTuple("real_source_A", Just(Yson::From(m.real_source_A))),
            AsTuple("real_source_B", Just(Yson::From(m.real_source_B))),

            AsTuple("checkboxes", COALESCE(m.checkboxes, $empty_dict)),
            AsTuple("markers", COALESCE(m.markers, $empty_list)),
            AsTuple("raw_outputs", COALESCE(roa.raw_outputs, $empty_list))
        )))) AS raw_tov_markup

    FROM $metadata_rows AS m
    LEFT JOIN $agg AS a
        ON m.group_key = a.group_key
    LEFT JOIN $flags_instr AS f
        ON m.group_key = f.group_key
    LEFT JOIN $cbA_instr AS cA
        ON m.group_key = cA.group_key
    LEFT JOIN $cbB_instr AS cB
        ON m.group_key = cB.group_key
    LEFT JOIN $cbA_false_instr AS cA0
        ON m.group_key = cA0.group_key
    LEFT JOIN $cbB_false_instr AS cB0
        ON m.group_key = cB0.group_key
    LEFT JOIN $pwA_instr AS pwA
        ON m.group_key = pwA.group_key
    LEFT JOIN $pwB_instr AS pwB
        ON m.group_key = pwB.group_key
    LEFT JOIN $input2_map AS i2
        ON m.group_key = i2.group_key
    LEFT JOIN $raw_outputs_agg AS roa
        ON m.group_key = roa.group_key
);

-- ==========================================================
-- ВЫХОД 1: АГРЕГАТ ПЛОСКИМИ КОЛОНКАМИ
-- ==========================================================

INSERT INTO $output1
WITH TRUNCATE
SELECT
    rm.group_key AS instruct_id,
    rm.task_id AS task_id,
    rm.rownum AS rownum,
    rm.pool_id AS pool_id,
    rm.project_id AS project_id,
    rm.ticket AS ticket,
    rm.basket_table AS basket_table,

    rm.answer_A AS answer_A,
    rm.answer_B AS answer_B,
    rm.source_A AS source_A,
    rm.source_B AS source_B,
    rm.real_source_A AS real_source_A,
    rm.real_source_B AS real_source_B,

    rm.worker_ids AS worker_ids,
    rm.assignment_ids AS assignment_ids,

    rm.skip AS skip,
    rm.winner AS winner,
    rm.winner_agreement AS winner_agreement,
    rm.winner_strength AS winner_strength,

    rm.diff_pa AS diff_pa,
    rm.diff_pa_winner AS diff_pa_winner,
    rm.diff_pa_winner_agreement AS diff_pa_winner_agreement,
    rm.diff_pa_winner_strength AS diff_pa_winner_strength,

    rm.direct_speech_A AS direct_speech_A,
    rm.direct_speech_B AS direct_speech_B,

    rm.checkboxes_A AS checkboxes_A,
    rm.checkboxes_B AS checkboxes_B,
    rm.pointwise_A AS pointwise_A,
    rm.pointwise_B AS pointwise_B,

    rm.markers AS markers,
    rm.checkboxes AS checkboxes,
    rm.markup_metadata AS markup_metadata,
    rm.task_summarization AS task_summarization
FROM $result_markup AS rm;

-- ==========================================================
-- ВЫХОД 2: ВХОД 4 КАК ЕСТЬ + СЛОВАРИ РАЗМЕТКИ
-- ==========================================================

INSERT INTO $output2
WITH TRUNCATE
SELECT
    i4.answers AS answers,
    i4.input_final_messages AS input_final_messages,
    i4.input_meta AS input_meta,
    i4.input_render_data AS input_render_data,

    rm.tov_markup AS agg_tov_markup,
    rm.raw_tov_markup AS raw_tov_markup
FROM $input4_prep AS i4
INNER JOIN $result_markup AS rm
    ON i4.group_key = rm.group_key
;
