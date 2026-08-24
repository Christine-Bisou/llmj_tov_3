PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;

DECLARE $input1 AS String;
DECLARE $output1 AS String;

$extra_tag = 'eval';

-- input_meta — это Yson-словарь вида
--   {"env" = {"overflow_strategy" = "ContextManagerForceGeneration"};
--    "instruct_id" = "74F8...";
--    "tags" = ["source__bt"; "memory_in_usefullness"; "split_llmj__llmj_validate"];
--    "tools" = "default"}
-- Изменить один ключ на месте нельзя, поэтому пересобираем словарь целиком
-- и дописываем в tags ещё один тег.
$with_tag = ($meta) -> {
    $tags = Yson::ConvertToStringList(Yson::Lookup($meta, 'tags'))
            ?? ListCreate(String);

    RETURN Yson::From(<|
        -- env состоит из строковых значений; если там появятся числа/вложенные
        -- словари, этот ConvertToStringDict придётся расписать по ключам
        env:         Yson::ConvertToStringDict(Yson::Lookup($meta, 'env'))
                     ?? DictCreate(String, String),
        instruct_id: Yson::LookupString($meta, 'instruct_id'),
        tags:        ListExtend($tags, AsList($extra_tag)),
        tools:       Yson::LookupString($meta, 'tools')
    |>);
};

INSERT INTO $output1
SELECT
    `answers`,
    `input_final_messages`,
    $with_tag(`input_meta`) AS input_meta,
    NULL AS input_render_data
FROM $input1

LIMIT 2;

-- Если колонка input_meta в приёмнике объявлена как String, а не Yson/Any,
-- оберни результат: CAST(Yson::SerializeText($with_tag(`input_meta`)) AS String).
