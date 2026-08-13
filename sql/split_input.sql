PRAGMA yt.InferSchema = "100";
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;
PRAGMA Yson.AutoConvert;
PRAGMA SimpleColumns;

DECLARE $input1 AS String;
DECLARE $output1 AS String;   -- диалоги
DECLARE $output2 AS String;   -- ответы первой модели
DECLARE $output3 AS String;   -- ответы второй модели

-- Обрезает хвост диалога так, чтобы последняя реплика была от пользователя:
-- оценивается ответ модели на последний запрос, поэтому реплики ассистента
-- в конце — это уже готовый ответ, которого джадж видеть не должен.
-- Список берётся префиксом, тип колонки не меняется — ниже по пайплайну
-- dialog остаётся нативным списком структур, а не Yson.
-- Если реплик пользователя в диалоге нет вообще, возвращается NULL.
$trim_dialog_to_user = ($dialog) -> {
    $user_indexes = ListMap(
        ListFilter(ListEnumerate($dialog), ($item) -> ($item.1.role == "user")),
        ($item) -> ($item.0)
    );
    $last_user_index = ListLast($user_indexes);
    RETURN IF(
        $last_user_index IS NOT NULL,
        ListTake($dialog, COALESCE($last_user_index, 0ul) + 1ul)
    );
};

$src = (
    SELECT
        CAST(instruct_id AS String)        AS instruct_id,
        dialog                             AS dialog,
        CAST(answer_1 AS Utf8)             AS answer_1,
        CAST(answer_2 AS Utf8)             AS answer_2,
        CAST(answer_source_1 AS String)    AS answer_source_1,
        CAST(answer_source_2 AS String)    AS answer_source_2
    FROM $input1
    WHERE dialog IS NOT NULL AND ListLength(dialog) > 0u
);

$trimmed = (
    SELECT
        instruct_id,
        $trim_dialog_to_user(Unwrap(dialog)) AS dialog,
        answer_1,
        answer_2,
        answer_source_1,
        answer_source_2
    FROM $src
);

-- Строки без реплик пользователя выкидываем из всех трёх выходов сразу,
-- иначе таблицы ответов разъедутся с таблицей диалогов.
$src_ok = (
    SELECT * FROM $trimmed
    WHERE dialog IS NOT NULL AND ListLength(dialog) > 0u
);

INSERT INTO $output1 WITH TRUNCATE
SELECT instruct_id, SOME(dialog) AS dialog
FROM $src_ok GROUP BY instruct_id ORDER BY instruct_id;

INSERT INTO $output2 WITH TRUNCATE
SELECT instruct_id, answer_1 AS answer, answer_source_1 AS answer_source
FROM $src_ok ORDER BY instruct_id;

INSERT INTO $output3 WITH TRUNCATE
SELECT instruct_id, answer_2 AS answer, answer_source_2 AS answer_source
FROM $src_ok ORDER BY instruct_id;
