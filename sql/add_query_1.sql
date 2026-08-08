PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

-- Добавляет query_1 — первый запрос пользователя из диалога.
-- instruct — последний запрос, query_1 — первый; на одноходовых диалогах
-- они совпадают.
DECLARE $input1 AS String;   -- таблица с колонкой dialog
DECLARE $output1 AS String;

$empty_dialog = ListCreate(ParseType(@@Struct<'content':Utf8,'role':Utf8>@@));

-- Системный промпт пропускаем: он лежит первым элементом, но запросом не является.
$user_turns = ($dialog) -> {
    RETURN ListExtract(
        ListFilter($dialog ?? $empty_dialog, ($m) -> { RETURN $m.role == 'user' }),
        'content'
    );
};

INSERT INTO $output1 WITH TRUNCATE
SELECT
    ListHead($user_turns(t.dialog))     AS query_1,
    -- сколько всего запросов в диалоге: одноход это или переписка
    ListLength($user_turns(t.dialog))   AS user_turns_cnt,

    t.* WITHOUT if exists t._other
FROM $input1 AS t;
