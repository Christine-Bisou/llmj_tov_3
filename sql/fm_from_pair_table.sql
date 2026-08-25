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
-- instruct_id пересобираем как md5: исходный instruct_id в парной таблице
-- может повторяться (один диалог — несколько пар), а на выходе ключ обязан
-- быть уникальным.
--
-- В хеш идут только строковые колонки. Сериализовать сюда final_messages_1/2
-- дороже всего остального запроса вместе взятого, а различать строки они не
-- помогают: ответы в них те же самые, что в answer_1 / answer_2.
-- ---------------------------------------------------------------------------
$make_instruct_id = ($id, $src1, $src2, $a1, $a2) -> (Digest::Md5Hex(
    $id || "\x1f" || $src1 || "\x1f" || $src2 || "\x1f" || $a1 || "\x1f" || $a2
));

DEFINE SUBQUERY $ids() AS
    SELECT $make_instruct_id(
        COALESCE(t.instruct_id, ""),
        COALESCE(t.answer_source_1, ""),
        COALESCE(t.answer_source_2, ""),
        COALESCE(t.answer_1, ""),
        COALESCE(t.answer_2, "")
    ) AS instruct_id
    FROM $input1 AS t;
END DEFINE;

-- ---------------------------------------------------------------------------
-- Построчные проверки. Первая же битая строка роняет весь запрос — так мы не
-- пишем молча битую корзину и при этом не платим за отдельный проход по
-- Yson-колонкам ради подсчёта нарушений.
-- ---------------------------------------------------------------------------
$last_role = ($items) -> (Yson::LookupString(ListLast($items), "role") ?? "");

$check_fm1 = ($items) -> (Ensure(
    Ensure(
        $items,
        ListLength($items) > 1u,
        "final_messages_1 must contain at least two messages"
    ),
    $last_role($items) == "assistant",
    "last message of final_messages_1 must be the assistant answer"
));

$check_fm2 = ($items) -> (Ensure(
    $items,
    ListLength($items) > 0u,
    "final_messages_2 must be non-empty"
));

-- Симметричная проверка: вызывается для каждой из двух моделей.
$check_source = ($src, $other) -> (Ensure(
    Ensure($src, $src != "", "answer_source_1 / answer_source_2 must be non-empty"),
    $src != $other,
    "answer_source_1 and answer_source_2 must differ"
));

-- Последняя реплика ассистента в input_final_messages не нужна: она и есть
-- ответ, который сравнивают. Берём диалог первой модели без хвоста.
-- $check_fm1 уже гарантировал ListLength > 1, так что вычитание безопасно.
$drop_last = ($items) -> (ListTake($items, ListLength($items) - 1u));

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

-- ---------------------------------------------------------------------------
-- Единственная глобальная проверка: хеш обязан быть уникальным. Проход читает
-- только строковые колонки, Yson-блобы в него не попадают.
-- ---------------------------------------------------------------------------
$id_stats = (
    SELECT
        COUNT(*) AS row_count,
        COUNT(DISTINCT instruct_id) AS unique_count
    FROM $ids()
);

DISCARD SELECT Ensure(
    row_count,
    row_count > 0u AND row_count == unique_count,
    "instruct_id hash must be unique across the whole output"
)
FROM $id_stats;

-- ---------------------------------------------------------------------------
-- Канонический FM: ровно 4 верхнеуровневые колонки, ответы в порядке
-- answer_source_1 -> answer_source_2.
--
-- Всё считается в одном SELECT по входу без промежуточных таблиц: колонку
-- List<Yson> со строгим Yson в YT записать нельзя ("Strict Yson type is not
-- allowed to write"), а именованное выражение с такой колонкой YQL как раз и
-- материализовал бы во временную таблицу.
--
-- render_data у ответов взять неоткуда (граф не запускался), поэтому null;
-- если понадобится — подставить третьим аргументом $make_answer колонку
-- render_data из исходной таблицы.
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
FROM (
    -- Подзапрос в FROM сливается с внешним SELECT в одну map-операцию, так что
    -- каждый диалог парсится ровно один раз и никуда не выгружается.
    SELECT
        $make_instruct_id(
            COALESCE(t.instruct_id, ""),
            COALESCE(t.answer_source_1, ""),
            COALESCE(t.answer_source_2, ""),
            COALESCE(t.answer_1, ""),
            COALESCE(t.answer_2, "")
        ) AS instruct_id,
        $check_fm1(Yson::ConvertToList(t.final_messages_1)) AS fm1_items,
        $check_fm2(Yson::ConvertToList(t.final_messages_2)) AS fm2_items,
        $check_source(
            COALESCE(t.answer_source_1, ""),
            COALESCE(t.answer_source_2, "")
        ) AS answer_source_1,
        $check_source(
            COALESCE(t.answer_source_2, ""),
            COALESCE(t.answer_source_1, "")
        ) AS answer_source_2
    FROM $input1 AS t
) AS r;
