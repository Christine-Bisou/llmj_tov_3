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

-- В исходной таблице dialog лежит как Yson, а канонический конвертер корзины
-- работает со списком структур (ListLength(dialog), ListLast(dialog).role,
-- ListMap(dialog, ...)). Приводим тип здесь, чтобы ниже по пайплайну ничего
-- не разбирало Yson руками.
-- Поля объявлены необязательными намеренно: конвертер сравнивает роль внутри
-- IF (`... .role == "user"`), а Optional<Bool> там не проходит типизацию.
-- content объявлен текстом: корзина текстовая. Строки, где content не текст
-- (мультимодальный список частей с картинками) или где нет role/content,
-- при yson.DisableStrict дадут NULL и отфильтруются ниже, а не поедут
-- в корзину покорёженными.
$dialog_type = ParseType("List<Struct<content:Utf8,role:String>>");

-- Обрезает хвост диалога так, чтобы последняя реплика была от пользователя:
-- оценивается ответ модели на последний запрос, поэтому реплики ассистента
-- в конце — это уже готовый ответ, которого джадж видеть не должен.
-- Если реплик пользователя в диалоге нет вообще, возвращается NULL.
$trim_dialog_to_user = ($dialog) -> {
    -- роли достаём отдельным списком: обращение вида $item.1.role парсер
    -- читает как число с точкой и падает
    $roles = ListMap($dialog, ($message) -> ($message.role));
    $user_indexes = ListMap(
        ListFilter(ListEnumerate($roles), ($item) -> ($item.1 == "user")),
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
        CAST(instruct_id AS String)                AS instruct_id,
        Yson::ConvertTo(dialog, $dialog_type)      AS dialog,
        CAST(answer_1 AS Utf8)                     AS answer_1,
        CAST(answer_2 AS Utf8)                     AS answer_2,
        CAST(answer_source_1 AS String)            AS answer_source_1,
        CAST(answer_source_2 AS String)            AS answer_source_2
    FROM $input1
    WHERE dialog IS NOT NULL
);

-- Не разобравшиеся и пустые диалоги отбрасываем: дальше работаем
-- с гарантированно непустым списком.
$parsed = (
    SELECT * FROM $src
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
    FROM $parsed
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
