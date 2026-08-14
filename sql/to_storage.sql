PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;

DECLARE $input1 AS String;  -- raw: поразметчиковые списки по заданию
DECLARE $input2 AS String;  -- agg: плоские колонки по заданию
DECLARE $output1 AS String; -- строка на разметчика (будущий raw storage)
DECLARE $output2 AS String; -- строка на задание (будущий agg storage)

$str = ($x) -> (NVL(Yson::ConvertToString($x), ""));
$i64 = ($x) -> (Yson::ConvertToInt64($x));

-- Оценка приходит и целым, и дробным узлом, поэтому пробуем оба типа.
$dbl = ($x) -> (
    COALESCE(
        Yson::ConvertToDouble($x),
        CAST(Yson::ConvertToInt64($x) AS Double)
    )
);

$list_len_or_zero = ($list) -> (
    IF($list IS NULL, 0u, ListLength($list))
);

$row_count = ($assignment_ids, $task_ids, $worker_ids) -> (
    IF(
        $list_len_or_zero($assignment_ids) >= $list_len_or_zero($task_ids)
        AND $list_len_or_zero($assignment_ids) >= $list_len_or_zero($worker_ids),
        $list_len_or_zero($assignment_ids),
        IF(
            $list_len_or_zero($task_ids) >= $list_len_or_zero($worker_ids),
            $list_len_or_zero($task_ids),
            $list_len_or_zero($worker_ids)
        )
    )
);

$dict_from_yson_or_empty = ($node) -> (
    IF(
        $node IS NULL,
        ToDict(AsList()),
        IF(
            Yson::IsList($node),
            ToDict(AsList()),
            Yson::ConvertToDict($node)
        )
    )
);

$yson_from_dict_or_empty = ($node) -> (
    Just(Yson::From($dict_from_yson_or_empty($node)))
);

-- Оценки лежат словарём критерий -> список по разметчикам, поэтому берём
-- значение по позиции разметчика. Позиции те же, что у чекбоксов и аннотаций:
-- первый этап сортирует всё по assignment_id. Нет значения — 0, как и в agg.
$pointwise_worker = ($node, $idx) -> (
    IF(
        $node IS NULL OR NOT Yson::IsDict($node),
        Just(Yson::From(ToDict(AsList()))),
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

$marker_struct_list = ($node) -> (
    IF(
        $node IS NULL,
        AsList(),
        ListMap(
            Yson::ConvertToList($node),
            ($x) -> (
                <|
                    "content": $str($x.content),
                    "comment": $str($x.comment),
                    "endIndex": $i64($x.endIndex),
                    "id": $str($x.id),
                    "markdownEndIndex": $i64($x.markdownEndIndex),
                    "markdownStartIndex": $i64($x.markdownStartIndex),
                    "startIndex": $i64($x.startIndex),
                    "type": $str($x.type)
                |>
            )
        )
    )
);

$marker_parts_from_packed = ($packed, $idx) -> (
    IF(
        $packed IS NULL,
        AsList(),
        IF(
            ListLength(Yson::ConvertToList($packed)) > $idx,
            $marker_struct_list(Yson::ConvertToList($packed)[$idx]),
            AsList()
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

$prep = (
    SELECT
        t.*,
        ListFromRange(0u, $row_count(t.assignment_ids, t.task_ids, t.worker_ids)) AS idxs
    FROM $input1 AS t
);

$rows_base = (
    SELECT
        p.answer_A AS answer_A,
        p.answer_B AS answer_B,
        IF(p.pool_id IS NULL, "", p.pool_id) AS pool_id,
        IF(p.project_id IS NULL, "", p.project_id) AS project_id,
        p.checkboxes AS checkboxes,
        p.dialog AS dialog,
        p.markers AS markers,
        p.metadata AS metadata,
        p.task_count AS task_count,
        p.idxs AS idx,

        IF(p.assignment_ids[p.idxs] IS NULL, "", p.assignment_ids[p.idxs]) AS assignment_id,
        IF(p.task_ids[p.idxs] IS NULL, "", p.task_ids[p.idxs]) AS task_id,
        IF(p.worker_ids[p.idxs] IS NULL, "", p.worker_ids[p.idxs]) AS worker_id,
        IF(p.editors_markup_dts[p.idxs] IS NULL, "", p.editors_markup_dts[p.idxs]) AS editors_markup_dt,

        IF(p.skip[p.idxs] IS NULL, false, p.skip[p.idxs]) AS skip_worker,
        IF(p.diff_pa[p.idxs] IS NULL, false, p.diff_pa[p.idxs]) AS diff_pa_worker,
        IF(p.direct_speech_A[p.idxs] IS NULL, false, p.direct_speech_A[p.idxs]) AS direct_speech_A_worker,
        IF(p.direct_speech_B[p.idxs] IS NULL, false, p.direct_speech_B[p.idxs]) AS direct_speech_B_worker,

        IF(p.source_winner[p.idxs] IS NULL, "", p.source_winner[p.idxs]) AS source_winner_worker,
        IF(p.diff_pa_winner[p.idxs] IS NULL, "", p.diff_pa_winner[p.idxs]) AS diff_pa_winner_worker,

        IF(p.general_comments[p.idxs] IS NULL, "", p.general_comments[p.idxs]) AS general_comment_worker,
        IF(p.comments_A[p.idxs] IS NULL, "", p.comments_A[p.idxs]) AS comments_A_worker,
        IF(p.comments_B[p.idxs] IS NULL, "", p.comments_B[p.idxs]) AS comments_B_worker,

        Just(Yson::From($marker_parts_from_packed(p.marker_text_parts_A, p.idxs))) AS marker_text_parts_A_worker,
        Just(Yson::From($marker_parts_from_packed(p.marker_text_parts_B, p.idxs))) AS marker_text_parts_B_worker,

        $pointwise_worker(p.pointwise_A, p.idxs) AS pointwise_A_worker,
        $pointwise_worker(p.pointwise_B, p.idxs) AS pointwise_B_worker,

        p.checkboxes_A AS checkboxes_A,
        p.checkboxes_B AS checkboxes_B,
        p.source_A AS source_A,
        p.source_B AS source_B
    FROM $prep AS p
    FLATTEN BY idxs
);

$worker_rows = (
    SELECT
        r.answer_A AS answer_A,
        r.answer_B AS answer_B,
        IF(r.assignment_id IS NULL, "", r.assignment_id) AS assignment_id,
        IF(
            r.assignment_id IS NULL OR r.assignment_id = "",
            "",
            "https://yang.yandex-team.ru/task/" || r.pool_id || "/" || r.assignment_id
        ) AS assignment_link,

        r.checkboxes AS checkboxes,
        $yson_from_dict_or_empty(r.checkboxes_A) AS checkboxes_A_worker,
        $yson_from_dict_or_empty(r.checkboxes_B) AS checkboxes_B_worker,

        NULL AS comment_judge,
        NULL AS comment_score,

        IF(r.comments_A_worker IS NULL, "", r.comments_A_worker) AS comments_A_worker,
        IF(r.comments_B_worker IS NULL, "", r.comments_B_worker) AS comments_B_worker,
        r.dialog AS dialog,
        IF(r.diff_pa_winner_worker IS NULL, "", r.diff_pa_winner_worker) AS diff_pa_winner_worker,
        IF(r.diff_pa_worker IS NULL, false, r.diff_pa_worker) AS diff_pa_worker,
        IF(r.direct_speech_A_worker IS NULL, false, r.direct_speech_A_worker) AS direct_speech_A_worker,
        IF(r.direct_speech_B_worker IS NULL, false, r.direct_speech_B_worker) AS direct_speech_B_worker,
        IF(r.editors_markup_dt IS NULL, "", r.editors_markup_dt) AS editors_markup_dt,
        IF(r.general_comment_worker IS NULL, "", r.general_comment_worker) AS general_comment_worker,

        $last_dialog_query(r.dialog) AS instruct,

        r.marker_text_parts_A_worker AS marker_text_parts_A_worker,
        r.marker_text_parts_B_worker AS marker_text_parts_B_worker,
        r.markers AS markers,
        r.metadata AS metadata,
        r.pointwise_A_worker AS pointwise_A_worker,
        r.pointwise_B_worker AS pointwise_B_worker,
        r.pool_id AS pool_id,
        r.project_id AS project_id,
        IF(r.skip_worker IS NULL, false, r.skip_worker) AS skip_worker,
        IF(r.source_A IS NULL, "", r.source_A) AS source_A,
        IF(r.source_B IS NULL, "", r.source_B) AS source_B,
        IF(r.source_winner_worker IS NULL, "", r.source_winner_worker) AS source_winner_worker,
        r.task_count AS task_count,
        IF(r.task_id IS NULL, "", r.task_id) AS task_id,
        IF(r.worker_id IS NULL, "", r.worker_id) AS worker_id
    FROM $rows_base AS r
);

INSERT INTO $output1
SELECT
    COALESCE(w.answer_A, "") AS answer_A,
    COALESCE(w.answer_B, "") AS answer_B,
    -- Исходное задание приходит колонками агрегата, отдельного входа под него нет.
    a.answers AS answers,
    COALESCE(w.assignment_id, "") AS assignment_id,
    COALESCE(w.assignment_link, "") AS assignment_link,
    w.checkboxes AS checkboxes,

    $yson_from_dict_or_empty(a.checkboxes_A) AS checkboxes_A_agg,
    w.checkboxes_A_worker AS checkboxes_A_worker,

    $yson_from_dict_or_empty(a.checkboxes_B) AS checkboxes_B_agg,
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

    a.diff_pa AS diff_pa_agg,
    a.diff_pa_winner AS diff_pa_winner_agg,

    COALESCE(w.diff_pa_winner_worker, "") AS diff_pa_winner_worker,
    COALESCE(w.diff_pa_worker, false) AS diff_pa_worker,

    a.direct_speech_A AS direct_speech_A_agg,
    COALESCE(w.direct_speech_A_worker, false) AS direct_speech_A_worker,

    a.direct_speech_B AS direct_speech_B_agg,
    COALESCE(w.direct_speech_B_worker, false) AS direct_speech_B_worker,

    COALESCE(w.editors_markup_dt, "") AS editors_markup_dt,
    COALESCE(w.general_comment_worker, "") AS general_comment_worker,

    a.input_final_messages AS input_final_messages,
    a.input_meta AS input_meta,
    a.input_render_data AS input_render_data,

    CAST(a.instruct_id AS String?) AS instruct_id,
    w.instruct AS instruct,

    w.marker_text_parts_A_worker AS marker_text_parts_A_worker,
    w.marker_text_parts_B_worker AS marker_text_parts_B_worker,
    w.markers AS markers,
    w.metadata AS metadata,

    -- Оценки этого разметчика: агрегатные лежат своей парой колонок в $output2.
    w.pointwise_A_worker AS pointwise_A_worker,
    w.pointwise_B_worker AS pointwise_B_worker,

    CAST(COALESCE(a.pool_id, w.pool_id) AS String?) AS pool_id,
    CAST(COALESCE(a.project_id, w.project_id) AS String?) AS project_id,

    a.skip AS skip_agg,
    COALESCE(w.skip_worker, false) AS skip_worker,

    COALESCE(w.source_A, "") AS source_A,
    COALESCE(w.source_B, "") AS source_B,

    a.source_winner AS source_winner_agg,
    COALESCE(w.source_winner_worker, "") AS source_winner_worker,

    CAST(w.task_count AS Int64?) AS task_count,
    CAST(w.task_id AS String?) AS task_id,
    COALESCE(w.worker_id, "") AS worker_id
FROM $worker_rows AS w
LEFT JOIN $input2 AS a
    ON w.task_id = a.task_id
;

INSERT INTO $output2
SELECT
    a.answer_A AS answer_A,
    a.answer_B AS answer_B,
    a.answers AS answers,
    a.assignment_ids AS assignment_ids,
    a.assignments_links AS assignments_links,
    a.checkboxes AS checkboxes,
    a.checkboxes_A AS checkboxes_A,
    a.checkboxes_B AS checkboxes_B,
    a.comments_A AS comments_A,
    a.comments_B AS comments_B,
    a.dialog AS dialog,
    a.diff_pa AS diff_pa,
    a.diff_pa_winner AS diff_pa_winner,
    a.diff_pa_winner_agreement AS diff_pa_winner_agreement,
    a.diff_pa_winner_strength AS diff_pa_winner_strength,
    a.direct_speech_A AS direct_speech_A,
    a.direct_speech_B AS direct_speech_B,
    a.editors_markup_dts AS editors_markup_dts,
    a.general_comments AS general_comments,
    a.input_final_messages AS input_final_messages,
    a.input_meta AS input_meta,
    a.input_render_data AS input_render_data,
    a.instruct_id AS instruct_id,
    CAST(a.marker_text_parts_A AS Yson?) AS marker_text_parts_A,
    CAST(a.marker_text_parts_B AS Yson?) AS marker_text_parts_B,
    a.markers AS markers,
    a.metadata AS metadata,
    -- Средние по заданию: поразметчиковые лежат своей парой колонок в $output1.
    a.pointwise_A AS pointwise_A,
    a.pointwise_B AS pointwise_B,
    COALESCE(a.pool_id, "") AS pool_id,
    COALESCE(a.project_id, "") AS project_id,
    a.skip AS skip,
    a.source_A AS source_A,
    a.source_B AS source_B,
    a.source_winner AS source_winner,
    a.source_winner_agreement AS source_winner_agreement,
    a.source_winner_strength AS source_winner_strength,
    a.task_count AS task_count,
    a.task_id AS task_id,
    CAST(a.task_summarization AS String?) AS task_summarization,
    a.worker_ids AS worker_ids
FROM $input2 AS a
;
