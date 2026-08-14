PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;

DECLARE $input1 AS String;  -- raw: поразметчиковые списки по заданию
DECLARE $input2 AS String;  -- второй выход agg: answers / input_* / словари разметки
DECLARE $output1 AS String; -- строка на разметчика (будущий raw storage)
DECLARE $output2 AS String; -- строка на задание (будущий agg storage)

$str = ($x) -> (NVL(Yson::ConvertToString($x), ""));
$i64 = ($x) -> (Yson::ConvertToInt64($x));
$bool = ($x) -> (Yson::ConvertToBool($x) ?? false);

-- Оценка приходит и целым, и дробным узлом, поэтому пробуем оба типа.
$dbl = ($x) -> (
    COALESCE(
        Yson::ConvertToDouble($x),
        CAST(Yson::ConvertToInt64($x) AS Double)
    )
);

$empty_dict = Just(Yson::From(ToDict(AsList())));
$empty_list = Just(Yson::From(AsList()));

$list_len_or_zero = ($list) -> (
    IF($list IS NULL, 0u, ListLength($list))
);

-- Узел словаря отдаём колонкой как есть; пустой словарь вместо NULL, чтобы
-- колонка всегда была одного вида.
$node_or_empty_dict = ($x) -> (
    IF($x IS NULL, $empty_dict, Just(Yson::From($x)))
);

$node_or_empty_list = ($x) -> (
    IF($x IS NULL, $empty_list, Just(Yson::From($x)))
);

-- Чекбоксы и оценки лежат словарём ключ -> список по разметчикам, поэтому
-- значение берётся по позиции разметчика. Позиции во всех ключах означают
-- одного и того же человека: первый этап сортирует всё по assignment_id.
$checkboxes_worker = ($node, $idx) -> (
    IF(
        $node IS NULL OR NOT Yson::IsDict($node),
        $empty_dict,
        Just(Yson::From(ToDict(
            ListMap(
                DictItems(Yson::ConvertToDict($node)),
                ($kv) -> (
                    AsTuple(
                        CAST($kv.0 AS String),
                        IF(
                            Yson::IsList($kv.1),
                            $bool(Yson::ConvertToList($kv.1)[$idx]),
                            $bool($kv.1)
                        )
                    )
                )
            )
        )))
    )
);

-- Нет оценки — 0, ровно как это делает агрегат.
$pointwise_worker = ($node, $idx) -> (
    IF(
        $node IS NULL OR NOT Yson::IsDict($node),
        $empty_dict,
        Just(Yson::From(ToDict(
            ListMap(
                DictItems(Yson::ConvertToDict($node)),
                ($kv) -> (
                    AsTuple(
                        CAST($kv.0 AS String),
                        IF(
                            Yson::IsList($kv.1),
                            COALESCE($dbl(Yson::ConvertToList($kv.1)[$idx]), 0.0),
                            COALESCE($dbl($kv.1), 0.0)
                        )
                    )
                )
            )
        )))
    )
);

-- Выделения текста в старой раскладке marker_text_parts: первый этап отдаёт
-- их аннотациями, где куски лежат в ranges, а сторона и комментарий — на самой
-- аннотации. Разворачиваем ranges и раскладываем по сторонам A/B.
$marker_parts_from_annotations = ($annotations, $side) -> (
    IF(
        $annotations IS NULL OR NOT Yson::IsList($annotations),
        AsList(),
        ListFlatMap(
            Yson::ConvertToList($annotations),
            ($ann) -> (
                IF(
                    $str($ann.side) != $side,
                    AsList(),
                    IF(
                        $ann.ranges IS NULL OR NOT Yson::IsList($ann.ranges),
                        AsList(),
                        ListMap(
                            Yson::ConvertToList($ann.ranges),
                            ($rng) -> (
                                <|
                                    "content": $str($rng.content),
                                    "comment": $str($ann.review.comment),
                                    "endIndex": $i64($rng.end),
                                    "id": $str($rng.id),
                                    "markdownEndIndex": $i64($rng.markdown_end),
                                    "markdownStartIndex": $i64($rng.markdown_start),
                                    "startIndex": $i64($rng.start),
                                    "type": $str($ann.type)
                                |>
                            )
                        )
                    )
                )
            )
        )
    )
);

-- Аннотации упакованы списком по разметчикам: на позиции разметчика лежит его
-- собственный список аннотаций.
$annotations_worker = ($packed, $idx) -> (
    IF(
        $packed IS NULL OR NOT Yson::IsList($packed),
        NULL,
        IF(
            ListLength(Yson::ConvertToList($packed)) > $idx,
            Yson::ConvertToList($packed)[$idx],
            NULL
        )
    )
);

$last_dialog_query = ($dialog) -> (
    IF(
        $dialog IS NULL OR NOT Yson::IsList($dialog) OR ListLength(Yson::ConvertToList($dialog)) = 0u,
        NULL,
        $str(
            Yson::ConvertToList($dialog)[
                ListLength(Yson::ConvertToList($dialog)) - 1u
            ].query
        )
    )
);

-- ==========================================================
-- ВТОРОЙ ВХОД: ЗАДАНИЕ ЦЕЛИКОМ
-- ==========================================================
-- Агрегат приходит словарями, а не плоскими колонками, поэтому то, что нужно
-- поразметчиковой строке, достаём из agg_tov_markup здесь.

$agg_src = (
    SELECT
        $str(input_meta.instruct_id) AS instruct_id,
        $str(agg_tov_markup.task_id) AS task_id,
        rownum,

        answers,
        input_final_messages,
        input_meta,
        input_render_data,

        agg_tov_markup,
        raw_tov_markup,

        $node_or_empty_dict(agg_tov_markup.markup_metadata) AS markup_metadata,
        $str(agg_tov_markup.markup_metadata.pool_id) AS pool_id,
        $str(agg_tov_markup.markup_metadata.project_id) AS project_id,

        $node_or_empty_dict(agg_tov_markup.checkboxes_A) AS checkboxes_A_agg,
        $node_or_empty_dict(agg_tov_markup.checkboxes_B) AS checkboxes_B_agg,
        $node_or_empty_dict(agg_tov_markup.pointwise_A) AS pointwise_A_agg,
        $node_or_empty_dict(agg_tov_markup.pointwise_B) AS pointwise_B_agg,

        $bool(agg_tov_markup.skip) AS skip_agg,
        $bool(agg_tov_markup.diff_pa) AS diff_pa_agg,
        $bool(agg_tov_markup.direct_speech_A) AS direct_speech_A_agg,
        $bool(agg_tov_markup.direct_speech_B) AS direct_speech_B_agg,

        $str(agg_tov_markup.winner) AS source_winner_agg,
        $str(agg_tov_markup.diff_pa_winner) AS diff_pa_winner_agg,
        $dbl(agg_tov_markup.winner_agreement) AS source_winner_agreement,
        $dbl(agg_tov_markup.diff_pa_winner_agreement) AS diff_pa_winner_agreement,
        $str(agg_tov_markup.winner_strength) AS source_winner_strength,
        $str(agg_tov_markup.diff_pa_winner_strength) AS diff_pa_winner_strength,

        $str(agg_tov_markup.real_source_A) AS real_source_A,
        $str(agg_tov_markup.real_source_B) AS real_source_B,
        $str(agg_tov_markup.task_summarization) AS task_summarization
    FROM $input2
);

-- ==========================================================
-- ПЕРВЫЙ ВХОД: СТРОКА НА РАЗМЕТЧИКА
-- ==========================================================

$prep = (
    SELECT
        t.*,
        $str(t.metadata.instruct_id) AS instruct_id,
        $str(t.markup_metadata.pool_id) AS pool_id,
        $str(t.markup_metadata.project_id) AS project_id,
        CAST($list_len_or_zero(t.assignment_ids) AS Int64) AS task_count,
        ListFromRange(0u, $list_len_or_zero(t.assignment_ids)) AS idxs
    FROM $input1 AS t
);

$worker_rows = (
    SELECT
        p.instruct_id AS instruct_id,
        CAST(p.task_id AS String) AS task_id,
        p.rownum AS rownum,
        p.pool_id AS pool_id,
        p.project_id AS project_id,
        p.task_count AS task_count,

        p.answer_A AS answer_A,
        p.answer_B AS answer_B,
        p.source_A AS source_A,
        p.source_B AS source_B,
        p.real_source_A AS real_source_A,
        p.real_source_B AS real_source_B,

        p.checkboxes AS checkboxes,
        p.dialog AS dialog,
        p.markers AS markers,
        p.metadata AS metadata,
        $last_dialog_query(p.dialog) AS instruct,

        IF(p.assignment_ids[p.idxs] IS NULL, "", p.assignment_ids[p.idxs]) AS assignment_id,
        IF(p.worker_ids[p.idxs] IS NULL, "", p.worker_ids[p.idxs]) AS worker_id,
        IF(p.editors_markup_dts[p.idxs] IS NULL, "", p.editors_markup_dts[p.idxs]) AS editors_markup_dt,

        IF(
            p.assignment_ids[p.idxs] IS NULL OR p.assignment_ids[p.idxs] = "",
            "",
            "https://yang.yandex-team.ru/task/" || p.pool_id || "/" || p.assignment_ids[p.idxs]
        ) AS assignment_link,

        IF(p.skip[p.idxs] IS NULL, false, p.skip[p.idxs]) AS skip_worker,
        IF(p.diff_pa[p.idxs] IS NULL, false, p.diff_pa[p.idxs]) AS diff_pa_worker,
        IF(p.direct_speech_A[p.idxs] IS NULL, false, p.direct_speech_A[p.idxs]) AS direct_speech_A_worker,
        IF(p.direct_speech_B[p.idxs] IS NULL, false, p.direct_speech_B[p.idxs]) AS direct_speech_B_worker,

        IF(p.source_winner[p.idxs] IS NULL, "", p.source_winner[p.idxs]) AS source_winner_worker,
        IF(p.diff_pa_winner[p.idxs] IS NULL, "", p.diff_pa_winner[p.idxs]) AS diff_pa_winner_worker,

        IF(p.general_comments[p.idxs] IS NULL, "", p.general_comments[p.idxs]) AS general_comment_worker,
        IF(p.comments_A[p.idxs] IS NULL, "", p.comments_A[p.idxs]) AS comments_A_worker,
        IF(p.comments_B[p.idxs] IS NULL, "", p.comments_B[p.idxs]) AS comments_B_worker,

        $checkboxes_worker(p.checkboxes_A, p.idxs) AS checkboxes_A_worker,
        $checkboxes_worker(p.checkboxes_B, p.idxs) AS checkboxes_B_worker,
        $pointwise_worker(p.pointwise_A, p.idxs) AS pointwise_A_worker,
        $pointwise_worker(p.pointwise_B, p.idxs) AS pointwise_B_worker,

        $node_or_empty_list($annotations_worker(p.annotations, p.idxs)) AS annotations_worker,
        Just(Yson::From(
            $marker_parts_from_annotations($annotations_worker(p.annotations, p.idxs), "A")
        )) AS marker_text_parts_A_worker,
        Just(Yson::From(
            $marker_parts_from_annotations($annotations_worker(p.annotations, p.idxs), "B")
        )) AS marker_text_parts_B_worker
    FROM $prep AS p
    FLATTEN LIST BY (idxs)
);

INSERT INTO $output1
WITH TRUNCATE
SELECT
    COALESCE(w.answer_A, "") AS answer_A,
    COALESCE(w.answer_B, "") AS answer_B,
    -- Исходное задание приходит вторым входом, отдельной таблицы под него нет.
    a.answers AS answers,
    COALESCE(w.assignment_id, "") AS assignment_id,
    COALESCE(w.assignment_link, "") AS assignment_link,
    w.annotations_worker AS annotations_worker,
    w.checkboxes AS checkboxes,

    a.checkboxes_A_agg AS checkboxes_A_agg,
    w.checkboxes_A_worker AS checkboxes_A_worker,

    a.checkboxes_B_agg AS checkboxes_B_agg,
    w.checkboxes_B_worker AS checkboxes_B_worker,

    -- Новая структура comment_judge
    <|
        editor_comment_evaluation: <|
            evaluation_details: <|
                what_to_improve: CAST(NULL AS String?),
                why_this_score: CAST(NULL AS String?)
            |>,
            final_verdict: CAST(NULL AS String?),
            overall_score: CAST(NULL AS Int64?)
        |>
    |> AS comment_judge,

    CAST(NULL AS String?) AS comment_score,

    COALESCE(w.comments_A_worker, "") AS comments_A_worker,
    COALESCE(w.comments_B_worker, "") AS comments_B_worker,

    w.dialog AS dialog,

    a.diff_pa_agg AS diff_pa_agg,
    a.diff_pa_winner_agg AS diff_pa_winner_agg,

    COALESCE(w.diff_pa_winner_worker, "") AS diff_pa_winner_worker,
    COALESCE(w.diff_pa_worker, false) AS diff_pa_worker,

    a.direct_speech_A_agg AS direct_speech_A_agg,
    COALESCE(w.direct_speech_A_worker, false) AS direct_speech_A_worker,

    a.direct_speech_B_agg AS direct_speech_B_agg,
    COALESCE(w.direct_speech_B_worker, false) AS direct_speech_B_worker,

    COALESCE(w.editors_markup_dt, "") AS editors_markup_dt,
    COALESCE(w.general_comment_worker, "") AS general_comment_worker,

    a.input_final_messages AS input_final_messages,
    a.input_meta AS input_meta,
    a.input_render_data AS input_render_data,

    CAST(w.instruct_id AS String?) AS instruct_id,
    w.instruct AS instruct,

    w.marker_text_parts_A_worker AS marker_text_parts_A_worker,
    w.marker_text_parts_B_worker AS marker_text_parts_B_worker,
    w.markers AS markers,
    w.metadata AS metadata,

    -- Оценки этого разметчика: агрегатные лежат своей парой колонок в $output2.
    w.pointwise_A_worker AS pointwise_A_worker,
    w.pointwise_B_worker AS pointwise_B_worker,

    CAST(w.pool_id AS String?) AS pool_id,
    CAST(w.project_id AS String?) AS project_id,

    COALESCE(w.real_source_A, "") AS real_source_A,
    COALESCE(w.real_source_B, "") AS real_source_B,

    w.rownum AS rownum,

    a.skip_agg AS skip_agg,
    COALESCE(w.skip_worker, false) AS skip_worker,

    COALESCE(w.source_A, "") AS source_A,
    COALESCE(w.source_B, "") AS source_B,

    a.source_winner_agg AS source_winner_agg,
    COALESCE(w.source_winner_worker, "") AS source_winner_worker,

    CAST(w.task_count AS Int64?) AS task_count,
    CAST(w.task_id AS String?) AS task_id,
    COALESCE(w.worker_id, "") AS worker_id
FROM $worker_rows AS w
LEFT JOIN $agg_src AS a
    ON w.instruct_id = a.instruct_id
;

INSERT INTO $output2
WITH TRUNCATE
SELECT
    a.answers AS answers,
    a.input_final_messages AS input_final_messages,
    a.input_meta AS input_meta,
    a.input_render_data AS input_render_data,

    a.instruct_id AS instruct_id,
    a.task_id AS task_id,
    a.rownum AS rownum,
    a.pool_id AS pool_id,
    a.project_id AS project_id,
    a.markup_metadata AS markup_metadata,

    a.real_source_A AS real_source_A,
    a.real_source_B AS real_source_B,

    a.checkboxes_A_agg AS checkboxes_A,
    a.checkboxes_B_agg AS checkboxes_B,

    -- Средние по заданию: поразметчиковые лежат своей парой колонок в $output1.
    a.pointwise_A_agg AS pointwise_A,
    a.pointwise_B_agg AS pointwise_B,

    a.skip_agg AS skip,
    a.diff_pa_agg AS diff_pa,
    a.direct_speech_A_agg AS direct_speech_A,
    a.direct_speech_B_agg AS direct_speech_B,

    a.source_winner_agg AS source_winner,
    a.source_winner_agreement AS source_winner_agreement,
    a.source_winner_strength AS source_winner_strength,
    a.diff_pa_winner_agg AS diff_pa_winner,
    a.diff_pa_winner_agreement AS diff_pa_winner_agreement,
    a.diff_pa_winner_strength AS diff_pa_winner_strength,

    a.task_summarization AS task_summarization,

    a.agg_tov_markup AS agg_tov_markup,
    a.raw_tov_markup AS raw_tov_markup
FROM $agg_src AS a
;
