DECLARE $input1 AS String;
DECLARE $input2 AS String;
DECLARE $output1 AS String;

PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;

$str = ($x) -> (nvl(Yson::ConvertToString($x), ""));
$bool = ($x) -> (Yson::ConvertToBool($x) ?? False);
$i64 = ($x) -> (Yson::ConvertToInt64($x));
-- Оценки приходят и целыми, и дробными, поэтому пробуем оба числовых типа.
-- NULL здесь значит «оценки нет», нули подставляются уже при упаковке.
$dbl = ($x) -> (
    COALESCE(
        Yson::ConvertToDouble($x),
        CAST(Yson::ConvertToInt64($x) AS Double)
    )
);

-- rownum приходит числом, строкой его не прочитать. Но в части выгрузок он
-- лежит строкой, поэтому пробуем оба вида.
$num = ($x) -> (
    COALESCE($i64($x), CAST(Yson::ConvertToString($x) AS Int64))
);

$fmt_dt = DateTime::Format("%Y-%m-%d");

$winner_norm = ($raw, $src_a, $src_b) -> (
    IF(
        IF($raw = "answer_a", $src_a, IF($raw = "answer_b", $src_b, $raw)) = "tie",
        "draw",
        IF($raw = "answer_a", $src_a, IF($raw = "answer_b", $src_b, $raw))
    )
);

$answers_list_norm = ($node) -> {
    RETURN IF(
        $node IS NULL,
        AsList(),
        ListMap(
            Yson::ConvertToList($node),
            ($ans) -> {
                RETURN <|
                    "label": $str($ans.label),
                    "source": $str($ans.source),
                    "answer_text": $str($ans.answer)
                |>;
            }
        )
    );
};

-- Маркера ясности больше не существует, поэтому clarity из чекбоксов не забираем:
-- ключ отбрасывается на входе, дальше по запросу его просто нет.
$is_clarity_key = ($key) -> (
    COALESCE(String::Contains(String::AsciiToLower($key), "clarity"), False)
);

$checkbox_kv_list = ($node) -> {
    RETURN IF(
        $node IS NULL,
        AsList(),
        ListSort(
            ListFilter(
                ListMap(
                    DictItems(Yson::ConvertToDict($node)),
                    ($kv) -> {
                        RETURN <|"key": CAST($kv.0 AS String), "value": ($bool($kv.1))|>;
                    }
                ),
                ($x) -> { RETURN NOT $is_clarity_key($x.key); }
            ),
            ($x) -> { RETURN $x.key; }
        )
    );
};

-- pointwise_ratings хранит критерии внутри answer_a/answer_b, а общую оценку —
-- рядом в overall_a/overall_b. Сводим то и другое в один словарь критерий -> оценка.
$pointwise_dict = ($node, $overall) -> {
    $overall_val = $dbl($overall);
    RETURN ToDict(
        ListExtend(
            IF(
                $node IS NULL,
                AsList(),
                ListMap(
                    ListFilter(
                        DictItems(Yson::ConvertToDict($node)),
                        ($kv) -> { RETURN $dbl($kv.1) IS NOT NULL; }
                    ),
                    ($kv) -> {
                        RETURN AsTuple(CAST($kv.0 AS String), Unwrap($dbl($kv.1)));
                    }
                )
            ),
            IF(
                $overall_val IS NULL,
                AsList(),
                AsList(AsTuple("overall", Unwrap($overall_val)))
            )
        )
    );
};

-- Ключи собираем по всем разметчикам задания, чтобы списки оценок были одной
-- длины: если разметчик критерий не оценил, на его месте оказывается 0.
$pack_pointwise = ($rows) -> {
    $sorted = ListSort($rows, ($x) -> { RETURN $x.assignment_id; });
    RETURN Yson::From(
        ToDict(
            ListMap(
                ListSort(
                    ListUniq(
                        ListFlatMap($sorted, ($x) -> { RETURN DictKeys($x.ratings); })
                    )
                ),
                ($key) -> {
                    RETURN AsTuple(
                        $key,
                        ListMap(
                            $sorted,
                            ($x) -> { RETURN COALESCE(DictLookup($x.ratings, $key), 0.0); }
                        )
                    );
                }
            )
        )
    );
};

$annotation_range_struct_list = ($node) -> {
    RETURN IF(
        $node IS NULL,
        AsList(),
        ListMap(
            Yson::ConvertToList($node),
            ($x) -> {
                RETURN <|
                    "content": $str($x.content),
                    "end": $i64($x.end),
                    "id": $str($x.id),
                    "markdown_end": $i64($x.markdown_end),
                    "markdown_start": $i64($x.markdown_start),
                    "side": $str($x.side),
                    "start": $i64($x.start)
                |>;
            }
        )
    );
};

$annotations_struct_list = ($node) -> {
    RETURN IF(
        $node IS NULL,
        AsList(),
        ListMap(
            Yson::ConvertToList($node),
            ($x) -> {
                RETURN <|
                    "background_color": $str($x.background_color),
                    "id": $str($x.id),
                    "ranges": $annotation_range_struct_list($x.ranges),
                    "review": <|
                        "comment": $str($x.review.comment)
                    |>,
                    "side": $str($x.side),
                    "type": $str($x.type),
                    "worker_id": $str($x.worker_id)
                |>;
            }
        )
    );
};

$src_for_answers = (
    SELECT
        taskId AS task_id,
        $answers_list_norm(inputValues.answers) AS answers_list
    FROM $input1
    WHERE status = "ACCEPTED"
      AND outputValues IS NOT NULL
);

$ans_sources = (
    SELECT
        task_id,
        MAX(IF(ans.label = "A", ans.source, "")) AS source_A,
        MAX(IF(ans.label = "B", ans.source, "")) AS source_B,
        MAX(IF(ans.label = "A", ans.answer_text, "")) AS answer_A,
        MAX(IF(ans.label = "B", ans.answer_text, "")) AS answer_B
    FROM $src_for_answers
    FLATTEN LIST BY answers_list AS ans
    GROUP BY task_id
);

$project_id_const = (
    SELECT
        SOME(projectId) AS project_id
    FROM $input2
);

$base = (
    SELECT
        t.taskId AS task_id,
        t.assignmentId AS assignment_id,
        t.workerId AS worker_id,
        t.poolId AS pool_id,

        IF(
            t.acceptTs IS NOT NULL,
            $fmt_dt(
                DateTime::FromMilliseconds(
                    CAST(Unwrap(t.acceptTs) AS Uint64)
                )
            ),
            NULL
        ) AS editors_markup_dt,

        s.source_A AS source_A,
        s.source_B AS source_B,
        s.answer_A AS answer_A,
        s.answer_B AS answer_B,

        $bool(t.outputValues.skip) AS skip_flag,
        $bool(t.outputValues.proactivity_affects_verdict) AS diff_pa_flag,

        $str(t.outputValues.winner) AS winner_main_raw,
        COALESCE(
            IF($str(t.outputValues.winner_diff_pa) != "", $str(t.outputValues.winner_diff_pa), NULL),
            IF($str(t.outputValues.diff_pa_winner) != "", $str(t.outputValues.diff_pa_winner), NULL),
            IF($str(t.outputValues.winner_proactivity) != "", $str(t.outputValues.winner_proactivity), NULL),
            IF($str(t.outputValues.winner_with_pa) != "", $str(t.outputValues.winner_with_pa), NULL),
            ""
        ) AS winner_diff_pa_raw,

        $bool(t.outputValues.checkbox_answers.answer_a.direct_speech) AS direct_speech_A,
        $bool(t.outputValues.checkbox_answers.answer_b.direct_speech) AS direct_speech_B,

        $checkbox_kv_list(t.outputValues.checkbox_answers.answer_a.checkboxes) AS checkboxes_A_kv,
        $checkbox_kv_list(t.outputValues.checkbox_answers.answer_b.checkboxes) AS checkboxes_B_kv,

        $pointwise_dict(
            t.outputValues.pointwise_ratings.answer_a,
            t.outputValues.pointwise_ratings.overall_a
        ) AS pointwise_A_dict,
        $pointwise_dict(
            t.outputValues.pointwise_ratings.answer_b,
            t.outputValues.pointwise_ratings.overall_b
        ) AS pointwise_B_dict,

        $annotations_struct_list(t.outputValues.annotations) AS annotations_list,

        $str(t.outputValues.general_comment) AS general_comment_raw,
        $str(t.outputValues.checkbox_answers.answer_a.comment) AS comment_A_raw,
        $str(t.outputValues.checkbox_answers.answer_b.comment) AS comment_B_raw,

        t.inputValues.metadata AS meta,

        -- Разметочная обвязка задания: что за корзина, какой тикет, какой пул.
        -- Значения бывают строкой "null" — так их и кладёт форма, не трогаем.
        $str(t.inputValues.metadata.priority_type) AS meta_priority_type,
        $str(t.inputValues.metadata.basket_table) AS meta_basket_table,
        $str(t.inputValues.metadata.pool_type) AS meta_pool_type,
        $str(t.inputValues.metadata.ticket) AS meta_ticket,
        $num(t.inputValues.metadata.rownum) AS meta_rownum,

        t.inputValues.checkboxes AS checkboxes,
        COALESCE(t.inputValues.dialog, t.inputValues.dialog_altformat) AS dialog,
        t.inputValues.markers AS markers
    FROM $input1 AS t
    INNER JOIN $ans_sources AS s
        ON t.taskId = s.task_id
    WHERE t.status = "ACCEPTED"
      AND t.outputValues IS NOT NULL
      AND $str(COALESCE(t.inputValues.metadata.instruct_id, t.inputValues.instruct_id)) != ""
);

$norm = (
    SELECT
        b.task_id AS task_id,
        b.assignment_id AS assignment_id,
        b.worker_id AS worker_id,
        b.pool_id AS pool_id,
        b.editors_markup_dt AS editors_markup_dt,

        b.source_A AS source_A,
        b.source_B AS source_B,
        b.answer_A AS answer_A,
        b.answer_B AS answer_B,

        b.skip_flag AS skip_flag,
        b.diff_pa_flag AS diff_pa_flag,
        b.direct_speech_A AS direct_speech_A,
        b.direct_speech_B AS direct_speech_B,

        b.checkboxes_A_kv AS checkboxes_A_kv,
        b.checkboxes_B_kv AS checkboxes_B_kv,

        b.pointwise_A_dict AS pointwise_A_dict,
        b.pointwise_B_dict AS pointwise_B_dict,

        b.annotations_list AS annotations_list,

        $winner_norm(b.winner_main_raw, b.source_A, b.source_B) AS source_winner,
        IF(
            b.diff_pa_flag,
            $winner_norm(b.winner_diff_pa_raw, b.source_A, b.source_B),
            ""
        ) AS diff_pa_winner,

        b.general_comment_raw AS general_comment_raw,
        b.comment_A_raw AS comments_A_raw,
        b.comment_B_raw AS comments_B_raw,

        b.meta AS meta,
        b.meta_priority_type AS meta_priority_type,
        b.meta_basket_table AS meta_basket_table,
        b.meta_pool_type AS meta_pool_type,
        b.meta_ticket AS meta_ticket,
        b.meta_rownum AS meta_rownum,
        b.checkboxes AS checkboxes,
        b.dialog AS dialog,
        b.markers AS markers
    FROM $base AS b
);

$main_agg = (
    SELECT
        task_id,

        SOME(source_A) AS source_A,
        SOME(source_B) AS source_B,

        AGGREGATE_LIST(assignment_id) AS assignment_ids,
        AGGREGATE_LIST(worker_id) AS worker_ids,
        AGGREGATE_LIST(editors_markup_dt) AS editors_markup_dts,
        SOME(pool_id) AS pool_id,

        MIN(answer_A) AS answer_A,
        MIN(answer_B) AS answer_B,

        AGGREGATE_LIST(skip_flag) AS skip,
        AGGREGATE_LIST(diff_pa_flag) AS diff_pa,

        AGGREGATE_LIST(direct_speech_A) AS direct_speech_A,
        AGGREGATE_LIST(direct_speech_B) AS direct_speech_B,

        AGGREGATE_LIST(source_winner) AS source_winner,
        ListFilter(
            AGGREGATE_LIST(diff_pa_winner),
            ($x) -> { RETURN $x != ""; }
        ) AS diff_pa_winner,

        AGGREGATE_LIST(general_comment_raw) AS general_comments,
        AGGREGATE_LIST(comments_A_raw) AS comments_A,
        AGGREGATE_LIST(comments_B_raw) AS comments_B,

        SOME(meta) AS meta,
        SOME(meta_priority_type) AS meta_priority_type,
        SOME(meta_basket_table) AS meta_basket_table,
        SOME(meta_pool_type) AS meta_pool_type,
        SOME(meta_ticket) AS meta_ticket,
        SOME(meta_rownum) AS meta_rownum,
        SOME(checkboxes) AS checkboxes,
        SOME(dialog) AS dialog,
        SOME(markers) AS markers
    FROM $norm
    GROUP BY task_id
);

$cbA_flat = (
    SELECT
        n.task_id AS task_id,
        cb.key AS cb_key,
        cb.value AS cb_value
    FROM $norm AS n
    FLATTEN LIST BY n.checkboxes_A_kv AS cb
);

$cbA_by_key = (
    SELECT
        task_id,
        cb_key AS key,
        AGGREGATE_LIST(cb_value) AS values
    FROM $cbA_flat
    GROUP BY task_id, cb_key
);

$cbA_packed = (
    SELECT
        task_id,
        Yson::From(ToDict(AGGREGATE_LIST(AsTuple(key, values)))) AS checkboxes_A
    FROM $cbA_by_key
    GROUP BY task_id
);

$cbB_flat = (
    SELECT
        n.task_id AS task_id,
        cb.key AS cb_key,
        cb.value AS cb_value
    FROM $norm AS n
    FLATTEN LIST BY n.checkboxes_B_kv AS cb
);

$cbB_by_key = (
    SELECT
        task_id,
        cb_key AS key,
        AGGREGATE_LIST(cb_value) AS values
    FROM $cbB_flat
    GROUP BY task_id, cb_key
);

$cbB_packed = (
    SELECT
        task_id,
        Yson::From(ToDict(AGGREGATE_LIST(AsTuple(key, values)))) AS checkboxes_B
    FROM $cbB_by_key
    GROUP BY task_id
);

$pointwise_packed = (
    SELECT
        task_id,
        $pack_pointwise(
            AGGREGATE_LIST(
                <|"assignment_id": assignment_id, "ratings": pointwise_A_dict|>
            )
        ) AS pointwise_A,
        $pack_pointwise(
            AGGREGATE_LIST(
                <|"assignment_id": assignment_id, "ratings": pointwise_B_dict|>
            )
        ) AS pointwise_B
    FROM $norm
    GROUP BY task_id
);

$annotations_by_worker = (
    SELECT
        task_id,
        assignment_id,
        annotations_list AS worker_annotations
    FROM $norm
);

$annotations_packed = (
    SELECT
        task_id,
        Yson::From(
            ListMap(
                ListSort(
                    AGGREGATE_LIST(
                        <|
                            "assignment_id": assignment_id,
                            "worker_annotations": worker_annotations
                        |>
                    ),
                    ($x) -> { RETURN $x.assignment_id; }
                ),
                ($x) -> {
                    RETURN $x.worker_annotations;
                }
            )
        ) AS annotations
    FROM $annotations_by_worker
    GROUP BY task_id
);

INSERT INTO $output1
WITH TRUNCATE
SELECT
    p.project_id AS project_id,
    m.source_A AS source_A,
    m.source_B AS source_B,
    m.task_id AS task_id,
    m.assignment_ids AS assignment_ids,
    m.worker_ids AS worker_ids,
    m.editors_markup_dts AS editors_markup_dts,
    m.pool_id AS pool_id,
    m.answer_A AS answer_A,
    m.answer_B AS answer_B,
    m.skip AS skip,
    m.diff_pa AS diff_pa,
    m.direct_speech_A AS direct_speech_A,
    m.direct_speech_B AS direct_speech_B,
    m.source_winner AS source_winner,
    m.diff_pa_winner AS diff_pa_winner,
    IF(cA.checkboxes_A IS NULL, Yson::From(ToDict(AsList())), cA.checkboxes_A) AS checkboxes_A,
    IF(cB.checkboxes_B IS NULL, Yson::From(ToDict(AsList())), cB.checkboxes_B) AS checkboxes_B,
    IF(pw.pointwise_A IS NULL, Yson::From(ToDict(AsList())), pw.pointwise_A) AS pointwise_A,
    IF(pw.pointwise_B IS NULL, Yson::From(ToDict(AsList())), pw.pointwise_B) AS pointwise_B,
    m.general_comments AS general_comments,
    m.comments_A AS comments_A,
    m.comments_B AS comments_B,
    IF(a.annotations IS NULL, Yson::From(AsList()), a.annotations) AS annotations,
    IF(m.meta IS NULL, Yson::From(ToDict(AsList())), m.meta) AS metadata,
    -- Внешний Just: строгий Yson в YT не пишется, колонка должна быть
    -- Optional<Yson>. Остальные Yson-колонки оптиональны сами — они приходят
    -- из LEFT JOIN. Значения обёрнуты в Yson поштучно, чтобы rownum остался
    -- числом: в словаре из одних строк по нему нельзя было бы сортировать.
    Just(Yson::From(ToDict(AsList(
        AsTuple("priority_type", Just(Yson::From(m.meta_priority_type))),
        AsTuple("basket_table", Just(Yson::From(m.meta_basket_table))),
        AsTuple("pool_type", Just(Yson::From(m.meta_pool_type))),
        AsTuple("ticket", Just(Yson::From(m.meta_ticket))),
        AsTuple("rownum", Just(Yson::From(m.meta_rownum))),
        AsTuple("pool_id", Just(Yson::From(COALESCE(CAST(m.pool_id AS String), "")))),
        AsTuple("project_id", Just(Yson::From(COALESCE(CAST(p.project_id AS String), ""))))
    )))) AS markup_metadata,
    m.checkboxes AS checkboxes,
    m.dialog AS dialog,
    m.markers AS markers
FROM $main_agg AS m
CROSS JOIN $project_id_const AS p
LEFT JOIN $cbA_packed AS cA
    ON m.task_id = cA.task_id
LEFT JOIN $cbB_packed AS cB
    ON m.task_id = cB.task_id
LEFT JOIN $pointwise_packed AS pw
    ON m.task_id = pw.task_id
LEFT JOIN $annotations_packed AS a
    ON m.task_id = a.task_id
;
