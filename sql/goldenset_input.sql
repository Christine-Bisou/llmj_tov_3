-- Вход для разметки из одной таблицы: ответ ровно один, поэтому он дублируется
-- в answer_1 и answer_2 — формат разметки всегда ждёт пару. Ключ склейки — instruct_id.
--
-- В колонке right_answer лежит структура вида:
--   {
--     "html_url": "...",
--     "version": "",
--     "neuro_alice_md_raw": "...",
--     "neuro_alice_md_raw_wout_reasoning": "...",   <- сам текст ответа
--     "meta": {"rn_meta": "...", "answer_producer": "S/GEN_APRIL_WEAK_PLAN_1504"}
--   }                                                        ^- отсюда берём source

PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA yt.UseNativeYtTypes;

DECLARE $input1 AS String;
DECLARE $output1 AS String;  -- оригинал входа
DECLARE $output2 AS String;  -- сконвертированный вход для разметки

$input1_ =
  SELECT
    target_markup,
    generator_dialog_json,
    right_answer,
    right_final_content_sources_json,
    session_id
  FROM $input1;

-- диалог: только content и role, остальные поля сообщения (extra_info и прочее) отбрасываем
$dialog = ($d) -> {
    RETURN ListMap(
        Yson::ConvertToList($d['messages']),
        ($m) -> {
            RETURN AsStruct(
                -- у мультимодальных реплик content — список частей, а не строка:
                -- такие оставляем json-ом, иначе ConvertToString вернёт NULL
                (Yson::ConvertToString($m['content'])
                    ?? CAST(Yson::SerializeJson($m['content']) AS String)) AS content,
                Yson::ConvertToString($m['role']) AS role
            );
        }
    );
};

-- текст ответа из структуры
$answer_text = ($a) -> {
    RETURN Yson::ConvertToString($a['neuro_alice_md_raw'])
        ?? Yson::ConvertToString($a['neuro_alice_md_raw_wout_reasoning']);
};

-- продюсер из meta — он же становится source
$answer_source = ($a) -> {
    RETURN Yson::LookupString(Yson::Lookup($a, 'meta'), 'answer_producer') ?? 'gs';
};

$t =
  SELECT
    t.target_markup AS target_markup,
    $dialog(t.generator_dialog_json) AS dialog,
    t.generator_dialog_json.meta AS meta,
    t.generator_dialog_json AS generator_dialog_json,
    t.session_id AS session_id,
    String::HexEncode(Digest::Sha256(ToBytes(Yson::SerializePretty(Yson::From(TableRow()))))) AS instruct_id,
    $answer_text(t.right_answer) AS answer_text,
    $answer_source(t.right_answer) AS answer_source,
    t.right_final_content_sources_json AS final_content_sources_json,
  FROM $input1_ AS t;

-- Оригинал входа: один и тот же ответ разложен в обе колонки.
-- В answer_* лежит текст ответа, а не структура; продюсер вынесен в answer_source_*
INSERT INTO $output1
SELECT
  instruct_id,
  session_id,
  target_markup,
  generator_dialog_json,
  final_content_sources_json AS final_content_sources_json_1,
  answer_text AS answer_1,
  answer_source AS answer_source_1,
  final_content_sources_json AS final_content_sources_json_2,
  answer_text AS answer_2,
  answer_source AS answer_source_2
FROM $t;

-- Сконвертированный вход для разметки
INSERT INTO $output2
SELECT
  instruct_id,
  dialog,
  meta,
  answer_text AS answer_1,
  answer_source AS answer_source_1,
  answer_text AS answer_2,
  answer_source AS answer_source_2
FROM $t;
