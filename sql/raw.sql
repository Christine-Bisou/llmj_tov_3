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

$or_null = ($x) -> (IF(COALESCE($x, "") = "", "null", $x));

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

$checkbox_dict = ($node) -> {
    RETURN ToDict(
        IF(
            $node IS NULL,
            AsList(),
            ListMap(
                ListFilter(
                    DictItems(Yson::ConvertToDict($node)),
                    ($kv) -> { RETURN NOT $is_clarity_key(CAST($kv.0 AS String)); }
                ),
                ($kv) -> {
                    RETURN AsTuple(CAST($kv.0 AS String), $bool($kv.1));
                }
            )
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

-- Списки чекбоксов строятся по всем разметчикам задания, а не только по тем,
-- кто до чекбоксов дошёл. Разметчик, нажавший скип, чекбоксы не заполняет —
-- раньше он просто выпадал из списка, и значения съезжали на чужие позиции.
-- Теперь у него на своём месте false, а порядок — по assignment_id, как у
-- аннотаций и оценок, поэтому позиции во всех ключах означают одного и того же
-- разметчика.
$pack_checkboxes = ($rows) -> {
    $sorted = ListSort($rows, ($x) -> { RETURN $x.assignment_id; });
    RETURN Yson::From(
        ToDict(
            ListMap(
                ListSort(
                    ListUniq(
                        ListFlatMap($sorted, ($x) -> { RETURN DictKeys($x.checks); })
                    )
                ),
                ($key) -> {
                    RETURN AsTuple(
                        $key,
                        ListMap(
                            $sorted,
                            ($x) -> { RETURN COALESCE(DictLookup($x.checks, $key), False); }
                        )
                    );
                }
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

        $checkbox_dict(t.outputValues.checkbox_answers.answer_a.checkboxes) AS checkboxes_A_dict,
        $checkbox_dict(t.outputValues.checkbox_answers.answer_b.checkboxes) AS checkboxes_B_dict,

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

        -- Из метаданных отдельными колонками достаются только rownum и
        -- настоящие имена моделей: корзина, тикет и тип пула лежат в
        -- markup_metadata, дублировать их колонками незачем.
        $num(t.inputValues.metadata.rownum) AS meta_rownum,

        -- В metadata.models лежит прогон, в real_models — сама модель. Метрики
        -- строят по ним срез real_model_name, поэтому они идут колонками.
        $str(t.inputValues.metadata.real_models.model_1) AS meta_real_source_A,
        $str(t.inputValues.metadata.real_models.model_2) AS meta_real_source_B,

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

        b.checkboxes_A_dict AS checkboxes_A_dict,
        b.checkboxes_B_dict AS checkboxes_B_dict,

        b.pointwise_A_dict AS pointwise_A_dict,
        b.pointwise_B_dict AS pointwise_B_dict,

        b.annotations_list AS annotations_list,

        $winner_norm(b.winner_main_raw, b.source_A, b.source_B) AS source_winner,
        -- Разметчик, не выбравший победителя с учётом проактивности, держит
        -- своё место строкой "null" — так же, как «победителя нет» приходит из
        -- разметки. Пустая строка на этом месте читалась бы как «поля нет».
        $or_null(
            IF(
                b.diff_pa_flag,
                $winner_norm(b.winner_diff_pa_raw, b.source_A, b.source_B),
                ""
            )
        ) AS diff_pa_winner,

        b.general_comment_raw AS general_comment_raw,
        b.comment_A_raw AS comments_A_raw,
        b.comment_B_raw AS comments_B_raw,

        b.meta AS meta,
        b.meta_rownum AS meta_rownum,
        b.meta_real_source_A AS meta_real_source_A,
        b.meta_real_source_B AS meta_real_source_B,
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

        SOME(pool_id) AS pool_id,

        MIN(answer_A) AS answer_A,
        MIN(answer_B) AS answer_B,

        SOME(meta) AS meta,
        SOME(meta_rownum) AS meta_rownum,
        SOME(meta_real_source_A) AS meta_real_source_A,
        SOME(meta_real_source_B) AS meta_real_source_B,
        SOME(checkboxes) AS checkboxes,
        SOME(dialog) AS dialog,
        SOME(markers) AS markers
    FROM $norm
    GROUP BY task_id
);

-- Всё поразметчиковое собирается одним списком структур и сортируется по
-- assignment_id — тем же порядком, что чекбоксы, оценки и аннотации. Иначе
-- позиция в одном списке и та же позиция в другом означали бы разных людей:
-- порядок AGGREGATE_LIST ничем не задан, а AGGREGATE_LIST вдобавок выбрасывает
-- NULL, укорачивая список (так терялась дата у неподтверждённых заданий).
$by_marker_sorted = (
    SELECT
        task_id,
        ListSort(
            AGGREGATE_LIST(
                <|
                    "assignment_id": assignment_id,
                    "worker_id": worker_id,
                    "editors_markup_dt": editors_markup_dt,
                    "skip_flag": skip_flag,
                    "diff_pa_flag": diff_pa_flag,
                    "direct_speech_A": direct_speech_A,
                    "direct_speech_B": direct_speech_B,
                    "source_winner": source_winner,
                    "diff_pa_winner": diff_pa_winner,
                    "general_comment": general_comment_raw,
                    "comment_A": comments_A_raw,
                    "comment_B": comments_B_raw
                |>
            ),
            ($x) -> { RETURN $x.assignment_id; }
        ) AS by_marker
    FROM $norm
    GROUP BY task_id
);

$by_marker_lists = (
    SELECT
        task_id,
        ListMap(by_marker, ($x) -> { RETURN $x.assignment_id; }) AS assignment_ids,
        ListMap(by_marker, ($x) -> { RETURN $x.worker_id; }) AS worker_ids,
        ListMap(by_marker, ($x) -> { RETURN $x.editors_markup_dt; }) AS editors_markup_dts,
        ListMap(by_marker, ($x) -> { RETURN $x.skip_flag; }) AS skip,
        ListMap(by_marker, ($x) -> { RETURN $x.diff_pa_flag; }) AS diff_pa,
        ListMap(by_marker, ($x) -> { RETURN $x.direct_speech_A; }) AS direct_speech_A,
        ListMap(by_marker, ($x) -> { RETURN $x.direct_speech_B; }) AS direct_speech_B,
        ListMap(by_marker, ($x) -> { RETURN $x.source_winner; }) AS source_winner,
        -- Без фильтра по непустым: пустая строка держит место разметчика,
        -- который проактивность отдельно не размечал.
        ListMap(by_marker, ($x) -> { RETURN $x.diff_pa_winner; }) AS diff_pa_winner,
        ListMap(by_marker, ($x) -> { RETURN $x.general_comment; }) AS general_comments,
        ListMap(by_marker, ($x) -> { RETURN $x.comment_A; }) AS comments_A,
        ListMap(by_marker, ($x) -> { RETURN $x.comment_B; }) AS comments_B
    FROM $by_marker_sorted
);

$checkboxes_packed = (
    SELECT
        task_id,
        $pack_checkboxes(
            AGGREGATE_LIST(
                <|"assignment_id": assignment_id, "checks": checkboxes_A_dict|>
            )
        ) AS checkboxes_A,
        $pack_checkboxes(
            AGGREGATE_LIST(
                <|"assignment_id": assignment_id, "checks": checkboxes_B_dict|>
            )
        ) AS checkboxes_B
    FROM $norm
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
    m.source_A AS source_A,
    m.source_B AS source_B,
    m.meta_real_source_A AS real_source_A,
    m.meta_real_source_B AS real_source_B,
    m.task_id AS task_id,
    m.meta_rownum AS rownum,
    bm.assignment_ids AS assignment_ids,
    bm.worker_ids AS worker_ids,
    bm.editors_markup_dts AS editors_markup_dts,
    m.answer_A AS answer_A,
    m.answer_B AS answer_B,
    bm.skip AS skip,
    bm.diff_pa AS diff_pa,
    bm.direct_speech_A AS direct_speech_A,
    bm.direct_speech_B AS direct_speech_B,
    bm.source_winner AS source_winner,
    bm.diff_pa_winner AS diff_pa_winner,
    IF(cb.checkboxes_A IS NULL, Yson::From(ToDict(AsList())), cb.checkboxes_A) AS checkboxes_A,
    IF(cb.checkboxes_B IS NULL, Yson::From(ToDict(AsList())), cb.checkboxes_B) AS checkboxes_B,
    IF(pw.pointwise_A IS NULL, Yson::From(ToDict(AsList())), pw.pointwise_A) AS pointwise_A,
    IF(pw.pointwise_B IS NULL, Yson::From(ToDict(AsList())), pw.pointwise_B) AS pointwise_B,
    bm.general_comments AS general_comments,
    bm.comments_A AS comments_A,
    bm.comments_B AS comments_B,
    IF(a.annotations IS NULL, Yson::From(AsList()), a.annotations) AS annotations,
    IF(m.meta IS NULL, Yson::From(ToDict(AsList())), m.meta) AS metadata,
    -- Разметочная обвязка задания читается прямо из metadata — отдельных
    -- meta-колонок для неё больше нет. Значения бывают строкой "null" — так их
    -- и кладёт форма, не трогаем. Пул и проект тоже живут только здесь:
    -- своими колонками они не выводятся.
    -- Внешний Just: строгий Yson в YT не пишется, колонка должна быть
    -- Optional<Yson>. Остальные Yson-колонки оптиональны сами — они приходят
    -- из LEFT JOIN. rownum здесь не дублируется: он идёт своей колонкой.
    Just(Yson::From(ToDict(AsList(
        AsTuple("priority_type", $str(m.meta.priority_type)),
        AsTuple("basket_table", $str(m.meta.basket_table)),
        AsTuple("pool_type", $str(m.meta.pool_type)),
        AsTuple("ticket", $str(m.meta.ticket)),
        AsTuple("pool_id", COALESCE(CAST(m.pool_id AS String), "")),
        AsTuple("project_id", COALESCE(CAST(p.project_id AS String), ""))
    )))) AS markup_metadata,
    m.checkboxes AS checkboxes,
    m.dialog AS dialog,
    m.markers AS markers
FROM $main_agg AS m
CROSS JOIN $project_id_const AS p
LEFT JOIN $by_marker_lists AS bm
    ON m.task_id = bm.task_id
LEFT JOIN $checkboxes_packed AS cb
    ON m.task_id = cb.task_id
LEFT JOIN $pointwise_packed AS pw
    ON m.task_id = pw.task_id
LEFT JOIN $annotations_packed AS a
    ON m.task_id = a.task_id
;
