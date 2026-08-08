PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA yt.UseNativeYtTypes;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

-- Выгрузка, где диалог уже лежит структурой, а на пару ответов приходится
-- одна строка: answers, input_final_messages, input_meta, input_render_data.
DECLARE $input1 AS String;
DECLARE $output1 AS String;  -- instruct, model_1/model_2, answer_1/answer_2

$msg_type = ParseType(@@Struct<'content':Utf8,'role':Utf8>@@);
$dialog_type = ParseType(@@List<Struct<'content':Utf8,'role':Utf8>>@@);
$empty_dialog = ListCreate($msg_type);

-- Нестрогий режим: extra_info, thought, answer_html_url, meta, render_data
-- в схему не входят и просто отбрасываются.
$answer_type = ParseType(@@Struct<
    'answer_producer':Struct<'name':Utf8>,
    'final_messages':List<Struct<'content':Utf8,'role':Utf8>>
>@@);
$answers_type = ParseType(@@List<Struct<
    'answer_producer':Struct<'name':Utf8>,
    'final_messages':List<Struct<'content':Utf8,'role':Utf8>>
>>@@);
$empty_answers = ListCreate($answer_type);

-- Если колонки приехали строками, а не Yson (зависит от схемы выгрузки),
-- оберните их здесь: $node = ($v) -> { RETURN Yson::Parse(CAST($v AS String)) };
$node = ($v) -> { RETURN $v };

$to_dialog = ($v) -> {
    RETURN Yson::ConvertTo($node($v), $dialog_type, Yson::Options(false as Strict)) ?? $empty_dialog;
};

-- последняя реплика заданной роли; '' вместо NULL, чтобы список ответов
-- оставался List<Utf8> и после взятия элемента не появлялся двойной Optional
$last_of_role = ($msgs, $role) -> {
    RETURN ListLast(
        ListExtract(
            ListFilter($msgs, ($m) -> { RETURN $m.role == $role }),
            'content'
        )
    ) ?? CAST('' AS Utf8);
};

$nth = ($list, $i) -> { RETURN ListHead(ListSkip($list, $i)) };

$producers = ($items) -> {
    RETURN ListMap($items, ($a) -> { RETURN $a.answer_producer.name });
};

$replies = ($items) -> {
    RETURN ListMap($items, ($a) -> { RETURN $last_of_role($a.final_messages, 'assistant') });
};

$parsed = (
    SELECT
        t.*,
        $to_dialog(t.input_final_messages) AS dialog,
        Yson::ConvertTo($node(t.answers), $answers_type, Yson::Options(false as Strict))
            ?? $empty_answers AS answer_items
    FROM $input1 AS t
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    -- ключ пары: по нему склеиваются прогоны в pairwise_merge.sql
    Yson::LookupString($node(p.input_meta), 'instruct_id') AS instruct_id,

    p.dialog                                AS dialog,
    -- последний запрос пользователя
    $last_of_role(p.dialog, 'user')         AS instruct,

    -- порядок ответов сохраняем как в answers: первый — model_1, второй — model_2
    $nth($producers(p.answer_items), 0)     AS model_1,
    $nth($producers(p.answer_items), 1)     AS model_2,
    $nth($replies(p.answer_items), 0)       AS answer_1,
    $nth($replies(p.answer_items), 1)       AS answer_2,

    -- в норме ответов ровно два; если нет — строку видно по этой колонке
    ListLength(p.answer_items)              AS answers_cnt,

    -- сырые колонки не тащим: render_data и final_messages ответов весят много,
    -- всё нужное из них уже разложено выше
    p.* WITHOUT if exists p._other, p.dialog, p.answer_items, p.answers,
                p.input_final_messages, p.input_render_data
FROM $parsed AS p;
