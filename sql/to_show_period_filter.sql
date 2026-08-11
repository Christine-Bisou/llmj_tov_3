PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;

DECLARE $input1 AS String;
DECLARE $table AS String;
DECLARE $output1 AS String;

$fmt_date = DateTime::Format("%Y-%m-%d");
$date_parse = DateTime::Parse("%Y-%m-%d");

$period_start_day = 22;
-- Добавляем день отсечки (вместо $period_end_day = 21)
$cutoff_day = 16;

$run_date = '${global.date}';

$run_date_tm =
    DateTime::Update(
        $date_parse($run_date),
        "Europe/Moscow" AS Timezone
    );

$today_day = DateTime::GetDayOfMonth($run_date_tm);

$current_period_start_tm =
    CASE
        WHEN $today_day >= $period_start_day THEN
            DateTime::Update(
                DateTime::StartOfMonth($run_date_tm),
                $period_start_day AS Day
            )
        ELSE
            DateTime::Update(
                DateTime::ShiftMonths(DateTime::StartOfMonth($run_date_tm), -1),
                $period_start_day AS Day
            )
    END;

$next_period_start_tm = DateTime::ShiftMonths($current_period_start_tm, 1);

$current_period_start_date =
    $fmt_date(DateTime::MakeTzTimestamp($current_period_start_tm));

-- Рассчитываем 16-е число следующего месяца (месяца окончания периода)
$period_cutoff_date =
    $fmt_date(
        DateTime::MakeTzTimestamp(
            DateTime::Update($next_period_start_tm, $cutoff_day AS Day)
        )
    );

-- ===================== ПРИВЕДЕНИЕ ТИПОВ ПОД СХЕМУ ПРИЁМНИКА =====================
-- SELECT * писать в существующую таблицу нельзя: у части колонок источника
-- и приёмника различается optional-ность, а comment_judge в источнике имеет
-- тип Null (колонка всегда пустая) вместо Optional<Struct<...>>.
-- Поэтому проблемные колонки перечисляем явно, остальные забираем через t.*.
-- Тип comment_judge берём ровно тот, что объявлен в схеме $table.
$comment_judge_type = ParseType(@@Optional<Struct<
    'editor_comment_evaluation': Struct<
        'evaluation_details': Struct<
            'what_to_improve': String?,
            'why_this_score': String?
        >,
        'final_verdict': String?,
        'overall_score': Int64?
    >
>>@@);

INSERT INTO $table
SELECT
    -- В источнике String, в таблице Optional<String>
    Just(t.clarity)       AS clarity,
    Just(t.confusing)     AS confusing,
    Just(t.empathy)       AS empathy,
    Just(t.other_markers) AS other_markers,
    Just(t.subjectivity)  AS subjectivity,
    Just(t.templates)     AS templates,
    Just(t.tone)          AS tone,

    -- В источнике Optional<String>, в таблице String
    COALESCE(t.comment_judge_verdict, '') AS comment_judge_verdict,
    COALESCE(t.comment_score, '')         AS comment_score,
    COALESCE(t.what_to_improve, '')       AS what_to_improve,
    COALESCE(t.why_this_score, '')        AS why_this_score,

    -- В источнике Null, в таблице Optional<Struct<...>>
    Nothing($comment_judge_type) AS comment_judge,

    -- дополнительные колонки идут ДО t.*: WITHOUT обязан быть последним в списке
    t.*
    WITHOUT
        t.clarity, t.confusing, t.empathy, t.other_markers, t.subjectivity,
        t.templates, t.tone,
        t.comment_judge_verdict, t.comment_score,
        t.what_to_improve, t.why_this_score,
        t.comment_judge
FROM $input1 AS t
WHERE
    -- Берем данные от 22 числа начального месяца
    String::Substring(CAST(t.editors_markup_dt AS String), 0, 10) >= $current_period_start_date
    -- И строго до 16 числа конечного месяца включительно
    AND String::Substring(CAST(t.editors_markup_dt AS String), 0, 10) <= $period_cutoff_date;
