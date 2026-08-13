-- Конвертация корзины диалогов в каноническую FM-корзину.
-- На вход ожидаются ровно две колонки: instruct_id и dialog.

DECLARE $input1 AS String;
DECLARE $output1 AS String;

PRAGMA yt.InferSchema = '1';
PRAGMA yt.UseNativeYtTypes;
PRAGMA Yson.AutoConvert;
PRAGMA yt.DefaultMaxJobFails = "1";

$region_id = 213;

-- dialog приходит как Optional<Yson> (InferSchema не типизирует вложенный
-- список), поэтому разбираем его Yson-функциями, а не list-функциями.
$messages_of = ($dialog) -> (Yson::ConvertToList(Yson::Parse($dialog)));
$dialog_text = ($dialog) -> (Yson::SerializeText(Yson::Parse($dialog)));
$last_role_of = ($dialog) -> (
    Yson::LookupString(Unwrap(ListLast(Unwrap($messages_of($dialog)))), "role")
);

$convert_dialog = ($dialog, $instruct_id) -> {
    $messages = Unwrap($messages_of($dialog));
    $last_message = Unwrap(ListLast($messages));
    $tags = AsList(
        "urm_llm_tov_gs_refilled_basket_v1",
        "priemka",
        "split__gen_eval_priemka",
        "platform__desktop",
        "tov",
        IF(ListLength($messages) == 1u, "query", "dialog")
    );

    $input_final_messages = Yson::From(ListExtend(
        [
            Yson::From(<|
                role: "system",
                content: "default",
                extra_info: <|type: "system_prompt"|>
            |>)
        ],
        ListMap(
            ListTake($messages, ListLength($messages) - 1u),
            ($message) -> (Yson::Serialize($message))
        ),
        [
            Yson::From(<|
                role: Unwrap(Yson::LookupString($last_message, "role")),
                content: Unwrap(Yson::LookupString($last_message, "content")),
                extra_info: <|
                    region_id: CAST($region_id AS String),
                    region_name: Geo::RegionById($region_id).en_name,
                    timestamp_seconds: CAST(DateTime::ToSeconds(CurrentUtcDatetime()) AS Uint32),
                    user_latitude: Geo::RegionById($region_id).latitude,
                    user_longitude: Geo::RegionById($region_id).longitude,
                    input_type: "text",
                    voice_output: "false",
                    device: "DESKTOP"
                |>
            |>)
        ]
    ));

    $input_meta = Yson::From(<|
        instruct_id: $instruct_id,
        tools: "default",
        env: <|overflow_strategy: "ContextManagerForceGeneration"|>,
        tags: $tags
    |>);

    RETURN AsTuple($input_final_messages, $input_meta);
};

$source = (
    SELECT
        TablePath() AS source_table,
        instruct_id,
        dialog,
    FROM $input1
);

$source_stats = (
    SELECT
        COUNT(*) AS row_count,
        COUNT(DISTINCT source_table) AS source_table_count,
        COALESCE(SUM(IF(instruct_id IS NULL OR instruct_id == "", 1u, 0u)), 0u) AS empty_key_count
    FROM $source
);

$valid_dialogs = (
    SELECT
        instruct_id,
        dialog
    FROM $source
    WHERE dialog IS NOT NULL
        AND ListLength($messages_of(dialog)) > 0u
);

$dialog_stats = (
    SELECT
        COUNT(*) AS row_count,
        COALESCE(SUM(IF(($last_role_of(dialog) == "user") ?? false, 0u, 1u)), 0u) AS bad_last_role_count
    FROM $valid_dialogs
);

-- Один instruct_id — одна строка в корзине: дубли схлопываем детерминированно
-- по тексту диалога.
$ranked_dialogs = (
    SELECT
        instruct_id,
        dialog,
        ROW_NUMBER() OVER (
            PARTITION BY instruct_id
            ORDER BY $dialog_text(dialog)
        ) AS duplicate_rank
    FROM $valid_dialogs
);

$deduplicated_dialogs = (
    SELECT
        instruct_id,
        dialog,
    FROM $ranked_dialogs
    WHERE duplicate_rank == 1u
);

DISCARD SELECT Ensure(
    source_stats.row_count,
    source_stats.row_count > 0u
        AND source_stats.source_table_count == 1u
        AND source_stats.empty_key_count == 0u,
    "Exactly one non-empty basket table with non-empty instruct_id values is required"
)
FROM $source_stats AS source_stats;

DISCARD SELECT Ensure(
    source_stats.row_count,
    source_stats.row_count == dialog_stats.row_count
        AND dialog_stats.bad_last_role_count == 0u,
    "Every basket row must contain a non-empty dialog ending with a user message"
)
FROM $source_stats AS source_stats
CROSS JOIN $dialog_stats AS dialog_stats;

$converted = (
    SELECT
        $convert_dialog(dialog, Unwrap(instruct_id)) AS fm
    FROM $deduplicated_dialogs
);

-- Каноническая FM-корзина без ответов: только 3 верхнеуровневые колонки.
INSERT INTO $output1 WITH TRUNCATE
SELECT
    fm.0 AS input_final_messages,
    fm.1 AS input_meta,
    Nothing(Yson?) AS input_render_data
FROM $converted;
