PRAGMA Yson.AutoConvert;
PRAGMA yson.DisableStrict;
PRAGMA SimpleColumns;
PRAGMA AnsiOptionalAs;
PRAGMA AnsiInForEmptyOrNullableItemsCollections;
PRAGMA yt.InferSchema = '1';

DECLARE $input1 AS String;   -- полный прогон: instruct_id, winner, tov_winner, meta_info, answer_source_1/2
DECLARE $input2 AS String;   -- сырой выход третьего прохода по близким парам: instruct_id, dst, dst_2
DECLARE $output1 AS String;  -- полная таблица со всеми вариантами склейки
DECLARE $output2 AS String;  -- сравнение правил склейки

-- какое правило кладём в итоговую колонку tov_winner: 'A' | 'A_high' | 'B' | 'C'
$rule = 'A';

$script = @@#py
import json
import cyson


# Достаёт winner/confidence из ответа сравнительного джаджа.
# Дешёвые модели любят обрамлять JSON текстом и markdown — это учтено.
# В докстринге только сигнатура: лишний текст YQL не переваривает.
def parse_pairwise(s):
    """
    (String?) -> Yson?
    """
    if s is None:
        return None
    if isinstance(s, bytes):
        s = s.decode('utf-8', errors='ignore')
    else:
        s = str(s)

    s = s.strip()
    if s.startswith('```json'):
        s = s[7:]
    elif s.startswith('```'):
        s = s[3:]
    if s.endswith('```'):
        s = s[:-3]
    s = s.strip()

    i, j = s.find('{'), s.rfind('}')
    if i != -1 and j != -1 and j > i:
        s = s[i:j + 1]

    try:
        d = json.loads(s, strict=False)
    except Exception:
        return None
    if not isinstance(d, dict):
        return None

    w = str(d.get('winner') or '').strip().lower()
    if w not in ('model_1', 'model_2', 'tie'):
        w = 'tie'
    c = str(d.get('confidence') or '').strip().lower()
    if c not in ('high', 'low'):
        c = 'low'

    return cyson.dumps({
        'winner': w,
        'confidence': c,
        'reason': str(d.get('reason') or ''),
    })
@@;

$parse = Python3::parse_pairwise($script);

-- в обратном проходе model_1 означает answer_2
$flip = ($v) -> {
    RETURN CASE WHEN $v = 'model_1' THEN 'model_2'
                WHEN $v = 'model_2' THEN 'model_1'
                ELSE 'tie' END;
};

-- та же склейка прямого и обратного, что и на втором этапе
$merge_two = ($a, $b) -> {
    RETURN CASE WHEN $a = $b                  THEN $a
                WHEN $a IN ('tie', 'draw')    THEN $b
                WHEN $b IN ('tie', 'draw')    THEN $a
                ELSE 'draw' END;
};

$norm = ($v) -> {
    RETURN CASE WHEN $v IS NULL OR $v IN ('tie', 'both_bad', 'skip', '') THEN 'draw' ELSE $v END;
};

-- золото приводим к model_1/model_2/draw через источники ответов
$gold = ($w, $s1, $s2) -> {
    RETURN CASE WHEN $w IS NULL                    THEN 'draw'
                WHEN $w IN ('draw', 'both_bad')    THEN 'draw'
                WHEN $w IN ('model_1', 'model_2')  THEN $w
                WHEN $w = $s1                      THEN 'model_1'
                WHEN $w = $s2                      THEN 'model_2'
                ELSE 'draw' END;
};

$vote = ($a, $b, $c) -> {
    $n1 = IF($a = 'model_1', 1, 0) + IF($b = 'model_1', 1, 0) + IF($c = 'model_1', 1, 0);
    $n2 = IF($a = 'model_2', 1, 0) + IF($b = 'model_2', 1, 0) + IF($c = 'model_2', 1, 0);
    RETURN CASE WHEN $n1 > $n2 THEN 'model_1'
                WHEN $n2 > $n1 THEN 'model_2'
                ELSE 'draw' END;
};

$score = ($pred, $g) -> {
    RETURN IF($pred = $g, 1.0, IF($pred = 'draw' OR $g = 'draw', 0.5, 0.0));
};

$joined = (
    SELECT
        a.*,

        $gold(CAST(a.winner AS String),
              CAST(a.answer_source_1 AS String),
              CAST(a.answer_source_2 AS String))              AS gold,

        $norm(CAST(a.tov_winner AS String))                   AS v_base,

        -- вердикты второго этапа по проходам, нужны для голосования
        $norm(Yson::LookupString(a.meta_info, 'model_winner_direct'))              AS v2_direct,
        $norm(Yson::LookupString(a.meta_info, 'model_winner_reversed_normalized')) AS v2_rev,

        -- третий проход: прямой порядок как есть, обратный — с разворотом
        Yson::LookupString($parse(CAST(b.dst   AS String)), 'winner')     AS p3_direct_raw,
        Yson::LookupString($parse(CAST(b.dst_2 AS String)), 'winner')     AS p3_rev_raw,
        Yson::LookupString($parse(CAST(b.dst   AS String)), 'confidence') AS p3_conf_direct,
        Yson::LookupString($parse(CAST(b.dst_2 AS String)), 'confidence') AS p3_conf_rev,
        Yson::LookupString($parse(CAST(b.dst   AS String)), 'reason')     AS p3_reason,

        IF(b.instruct_id IS NULL, false, true)                AS routed
    FROM $input1 AS a
    LEFT JOIN $input2 AS b USING (instruct_id)
);

$enriched = (
    SELECT
        j.*,
        $merge_two(COALESCE(p3_direct_raw, 'tie'), $flip(COALESCE(p3_rev_raw, 'tie'))) AS p3,
        IF(p3_conf_direct = 'high' AND p3_conf_rev = 'high', 'high', 'low')            AS p3_conf
    FROM $joined AS j
);

$rules = (
    SELECT
        e.*,
        -- A: на маршрутизированных парах заменяем вердикт второго этапа
        IF(routed AND p3 IN ('model_1', 'model_2'), p3, v_base)                       AS rule_a,
        -- A_high: заменяем только когда оба прохода третьего судьи уверены
        IF(routed AND p3_conf = 'high' AND p3 IN ('model_1', 'model_2'), p3, v_base)  AS rule_a_high,
        -- B: вето — не согласен с прежним вердиктом, значит ничья
        IF(routed AND p3 IN ('model_1', 'model_2') AND p3 != v_base, 'draw', v_base)  AS rule_b,
        -- C: большинство из трёх голосов
        IF(routed, $vote(v2_direct, v2_rev, p3), v_base)                              AS rule_c
    FROM $enriched AS e
);

INSERT INTO $output1 WITH TRUNCATE
SELECT
    r.* WITHOUT if exists r._other, r.tov_winner,
    CAST(r.v_base AS String) AS tov_winner_stage2,
    -- итоговый вердикт под выбранное правило: колонка называется как раньше,
    -- чтобы скрипт метрики завёлся без правок
    CASE $rule
        WHEN 'A'      THEN r.rule_a
        WHEN 'A_high' THEN r.rule_a_high
        WHEN 'B'      THEN r.rule_b
        WHEN 'C'      THEN r.rule_c
        ELSE r.v_base
    END AS tov_winner
FROM $rules AS r;

-- Сравнение правил: сначала по всей выборке, потом только по пересуженным парам
INSERT INTO $output2 WITH TRUNCATE
SELECT
    'вся выборка'                        AS scope,
    COUNT(*)                             AS cnt,
    AVG($score(v_base,     gold))        AS base_stage2,
    AVG($score(rule_a,     gold))        AS rule_a,
    AVG($score(rule_a_high, gold))       AS rule_a_high,
    AVG($score(rule_b,     gold))        AS rule_b,
    AVG($score(rule_c,     gold))        AS rule_c,
    AVG(IF(routed, 1.0, 0.0))            AS routed_share,
    AVG(IF(routed AND p3 = v_base, 1.0, 0.0)) AS p3_agrees_with_stage2
FROM $rules

UNION ALL

SELECT
    'только пересуженные'                AS scope,
    COUNT(*)                             AS cnt,
    AVG($score(v_base,     gold))        AS base_stage2,
    AVG($score(rule_a,     gold))        AS rule_a,
    AVG($score(rule_a_high, gold))       AS rule_a_high,
    AVG($score(rule_b,     gold))        AS rule_b,
    AVG($score(rule_c,     gold))        AS rule_c,
    AVG(IF(routed, 1.0, 0.0))            AS routed_share,
    AVG(IF(p3 = v_base, 1.0, 0.0))       AS p3_agrees_with_stage2
FROM $rules
WHERE routed;
