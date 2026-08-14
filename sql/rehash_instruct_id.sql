-- Копия таблицы один-в-один: все строки и все колонки остаются как были,
-- меняется только instruct_id — вместо исходного значения кладём хэш
-- от содержимого задания (диалог + оба ответа + их источники).
--
-- Зачем: одинаковые по содержанию задания получают одинаковый instruct_id,
-- поэтому его можно использовать как ключ склейки между прогонами и пулами.
-- real_instruct_id не трогаем — исходный идентификатор остаётся в нём.

DECLARE $input1 AS String;
DECLARE $output1 AS String;

PRAGMA yt.InferSchema = "100";
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA yson.DisableStrict;
PRAGMA Yson.AutoConvert;
PRAGMA SimpleColumns;

-- Набор полей, от которых считается хэш. Чтобы добавить/убрать переменную,
-- правим только этот список и вызов $new_instruct_id ниже.
--
-- Собираем поля в структуру и сериализуем её в YSON: так корректно
-- обрабатываются NULL и вложенный dialog (List<Struct<content, role>>),
-- а порядок полей фиксирован — хэш детерминирован между запусками.
$key = ($dialog, $answer_1, $answer_2, $source_1, $source_2) -> {
    RETURN Yson::SerializeText(Yson::From(AsStruct(
        $dialog   AS dialog,
        $answer_1 AS answer_1,
        $answer_2 AS answer_2,
        $source_1 AS answer_source_1,
        $source_2 AS answer_source_2
    )));
};

-- Md5Hex даёт стабильную строку из 32 hex-символов, тип колонки остаётся String.
-- Если нужен числовой ключ (например, для шардирования) — замените на
-- Digest::CityHash($key(...)) и получите Uint64.
$new_instruct_id = ($dialog, $answer_1, $answer_2, $source_1, $source_2) -> {
    RETURN Digest::Md5Hex($key($dialog, $answer_1, $answer_2, $source_1, $source_2));
};

INSERT INTO $output1 WITH TRUNCATE
SELECT
    -- новая колонка идёт ДО t.*: WITHOUT обязан быть последним в списке
    $new_instruct_id(
        t.dialog,
        t.answer_1,
        t.answer_2,
        t.answer_source_1,
        t.answer_source_2
    ) AS instruct_id,
    -- чтобы сохранить исходный идентификатор рядом, раскомментируйте строку:
    -- t.instruct_id AS old_instruct_id,
    t.*,
    WITHOUT IF EXISTS t.instruct_id
FROM $input1 AS t;

-- Проверка на коллизии/схлопывание: сколько строк приходится на один новый id.
-- Раскомментируйте и подставьте отдельную выходную таблицу, если нужно.
-- SELECT
--     COUNT(*)                                 AS rows_total,
--     COUNT(DISTINCT instruct_id)              AS ids_new,
--     COUNT(DISTINCT real_instruct_id)         AS ids_real
-- FROM $output1;
