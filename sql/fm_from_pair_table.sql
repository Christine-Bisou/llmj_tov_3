DECLARE $input1 AS String;   -- парная таблица: final_messages_1/2, answer_source_1/2, ...
DECLARE $output1 AS String;  -- канонический FM: answers, input_final_messages, input_meta, input_render_data

PRAGMA yt.InferSchema = '1';
PRAGMA yt.UseNativeYtTypes;
PRAGMA Yson.AutoConvert;
PRAGMA yt.MaxRowWeight = "128M";

-- Здесь граф не нужен: диалоги с приклеенными ответами уже лежат в
-- final_messages_1 / final_messages_2, поэтому обе прежние стадии
-- (джойн ответов + прогон GraphExec) схлопываются в один SELECT.

-- ---------------------------------------------------------------------------
-- Константы input_meta. env / tags / tools зафиксированы по ТЗ, меняется
-- только instruct_id. Если tags когда-нибудь понадобится брать из строки —
-- достаточно заменить $tags на Yson::ConvertToStringList(meta["tags"]).
-- ---------------------------------------------------------------------------
$env = AsStruct("ContextManagerForceGeneration" AS overflow_strategy);
$tools = "default";
$tags = AsList(
    "urm_llm_tov_memory_basket_v1",
    "priemka",
    "split_gen_eval_priemka",
    "platform__desktop",
    "tov",
    "memory",
    "query"
);

-- Yson-энтити (`#`), он же null в JSON.
$null_yson = Yson::From(Nothing(String?));

-- ---------------------------------------------------------------------------
-- instruct_id пересобираем как md5 от диалогов, ответов и имён моделей:
-- исходный instruct_id в парной таблице может повторяться (один диалог —
-- несколько пар), а на выходе ключ обязан быть уникальным.
-- ---------------------------------------------------------------------------
$json = ($value) -> (CAST(Yson::SerializeJson($value) AS String) ?? "");

$make_instruct_id = ($fm1, $fm2, $src1, $src2, $a1, $a2) -> (Digest::Md5Hex(
    $json($fm1) || "\x1f" ||
    $json($fm2) || "\x1f" ||
    $src1 || "\x1f" || $src2 || "\x1f" ||
    $a1 || "\x1f" || $a2
));

-- Последняя реплика ассистента в input_final_messages не нужна: она и есть
-- ответ, который сравнивают. Берём диалог из первой модели без хвоста.
$drop_last = ($items) -> (ListTake(
    $items,
    IF(ListLength($items) > 0u, ListLength($items) - 1u, 0u)
));

$last_role = ($items) -> (Yson::LookupString(ListLast($items), "role") ?? "");

-- Один элемент списка answers в том же виде, что раньше собирал build_output.
$make_answer = ($final_messages, $answer_source, $render_data) -> (AsStruct(
    $final_messages AS final_messages,
    AsStruct(
        $env AS env,
        $tools AS tools,
        $tags AS tags
    ) AS meta,
    $render_data AS render_data,
    AsStruct($answer_source AS name) AS answer_producer,
    $null_yson AS answer_html_url
));

$rows = (
    SELECT
        $make_instruct_id(
            final_messages_1,
            final_messages_2,
            COALESCE(answer_source_1, ""),
            COALESCE(answer_source_2, ""),
            COALESCE(answer_1, ""),
            COALESCE(answer_2, "")
        ) AS instruct_id,
        Yson::ConvertToList(final_messages_1) AS fm1_items,
        Yson::ConvertToList(final_messages_2) AS fm2_items,
        COALESCE(answer_source_1, "") AS answer_source_1,
        COALESCE(answer_source_2, "") AS answer_source_2
    FROM $input1
);

-- ---------------------------------------------------------------------------
-- Проверки. Падаем на всей таблице, а не молча пишем битую корзину.
-- ---------------------------------------------------------------------------
$stats = (
    SELECT
        COUNT(*) AS row_count,
        COUNT(DISTINCT instruct_id) AS unique_count,
        COALESCE(SUM(IF(ListLength(fm1_items) > 1u, 0u, 1u)), 0u) AS short_dialog_count,
        COALESCE(SUM(IF(ListLength(fm2_items) > 0u, 0u, 1u)), 0u) AS empty_fm2_count,
        COALESCE(SUM(IF($last_role(fm1_items) == "assistant", 0u, 1u)), 0u) AS bad_tail_count,
        COALESCE(SUM(IF(answer_source_1 == "" OR answer_source_2 == "", 1u, 0u)), 0u) AS empty_source_count,
        COALESCE(SUM(IF(answer_source_1 == answer_source_2, 1u, 0u)), 0u) AS same_source_count
    FROM $rows
);

DISCARD SELECT Ensure(
    row_count,
    row_count > 0u AND row_count == unique_count,
    "instruct_id hash must be unique across the whole output"
)
FROM $stats;

DISCARD SELECT Ensure(
    row_count,
    short_dialog_count == 0u AND empty_fm2_count == 0u,
    "final_messages_1 must have at least two messages and final_messages_2 must be non-empty"
)
FROM $stats;

DISCARD SELECT Ensure(
    row_count,
    bad_tail_count == 0u,
    "last message of final_messages_1 must be the assistant answer"
)
FROM $stats;

DISCARD SELECT Ensure(
    row_count,
    empty_source_count == 0u AND same_source_count == 0u,
    "answer_source_1 / answer_source_2 must be non-empty and different"
)
FROM $stats;

-- ---------------------------------------------------------------------------
-- Канонический FM: ровно 4 верхнеуровневые колонки, ответы в порядке
-- answer_source_1 -> answer_source_2.
-- render_data у ответов нам взять неоткуда (граф не запускался), поэтому null;
-- если понадобится — подставить сюда колонку render_data из исходной таблицы.
-- ---------------------------------------------------------------------------
INSERT INTO $output1 WITH TRUNCATE
SELECT
    Yson::From(AsList(
        $make_answer(fm1_items, answer_source_1, $null_yson),
        $make_answer(fm2_items, answer_source_2, $null_yson)
    )) AS answers,
    Yson::From($drop_last(fm1_items)) AS input_final_messages,
    Yson::From(AsStruct(
        $env AS env,
        instruct_id AS instruct_id,
        $tags AS tags,
        $tools AS tools
    )) AS input_meta,
    $null_yson AS input_render_data
FROM $rows;
