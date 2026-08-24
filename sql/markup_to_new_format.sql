PRAGMA yt.InferSchema = "100";
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;
PRAGMA Yson.AutoConvert;
PRAGMA SimpleColumns;

DECLARE $input1 AS String;  -- таблица в старом формате
DECLARE $output1 AS String; -- она же, приведённая к новому

-- Что получается на выходе:
-- agg_tov_markup: task_id, worker_ids, answer_A, answer_B, source_A, source_B,
--   checkboxes_A, checkboxes_B, annotations, comments_A, comments_B,
--   general_comments, task_summarization, diff_pa, diff_pa_winner,
--   diff_pa_winner_agreement, diff_pa_winner_strength, direct_speech_A,
--   direct_speech_B, winner, winner_agreement, winner_strength, skip,
--   pointwise_A, pointwise_B, real_source_A, real_source_B, markup_metadata
-- raw_tov_markup: task_id, answer_A, answer_B, source_A, source_B, checkboxes,
--   markers, raw_outputs, markup_metadata, real_source_A, real_source_B

$opts = Yson::Options(false AS Strict, true AS AutoConvert);

-- Опции передаются явно: без них ConvertTo* падает вместо того, чтобы вернуть
-- NULL, а pool_id, project_id и task_summarization в старом формате лежат
-- словарём-заглушкой {} — как раз тот случай.
$str = ($x) -> (
    COALESCE(
        Yson::ConvertToString($x, $opts),
        CAST(Yson::ConvertToInt64($x, $opts) AS String),
        ""
    )
);

-- Поле верхнего уровня; нет поля — пустая строка.
$top_str = ($node, $key) -> ($str(Yson::Lookup($node, $key, $opts)));

-- Поле из уже собранной обвязки: если запрос гоняют по переведённой таблице,
-- заполненные значения (тот же ticket) должны пережить второй прогон.
$meta_str = ($node, $key) -> (
    $str(Yson::Lookup(Yson::Lookup($node, "markup_metadata", $opts), $key, $opts))
);

-- Критериев в старом формате нет вообще, поэтому набор ключей задаётся здесь.
-- Если в разметке появится новый критерий, править надо эту строку.
$zero_pointwise = Yson::From(ToDict(AsList(
    AsTuple(Utf8("clarity"), 0.0),
    AsTuple(Utf8("connect"), 0.0),
    AsTuple(Utf8("liveliness"), 0.0),
    AsTuple(Utf8("overall"), 0.0)
)));

-- Уже проставленные оценки сохраняются, отсутствующие заводятся нулями.
$pointwise = ($node, $key) -> (
    COALESCE(
        IF(Yson::IsDict(Yson::Lookup($node, $key, $opts)),
           Yson::Lookup($node, $key, $opts)),
        $zero_pointwise
    )
);

-- Обвязки в старом формате нет, и достать её неоткуда — кладём пустые строки,
-- чтобы совпадал набор ключей. Пул и проект сюда не переезжают: в новом
-- формате их нет ни здесь, ни наверху.
$markup_metadata = ($node) -> (
    Yson::From(ToDict(AsList(
        AsTuple(Utf8("basket_table"), $meta_str($node, "basket_table")),
        AsTuple(Utf8("graph_owner"),  $meta_str($node, "graph_owner")),
        AsTuple(Utf8("process_url"),  $meta_str($node, "process_url")),
        AsTuple(Utf8("storage_mode"), $meta_str($node, "storage_mode")),
        AsTuple(Utf8("storage_type"), $meta_str($node, "storage_type")),
        AsTuple(Utf8("ticket"),       $meta_str($node, "ticket"))
    )))
);

-- Ключи, которые пересобираются, выбрасываются перед добавлением: так запрос
-- можно прогнать и по уже переведённой таблице, ничего не задвоив.
-- Ключи здесь Utf8: именно такие отдаёт Yson::ConvertToDict, и подмешать к ним
-- String-литералы через ListExtend нельзя.
$drop = ($node, $keys) -> (
    ListFilter(
        DictItems(Yson::ConvertToDict($node, $opts)),
        ($kv) -> (NOT ListHas($keys, $kv.0))
    )
);

$agg_drop_keys = AsList(
    Utf8("pool_id"), Utf8("project_id"), Utf8("markup_metadata"),
    Utf8("real_source_A"), Utf8("real_source_B"),
    Utf8("pointwise_A"), Utf8("pointwise_B"),
    -- в старом формате тут пустой словарь-заглушка, в новом — строка
    Utf8("task_summarization"),
    -- в новой схеме этих ключей нет; в выгрузках разметки их и не бывает,
    -- строка на случай таблиц, собранных judge_merge_pretty.sql
    Utf8("clc_metrics_A"), Utf8("clc_metrics_B"),
    Utf8("markers_A"), Utf8("markers_B")
);

$raw_drop_keys = AsList(
    Utf8("pool_id"), Utf8("project_id"), Utf8("markup_metadata"),
    Utf8("real_source_A"), Utf8("real_source_B"),
    Utf8("raw_outputs")
);

$to_new_agg = ($x) -> {
    $node = CAST($x AS Yson);
    RETURN IF(
        $node IS NULL OR NOT Yson::IsDict($node),
        CAST($x AS Yson?),
        Yson::From(ToDict(ListExtend(
            $drop($node, $agg_drop_keys),
            AsList(
                AsTuple(Utf8("markup_metadata"), $markup_metadata($node)),
                AsTuple(Utf8("real_source_A"), Yson::From($top_str($node, "real_source_A"))),
                AsTuple(Utf8("real_source_B"), Yson::From($top_str($node, "real_source_B"))),
                AsTuple(Utf8("task_summarization"), Yson::From($top_str($node, "task_summarization"))),
                AsTuple(Utf8("pointwise_A"), $pointwise($node, "pointwise_A")),
                AsTuple(Utf8("pointwise_B"), $pointwise($node, "pointwise_B"))
            )
        )))
    );
};

-- В поразметчиковом блоке добавляются только оценки; всё остальное у элемента
-- остаётся как есть, включая ключи, которых мы не знаем.
$with_pointwise = ($item) -> (
    Yson::From(ToDict(ListExtend(
        $drop($item, AsList(Utf8("pointwise_A"), Utf8("pointwise_B"))),
        AsList(
            AsTuple(Utf8("pointwise_A"), $pointwise($item, "pointwise_A")),
            AsTuple(Utf8("pointwise_B"), $pointwise($item, "pointwise_B"))
        )
    )))
);

$raw_outputs_new = ($node) -> (
    IF(
        $node IS NULL OR NOT Yson::IsList($node),
        Yson::From(AsList()),
        Yson::From(
            ListMap(
                Yson::ConvertToList($node, $opts),
                ($item) -> ($with_pointwise($item))
            )
        )
    )
);

$to_new_raw = ($x) -> {
    $node = CAST($x AS Yson);
    RETURN IF(
        $node IS NULL OR NOT Yson::IsDict($node),
        CAST($x AS Yson?),
        Yson::From(ToDict(ListExtend(
            $drop($node, $raw_drop_keys),
            AsList(
                AsTuple(Utf8("markup_metadata"), $markup_metadata($node)),
                AsTuple(Utf8("real_source_A"), Yson::From($top_str($node, "real_source_A"))),
                AsTuple(Utf8("real_source_B"), Yson::From($top_str($node, "real_source_B"))),
                AsTuple(
                    Utf8("raw_outputs"),
                    $raw_outputs_new(Yson::Lookup($node, "raw_outputs", $opts))
                )
            )
        )))
    );
};

INSERT INTO $output1
WITH TRUNCATE
SELECT
    t.*,
    $to_new_agg(t.agg_tov_markup) AS agg_tov_markup,
    $to_new_raw(t.raw_tov_markup) AS raw_tov_markup
WITHOUT t.agg_tov_markup, t.raw_tov_markup
FROM $input1 AS t;
