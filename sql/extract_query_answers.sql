PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- сырая выгрузка: input, output, row_id, timestamp
DECLARE $output1 AS String;  -- плоская таблица: dialog, instruct, answers

$dialog_item_type = ParseType(@@Struct<'content':Utf8,'role':Utf8>@@);
$dialog_type = ParseType(@@List<Struct<'content':Utf8,'role':Utf8>>@@);
$empty_dialog = ListCreate($dialog_item_type);

$script = @@#py
import json
import re
from yql.typing import *


# Диалог в query склеен теми же маркерами, что и в pairwise_input.sql.
# Двоеточие ловим с любым числом пробелов перед ним.
_MARKER = re.compile(r'(Пользователь|Ассистент)\s*:')


def parse_dialog(query: Optional[Utf8]) -> Optional[Utf8]:
    """Разбирает склеенный query обратно в [{role, content}, ...].

    Пустые реплики выбрасываем: хвостовое «Ассистент:» — это приглашение
    для модели, а не сообщение диалога.
    Текст до первого маркера (если он есть) не сохраняем — роли у него нет.
    Маркер внутри пользовательского текста разрежет реплику: сам формат
    query это не различает, так что здесь ничего не поделать."""
    if query is None:
        return None
    text = query.decode('utf-8', errors='ignore') if isinstance(query, bytes) else str(query)
    if not text.strip():
        return None

    marks = list(_MARKER.finditer(text))
    if not marks:
        return json.dumps([{'role': 'user', 'content': text.strip()}], ensure_ascii=False)

    out = []
    for i, m in enumerate(marks):
        end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
        content = text[m.end():end].strip()
        if not content:
            continue
        role = 'user' if m.group(1) == 'Пользователь' else 'assistant'
        out.append({'role': role, 'content': content})

    return json.dumps(out, ensure_ascii=False)
@@;

$parse_dialog = Python3::parse_dialog($script);

-- Если input/output приехали строками, а не Yson (зависит от схемы выгрузки),
-- оберните их здесь: $node = ($v) -> { RETURN Yson::Parse(CAST($v AS String)) };
$node = ($v) -> { RETURN $v };

$str = ($n, $key) -> { RETURN Yson::LookupString($node($n), $key) };

$to_dialog = ($json) -> {
    RETURN Yson::ConvertTo(
        Yson::ParseJson($json),
        $dialog_type,
        Yson::Options(false as Strict)
    ) ?? $empty_dialog;
};

-- instruct — последний запрос пользователя, без хвостового «Ассистент:»
$instruct = ($dialog) -> {
    RETURN ListLast(
        ListExtract(
            ListFilter($dialog, ($m) -> { RETURN $m.role == 'user' }),
            'content'
        )
    );
};

-- ответов в норме один, но колонка в выгрузке — список
$answers = ($out) -> {
    RETURN Yson::ConvertToStringList(Yson::Lookup($node($out), 'answers')) ?? ListCreate(String);
};

$parsed = (
    SELECT
        t.*,
        $to_dialog($parse_dialog(CAST($str(t.input, 'query') AS Utf8))) AS dialog
    FROM $input1 AS t
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    p.row_id                                AS row_id,
    p.timestamp                             AS timestamp,

    p.dialog                                AS dialog,
    $instruct(p.dialog)                     AS instruct,
    -- исходная склейка на случай, если разбор где-то разъедется
    $str(p.input, 'query')                  AS query,

    ListHead($answers(p.output))            AS answer,
    $answers(p.output)                      AS answers,
    ListLength($answers(p.output))          AS answers_cnt,

    -- параметры прогона: пригодятся для группировки метрик
    $str(p.input, 'vendor')                 AS vendor,
    $str(p.input, 'model_type')             AS model_type,
    $str(p.input, 'locale_code')            AS locale_code,
    Yson::LookupBool($node(p.input), 'thinking_enabled') AS thinking_enabled,
    Yson::LookupBool($node(p.input), 'search')           AS search,

    $str(p.output, 'account')               AS account,
    -- page_source не берём: это вся страница целиком, ссылки на s3 достаточно
    $str(p.output, 's3_page_source')        AS s3_page_source,
    $str(p.output, 'hitrenimals_uuid')      AS hitrenimals_uuid,

    Yson::ConvertToDouble(Yson::Lookup($node(p.output), 'timings.query_sent')) AS query_sent,
    Yson::ConvertToDouble(Yson::Lookup($node(p.output), 'timings.answer_end')) AS answer_time
FROM $parsed AS p;
