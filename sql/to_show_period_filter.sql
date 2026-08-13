PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA yt.UseNativeYtTypes;

DECLARE $input1 AS String;
DECLARE $table AS String;

$fmt_date = DateTime::Format("%Y-%m-%d");
$date_parse = DateTime::Parse("%Y-%m-%d");

$period_start_day = 22;
-- День отсечки в месяце окончания периода (вместо $period_end_day = 21)
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

-- 16-е число следующего месяца (месяца окончания периода)
$period_cutoff_date =
    $fmt_date(
        DateTime::MakeTzTimestamp(
            DateTime::Update($next_period_start_tm, $cutoff_day AS Day)
        )
    );

-- ===================== ПРИВЕДЕНИЕ ТИПОВ ПОД СХЕМУ ТАБЛИЦЫ =====================
-- Таблица-приёмник уже существует со строгой схемой, и INSERT (без TRUNCATE)
-- требует совпадения типов колонка в колонку. Расхождения:
--   * clarity/confusing/empathy/other_markers/subjectivity/templates/tone
--     приходят как String, а в таблице String? -> оборачиваем в Just();
--   * comment_judge_verdict/comment_score/what_to_improve/why_this_score
--     приходят как String?, а в таблице String -> снимаем Optional через COALESCE;
--   * comment_judge во входе целиком пустой, поэтому его тип выводится как Null,
--     а такой тип не присваивается Optional<Struct<...>> -> подставляем
--     типизированный NULL нужной структуры.
$comment_judge_type = ParseType(@@Struct<
    'editor_comment_evaluation': Struct<
        'evaluation_details': Struct<
            'what_to_improve': String?,
            'why_this_score': String?
        >,
        'final_verdict': String?,
        'overall_score': Int64?
    >
>?@@);

INSERT INTO $table
SELECT
    -- переопределённые колонки идут ДО t.*: WITHOUT обязан быть последним в списке
    Just(t.clarity)                        AS clarity,
    Just(t.confusing)                      AS confusing,
    Just(t.empathy)                        AS empathy,
    Just(t.other_markers)                  AS other_markers,
    Just(t.subjectivity)                   AS subjectivity,
    Just(t.templates)                      AS templates,
    Just(t.tone)                           AS tone,

    COALESCE(t.comment_judge_verdict, '')  AS comment_judge_verdict,
    COALESCE(t.comment_score, '')          AS comment_score,
    COALESCE(t.what_to_improve, '')        AS what_to_improve,
    COALESCE(t.why_this_score, '')         AS why_this_score,

    Nothing($comment_judge_type)           AS comment_judge,

    t.*,
    WITHOUT IF EXISTS
        t.clarity, t.confusing, t.empathy, t.other_markers, t.subjectivity,
        t.templates, t.tone,
        t.comment_judge_verdict, t.comment_score, t.what_to_improve, t.why_this_score,
        t.comment_judge
FROM $input1 AS t
WHERE
    -- Берем данные от 22 числа начального месяца
    String::Substring(CAST(t.editors_markup_dt AS String), 0, 10) >= $current_period_start_date
    -- И до 16 числа конечного месяца включительно
    AND String::Substring(CAST(t.editors_markup_dt AS String), 0, 10) <= $period_cutoff_date;
